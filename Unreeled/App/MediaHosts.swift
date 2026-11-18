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

    /// Downloads `url` and hands its body to `take` in pieces as they come, `limit` bytes in all at
    /// most. `accept` looks at the response first: one it turns down is stopped before its body
    /// comes, and so is one that says it's larger than `limit`. One that turns out larger is
    /// stopped there. The pieces are as the connection delivers them, tens of kilobytes each, on
    /// the session's own queue, one at a time. Cancelling the task that waits for it stops the
    /// download.
    static func download(
        _ url: URL, session: URLSession, limit: Int,
        accept: @escaping (HTTPURLResponse) -> Bool, take: @escaping (Data) throws -> Void
    ) async throws {
        let receiver = Receiver(limit: limit, accept: accept, take: take)
        let task = session.dataTask(with: url)
        // The task's own delegate: the session's still decides where a redirect may lead.
        task.delegate = receiver
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Takes a download's pieces as they arrive, and says how it ended.
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let accept: (HTTPURLResponse) -> Bool
        private let take: (Data) throws -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        // Only touched on the session's queue, one call at a time.
        private var received = 0
        private var failure: Error?

        init(limit: Int, accept: @escaping (HTTPURLResponse) -> Bool, take: @escaping (Data) throws -> Void) {
            self.limit = limit
            self.accept = accept
            self.take = take
        }

        func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
            task.resume()
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, accept(http) else {
                failure = URLError(.badServerResponse)
                return completionHandler(.cancel)
            }
            guard http.expectedContentLength <= Int64(limit) else {
                failure = TooLarge()
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            received += data.count
            guard received <= limit else {
                failure = TooLarge()
                return dataTask.cancel()
            }
            do {
                try take(data)
            } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            if let failure = failure ?? error {
                continuation?.resume(throwing: failure)
            } else {
                continuation?.resume()
            }
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
