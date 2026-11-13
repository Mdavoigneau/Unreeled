import SwiftUI
import WebKit

/// Talks to Instagram the way instagram.com does.
///
/// Requests go out as the website's pages send them, with the website's cookies and the browser's
/// headers (WebRequests); the cookies stay in WebKit's store on the phone. Nearly all of the
/// website's data comes from GraphQL queries it refers to by ID; Queries.json lists the ones the
/// app uses, and Endpoints.swift calls them.
@MainActor
final class InstagramAPI {
    static let site = URL(string: "https://www.instagram.com/")!
    static let appID = "1217981644879628"

    enum Failure: LocalizedError {
        case loginRequired
        case challenge
        case rateLimited
        /// The phone has no connection.
        case offline
        /// The connection dropped or stalled, three times for reading.
        case connection
        case http(status: Int, message: String?)
        case query(String)
        case unreadable(String)

        init(_ error: URLError) {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: self = .offline
            default: self = .connection
            }
        }

        var errorDescription: String? {
            switch self {
            case .loginRequired: "Instagram wants you to log in again."
            case .challenge: "Instagram wants to confirm it's you. Open the website to continue."
            case .rateLimited: "Instagram asked to slow down. Try again in a few minutes."
            case .offline: "You're offline."
            case .connection: "Couldn't reach Instagram."
            case .http(let status, let message): message ?? "Instagram returned an error (\(status))."
            case .query(let message): message
            case .unreadable(let detail): "Couldn't read Instagram's response: \(detail)"
            }
        }

        /// Worth one more try with fresh tokens.
        var isRetryable: Bool {
            switch self {
            case .query, .http: true
            default: false
            }
        }

