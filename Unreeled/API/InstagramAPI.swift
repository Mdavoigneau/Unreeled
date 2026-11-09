import SwiftUI
import WebKit

/// Talks to Instagram the way instagram.com does.
///
/// Requests run as fetch() in a hidden web view showing a blank page on www.instagram.com,
/// so they carry the website's cookies and the browser's own headers. The session never
/// leaves WebKit's cookie store. Nearly all of the website's data comes from GraphQL queries
/// it refers to by ID; Queries.json lists the ones the app uses, and Endpoints.swift calls them.
@MainActor
final class InstagramAPI: NSObject {
    static let site = URL(string: "https://www.instagram.com/")!

    enum Failure: LocalizedError {
        case loginRequired
        case challenge
        case rateLimited
        case http(status: Int, message: String?)
        case query(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .loginRequired: "Instagram wants you to log in again."
            case .challenge: "Instagram wants to confirm it's you. Open the website to continue."
            case .rateLimited: "Instagram asked to slow down. Try again in a few minutes."
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
    }

    let webView: WKWebView
    /// The session values read from the website at the last launch, kept in the Keychain, so a
    /// launch doesn't wait for the website's page before its first request.
    private var siteSeed: [String: Any]?
    /// Numbers the mutations sent, like the website's client_mutation_id.
    var mutationCount = 0
    private let dataStore: WKWebsiteDataStore
    private var isReady = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        super.init()
        webView.navigationDelegate = self
        siteSeed = SecureStore.data(for: "site").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        loadBlankPage()
    }

    /// Forgets the session values, in the Keychain and in the hidden page: for logging out.
    func reset() {
        siteSeed = nil
        SecureStore.set(nil, for: "site")
        loadBlankPage()
    }

    /// Keeps values the hidden page just read from the website, for the next launch.
    private func keepSite(from response: [String: Any]) {
        guard let fresh = response["fresh"] as? [String: Any], (fresh["dtsg"] as? String)?.isEmpty == false else { return }
        siteSeed = fresh
        SecureStore.set(try? JSONSerialization.data(withJSONObject: fresh), for: "site")
    }

    // MARK: GraphQL

    /// Runs one of the website's GraphQL queries and decodes the object at `path` in its data.
    func query<T: Decodable>(_ name: String, _ variables: [String: Any], at path: [String], as type: T.Type = T.self) async throws -> T {
        try decode(type, from: await queryData(name, variables, at: path))
    }

    /// The JSON at `path` in a query's data, as Instagram sent it, to decode and to save.
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
        return try JSONSerialization.data(withJSONObject: node)
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
    /// with that.
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

    private func graphQLAttempt(_ name: String, _ variables: [String: Any], freshTokens: Bool) async throws -> [String: Any] {
        guard let query = WebQuery.all[name] else { throw Failure.unreadable("unknown query \(name)") }
        let variables = variables.merging(query.providers.mapValues(\.value)) { current, _ in current }
        let json = try JSONSerialization.data(withJSONObject: variables, options: [.withoutEscapingSlashes])

        await waitUntilReady()
        let result = try await webView.callAsyncJavaScript(
            Self.graphQLScript,
            arguments: [
                "name": name,
                "docID": query.docID,
                "path": query.path,
                "rootField": query.rootField ?? "",
                "variables": String(decoding: json, as: UTF8.self),
                "freshTokens": freshTokens,
                "seed": siteSeed ?? NSNull(),
            ],
            contentWorld: .defaultClient
        )
        guard let response = result as? [String: Any],
              let status = (response["status"] as? NSNumber)?.intValue,
              let body = response["body"] as? String
        else { throw Failure.unreadable("no response to \(name)") }
        keepSite(from: response)

        #if DEBUG
        if let found = response["found"] {
            // Which session values the website's page provided, by length. Never the values.
            NetworkRecorder.append(["time": Date().ISO8601Format(), "siteValues": found, "query": name, "status": status])
        }
        #endif
        return try Self.data(of: name, status: status, body: body)
    }

