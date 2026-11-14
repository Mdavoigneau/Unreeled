import CryptoKit
import Foundation

/// Keeps the app's list of Instagram's queries current without a new version of the app.
///
/// Instagram gives a query a new ID whenever it changes it, and the old ID stops working. The
/// project keeps Queries.json current on unreeled.app and in its repository. The app checks for a
/// newer copy at launch (at most every 6 hours) and right after a query fails (at most every 10
/// minutes), and uses it instead of the copy it shipped with.
///
/// A list counts only with its signature, Queries.json.sig from the same place: made with the
/// project's key over the list and the time it was signed (tools/sign-queries.mjs). So whoever
/// can change what the website or GitHub serve still can't choose which of Instagram's queries
/// the app sends; only whoever keeps the key can. A list signed before the one in use is ignored,
/// so an older list can't be served again either. Of a signed list, only IDs and settings for
/// queries this version already sends are taken; anything that doesn't look right is ignored.
///
/// The requests carry nothing about you or your account.
@MainActor
enum QueryUpdates {
    /// The keys a list may be signed with: Ed25519, raw, base64. Whoever maintains the list keeps
    /// the private half (docs/MAINTAINING.md). tools/query-signature.mjs reads them from here.
    static let publicKeys = [
        "koGDZinm2HoJnjM7/yXCi/nyxq2ow8gC3BREmCostcU=",
    ]

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
    private static let signatureFile = URL.applicationSupportDirectory.appending(path: "Queries.json.sig")
    /// When the app last looked for a list, and from which version.
    private static let checkedKey = "queriesChecked"
    private static let checkedBuildKey = "queriesCheckedBuild"
    /// When the saved list was taken, and by which version.
    private static let updatedKey = "queriesUpdated"
    private static let buildKey = "queriesBuild"
    /// When the newest list the app took was signed.
    private static let signedKey = "queriesSigned"
    private static var checking: Task<Bool, Never>?

    /// The most a list, or its signature, can be: the list is about 8 KB.
    private static let listLimit = 512 << 10
    private static let signatureLimit = 4 << 10

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

    /// The list the app shipped with, with the newest copy it took on top, as long as that copy's
    /// signature still holds. A copy taken by an earlier version of the app is left out until the
    /// next check.
    static func load(over bundled: [String: WebQuery]) -> [String: WebQuery] {
        guard updatedAt != nil, let data = try? Data(contentsOf: file) else { return bundled }
        let signature = try? Data(contentsOf: signatureFile)
        guard let signature, let signed = try? signedTime(of: data, signature: signature), signed >= bundledSigned,
              let saved = try? validated(data, known: bundled)
        else {
            // A copy whose signature doesn't hold is never used, so it goes, and About stops
            // saying the app took a newer list. Not one the phone can't read yet, before it's
            // first unlocked after a restart.
            if signature != nil || !FileManager.default.fileExists(atPath: signatureFile.path) {
                forgetSaved()
                log(file, ["savedCopy": "deleted: its signature doesn't hold"])
            }
            return bundled
        }
        return bundled.merging(saved) { _, newer in newer }
    }

