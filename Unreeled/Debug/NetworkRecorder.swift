#if DEBUG
import WebKit

/// Debug builds only: a log of the API calls instagram.com makes in the app's web screens, for
/// finding endpoints. Each line of Library/Caches/network-log.jsonl holds the method, path,
/// GraphQL query name, status, and the *shape* of the JSON response: field names and value types,
/// never the values. Tokens in request bodies are masked.
@MainActor
final class NetworkRecorder: NSObject, WKScriptMessageHandler {
    static let shared = NetworkRecorder()
    static let logURL = URL.cachesDirectory.appending(path: "network-log.jsonl")

    static func install(in controller: WKUserContentController) {
        guard let url = Bundle.main.url(forResource: "Recorder", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        // The page's own world, where its fetch and XMLHttpRequest live.
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(shared, contentWorld: .page, name: "recorder")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let entry = message.body as? [String: Any] else { return }
        Self.append(entry)
    }

    static func append(_ entry: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(UInt8(ascii: "\n"))
        if let file = try? FileHandle(forWritingTo: logURL) {
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: line)
            try? file.close()
        } else {
            try? line.write(to: logURL)
        }
    }

    /// Field names and value types of decoded JSON, without the values. Arrays become
    /// [merged shape of their elements, count]. An object with a GraphQL type is keyed by it, so the
    /// kinds of one thing (a message's content, say) stay apart when merged. Type names and the few
    /// fields in `kindKeys` are names from Instagram's schema, not content, and are kept.
    static func shape(of value: Any, depth: Int = 0) -> Any {
        if depth > 14 { return "…" }
        switch value {
        case let array as [Any]:
            guard !array.isEmpty else { return [Any]() }
            var merged: Any = shape(of: array[0], depth: depth + 1)
            for item in array.dropFirst().prefix(49) {
                merged = merge(merged, shape(of: item, depth: depth + 1))
            }
            return [merged, array.count]
        case let object as [String: Any]:
            var fields: [String: Any] = [:]
            for (key, value) in object where key != "__typename" {
                if kindKeys.contains(key), let kind = value as? String {
                    fields[key] = kind
                } else if key == "target_url", let link = value as? String {
                    fields[key] = linkPattern(link)
                } else {
                    fields[key] = shape(of: value, depth: depth + 1)
                }
            }
            if let type = object["__typename"] as? String { return ["<\(type)>": fields] }
            return fields
        case is NSNull:
            return "null"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String:
            return "string"
        default:
            return "?"
        }
    }

    private static let kindKeys: Set<String> = ["content_type", "__isSlideMessageContent", "xma_layout_type", "media_type"]

    /// A link's site and kind of page, like www.instagram.com/reel/*: what it points to, not where.
    private static func linkPattern(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host() else { return "link" }
        let parts = url.pathComponents.filter { $0 != "/" }
        let kinds: Set<String> = ["p", "reel", "reels", "tv", "stories", "explore", "direct", "s", "accounts"]
        let first = parts.first.map { kinds.contains($0) ? $0 : "*" } ?? ""
        return "\(host)/\(first)" + (parts.count > 1 ? "/*" : "")
    }

    private static func merge(_ a: Any, _ b: Any) -> Any {
        if a as? String == "null" { return b }
        if b as? String == "null" { return a }
        if let a = a as? [String: Any], let b = b as? [String: Any] {
            return a.merging(b) { merge($0, $1) }
        }
        if let a = a as? [Any], let b = b as? [Any] {
            if a.isEmpty { return b }
            if b.isEmpty { return a }
            return [merge(a[0], b[0]), max(a[1] as? Int ?? 0, b[1] as? Int ?? 0)]
        }
        if let a = a as? String, let b = b as? String, a != b {
            return Set(a.components(separatedBy: " | ") + b.components(separatedBy: " | ")).sorted().joined(separator: " | ")
        }
        return a
    }
}