    /// Runs first in the hidden page: the session values the website embeds in its pages. Every
    /// request waiting for them shares one load of the page. Values saved at the last launch
    /// (`seed`) are used at once and renewed behind once they're an hour old; `freshTokens` loads
    /// them again now, after a request failed.
    private static let siteScript = #"""
        if (!window.unreeledLoadSite) {
          window.unreeledLoadSite = () => window.unreeledSiteLoading ??= (async () => {
            try {
              const html = await (await fetch('/', { credentials: 'include' })).text();
              const find = (...patterns) => {
                for (const pattern of patterns) {
                  const match = html.match(pattern);
                  if (match) return match[1];
                }
                return '';
              };
              const loaded = {
                time: Date.now(),
                dtsg: find(/"DTSGInitialData",\[\],\{"token":"([^"]+)"/, /"dtsg":\{"token":"([^"]+)"/),
                lsd: find(/"LSD",\[\],\{"token":"([^"]+)"/, /"lsd":"([^"]+)"/),
                av: find(/"actorID":"(\d+)"/, /"viewerId":"(\d+)"/, /"viewer_id":"(\d+)"/),
                rev: find(/"server_revision":(\d+)/, /"__spin_r":(\d+)/),
                hs: find(/"haste_session":"([^"]+)"/),
                hsi: find(/"hsi":"(\d+)"/),
                spinT: find(/"__spin_t":(\d+)/),
                bloks: find(/"versioningID":"([0-9a-f]+)"/),
                dtsgAG: find(/"async_get_token":"([^"]+)"/),
              };
              window.unreeledSite = loaded;
              window.unreeledSiteFresh = loaded;
              return loaded;
            } finally {
              window.unreeledSiteLoading = null;
            }
          })();
        }
        let site = window.unreeledSite;
        let found;
        if (!site && seed && seed.dtsg && Date.now() - seed.time < 86400000) {
          site = window.unreeledSite = seed;
        }
        if (freshTokens || !site) {
          site = await window.unreeledLoadSite();
          found = Object.fromEntries(Object.entries(site).filter(([key]) => key !== 'time').map(([key, value]) => [key, value.length]));
        } else if (Date.now() - site.time > 3600000) {
          window.unreeledLoadSite().catch(() => {});
        }
        const fresh = window.unreeledSiteFresh ?? null;
        window.unreeledSiteFresh = null;
        """#

    /// Runs in the hidden page: sends the query with the parameters and headers the website uses.
    /// The string "{viewer}" in the variables becomes the account's ID as the website knows it.
    private static let graphQLScript = siteScript + #"""
        variables = variables.replaceAll('"{viewer}"', JSON.stringify(site.av));
        window.unreeledRequests = (window.unreeledRequests ?? 0) + 1;
        const params = {
          av: site.av, __d: 'www', __user: '0', __a: '1', __req: window.unreeledRequests.toString(36),
          __hs: site.hs, dpr: String(Math.round(devicePixelRatio)), __ccg: 'EXCELLENT', __rev: site.rev,
          __hsi: site.hsi, __comet_req: '7', fb_dtsg: site.dtsg,
          jazoest: '2' + [...site.dtsg].reduce((sum, char) => sum + char.charCodeAt(0), 0),
          lsd: site.lsd, __spin_r: site.rev, __spin_b: 'trunk', __spin_t: site.spinT,
          fb_api_caller_class: 'RelayModern', fb_api_req_friendly_name: name, variables,
          server_timestamps: 'true', doc_id: docID,
        };
        const headers = {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-ASBD-ID': '359341',
          'X-CSRFToken': document.cookie.match(/(?:^|;\s*)csrftoken=([^;]*)/)?.[1] ?? '',
          'X-FB-Friendly-Name': name,
          'X-FB-LSD': site.lsd,
          'X-IG-App-ID': '1217981644879628',
          'X-IG-Max-Touch-Points': String(navigator.maxTouchPoints),
        };
        if (rootField) {
          headers['X-Root-Field-Name'] = rootField;
          if (site.bloks) headers['X-BLOKS-VERSION-ID'] = site.bloks;
        }
        const body = new URLSearchParams(Object.entries(params).filter(([, value]) => value !== '')).toString();
        const response = await fetch(path, { method: 'POST', headers, body, credentials: 'include' });
        return { status: response.status, body: await response.text(), found, fresh };
        """#

    /// The data of a GraphQL response, with streamed parts merged in.
    private static func data(of name: String, status: Int, body: String) throws -> [String: Any] {
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

    private static func merge(_ piece: Any, at path: ArraySlice<Any>, into node: Any) -> Any {
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
        let (status, body) = try await upload(
            target: "mercury", url: "/ajax/mercury/upload.php", data: data, mimeType: mimeType, fileName: fileName,
            headers: [:], fields: fields
        )
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

    /// Uploads a story's photo or video to Instagram's upload service, as the website's story
    /// camera does. `kind` is "igphoto" or "igvideo".
    func ruploadForStory(kind: String, entityName: String, data: Data, mimeType: String, params: [String: Any]) async throws {
        let paramsJSON = try JSONSerialization.data(withJSONObject: params, options: [.withoutEscapingSlashes])
        var headers = [
            "Offset": "0",
            "X-Entity-Length": String(data.count),
            "X-Entity-Name": entityName,
            "X-Instagram-Rupload-Params": String(decoding: paramsJSON, as: UTF8.self),
        ]
        if kind == "igphoto" { headers["X-Entity-Type"] = mimeType }
        let (status, body) = try await upload(
            target: "rupload", url: "https://i.instagram.com/rupload_\(kind)/\(entityName)",
            data: data, mimeType: mimeType, fileName: entityName, headers: headers, fields: []
        )
        try Self.check(status: status, data: Data(body.utf8))
    }

    private func upload(
        target: String, url: String, data: Data, mimeType: String, fileName: String, headers: [String: String],
        fields: [(String, String)]
    ) async throws -> (status: Int, body: String) {
        await waitUntilReady()
        let result: Any?
        do {
            result = try await runUpload(
                target: target, url: url, data: data, mimeType: mimeType, fileName: fileName, headers: headers, fields: fields
            )
        } catch let error as NSError {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            #if DEBUG
            NetworkRecorder.append(["time": Date().ISO8601Format(), "uploadScriptError": message])
            #endif
            throw Failure.unreadable("the upload stopped: \(message)")
        }
        return try uploadResponse(result, target: target, data: data, mimeType: mimeType)
    }

    private func runUpload(
        target: String, url: String, data: Data, mimeType: String, fileName: String, headers: [String: String],
        fields: [(String, String)]
    ) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            Self.uploadScript,
            arguments: [
                "target": target, "url": url, "data": data.base64EncodedString(), "mime": mimeType, "fileName": fileName,
                "uploadID": UUID().uuidString.lowercased(), "extraHeaders": headers, "freshTokens": false,
                "seed": siteSeed ?? NSNull(),
                "fields": fields.map { [$0.0, $0.1] },
            ],
            contentWorld: .defaultClient
        )
    }

    private func uploadResponse(_ result: Any?, target: String, data: Data, mimeType: String) throws -> (status: Int, body: String) {
        guard let response = result as? [String: Any],
              let status = (response["status"] as? NSNumber)?.intValue,
              var body = response["body"] as? String
        else { throw Failure.unreadable("no response to the upload") }
        keepSite(from: response)
        if body.hasPrefix("for (;;);") { body.removeFirst("for (;;);".count) }
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "upload": target, "bytes": data.count, "mime": mimeType, "status": status])
        #endif
        return (status, body)
    }

    /// Runs in the hidden page. Chat uploads go to /ajax/mercury/upload.php as a form with the
    /// file in "farr" and the session values in the URL; story uploads post the bytes to
    /// i.instagram.com/rupload_… with what they are in headers. Both as the website sends them.
    private static let uploadScript = siteScript + #"""
        const bytes = Uint8Array.from(atob(data), (char) => char.charCodeAt(0));
        const blob = new Blob([bytes], { type: mime });
        let response;
        if (target === 'mercury') {
          window.unreeledRequests = (window.unreeledRequests ?? 0) + 1;
          const params = {
            __d: 'www', __user: '0', __a: '1', __req: window.unreeledRequests.toString(36), __hs: site.hs,
            dpr: String(Math.round(devicePixelRatio)), __ccg: 'EXCELLENT', __rev: site.rev, __hsi: site.hsi,
            __comet_req: '7', fb_dtsg: site.dtsg,
            jazoest: '2' + [...site.dtsg].reduce((sum, char) => sum + char.charCodeAt(0), 0),
            lsd: site.lsd, __spin_r: site.rev, __spin_b: 'trunk', __spin_t: site.spinT,
          };
          const query = new URLSearchParams(Object.entries(params).filter(([, value]) => value !== '')).toString();
          const form = new FormData();
          for (const [name, value] of fields) form.append(name, value);
          form.append('farr', blob, fileName);
          form.append('upload_id', uploadID);
          response = await fetch(url + '?' + query, {
            method: 'POST', body: form, credentials: 'include',
            headers: { 'X-ASBD-ID': '359341', 'X-FB-LSD': site.lsd },
          });
        } else {
          // i.instagram.com, from www: the website's headers there. No CSRF token (it only goes
          // to the website's own /api/ paths), claim or device ID.
          try {
            response = await fetch(url, {
              method: 'POST', body: blob, credentials: 'include',
              headers: Object.assign({
                'X-ASBD-ID': '359341',
                'X-IG-App-ID': '1217981644879628',
                'X-IG-Max-Touch-Points': String(navigator.maxTouchPoints),
                'X-Instagram-AJAX': site.rev,
              }, extraHeaders),
            });
          } catch (error) {
            return { status: 0, body: JSON.stringify({ message: 'upload blocked: ' + String(error) }) };
          }
        }
        return { status: response.status, body: await response.text(), fresh };
        """#

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
        await waitUntilReady()
        let result = try await webView.callAsyncJavaScript(
            Self.cometGETScript,
            arguments: [
                "path": path,
                "parameters": parameters.map { [$0.0, $0.1] },
                "route": route,
                "freshTokens": freshTokens,
                "seed": siteSeed ?? NSNull(),
            ],
            contentWorld: .defaultClient
        )
        guard let response = result as? [String: Any],
              let status = (response["status"] as? NSNumber)?.intValue,
              var body = response["body"] as? String
        else { throw Failure.unreadable("no response") }
        keepSite(from: response)
        if body.hasPrefix("for (;;);") { body.removeFirst("for (;;);".count) }
        let data = Data(body.utf8)
        try Self.check(status: status, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.http(status: status, message: nil)
        }
        if let summary = json["errorSummary"] as? String { throw Failure.query(summary) }
        guard let payload = json["payload"], !(payload is NSNull) else { throw Failure.http(status: status, message: nil) }
        return payload
    }

    /// Runs in the hidden page, after the session values are read.
    private static let cometGETScript = siteScript + #"""
        let refreshed = null;
        if (site.dtsgAG === undefined) {
          // Saved before the app read this value: read the page once more.
          site = await window.unreeledLoadSite();
          refreshed = window.unreeledSiteFresh ?? null;
          window.unreeledSiteFresh = null;
        }
        window.unreeledRequests = (window.unreeledRequests ?? 0) + 1;
        const token = site.dtsgAG ?? '';
        const common = [
          ['__d', 'www'], ['__user', '0'], ['__a', '1'], ['__req', window.unreeledRequests.toString(36)],
          ['__hs', site.hs], ['dpr', String(Math.round(devicePixelRatio))], ['__ccg', 'EXCELLENT'],
          ['__rev', site.rev], ['__hsi', site.hsi], ['__comet_req', '7'], ['fb_dtsg_ag', token],
          ['jazoest', token ? '2' + [...token].reduce((sum, char) => sum + char.charCodeAt(0), 0) : ''],
          ['__spin_r', site.rev], ['__spin_b', 'trunk'], ['__spin_t', site.spinT], ['__crn', route],
        ];
        const query = new URLSearchParams([...parameters, ...common].filter(([, value]) => value !== '')).toString();
        const response = await fetch(path + '?' + query, {
          method: 'GET',
          credentials: 'include',
          headers: {
            'X-ASBD-ID': '359341',
            'X-FB-LSD': site.lsd,
            'X-IG-App-ID': '1217981644879628',
            'X-IG-D': 'www',
            'X-IG-Max-Touch-Points': String(navigator.maxTouchPoints),
          },
        });
        return { status: response.status, body: await response.text(), fresh: refreshed ?? fresh };
        """#

    // MARK: REST

    /// The response body of a request to one of the website's REST endpoints (/api/v1/…),
    /// after checking for the errors Instagram reports.
    func send(_ method: String, _ path: String, form: [String: String] = [:]) async throws -> Data {
        let (status, body) = try await raw(method, path, form: form)
        let data = Data(body.utf8)
        try Self.check(status: status, data: data)
        return data
    }

    /// Status and body text, whatever they are.
    func raw(_ method: String, _ path: String, form: [String: String] = [:]) async throws -> (status: Int, body: String) {
        await waitUntilReady()
        let result = try await webView.callAsyncJavaScript(
            Self.restScript,
            arguments: ["method": method, "path": path, "form": form],
            contentWorld: .defaultClient
        )
        guard let response = result as? [String: Any],
              let status = (response["status"] as? NSNumber)?.intValue,
              var body = response["body"] as? String
        else { throw Failure.unreadable("no response") }
        if body.hasPrefix("for (;;);") { body.removeFirst("for (;;);".count) }
        return (status, body)
    }

    private static let restScript = #"""
        const headers = {
          'X-ASBD-ID': '359341',
          'X-CSRFToken': document.cookie.match(/(?:^|;\s*)csrftoken=([^;]*)/)?.[1] ?? '',
          'X-IG-App-ID': '1217981644879628',
          'X-IG-WWW-Claim': sessionStorage.getItem('www-claim-v2') ?? '0',
          'X-Requested-With': 'XMLHttpRequest',
        };
        const init = { method, headers, credentials: 'include' };
        if (method !== 'GET') {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
          init.body = new URLSearchParams(form).toString();
        }
        const response = await fetch(path, init);
        const claim = response.headers.get('x-ig-set-www-claim');
        if (claim) sessionStorage.setItem('www-claim-v2', claim);
        return { status: response.status, body: await response.text() };
        """#

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
        let cookies = await dataStore.httpCookieStore.allCookies()
        return cookies.first { $0.name == "ig_did" && $0.domain.hasSuffix("instagram.com") }?.value ?? ""
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw Failure.unreadable(Self.describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
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

    // MARK: Hidden page

    private func loadBlankPage() {
        isReady = false
        webView.loadHTMLString("<!doctype html><meta charset=utf-8><title>Unreeled</title>", baseURL: Self.site)
    }

    private func waitUntilReady() async {
        guard !isReady else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

extension InstagramAPI: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        let waiting = self.waiting
        self.waiting.removeAll()
        waiting.forEach { $0.resume() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadBlankPage()
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

/// Puts the API's web view in the window, invisibly, where WebKit keeps it running.
struct APIWebView: UIViewRepresentable {
    let api: InstagramAPI

    func makeUIView(context: Context) -> WKWebView { api.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
