import Foundation
import WebKit

/// A set of filters from Rules.json for the instagram.com pages the app shows.
struct RuleGroup: Decodable {
    struct Redirect: Codable {
        /// Regular expression (JavaScript syntax) matched against the page's path and query.
        let from: String
        /// Path to load instead. $1, $2… insert what `from` captured.
        let to: String
    }

    let id: String
    let title: String
    /// Set to false to switch the group off.
    let enabled: Bool
    /// CSS selectors of elements to hide.
    let hide: [String]?
    /// Pages to send elsewhere.
    let redirect: [Redirect]?
}

@MainActor
enum WebFilters {
    /// Scripts for a web screen: Filter.js with the enabled rules, plus the network recorder in Debug builds.
    static func contentController() -> WKUserContentController {
        let controller = WKUserContentController()
        controller.addUserScript(filterScript)
        #if DEBUG
        NetworkRecorder.install(in: controller)
        #endif
        return controller
    }

    private struct Config: Encodable {
        var hide: [String] = []
        var redirect: [RuleGroup.Redirect] = []
    }

    /// Filter.js runs in its own JavaScript world, out of reach of the site's scripts.
    private static let filterScript: WKUserScript = {
        var config = Config()
        for group in rules where group.enabled {
            config.hide += group.hide ?? []
            config.redirect += group.redirect ?? []
        }
        let json = String(decoding: try! JSONEncoder().encode(config), as: UTF8.self)
        return WKUserScript(
            source: resource("Filter", "js") + "\nunreeled(\(json));\n",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .world(name: "Unreeled")
        )
    }()

    private static let rules: [RuleGroup] = {
        do {
            return try JSONDecoder().decode([RuleGroup].self, from: Data(resource("Rules", "json").utf8))
        } catch {
            fatalError("Rules.json is invalid: \(error)")
        }
    }()

    private static func resource(_ name: String, _ type: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: type),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("\(name).\(type) is missing from the app bundle") }
        return text
    }
}
