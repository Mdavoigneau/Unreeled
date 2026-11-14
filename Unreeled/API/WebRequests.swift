import UIKit
import WebKit

/// Sends the website's requests the way Safari sends them from one of its pages: the same
/// headers, and the website's cookies, which stay in WebKit's store on the phone.
///
/// On iOS, WebKit loads pages through the same system networking that URLSession uses, so these
/// requests leave the phone as a page's fetch() would. Unlike a page, the app learns what went
/// wrong (no connection, a dropped one), waits for the network before sending something, and
/// tries again when it's safe to: always for reading, and for a change only when it certainly
/// didn't reach Instagram.
@MainActor
final class WebRequests {
    static let origin = "https://www.instagram.com"
    /// The page the requests come from, as WebKit names it in `Referer`.
    static let page = origin + "/"

    enum Purpose {
        /// Reading: tried three times whatever happened to the connection.
        case read
        /// Sending or changing something: waits for a connection, and is tried again only when it
        /// never left the phone.
        case write
        /// A photo, video or voice clip: as `write`, with more time.
        case upload

        /// Seconds without a byte either way before a request counts as stuck.
        var idleTimeout: TimeInterval {
            switch self {
            case .read: 15
            case .write: 30
            case .upload: 60
            }
        }
    }

    struct Response {
        let status: Int
        let data: Data
        let http: HTTPURLResponse

        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
    }

    let cookies: CookieJar
    private let session: URLSession
    /// Goes up when the requests under way are abandoned, so none of them is tried again.
    private var generation = 0

    init(dataStore: WKWebsiteDataStore) {
        cookies = CookieJar(store: dataStore.httpCookieStore)
        let configuration = URLSessionConfiguration.default
        // Cookies come from WebKit's store and go back to it (CookieJar), never URLSession's own.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 10 * 60
        session = URLSession(configuration: configuration, delegate: Redirects(cookies: cookies), delegateQueue: nil)
        Task { _ = await BrowserIdentity.current() }
    }

    // MARK: Requests

    /// A same-origin request, as the website's pages send them with fetch().
    func send(
        _ method: String, _ path: String, query: String? = nil, headers: [(String, String)], body: Data? = nil,
        purpose: Purpose
    ) async throws -> Response {
        guard let url = URL(string: Self.origin + path + (query.map { "?" + $0 } ?? "")) else {
            throw URLError(.badURL)
        }
        return try await perform(method, url, headers: headers, body: body, purpose: purpose, crossOrigin: false)
    }

    /// A request to another of Instagram's hosts (i.instagram.com), as a page sends one: the
    /// browser asks first whether the host takes these headers from www (a CORS preflight), then
    /// sends it.
    func sendCrossOrigin(_ method: String, _ url: URL, headers: [(String, String)], body: Data?, purpose: Purpose) async throws -> Response {
        try await preflight(method, url, headers: headers)
        return try await perform(method, url, headers: headers, body: body, purpose: purpose, crossOrigin: true)
    }

