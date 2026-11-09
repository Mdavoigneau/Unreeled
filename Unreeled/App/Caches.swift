import Foundation
import Security

/// Instagram's responses kept on the phone, so screens show at once and refresh behind. It cleans
/// itself: anything unused for two weeks goes, and past 150 entries or 50 MB the least recently
/// used go first. Logging out empties it.
final class ResponseCache: @unchecked Sendable {
    static let shared = ResponseCache()

    private static let maxAge: TimeInterval = 14 * 86_400
    private static let maxEntries = 150
    private static let maxBytes = 50 << 20

    private let folder = URL.cachesDirectory.appending(path: "Responses", directoryHint: .isDirectory)
    private let queue = DispatchQueue(label: "Unreeled.ResponseCache", qos: .utility)

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The saved response, marked as just used. Small files: read right away.
    func data(for key: String) -> Data? {
        let url = file(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        queue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return data
    }

    func store(_ data: Data, for key: String) {
        let url = file(for: key)
        queue.async {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func removeAll() {
        let folder = folder
        queue.async {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Drops what's old, then the least recently used past the limits.
    func clean() {
        let folder = folder
        queue.async {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
            let entries = files
                .map { url -> (url: URL, used: Date, bytes: Int) in
                    let values = try? url.resourceValues(forKeys: keys)
                    return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
                }
                .sorted { $0.used > $1.used }
            var total = 0
            for (index, entry) in entries.enumerated() {
                total += entry.bytes
                if Date.now.timeIntervalSince(entry.used) > Self.maxAge || index >= Self.maxEntries || total > Self.maxBytes {
                    try? FileManager.default.removeItem(at: entry.url)
                }
            }
        }
    }

    private func file(for key: String) -> URL {
        let name = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return folder.appending(path: name + ".json")
    }
}

/// Conversations, decoded once from the saved copy and kept in memory while the app runs.
@MainActor
enum ThreadStore {
    private static var memory: [String: DirectThread] = [:]
    private static var order: [String] = []

    static func cached(_ id: String) -> DirectThread? {
        if let thread = memory[id] {
            touch(id)
            return thread
        }
        guard let data = ResponseCache.shared.data(for: key(id)),
              let thread = try? InstagramAPI.decodeThread(data)
        else { return nil }
        remember(thread, id: id)
        return thread
    }

    /// Like `cached`, reading the saved copy off the main thread.
    static func load(_ id: String) async -> DirectThread? {
        if let thread = memory[id] { return thread }
        let key = key(id)
        let thread = await Task.detached(priority: .utility) { () -> DirectThread? in
            guard let data = ResponseCache.shared.data(for: key) else { return nil }
            return try? InstagramAPI.decodeThread(data)
        }.value
        if let thread, memory[id] == nil { remember(thread, id: id) }
        return memory[id] ?? thread
    }

    /// The conversation as Instagram just returned it, for next time.
    static func save(_ data: Data, thread: DirectThread, id: String) {
        ResponseCache.shared.store(data, for: key(id))
        remember(thread, id: id)
    }

    static func removeAll() {
        memory = [:]
        order = []
    }

    private static func key(_ id: String) -> String { "thread-\(id)" }

    private static func remember(_ thread: DirectThread, id: String) {
        memory[id] = thread
        touch(id)
        while order.count > 30 { memory[order.removeFirst()] = nil }
    }

    private static func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

/// How often you open each conversation, to keep the ones you open most ready.
enum ChatStats {
    private static let key = "chatOpens"

    static func recordOpen(_ threadID: String) {
        var opens = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        opens[threadID, default: 0] += 1
        if opens.count > 60 {
            for (id, _) in opens.sorted(by: { $0.value < $1.value }).prefix(opens.count - 60) { opens[id] = nil }
        }
        UserDefaults.standard.set(opens, forKey: key)
    }

    /// The conversations you open most, most first.
    static func mostOpened(_ limit: Int) -> [String] {
        let opens = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        return opens.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// A small secret in the Keychain, readable once the phone has been unlocked after a restart.
enum SecureStore {
    private static let service = Bundle.main.bundleIdentifier ?? "Unreeled"

    static func data(for account: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data?, for account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard let data else { return }
        var item = match
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