        /// The connection failed, not Instagram: it may work once the phone is back online.
        var isConnection: Bool {
            switch self {
            case .offline, .connection: true
            default: false
            }
        }
    }

    let requests: WebRequests
    /// Numbers the mutations sent, like the website's client_mutation_id.
    var mutationCount = 0
    /// The session values the website's page provides, read from it at most every hour.
    private var site: SiteValues?
    private var siteLoading: Task<SiteValues, Error>?
    /// Those read at the last launch, kept in the Keychain, so a launch doesn't wait for the
    /// website's page before its first request.
    private var savedSite: SiteValues?
    /// Requests sent so far, as a page counts them in `__req`.
    private var requestCount = 0
    /// The website's claim for its REST calls, which it keeps for the page's lifetime.
    private var claim = "0"
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(dataStore: WKWebsiteDataStore) {
        requests = WebRequests(dataStore: dataStore)
        savedSite = SecureStore.data(for: "site").flatMap { try? JSONDecoder().decode(SiteValues.self, from: $0) }
        #if DEBUG
        // -freshSite YES: read the session values from the website at launch, as after a day away.
        if UserDefaults.standard.bool(forKey: "freshSite") { savedSite = nil }
        #endif
    }

    /// Stops every request under way, as leaving a page stops its fetches: for a reply sent from a
    /// notification that ran out of time in the background, which mustn't go out late.
    func abandonRequests() {
        requests.abandonAll()
    }

    /// Forgets the session values, in the Keychain and here: for logging out.
    func reset() {
        site = nil
        savedSite = nil
        siteLoading = nil
        requestCount = 0
        claim = "0"
        SecureStore.set(nil, for: "site")
        requests.abandonAll()
        requests.cookies.forget()
    }

    // MARK: Session values

    /// What the website embeds in its pages for its requests to use.
    struct SiteValues: Codable {
        /// When they were read, in milliseconds.
        var time: Double
        var dtsg = ""
        var lsd = ""
        var av = ""
        var rev = ""
        var hs = ""
        var hsi = ""
        var spinT = ""
        var bloks = ""
        /// Read since the app sent Direct search; missing from values saved before.
        var dtsgAG: String?

        var age: TimeInterval { Date.now.timeIntervalSince1970 - time / 1000 }
    }

    /// The session values: last launch's at first, while they're under a day old, renewed behind
    /// once they're an hour old. `fresh` reads them from the website now, after a request failed.
    private func siteValues(fresh: Bool) async throws -> SiteValues {
        if site == nil, let savedSite, !savedSite.dtsg.isEmpty, savedSite.age < 86_400 { site = savedSite }
        if !fresh, let site {
            if site.age > 3600, siteLoading == nil { Task { try? await self.loadSite() } }
            return site
        }
        return try await loadSite()
    }

    /// Reads the session values from the website's home page, as the website's own scripts find
    /// them. Every request waiting for them shares one load of the page.
    @discardableResult
    private func loadSite() async throws -> SiteValues {
        if let siteLoading { return try await siteLoading.value }
        let task = Task { () throws -> SiteValues in
            let response = try await self.requests.send("GET", "/", headers: [], purpose: .read)
            return await Self.siteValues(in: response.data)
        }
        siteLoading = task
        defer { siteLoading = nil }
        let loaded = try await task.value
        site = loaded
        // Kept for the next launch only when the page was a logged-in one: the account's ID, not 0.
        if !loaded.dtsg.isEmpty, !loaded.av.isEmpty, loaded.av != "0" {
            savedSite = loaded
            SecureStore.set(try? JSONEncoder().encode(loaded), for: "site")
        }
        #if DEBUG
        // Which values the page provided, by length. Never the values.
        let lengths: [String: Int] = [
            "dtsg": loaded.dtsg.count, "lsd": loaded.lsd.count, "av": loaded.av.count, "rev": loaded.rev.count,
            "hs": loaded.hs.count, "hsi": loaded.hsi.count, "spinT": loaded.spinT.count, "bloks": loaded.bloks.count,
            "dtsgAG": loaded.dtsgAG?.count ?? 0,
        ]
        NetworkRecorder.append(["time": Date().ISO8601Format(), "siteValues": lengths])
        #endif
        return loaded
    }

    @concurrent
    private nonisolated static func siteValues(in data: Data) async -> SiteValues {
        let html = String(decoding: data, as: UTF8.self)
        func find(_ patterns: NSRegularExpression...) -> String {
            let range = NSRange(html.startIndex..., in: html)
            for pattern in patterns {
                if let match = pattern.firstMatch(in: html, range: range), let found = Range(match.range(at: 1), in: html) {
                    return String(html[found])
                }
            }
            return ""
        }
        return SiteValues(
            time: (Date.now.timeIntervalSince1970 * 1000).rounded(),
            dtsg: find(Patterns.dtsg, Patterns.dtsgOther),
            lsd: find(Patterns.lsd, Patterns.lsdOther),
            av: find(Patterns.actor, Patterns.viewer, Patterns.viewerOther),
            rev: find(Patterns.revision, Patterns.spinR),
            hs: find(Patterns.hasteSession),
            hsi: find(Patterns.hsi),
            spinT: find(Patterns.spinT),
            bloks: find(Patterns.bloks),
            dtsgAG: find(Patterns.asyncGetToken)
        )
    }

    /// Where the values sit in the website's page.
    private enum Patterns {
        static let dtsg = regex(#""DTSGInitialData",\[\],\{"token":"([^"]+)""#)
        static let dtsgOther = regex(#""dtsg":\{"token":"([^"]+)""#)
        static let lsd = regex(#""LSD",\[\],\{"token":"([^"]+)""#)
        static let lsdOther = regex(#""lsd":"([^"]+)""#)
        static let actor = regex(#""actorID":"(\d+)""#)
        static let viewer = regex(#""viewerId":"(\d+)""#)
        static let viewerOther = regex(#""viewer_id":"(\d+)""#)
        static let revision = regex(#""server_revision":(\d+)"#)
        static let spinR = regex(#""__spin_r":(\d+)"#)
        static let hasteSession = regex(#""haste_session":"([^"]+)""#)
        static let hsi = regex(#""hsi":"(\d+)""#)
        static let spinT = regex(#""__spin_t":(\d+)"#)
        static let bloks = regex(#""versioningID":"([0-9a-f]+)""#)
        static let asyncGetToken = regex(#""async_get_token":"([^"]+)""#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern)
        }
    }

    /// The parameters every request of a page carries, as the website's scripts add them.
    private func pageParameters(_ site: SiteValues, dpr: Int) -> [(String, String)] {
        requestCount += 1
        return [
            ("__d", "www"), ("__user", "0"), ("__a", "1"), ("__req", String(requestCount, radix: 36)), ("__hs", site.hs),
            ("dpr", String(dpr)), ("__ccg", "EXCELLENT"), ("__rev", site.rev), ("__hsi", site.hsi), ("__comet_req", "7"),
            ("fb_dtsg", site.dtsg), ("jazoest", Self.checksum(site.dtsg)), ("lsd", site.lsd), ("__spin_r", site.rev),
            ("__spin_b", "trunk"), ("__spin_t", site.spinT),
        ]
    }

    /// The website's `jazoest`: a 2, then the sum of the token's character codes.
    private nonisolated static func checksum(_ token: String) -> String {
        "2" + String(token.utf16.reduce(0) { $0 + Int($1) })
    }

    // MARK: GraphQL

    /// Runs one of the website's GraphQL queries and decodes the object at `path` in its data.
    nonisolated func query<T: Decodable>(_ name: String, _ variables: [String: Any], at path: [String], as type: T.Type = T.self) async throws -> T {
        try await decoded(type, from: queryData(name, variables, at: path))
    }

    /// The JSON at `path` in a query's data, as Instagram sent it, to decode and to save. Read and
    /// written off the main thread, like the rest of a response.
    func queryData(_ name: String, _ variables: [String: Any], at path: [String]) async throws -> Data {
        var node: Any = try await graphQL(name, variables)
        for key in path {
            guard let next = (node as? [String: Any])?[key], !(next is NSNull) else {
                throw Failure.unreadable("\(name) has no \(path.joined(separator: "."))")
            }
            node = next
        }
        #if DEBUG
        // -directShapes YES: log the shape (field names and kinds, no content) of the conversations
        // you open, to see which kinds of messages the app should learn to show.
        if UserDefaults.standard.bool(forKey: "directShapes"), name.hasPrefix("IGD") {
            NetworkRecorder.append(["time": Date().ISO8601Format(), "directShape": name, "shape": NetworkRecorder.shape(of: node)])
        }
        #endif
        return try await Self.serialized(node)
    }

    @concurrent
    private nonisolated static func serialized(_ node: Any) async throws -> Data {
        try JSONSerialization.data(withJSONObject: node)
    }

    /// Decodes Instagram's JSON off the main thread, so a large response never holds up scrolling.
    @concurrent
    nonisolated func decoded<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        do {
            return try Self.decodeSaved(type, from: data)
        } catch let error as DecodingError {
            throw Failure.unreadable(Self.describe(error))
        }
    }

    /// Decodes a saved response the way queries decode Instagram's, from any thread.
    nonisolated static func decodeSaved<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    nonisolated static func decodeThread(_ data: Data) throws -> DirectThread? {
        try decodeSaved(ThreadDetail.self, from: data).asIgDirectThread
    }

    /// The `data` of a query's response. When a query fails, tokens may have expired:
    /// this reads fresh ones from the website and tries once more. If it still fails, Instagram
    /// may have changed the query: when the project has a newer ID for it, this tries once more
    /// with that. A failed connection was already tried again (WebRequests).
    func graphQL(_ name: String, _ variables: [String: Any]) async throws -> [String: Any] {
        do {
            return try await graphQLAttempt(name, variables, freshTokens: false)
        } catch let error as Failure where error.isRetryable {
            do {
                return try await graphQLAttempt(name, variables, freshTokens: true)
            } catch let error as Failure where error.isRetryable {
                let before = WebQuery.all[name]
                await QueryUpdates.check(afterFailure: true)
                guard WebQuery.all[name] != before else { throw error }
                return try await graphQLAttempt(name, variables, freshTokens: false)
            }
        }
    }

    /// Sends the query with the parameters and headers the website uses. The string "{viewer}" in
    /// the variables becomes the account's ID as the website knows it.
    private func graphQLAttempt(_ name: String, _ variables: [String: Any], freshTokens: Bool) async throws -> [String: Any] {
        guard let query = WebQuery.all[name] else { throw Failure.unreadable("unknown query \(name)") }
        let variables = variables.merging(query.providers.mapValues(\.value)) { current, _ in current }
        let json = try JSONSerialization.data(withJSONObject: variables, options: [.withoutEscapingSlashes])
        let site = try await siteValues(fresh: freshTokens)
        let identity = await BrowserIdentity.current()
        let text = String(decoding: json, as: UTF8.self).replacingOccurrences(of: #""{viewer}""#, with: #""\#(site.av)""#)
        let parameters = [("av", site.av)] + pageParameters(site, dpr: identity.pixelRatio) + [
            ("fb_api_caller_class", "RelayModern"), ("fb_api_req_friendly_name", name), ("variables", text),
            ("server_timestamps", "true"), ("doc_id", query.docID),
        ]
        var headers = [
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("X-ASBD-ID", "359341"),
            ("X-CSRFToken", await requests.cookies.value("csrftoken")),
            ("X-FB-Friendly-Name", name),
            ("X-FB-LSD", site.lsd),
            ("X-IG-App-ID", Self.appID),
            ("X-IG-Max-Touch-Points", String(identity.maxTouchPoints)),
        ]
        if let rootField = query.rootField, !rootField.isEmpty {
            headers.append(("X-Root-Field-Name", rootField))
            if !site.bloks.isEmpty { headers.append(("X-BLOKS-VERSION-ID", site.bloks)) }
        }
        let response = try await requests.send(
            "POST", query.path, headers: headers,
            body: Data(WebRequests.form(parameters.filter { !$0.1.isEmpty }).utf8),
            purpose: name.contains("Mutation") ? .write : .read
        )
        return try await Self.parsed(name, status: response.status, data: response.data)
    }

    @concurrent
    private nonisolated static func parsed(_ name: String, status: Int, data: Data) async throws -> [String: Any] {
        try Self.data(of: name, status: status, body: String(decoding: data, as: UTF8.self))
    }

    /// The data of a GraphQL response, with streamed parts merged in.
    private nonisolated static func data(of name: String, status: Int, body: String) throws -> [String: Any] {
        var text = Substring(body)
        if text.hasPrefix("for (;;);") { text = text.dropFirst("for (;;);".count) }
        let parts = text.split(whereSeparator: \.isNewline).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        guard let first = parts.first else {
            if status == 401 || text.hasPrefix("<") { throw Failure.loginRequired }
            throw Failure.http(status: status, message: nil)
        }
        if first["require_login"] as? Bool == true { throw Failure.loginRequired }
        if first["checkpoint_url"] is String || first["message"] as? String == "checkpoint_required" { throw Failure.challenge }
        if status == 429 { throw Failure.rateLimited }
        if let summary = first["errorSummary"] as? String {
            throw Failure.query("\(name): \(summary) (\(first["error"].map { "\($0)" } ?? "?"))")
        }
        guard var data = first["data"] as? [String: Any] else {
            let error = (first["errors"] as? [[String: Any]])?.first
            if error?["requires_reauth"] as? Bool == true { throw Failure.loginRequired }
            let message = (error?["message"] as? String) ?? (error?["summary"] as? String) ?? "no data (\(status))"
            throw Failure.query("\(name): \(message)")
        }
        // A mutation that failed: its field is null, and the reason is in the errors.
        if let error = (first["errors"] as? [[String: Any]])?.first, !data.isEmpty, data.values.allSatisfy({ $0 is NSNull }) {
            if error["requires_reauth"] as? Bool == true { throw Failure.loginRequired }
            let reasons = ["message", "summary", "description"].compactMap { error[$0] as? String }.filter { !$0.isEmpty }
            throw Failure.query("\(name): \(reasons.isEmpty ? "no data (\(status))" : reasons.joined(separator: " — "))")
        }
        // Long lists arrive in parts. Each later part has a path into the data and a piece to put there.
        for part in parts.dropFirst() {
            guard let path = part["path"] as? [Any], let piece = part["data"], !(piece is NSNull) else { continue }
            data = merge(piece, at: path[...], into: data) as? [String: Any] ?? data
        }
        return data
    }

    private nonisolated static func merge(_ piece: Any, at path: ArraySlice<Any>, into node: Any) -> Any {
        guard let key = path.first else {
            if var object = node as? [String: Any], let fields = piece as? [String: Any] {
                object.merge(fields) { _, new in new }
                return object
            }
            return piece
        }
        let rest = path.dropFirst()
        if var array = node as? [Any], let index = key as? Int {
            if index < array.count {
                array[index] = merge(piece, at: rest, into: array[index])
            } else if index == array.count {
                array.append(merge(piece, at: rest, into: [String: Any]()))
            }
            return array
        }
        if var object = node as? [String: Any], let field = key as? String {
            object[field] = merge(piece, at: rest, into: object[field] ?? [String: Any]())
            return object
        }
        return node
    }

    // MARK: Uploads

    /// Uploads a photo, video or voice clip for Direct, the way the website's chat does, and
    /// returns the attachment ID to send it with.
    /// `fields` go in the form before the file, like the website's `voice_clip` ones.
    func uploadForDirect(_ data: Data, mimeType: String, fileName: String, fields: [(String, String)] = []) async throws -> String {
        let (status, body) = try await mercuryUpload(data, mimeType: mimeType, fileName: fileName, fields: fields)
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let metadata = (json?["payload"] as? [String: Any])?["metadata"]
        let first = ((metadata as? [String: Any])?["0"] ?? (metadata as? [Any])?.first) as? [String: Any]
        for key in ["fbid", "image_id", "video_id", "audio_id", "gif_id", "file_id"] {
            if let id = first?[key] as? String, !id.isEmpty { return id }
            if let id = first?[key] as? NSNumber { return id.stringValue }
        }
        let message = (json?["errorSummary"] as? String) ?? (json?["errorDescription"] as? String)
        throw Failure.http(status: status, message: message.map { "Upload failed: \($0)" } ?? "The upload didn't go through (\(status)).")
    }

    /// Chat uploads go to /ajax/mercury/upload.php as a form with the file in "farr" and the
    /// session values in the address, as the website sends them.
    private func mercuryUpload(_ data: Data, mimeType: String, fileName: String, fields: [(String, String)]) async throws -> (status: Int, body: String) {
        let site = try await siteValues(fresh: false)
        let identity = await BrowserIdentity.current()
        let query = WebRequests.form(pageParameters(site, dpr: identity.pixelRatio).filter { !$0.1.isEmpty })
        let form = WebRequests.Multipart(
            fields.map { .field($0.0, $0.1) } + [
                .file(name: "farr", fileName: fileName, type: mimeType, data: data),
                .field("upload_id", UUID().uuidString.lowercased()),
            ]
        )
        let response = try await requests.send(
            "POST", "/ajax/mercury/upload.php", query: query,
            headers: [("Content-Type", form.contentType), ("X-ASBD-ID", "359341"), ("X-FB-LSD", site.lsd)],
            body: form.body, purpose: .upload
        )
        return uploadResponse(response, target: "mercury", bytes: data.count, mimeType: mimeType)
    }

    /// Uploads a story's photo or video to Instagram's upload service, as the website's story
    /// camera does: the bytes to i.instagram.com/rupload_…, with what they are in headers. `kind`
    /// is "igphoto" or "igvideo".
    func ruploadForStory(kind: String, entityName: String, data: Data, mimeType: String, params: [String: Any]) async throws {
        let paramsJSON = try JSONSerialization.data(withJSONObject: params, options: [.withoutEscapingSlashes])
        let site = try await siteValues(fresh: false)
        let identity = await BrowserIdentity.current()
        // From www to i.instagram.com: the website's headers there. No CSRF token (it only goes to
        // the website's own /api/ paths), claim or device ID.
        var headers = [
            ("Content-Type", mimeType),
            ("X-ASBD-ID", "359341"),
            ("X-IG-App-ID", Self.appID),
            ("X-IG-Max-Touch-Points", String(identity.maxTouchPoints)),
            ("X-Instagram-AJAX", site.rev),
            ("Offset", "0"),
            ("X-Entity-Length", String(data.count)),
            ("X-Entity-Name", entityName),
            ("X-Instagram-Rupload-Params", String(decoding: paramsJSON, as: UTF8.self)),
        ]
        if kind == "igphoto" { headers.append(("X-Entity-Type", mimeType)) }
        guard let url = URL(string: "https://i.instagram.com/rupload_\(kind)/\(entityName)") else { throw URLError(.badURL) }
        let response = try await requests.sendCrossOrigin("POST", url, headers: headers, body: data, purpose: .upload)
        let (status, body) = uploadResponse(response, target: "rupload", bytes: data.count, mimeType: mimeType)
        try Self.check(status: status, data: Data(body.utf8))
    }

    private func uploadResponse(_ response: WebRequests.Response, target: String, bytes: Int, mimeType: String) -> (status: Int, body: String) {
        var body = String(decoding: response.data, as: UTF8.self)
        if body.hasPrefix("for (;;);") { body.removeFirst("for (;;);".count) }
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "upload": target, "bytes": bytes, "mime": mimeType, "status": response.status])
        #endif
        return (response.status, body)
    }

    // MARK: Comet GET

    /// The `payload` of a GET to one of the website's endpoints, sent the way its pages send them
    /// (cometAsyncFetch): the endpoint's parameters, then the page's usual ones, and the same
    /// headers. Some endpoints answer nothing without them.
    func cometGET(_ path: String, _ parameters: [(String, String)], route: String) async throws -> Any {
        do {
            return try await cometGETAttempt(path, parameters, route: route, freshTokens: false)
        } catch let error as Failure where error.isRetryable {
            return try await cometGETAttempt(path, parameters, route: route, freshTokens: true)
        }
    }

    private func cometGETAttempt(_ path: String, _ parameters: [(String, String)], route: String, freshTokens: Bool) async throws -> Any {
        var site = try await siteValues(fresh: freshTokens)
        // Saved before the app read this value: the page once more.
        if site.dtsgAG == nil { site = try await loadSite() }
        let identity = await BrowserIdentity.current()
        requestCount += 1
        let token = site.dtsgAG ?? ""
        let common = [
            ("__d", "www"), ("__user", "0"), ("__a", "1"), ("__req", String(requestCount, radix: 36)),
            ("__hs", site.hs), ("dpr", String(identity.pixelRatio)), ("__ccg", "EXCELLENT"),
            ("__rev", site.rev), ("__hsi", site.hsi), ("__comet_req", "7"), ("fb_dtsg_ag", token),
            ("jazoest", token.isEmpty ? "" : Self.checksum(token)),
            ("__spin_r", site.rev), ("__spin_b", "trunk"), ("__spin_t", site.spinT), ("__crn", route),
        ]
        let response = try await requests.send(
            "GET", path, query: WebRequests.form((parameters + common).filter { !$0.1.isEmpty }),
            headers: [
                ("X-ASBD-ID", "359341"),
                ("X-FB-LSD", site.lsd),
                ("X-IG-App-ID", Self.appID),
                ("X-IG-D", "www"),
                ("X-IG-Max-Touch-Points", String(identity.maxTouchPoints)),
            ],
            purpose: .read
        )
        var body = String(decoding: response.data, as: UTF8.self)
        if body.hasPrefix("for (;;);") { body.removeFirst("for (;;);".count) }
        let data = Data(body.utf8)
        try Self.check(status: response.status, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.http(status: response.status, message: nil)
        }
        if let summary = json["errorSummary"] as? String { throw Failure.query(summary) }
        guard let payload = json["payload"], !(payload is NSNull) else { throw Failure.http(status: response.status, message: nil) }
        return payload
    }

    // MARK: REST

    /// The response body of a request to one of the website's REST endpoints (/api/v1/…),
    /// after checking for the errors Instagram reports.
    func send(_ method: String, _ path: String, form: [String: String] = [:]) async throws -> Data {
        let (status, body) = try await raw(method, path, form: form)
        let data = Data(body.utf8)
        try Self.check(status: status, data: data)
        return data
    }

    /// Status and body text, whatever they are. Sent with the headers the website's REST calls
    /// carry, and its claim, which the answers renew.
    func raw(_ method: String, _ path: String, form: [String: String] = [:]) async throws -> (status: Int, body: String) {
        var headers = [
            ("X-ASBD-ID", "359341"),
            ("X-CSRFToken", await requests.cookies.value("csrftoken")),
            ("X-IG-App-ID", Self.appID),
            ("X-IG-WWW-Claim", claim),
            ("X-Requested-With", "XMLHttpRequest"),
        ]
        var body: Data?
        if method != "GET" {
            headers.append(("Content-Type", "application/x-www-form-urlencoded"))
            body = Data(WebRequests.form(form.sorted { $0.key < $1.key }).utf8)
        }
        let response = try await requests.send(method, path, headers: headers, body: body, purpose: method == "GET" ? .read : .write)
        if let renewed = response.header("x-ig-set-www-claim"), !renewed.isEmpty { claim = renewed }
        var text = String(decoding: response.data, as: UTF8.self)
        if text.hasPrefix("for (;;);") { text.removeFirst("for (;;);".count) }
        return (response.status, text)
    }

    private static func check(status: Int, data: Data) throws {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = json?["message"] as? String
        if status == 401 || json?["require_login"] as? Bool == true || message == "login_required" {
            throw Failure.loginRequired
        }
        if json?["checkpoint_url"] is String || message == "checkpoint_required" || message == "challenge_required" {
            throw Failure.challenge
        }
        if status == 429 || message?.localizedCaseInsensitiveContains("wait a few minutes") == true {
            throw Failure.rateLimited
        }
        if !(200..<300).contains(status) || json?["status"] as? String == "fail" {
            throw Failure.http(status: status, message: message)
        }
        if json == nil, data.first == UInt8(ascii: "<") {
            throw Failure.loginRequired
        }
    }

    // MARK: Helpers

    /// The website's device ID cookie, which the feed query sends along.
    func deviceID() async -> String {
        await requests.cookies.value("ig_did")
    }

    /// The website's machine ID cookie, which a push registration sends along.
    func machineID() async -> String {
        await requests.cookies.value("mid")
    }

    /// The checksum of the CSRF token that the website adds to the forms it posts, as `jazoest`.
    func formChecksum() async -> String {
        Self.checksum(await requests.cookies.value("csrftoken"))
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw Failure.unreadable(Self.describe(error))
        }
    }

    private nonisolated static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(path(context.codingPath + [key]))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) (\(path(context.codingPath)))"
        @unknown default: return String(describing: error)
        }
    }
}

/// One of the website's GraphQL queries. Instagram keeps the query text on its servers, and the
/// website sends the query's document ID with the variables. When Instagram ships a new version
/// of a query, its ID changes: record the website again in a Debug build and update Queries.json.
/// Apps already out there pick up the change from the project (see QueryUpdates).
struct WebQuery: Decodable, Equatable {
    let docID: String
    /// "/api/graphql" or "/graphql/query", whichever the website uses for this query.
    let path: String
    /// Sent as X-Root-Field-Name to /graphql/query.
    let rootField: String?
    /// Feature flags and settings the stored query expects among its variables.
    let providers: [String: Provider]

    enum CodingKeys: String, CodingKey {
        case docID = "doc_id", path, rootField = "root_field", providers
    }

    /// A provider value: a flag, or a number such as a page size.
    enum Provider: Decodable, Equatable {
        case flag(Bool)
        case number(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else {
                self = .number(try container.decode(Int.self))
            }
        }

        var value: Any {
            switch self {
            case .flag(let flag): flag
            case .number(let number): number
            }
        }
    }

    /// The queries in use: the app's own list, or a newer one from the project.
    @MainActor static var all = QueryUpdates.load(over: bundled)

    /// The list this version of the app shipped with.
    @MainActor static let bundled: [String: WebQuery] = {
        guard let url = Bundle.main.url(forResource: "Queries", withExtension: "json") else {
            fatalError("Queries.json is missing from the app bundle")
        }
        do {
            return try JSONDecoder().decode([String: WebQuery].self, from: Data(contentsOf: url))
        } catch {
            fatalError("Queries.json is invalid: \(error)")
        }
    }()
}