    /// Stops every request under way and every one waiting to be tried again, as leaving a page
    /// stops its fetches: for a reply from a notification that ran out of time, which mustn't go
    /// out late.
    func abandonAll() {
        generation += 1
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    /// Once started, a request finishes even when the screen that asked for it has gone, as a
    /// page's fetch() did: what it brings is kept for next time, and it isn't asked for twice.
    /// Only `abandonAll` stops it.
    private func perform(
        _ method: String, _ url: URL, headers: [(String, String)], body: Data?, purpose: Purpose, crossOrigin: Bool
    ) async throws -> Response {
        try await Task {
            try await self.attempts(method, url, headers: headers, body: body, purpose: purpose, crossOrigin: crossOrigin)
        }.value
    }

    private func attempts(
        _ method: String, _ url: URL, headers: [(String, String)], body: Data?, purpose: Purpose, crossOrigin: Bool
    ) async throws -> Response {
        let started = generation
        var attempt = 0
        while true {
            guard generation == started else { throw CancellationError() }
            if purpose != .read, !Connectivity.shared.isOnline {
                // Something to send: it goes once the phone is back online, if that's soon.
                guard await Connectivity.shared.waitUntilOnline(seconds: 60) else { throw InstagramAPI.Failure.offline }
                guard generation == started else { throw CancellationError() }
            }
            let request = try await request(method, url, headers: headers, purpose: purpose, crossOrigin: crossOrigin)
            do {
                #if DEBUG
                try await Faults.inject(purpose: purpose, url: url)
                #endif
                // A body set on the request, never an upload task: those add headers of their own
                // (Upload-Complete, Upload-Draft-Interop-Version) that no browser sends.
                var request = request
                request.httpBody = body
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                await cookies.take(from: http)
                // Instagram's servers briefly unavailable: worth another look, for reading.
                if purpose == .read, [502, 503, 504].contains(http.statusCode), attempt < 2 {
                    attempt += 1
                    try await pause(before: attempt, started: started)
                    continue
                }
                return Response(status: http.statusCode, data: data, http: http)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                let failure = InstagramAPI.Failure(error)
                #if DEBUG
                NetworkRecorder.append([
                    "time": Date().ISO8601Format(), "requestFailed": url.path, "code": error.code.rawValue, "attempt": attempt + 1,
                ])
                #endif
                // No connection at all: a screen shows what it has and loads when it's back.
                if purpose == .read, error.code == .notConnectedToInternet { throw failure }
                let neverSent = Self.neverSent.contains(error.code)
                guard attempt < 2, purpose == .read || neverSent else { throw failure }
                attempt += 1
                try await pause(before: attempt, started: started)
            }
        }
    }

    /// Failures that happen before a request leaves the phone: trying again can't send anything twice.
    private static let neverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// A moment before trying again, longer each time, a little different each time.
    private func pause(before attempt: Int, started: Int) async throws {
        let seconds = (attempt == 1 ? 0.6 : 1.8) * Double.random(in: 0.8...1.2)
        try await Task.sleep(for: .seconds(seconds))
        guard generation == started else { throw CancellationError() }
    }

    /// The request as WebKit sends a page's fetch(): its own headers, then the page's.
    private func request(
        _ method: String, _ url: URL, headers: [(String, String)], purpose: Purpose, crossOrigin: Bool
    ) async throws -> URLRequest {
        let identity = await BrowserIdentity.current()
        var request = URLRequest(url: url, timeoutInterval: purpose.idleTimeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // A page sends its origin with anything but a GET to itself, and with every request elsewhere.
        if method != "GET" || crossOrigin { request.setValue(Self.origin, forHTTPHeaderField: "Origin") }
        request.setValue(Self.page, forHTTPHeaderField: "Referer")
        request.setValue(crossOrigin ? "same-site" : "same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue(Self.priority, forHTTPHeaderField: "Priority")
        if let cookie = await cookies.header(for: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        #if DEBUG
        // -cookieLog YES: which cookies each request carries, by name and length. Never the values.
        if UserDefaults.standard.bool(forKey: "cookieLog") {
            let sent = (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";").map {
                let pair = $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                return "\(pair.first ?? "")(\(pair.count > 1 ? pair[1].count : 0))"
            }
            NetworkRecorder.append(["time": Date().ISO8601Format(), "cookiesSent": sent, "path": url.path])
        }
        #endif
        return request
    }

    /// What WebKit asks i.instagram.com before sending it a request with the website's headers.
    /// Each upload has its own address, so WebKit never has the answer kept from an earlier one.
    private func preflight(_ method: String, _ url: URL, headers: [(String, String)]) async throws {
        let identity = await BrowserIdentity.current()
        var request = URLRequest(url: url, timeoutInterval: Purpose.read.idleTimeout)
        request.httpMethod = "OPTIONS"
        request.httpShouldHandleCookies = false
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(method, forHTTPHeaderField: "Access-Control-Request-Method")
        let names = headers.map { $0.0.lowercased() }.filter { !Self.safeHeaders.contains($0) }.sorted()
        if !names.isEmpty { request.setValue(names.joined(separator: ","), forHTTPHeaderField: "Access-Control-Request-Headers") }
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.page, forHTTPHeaderField: "Referer")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue(Self.priority, forHTTPHeaderField: "Priority")
        let started = generation
        var attempt = 0
        while true {
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    // A browser stops here, and the page sees a failed fetch.
                    throw InstagramAPI.Failure.http(status: 0, message: "Instagram's upload service turned the upload down.")
                }
                return
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard attempt < 2, error.code != .notConnectedToInternet else { throw InstagramAPI.Failure(error) }
                attempt += 1
                try await pause(before: attempt, started: started)
            }
        }
    }

    /// The priority WebKit gives a page's fetch(), in the header it sends it in (RFC 9218).
    private static let priority = "u=3, i"

    /// Headers a page may send anywhere without asking first.
    private static let safeHeaders: Set<String> = ["accept", "accept-language", "content-language"]

    // MARK: Forms

    /// Encodes a form as a page's URLSearchParams does: letters, digits and `*-._` as they are,
    /// spaces as `+`, every other byte as `%XX`.
    nonisolated static func form(_ pairs: [(String, String)]) -> String {
        pairs.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }

    private nonisolated static func encode(_ text: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            case UInt8(ascii: " "):
                encoded.append("+")
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    /// A multipart form as WebKit sends a page's FormData: text fields, then files, each in its
    /// part, between boundaries named the way WebKit names them.
    struct Multipart {
        enum Part {
            case field(String, String)
            case file(name: String, fileName: String, type: String, data: Data)
        }

        let boundary: String
        let body: Data

        var contentType: String { "multipart/form-data; boundary=\(boundary)" }

        init(_ parts: [Part]) {
            let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789AB")
            boundary = "----WebKitFormBoundary" + String((0..<16).map { _ in characters.randomElement()! })
            var body = Data()
            for part in parts {
                body.append(Data("--\(boundary)\r\n".utf8))
                switch part {
                case .field(let name, let value):
                    body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
                case .file(let name, let fileName, let type, let data):
                    body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
                    body.append(data)
                    body.append(Data("\r\n".utf8))
                }
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            self.body = body
        }
    }
}

/// Follows a redirect the way WebKit does, with the cookies the redirect set.
private final class Redirects: NSObject, URLSessionTaskDelegate {
    let cookies: CookieJar

    init(cookies: CookieJar) {
        self.cookies = cookies
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        await cookies.take(from: response)
        var request = request
        if let url = request.url { request.setValue(await cookies.header(for: url), forHTTPHeaderField: "Cookie") }
        return request
    }
}

// MARK: - Cookies

/// The website's cookies, read from WebKit's store and kept in step with it: what a request sends,
/// and what responses set, written back so the login page and the website's screens share them.
@MainActor
final class CookieJar: NSObject {
    private let store: WKHTTPCookieStore
    /// Nil until read from the store, and again once something else changed the store.
    private var cookies: [HTTPCookie]?
    private var reading: Task<[HTTPCookie], Never>?
    /// Goes up whenever what was read can no longer be trusted, so a read under way isn't kept.
    private var generation = 0
    /// Cookies being written back, and whether the store changed otherwise meanwhile.
    private var writing = 0
    private var changedMeanwhile = false

    init(store: WKHTTPCookieStore) {
        self.store = store
        super.init()
        store.add(self)
    }

    /// The value of one of the website's cookies as its pages on www.instagram.com see it, or ""
    /// without one: never one kept for another of Instagram's hosts, which the page doesn't get.
    func value(_ name: String) async -> String {
        await all().first { $0.name == name && Self.domain($0.domain, matches: "www.instagram.com") }?.value ?? ""
    }

    /// The Cookie header for a request to `url`, as WebKit would send it.
    func header(for url: URL) async -> String? {
        Self.header(for: url, from: await all())
    }

    private static func header(for url: URL, from cookies: [HTTPCookie]) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let now = Date.now
        let path = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter { cookie in
            (cookie.expiresDate.map { $0 > now } ?? true)
                && domain(cookie.domain, matches: host)
                && (path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/") || cookie.path == "/")
                && (!cookie.isSecure || url.scheme == "https")
        }
        // Longer paths first, as browsers order them.
        let ordered = matching.sorted { $0.path.count > $1.path.count }
        return HTTPCookie.requestHeaderFields(with: ordered)["Cookie"]
    }

    /// Keeps the cookies a response sets, here at once and in WebKit's store behind. They change
    /// the whole set, read from the store first if it has to be: never a set started afresh.
    func take(from response: HTTPURLResponse) async {
        guard let url = response.url, let fields = response.allHeaderFields as? [String: String],
              fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame })
        else { return }
        let set = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !set.isEmpty else { return }
        let read = await all()
        var current = cookies ?? read
        for cookie in set {
            let old = current.firstIndex { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            let expired = cookie.expiresDate.map { $0 <= .now } ?? false
            if let old {
                let same = current[old].value == cookie.value
                    && abs((current[old].expiresDate ?? .distantFuture).timeIntervalSince(cookie.expiresDate ?? .distantFuture)) < 60
                if same, !expired { continue }
                let replaced = current.remove(at: old)
                if expired { write { await self.store.deleteCookie(replaced) } }
            } else if expired {
                continue
            }
            if !expired {
                current.append(cookie)
                write { await self.store.setCookie(cookie) }
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "cookieLog") {
                NetworkRecorder.append([
                    "time": Date().ISO8601Format(), "cookieSet": cookie.name, "length": cookie.value.count,
                    "expired": expired, "path": url.path,
                ])
            }
            #endif
        }
        cookies = current
    }

    /// After logging out, or when the store changed: read again from it next time.
    func forget() {
        generation += 1
        cookies = nil
    }

    /// Every cookie, read from the store once and shared by everything that asks meanwhile. A
    /// read that the store changed under is done again.
    private func all() async -> [HTTPCookie] {
        while true {
            if let cookies { return cookies }
            if let reading {
                // Kept by the read itself before anyone waiting on it carries on: look again.
                _ = await reading.value
                if let cookies { return cookies }
                if self.reading != nil { continue }
            }
            let started = generation
            let task = Task { () -> [HTTPCookie] in
                let read = await store.allCookies()
                if started == generation, cookies == nil { cookies = read }
                reading = nil
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "cookieLog") {
                    let listed = read.map {
                        "\($0.name)@\($0.domain)\($0.path) len \($0.value.count)\($0.expiresDate.map { $0 < .now ? " expired" : "" } ?? " session")"
                    }
                    NetworkRecorder.append(["time": Date().ISO8601Format(), "cookieStore": listed])
                }
                #endif
                return read
            }
            reading = task
            let read = await task.value
            if started == generation { return cookies ?? read }
        }
    }

    private func write(_ change: @escaping @MainActor () async -> Void) {
        writing += 1
        Task {
            await change()
            writing -= 1
            if writing == 0, changedMeanwhile {
                changedMeanwhile = false
                forget()
            }
        }
    }

    /// RFC 6265: a cookie with a domain (".instagram.com") goes to that host and those under it;
    /// one without goes to its own host only.
    private static func domain(_ domain: String, matches host: String) -> Bool {
        let domain = domain.lowercased()
        if domain.hasPrefix(".") {
            let bare = domain.dropFirst()
            return host == bare || host.hasSuffix(domain)
        }
        return host == domain
    }
}

extension CookieJar: WKHTTPCookieStoreObserver {
    /// The login page or a website screen changed the cookies: read them again before the next request.
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        if writing > 0 {
            changedMeanwhile = true
        } else {
            forget()
        }
    }
}