/// Debug builds only: -probe calls endpoints through InstagramAPI at launch and logs their status
/// and response shape to network-log.jsonl, like the recorder does. Separate several probes with
/// " | ".
///
/// - `GQL <QueryName> {"variables":…}` runs a query from Queries.json (providers are added).
/// - `GET /api/v1/…` calls a REST endpoint; a POST takes its form after the path: `POST /api/v1/… a=1&b=2`.
/// - `PUSH <address> <p256dh> <auth>` registers a web push address for this login. It writes to
///   the account: Instagram starts sending its notifications there.
enum DebugProbe {
    @MainActor
    static func runIfRequested(api: InstagramAPI) async {
        guard let spec = UserDefaults.standard.string(forKey: "probe") else { return }
        for probe in spec.components(separatedBy: " | ") {
            let parts = probe.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            if parts[0] == "PUSH" {
                let keys = parts.count == 3 ? parts[2].split(separator: " ").map(String.init) : []
                // The address ends in a secret: only its host is logged.
                var entry: [String: Any] = ["probe": true, "pushRegistration": URL(string: parts[1])?.host() ?? "?", "time": Date().ISO8601Format()]
                do {
                    guard keys.count == 2 else { throw InstagramAPI.Failure.unreadable("PUSH takes an address and two keys") }
                    try await api.registerWebPush(endpoint: parts[1], p256dh: keys[0], auth: keys[1])
                    entry["status"] = "ok"
                } catch {
                    entry["error"] = error.localizedDescription
                }
                NetworkRecorder.append(entry)
                continue
            }
            if parts[0] == "GQL" {
                let json = parts.count == 3 ? parts[2] : "{}"
                let variables = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
                var entry: [String: Any] = ["probe": true, "query": parts[1], "time": Date().ISO8601Format()]
                do {
                    entry["shape"] = NetworkRecorder.shape(of: try await api.graphQL(parts[1], variables))
                } catch {
                    entry["error"] = error.localizedDescription
                }
                NetworkRecorder.append(entry)
                continue
            }
            var form: [String: String] = [:]
            if parts.count == 3 {
                for pair in parts[2].split(separator: "&") {
                    let keyValue = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    form[keyValue[0]] = keyValue.count > 1 ? (keyValue[1].removingPercentEncoding ?? keyValue[1]) : ""
                }
            }
            var entry: [String: Any] = ["probe": true, "method": parts[0], "path": parts[1], "time": Date().ISO8601Format()]
            do {
                let (status, body) = try await api.raw(parts[0], parts[1], form: form)
                entry["status"] = status
                entry["bytes"] = body.utf8.count
                if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) {
                    entry["shape"] = NetworkRecorder.shape(of: json)
                    if let object = json as? [String: Any] {
                        // Instagram's error fields are safe to keep verbatim.
                        for key in ["message", "status", "error_type", "require_login"] where object[key] != nil {
                            entry[key] = object[key]
                        }
                    }
                } else {
                    entry["shape"] = body.hasPrefix("<") ? "(web page)" : "(not JSON)"
                }
            } catch {
                entry["error"] = error.localizedDescription
            }
            NetworkRecorder.append(entry)
        }
    }
}

/// Debug builds only: -findScripts '<regex>' searches the website's own scripts, as a web screen
/// loaded them, and logs each match with the code around it, plus the ID of every GraphQL
/// operation whose name matches. That finds a mutation's ID and variables without running it.
/// The scripts are the website's public code, fetched without cookies. They're also saved to
/// Library/Caches/scripts/, to search further from the Mac.
enum ScriptSearch {
    private static var started = false

    @MainActor
    static func runIfRequested(in webView: WKWebView) {
        guard !started, let pattern = UserDefaults.standard.string(forKey: "findScripts"),
              let regex = try? NSRegularExpression(pattern: pattern)
        else { return }
        started = true
        Task {
            // Let the page load what it loads lazily.
            try? await Task.sleep(for: .seconds(12))
            let urls = (try? await webView.evaluateJavaScript(collectScript)) as? [String] ?? []
            NetworkRecorder.append(["time": Date().ISO8601Format(), "scriptSearch": pattern, "scripts": urls.count])
            let session = URLSession(configuration: .ephemeral)
            let folder = URL.cachesDirectory.appending(path: "scripts")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var operations: [String: String] = [:]
            var matches = 0
            for url in urls.compactMap(URL.init(string:)) {
                guard let (data, _) = try? await session.data(from: url),
                      let text = String(data: data, encoding: .utf8)
                else { continue }
                try? data.write(to: folder.appending(path: String(url.lastPathComponent.suffix(60))))
                let whole = NSRange(text.startIndex..., in: text)
                for match in operationID.matches(in: text, range: whole) {
                    guard let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                          let id = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                          regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                    else { continue }
                    operations[name] = id
                }
                for match in regex.matches(in: text, range: whole).prefix(6) where matches < 80 {
                    guard let found = Range(match.range, in: text) else { continue }
                    let start = text.index(found.lowerBound, offsetBy: -500, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(found.upperBound, offsetBy: 900, limitedBy: text.endIndex) ?? text.endIndex
                    matches += 1
                    NetworkRecorder.append(["scriptMatch": url.lastPathComponent, "found": String(text[found]), "code": String(text[start..<end])])
                }
            }
            NetworkRecorder.append(["time": Date().ISO8601Format(), "scriptSearch": "done", "operations": operations, "matches": matches])
        }
    }

    /// `__d("SomeQuery_instagramRelayOperation",[],(function(…){…exports="1234"}),…)`
    private static let operationID = try! NSRegularExpression(
        pattern: #"__d\("([A-Za-z0-9_]+)_instagramRelayOperation".{0,160}?exports="(\d+)""#,
        options: [.dotMatchesLineSeparators]
    )

    /// Every script the page has, has loaded, or names in its HTML for later.
    private static let collectScript = #"""
    (() => {
      const urls = new Set();
      for (const s of document.scripts) if (s.src) urls.add(s.src);
      for (const e of performance.getEntriesByType('resource')) {
        if (e.initiatorType === 'script' || /\.js(\?|$)/.test(e.name)) urls.add(e.name);
      }
      const html = document.documentElement.outerHTML;
      for (const m of html.matchAll(/https:\\?\/\\?\/static\.cdninstagram\.com\\?\/rsrc\.php\\?\/[^"'\s]+?\.js/g)) {
        urls.add(m[0].replace(/\\\//g, '/'));
      }
      return Array.from(urls);
    })()
    """#
}
#endif
