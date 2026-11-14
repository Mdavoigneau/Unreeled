import Foundation

/// Where the app takes pictures and videos from: Instagram's own servers for them, over https.
///
/// Their links come in Instagram's answers, some of them in messages other people send, and the
/// app loads many ahead, before anything is opened. A link to any other server would tell that
/// server you have the message, and it could send anything: such links aren't loaded. What is
/// loaded has a size limit too.
enum MediaHosts {
    /// Instagram's and Facebook's servers for pictures and videos, Facebook's for files sent in
    /// messages, and Instagram's own (the icons on shared links come from i.instagram.com).
    private static let domains = ["cdninstagram.com", "fbcdn.net", "fbsbx.com", "instagram.com"]

    /// A link the app may load a picture or video from.
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Larger than a picture or video of its kind can be.
    struct TooLarge: Error {}

    /// Downloads `url` and hands its body to `take` in pieces as it comes, `limit` bytes in all at
    /// most. `accept` looks at the response first: one it turns down is stopped before its body
    /// comes, and so is one that says it's larger than `limit`. One that turns out larger is
    /// stopped there.
    static func download(
        _ url: URL, session: URLSession, limit: Int,
        accept: (HTTPURLResponse) -> Bool, take: (Data) throws -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        do {
            guard let http = response as? HTTPURLResponse, accept(http) else { throw URLError(.badServerResponse) }
            guard http.expectedContentLength <= Int64(limit) else { throw TooLarge() }
            let pieceSize = 64 << 10
            var piece = Data()
            piece.reserveCapacity(pieceSize)
            var total = 0
            for try await byte in bytes {
                piece.append(byte)
                guard piece.count == pieceSize else { continue }
                total += piece.count
                guard total <= limit else { throw TooLarge() }
                try take(piece)
                piece.removeAll(keepingCapacity: true)
            }
            total += piece.count
            guard total <= limit else { throw TooLarge() }
            if !piece.isEmpty { try take(piece) }
        } catch {
            bytes.task.cancel()
            throw error
        }
    }
}

/// For the sessions that download pictures and videos: a redirect is followed only to where they
/// may come from. Otherwise the redirect itself is the answer, which isn't a picture.
final class MediaRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, MediaHosts.allows(url) else { return nil }
        return request
    }
}