// MARK: - The browser's identity

/// How WebKit describes itself to the website on this phone: its user agent and the touch points
/// the pages see. Asked of WebKit once per version of iOS, then kept.
struct BrowserIdentity: Codable, Equatable {
    let system: String
    let userAgent: String
    let maxTouchPoints: Int
    /// The screen's scale, as a page's devicePixelRatio, rounded.
    let pixelRatio: Int

    private static let key = "browserIdentity"
    @MainActor private static var known: BrowserIdentity?
    @MainActor private static var asking: Task<BrowserIdentity, Never>?

    @MainActor
    static func current() async -> BrowserIdentity {
        if let known { return known }
        if let asking { return await asking.value }
        let system = UIDevice.current.systemVersion
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(BrowserIdentity.self, from: $0) }
        if let saved, saved.system == system {
            known = saved
            return saved
        }
        let task = Task { @MainActor () -> BrowserIdentity in
            let scale = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 3
            if let answer = await WebKitAnswer.ask() {
                let identity = BrowserIdentity(
                    system: system, userAgent: answer.userAgent, maxTouchPoints: answer.maxTouchPoints, pixelRatio: Int(scale.rounded())
                )
                UserDefaults.standard.set(try? JSONEncoder().encode(identity), forKey: key)
                return identity
            }
            // WebKit didn't answer (asked again at the next launch). What it said under the last
            // version of iOS, which rarely changes (it gives an older iOS version anyway)...
            if let saved { return saved }
            // ...or its usual form.
            let version = system.replacingOccurrences(of: ".", with: "_")
            return BrowserIdentity(
                system: system,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS \(version) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                maxTouchPoints: 5, pixelRatio: Int(scale.rounded())
            )
        }
        asking = task
        let identity = await task.value
        asking = nil
        known = identity
        return identity
    }
}

/// A blank web view, kept no longer than it takes to ask WebKit what it tells websites.
@MainActor
private final class WebKitAnswer: NSObject, WKNavigationDelegate {
    struct Answer {
        let userAgent: String
        let maxTouchPoints: Int
    }

    private let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    static func ask() async -> Answer? {
        let asker = WebKitAnswer()
        return await asker.answer()
    }

    private func answer() async -> Answer? {
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.finishLoading()
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        }
        let result = try? await webView.evaluateJavaScript("[navigator.userAgent, navigator.maxTouchPoints]") as? [Any]
        guard let userAgent = result?.first as? String, userAgent.hasPrefix("Mozilla/") else { return nil }
        return Answer(userAgent: userAgent, maxTouchPoints: (result?.last as? NSNumber)?.intValue ?? 5)
    }

    private func finishLoading() {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoading() }
}