    /// The saved list and its signature: gone.
    private static func forgetSaved() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: signatureFile)
        UserDefaults.standard.removeObject(forKey: updatedKey)
    }

    /// Looks for a newer list unless one was looked for recently: 6 hours, or 10 minutes when a
    /// query just failed. True when a query changed.
    @discardableResult
    static func check(afterFailure: Bool) async -> Bool {
        if let checking { return await checking.value }
        let last = UserDefaults.standard.object(forKey: checkedKey) as? Date ?? .distantPast
        let interval: TimeInterval = afterFailure ? 600 : 6 * 3600
        let isNewBuild = UserDefaults.standard.string(forKey: checkedBuildKey) != build
        guard isNewBuild || Date.now.timeIntervalSince(last) > interval || isTryingList else { return false }
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
            let data: Data
            let signature: Data?
            let signed: String?
            let fetched: [String: WebQuery]
            do {
                data = try await download(source, limit: listLimit)
                if takesUnsigned {
                    signature = nil
                    signed = nil
                } else {
                    let downloaded: Data
                    do {
                        downloaded = try await download(source.appendingPathExtension("sig"), limit: signatureLimit)
                    } catch {
                        throw Refused.noSignature(String(describing: error))
                    }
                    let time = try signedTime(of: data, signature: downloaded)
                    let inUse = signedInUse
                    guard time >= inUse else { throw Refused.older(signed: time, inUse: inUse) }
                    signature = downloaded
                    signed = time
                }
                fetched = try validated(data, known: WebQuery.bundled)
            } catch {
                log(source, ["error": String(describing: error)])
                continue
            }
            if let signed { UserDefaults.standard.set(signed, forKey: signedKey) }
            let before = WebQuery.all
            let queries = WebQuery.bundled.merging(fetched) { _, newer in newer }
            if queries == WebQuery.bundled {
                // Nothing newer than what the app shipped with.
                forgetSaved()
            } else if queries != before || updatedAt == nil {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                if let signature {
                    try? signature.write(to: signatureFile, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: signatureFile)
                }
                UserDefaults.standard.set(Date.now, forKey: updatedKey)
            }
            UserDefaults.standard.set(build, forKey: buildKey)
            WebQuery.all = queries
            let changed = queries.keys.filter { queries[$0] != before[$0] }.sorted()
            log(source, ["valid": fetched.count, "changed": changed, "signed": signed ?? "not checked (-queriesUnsigned)"])
            return !changed.isEmpty
        }
        return false
    }

    /// The body at `url`, when it answers 200 within `limit` bytes.
    private static func download(_ url: URL, limit: Int) async throws -> Data {
        var received = Data()
        try await MediaHosts.download(url, session: session, limit: limit) { http in
            http.statusCode == 200
        } take: { received.append($0) }
        return received
    }

    // MARK: The signature

    /// Why a downloaded list was turned down before its entries were looked at.
    enum Refused: Error {
        /// No signature came with it: none there, or no answer.
        case noSignature(String)
        /// Its signature isn't one of `publicKeys`' over it.
        case unsigned
        /// Signed before the list in use: an older list, served again.
        case older(signed: String, inUse: String)
    }

    /// Queries.json.sig: when the list was signed, and the signature, base64.
    private struct SignatureFile: Decodable {
        let signed: String
        let signature: String
    }

    /// When `list` was signed, if `signature` (a Queries.json.sig) is one of `publicKeys`' over
    /// "Unreeled query list\n", the time, "\n", then the list's bytes. Throws otherwise.
    static func signedTime(of list: Data, signature: Data) throws -> String {
        guard let file = try? JSONDecoder().decode(SignatureFile.self, from: signature),
              isSigningTime(file.signed),
              let bytes = Data(base64Encoded: file.signature)
        else { throw Refused.unsigned }
        let message = Data("Unreeled query list\n\(file.signed)\n".utf8) + list
        let valid = publicKeys.contains { key in
            guard let raw = Data(base64Encoded: key),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            else { return false }
            return publicKey.isValidSignature(bytes, for: message)
        }
        guard valid else { throw Refused.unsigned }
        return file.signed
    }

    /// When the list the app shipped with was signed, from the signature that shipped with it.
    /// A list signed before it is older than the app's own.
    private static let bundledSigned: String = {
        guard let url = Bundle.main.url(forResource: "Queries.json", withExtension: "sig"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SignatureFile.self, from: data),
              isSigningTime(file.signed)
        else { return "" }
        return file.signed
    }()

    /// When the list in use was signed, at the latest: the newest the app took, or its own.
    private static var signedInUse: String {
        max(bundledSigned, UserDefaults.standard.string(forKey: signedKey) ?? "")
    }

    /// A signing time, such as 2026-11-14T10:32:05Z: always in this form, so two compare as text.
    private static func isSigningTime(_ text: String) -> Bool {
        let form = Array("0000-00-00T00:00:00Z")
        let characters = Array(text)
        return characters.count == form.count && zip(characters, form).allSatisfy { character, expected in
            expected == "0" ? character.isASCIIDigit : character == expected
        }
    }

    /// Debug builds: a list being tried, at -queriesURL, is looked for every time.
    private static var isTryingList: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "queriesURL") != nil
        #else
        return false
        #endif
    }

    /// Debug builds: -queriesUnsigned YES, with -queriesURL, takes the list there without a
    /// signature, to try an edit before signing it.
    private static var takesUnsigned: Bool {
        #if DEBUG
        return isTryingList && UserDefaults.standard.bool(forKey: "queriesUnsigned")
        #else
        return false
        #endif
    }

    // MARK: The entries

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
