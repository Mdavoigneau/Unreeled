import Foundation

/// Keeps the app's list of Instagram's queries current without a new version of the app.
///
/// Instagram gives a query a new ID whenever it changes it, and the old ID stops working. The
/// project keeps Queries.json current on unreeled.app and in its repository. The app checks for a
/// newer copy at launch (at most every 6 hours) and right after a query fails (at most every 10
/// minutes), and uses it instead of the copy it shipped with. Only IDs and settings for queries
/// this version already sends are taken; anything that doesn't look right is ignored.
///
/// The request carries nothing about you or your account.
@MainActor
enum QueryUpdates {
    static var sources: [URL] {
        #if DEBUG
        // -queriesURL <url> checks that address instead, to test an update.
        if let test = UserDefaults.standard.string(forKey: "queriesURL").flatMap(URL.init(string:)) { return [test] }
        #endif
        return [
            URL(string: "https://unreeled.app/queries.json")!,
            URL(string: "https://raw.githubusercontent.com/Mdavoigneau/Unreeled/main/Unreeled/API/Queries.json")!,
        ]
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Queries.json")
    /// When the app last looked for a list, and from which version.
    private static let checkedKey = "queriesChecked"
    private static let checkedBuildKey = "queriesCheckedBuild"
    /// When the saved list was taken, and by which version.
    private static let updatedKey = "queriesUpdated"
    private static let buildKey = "queriesBuild"
    private static var checking: Task<Bool, Never>?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// When the newer list in use was taken; nil while the app uses the list it shipped with.
    static var updatedAt: Date? {
        guard UserDefaults.standard.string(forKey: buildKey) == build else { return nil }
        return UserDefaults.standard.object(forKey: updatedKey) as? Date
    }

    /// The list the app shipped with, with the newest copy it took on top. A copy taken by an
    /// earlier version of the app is left out until the next check.
    static func load(over bundled: [String: WebQuery]) -> [String: WebQuery] {
        guard updatedAt != nil, let data = try? Data(contentsOf: file),
              let saved = try? validated(data, known: bundled)
        else { return bundled }
        return bundled.merging(saved) { _, newer in newer }
    }

    /// Looks for a newer list unless one was looked for recently: 6 hours, or 10 minutes when a
    /// query just failed. True when a query changed.
    @discardableResult
    static func check(afterFailure: Bool) async -> Bool {
        if let checking { return await checking.value }
        let last = UserDefaults.standard.object(forKey: checkedKey) as? Date ?? .distantPast
        let interval: TimeInterval = afterFailure ? 600 : 6 * 3600
        let isNewBuild = UserDefaults.standard.string(forKey: checkedBuildKey) != build
        guard isNewBuild || Date.now.timeIntervalSince(last) > interval else { return false }
        let task = Task { await fetch() }
        checking = task
        let changed = await task.value
        checking = nil
        return changed
    }

    private static func fetch() async -> Bool {
        UserDefaults.standard.set(Date.now, forKey: checkedKey)
        UserDefaults.standard.set(build, forKey: checkedBuildKey)
        for source in sources {
            let status: Int
            let fetched: [String: WebQuery]
            let data: Data
            do {
                let (body, response) = try await session.data(from: source)
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw URLError(.badServerResponse) }
                fetched = try validated(body, known: WebQuery.bundled)
                data = body
            } catch {
                log(source, ["error": String(describing: error)])
                continue
            }
            let before = WebQuery.all
            let queries = WebQuery.bundled.merging(fetched) { _, newer in newer }
            if queries == WebQuery.bundled {
                // Nothing newer than what the app shipped with.
                try? FileManager.default.removeItem(at: file)
                UserDefaults.standard.removeObject(forKey: updatedKey)
            } else if queries != before || updatedAt == nil {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                UserDefaults.standard.set(Date.now, forKey: updatedKey)
            }
            UserDefaults.standard.set(build, forKey: buildKey)
            WebQuery.all = queries
            let changed = queries.keys.filter { queries[$0] != before[$0] }.sorted()
            log(source, ["valid": fetched.count, "changed": changed])
            return !changed.isEmpty
        }
        return false
    }

    /// The entries of a list that are well formed and name a query this version sends. Throws when
    /// none are.
    static func validated(_ data: Data, known: [String: WebQuery]) throws -> [String: WebQuery] {
        let list = try JSONDecoder().decode([String: Lenient].self, from: data)
        let valid = list.compactMapValues(\.query).filter { name, query in
            known[name] != nil
                && !query.docID.isEmpty && query.docID.allSatisfy(\.isASCIIDigit)
                && ["/api/graphql", "/graphql/query"].contains(query.path)
                && (query.rootField ?? "").allSatisfy { $0.isASCIILetterOrDigit || $0 == "_" }
                && query.providers.keys.allSatisfy { $0.hasPrefix("__relay_internal__pv__") && $0.allSatisfy { $0.isASCIILetterOrDigit || $0 == "_" } }
        }
        guard !valid.isEmpty else { throw URLError(.cannotParseResponse) }
        return valid
    }

    /// One entry, or nil when it doesn't decode, so one bad entry doesn't throw the list away.
    private struct Lenient: Decodable {
        let query: WebQuery?

        init(from decoder: Decoder) throws {
            query = try? WebQuery(from: decoder)
        }
    }

    private static var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "")-\(info?["CFBundleVersion"] as? String ?? "")"
    }

    private static func log(_ source: URL, _ details: [String: Any]) {
        #if DEBUG
        var entry: [String: Any] = ["time": Date().ISO8601Format(), "queryUpdate": source.absoluteString]
        entry.merge(details) { _, new in new }
        NetworkRecorder.append(entry)
        #endif
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetterOrDigit: Bool { isASCII && (isLetter || isNumber) }
}
