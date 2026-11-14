import CryptoKit
import Foundation
import Security

/// Whose saved copies the app reads and keeps: the account logged in, which Session sets as the
/// login changes, and nil while there's none, when nothing is read or kept. Each account's copies
/// are files of their own (see ResponseCache), so one account's never show for another, even in
/// the moment before they're deleted.
enum SavedCopies {
    private static let lock = NSLock()
    private static var current: String?

    static var account: String? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Instagram's responses kept on the phone, so screens show at once and refresh behind. It cleans
/// itself: anything unused for two weeks goes, and past 100 entries or 40 MB the least recently
/// used go first, and so does anything Instagram hasn't sent again for a month. Conversations are
/// kept apart, so visiting profiles never pushes them out: the 60 you opened last, for a month.
/// So are your own profile and your activity (keys starting with `kept-`), a few hundred
/// kilobytes, which stay until you log out. Each account has its own copies, and the end of a
/// login empties it.
final class ResponseCache: @unchecked Sendable {
    static let shared = ResponseCache()

    private static let maxAge: TimeInterval = 14 * 86_400
    private static let maxEntries = 100
    private static let maxBytes = 40 << 20
    private static let conversationMaxAge: TimeInterval = 30 * 86_400
    private static let maxConversations = 60
    /// A copy Instagram hasn't sent again for this long goes, however often it's read: a profile
    /// that no longer loads, a conversation you've left.
    private static let maxUnconfirmed: TimeInterval = 30 * 86_400

    private let folder = URL.cachesDirectory.appending(path: "Copies", directoryHint: .isDirectory)
    private let queue = DispatchQueue(label: "Unreeled.ResponseCache", qos: .utility)

    private init() {
        CacheFolder.create(folder)
        // Copies from before each account had files of its own, named after their keys alone:
        // they go, once. Screens fill again from Instagram.
        let earlier = URL.cachesDirectory.appending(path: "Responses", directoryHint: .isDirectory)
        queue.async { try? FileManager.default.removeItem(at: earlier) }
    }

    /// The saved response of the account logged in, marked as just used. Small files: read right away.
    func data(for key: String) -> Data? {
        guard let account = SavedCopies.account else { return nil }
        let url = file(for: key, account: account)
        guard let data = try? Data(contentsOf: url) else { return nil }
        queue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return data
    }

    /// Keeps a response for `account`, the one logged in when it was asked for. Once that login
    /// has ended or changed, an answer still on its way isn't kept.
    func store(_ data: Data, for key: String, account: String?) {
        guard let account, account == SavedCopies.account else { return }
        let url = file(for: key, account: account)
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

    /// Drops what's old, or hasn't come from Instagram again for a month, then the least recently
    /// used past the limits.
    func clean() {
        let folder = folder
        queue.async {
            let all = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: CacheFolder.keys + [.creationDateKey]
            )) ?? []
            // Each write makes a new file, so its creation date is when Instagram last sent it.
            let files = all.filter { file in
                guard !file.lastPathComponent.hasPrefix("kept-") else { return false }
                let written = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                guard Date.now.timeIntervalSince(written) > Self.maxUnconfirmed else { return true }
                try? FileManager.default.removeItem(at: file)
                return false
            }
            let isConversation = { (file: URL) in file.lastPathComponent.hasPrefix("thread-") }
            CacheFolder.prune(files.filter(isConversation), maxAge: Self.conversationMaxAge, maxEntries: Self.maxConversations)
            CacheFolder.prune(files.filter { !isConversation($0) }, maxAge: Self.maxAge, maxEntries: Self.maxEntries, maxBytes: Self.maxBytes)
        }
    }

    /// The file of a key's copy for an account: a hash of both, so two keys never share a file
    /// (the usernames a.b and a_b once did), nor two accounts. What kind of copy it is stays in
    /// front, for `clean`.
    private func file(for key: String, account: String) -> URL {
        let kind = ["kept-", "thread-"].first { key.hasPrefix($0) } ?? ""
        return folder.appending(path: kind + CacheFolder.name(for: account + "\n" + key) + ".json")
    }
}

/// Pictures from Instagram's CDN as files on the phone, so they show at once, across launches too.
///
/// Instagram signs a picture's link anew in every response, so the same profile picture comes with
/// a different link each time. Files go by what stays the same: the picture's path on the CDN and
/// the size asked for (`stp`). Kept light: anything unused for two weeks goes, then the least
/// recently used past 100 MB, at every launch and whenever the app leaves the screen. Logging out
/// empties it. Pictures come only from Instagram's servers for them (MediaHosts), 16 MB at most.
final class ImageFiles: @unchecked Sendable {
    static let shared = ImageFiles()

    private static let maxAge: TimeInterval = 14 * 86_400
    private static let maxBytes = 100 << 20
    /// Far more than any picture Instagram sends.
    private static let maxFileBytes = 16 << 20

    private let folder = URL.cachesDirectory.appending(path: "Images", directoryHint: .isDirectory)
    private let queue = DispatchQueue(label: "Unreeled.ImageFiles", qos: .utility)
    private let lock = NSLock()
    /// Goes up when everything is deleted, so a download from before isn't kept after.
    private var generation = 0

    /// Not through URLCache, which would keep a copy under each new link.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: MediaRedirects(), delegateQueue: nil)
    }()

    private init() {
        CacheFolder.create(folder)
    }

    /// What identifies the picture: on Instagram's and Facebook's CDNs, the file's path and its
    /// size, whichever server and signature the link has, and for a picture they pass on from
    /// another site (a link's preview), that picture's own address. Any other link counts as a whole.
    static func key(for url: URL) -> String {
        guard let host = url.host(), host.hasSuffix(".fbcdn.net") || host.hasSuffix(".cdninstagram.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url.absoluteString }
        let items = components.queryItems ?? []
        let size = items.first { $0.name == "stp" }?.value ?? ""
        let source = items.first { $0.name == "url" }?.value
        return components.path + "?stp=" + size + (source.map { "&url=" + $0 } ?? "")
    }

    /// The picture's bytes: the file on the phone, or downloaded and kept when `download` allows.
    func data(for url: URL, download: Bool = true) async -> Data? {
        let file = file(for: Self.key(for: url))
        if let data = try? Data(contentsOf: file) {
            queue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
            return data
        }
        guard download, MediaHosts.allows(url) else { return nil }
        let started = lock.withLock { generation }
        var received = Data()
        do {
            try await MediaHosts.download(url, session: session, limit: Self.maxFileBytes) { http in
                http.statusCode == 200 && http.mimeType?.hasPrefix("image/") == true
            } take: { received.append($0) }
        } catch {
            return nil
        }
        let data = received
        guard !data.isEmpty else { return nil }
        queue.async {
            // Not when everything was deleted meanwhile, as when logging out.
            guard self.lock.withLock({ self.generation }) == started else { return }
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return data
    }

    func contains(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: Self.key(for: url)).path)
    }

    /// For a file that turned out unreadable: the next look downloads it again.
    func remove(_ url: URL) {
        let file = file(for: Self.key(for: url))
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    func removeAll() {
        lock.withLock { generation += 1 }
        let folder = folder
        queue.async {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Drops what's old, then the least recently used past 100 MB.
    func clean() {
        let folder = folder
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: CacheFolder.keys)) ?? []
            CacheFolder.prune(files, maxAge: Self.maxAge, maxBytes: Self.maxBytes)
        }
    }

    private func file(for key: String) -> URL {
        folder.appending(path: CacheFolder.name(for: key))
    }
}

/// Story photos and videos as files, loaded ahead so stories open and play at once. Stories last a
/// day, so their files go a day after they were saved, and past 60 MB the least recently watched
/// go first: at every launch, whenever the app leaves the screen and when the viewer closes.
/// Logging out empties it. Files come only from Instagram's servers for them (MediaHosts), 50 MB
/// at most; a video too large for that plays as it streams.
final class StoryFiles: @unchecked Sendable {
    static let shared = StoryFiles()

    private static let maxAge: TimeInterval = 86_400
    private static let maxBytes = 60 << 20
    /// Far more than any story Instagram sends.
    private static let maxFileBytes = 50 << 20
    /// Loading ahead stops here; what you're about to watch still loads.
    static let aheadBudget = 30 << 20

    private let folder = URL.cachesDirectory.appending(path: "Stories", directoryHint: .isDirectory)
    private let queue = DispatchQueue(label: "Unreeled.StoryFiles", qos: .utility)
    private let lock = NSLock()
    private var downloads: [String: Task<URL?, Never>] = [:]
    /// Goes up when everything is deleted, so a download from before isn't kept after.
    private var generation = 0

    /// Not through URLCache, which would keep a second copy.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: MediaRedirects(), delegateQueue: nil)
    }()

    private init() {
        CacheFolder.create(folder)
    }

    /// The photo's or video's file, when it's on the phone.
    func file(for url: URL) -> URL? {
        let file = path(for: url)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        queue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
        return file
    }

    /// Downloads a photo or video onto the phone, once even when asked twice, and returns its file.
    func download(_ url: URL) async -> URL? {
        if let file = file(for: url) { return file }
        guard MediaHosts.allows(url) else { return nil }
        let key = ImageFiles.key(for: url)
        let destination = path(for: url)
        let session = session
        let task = lock.withLock { () -> Task<URL?, Never> in
            if let running = downloads[key] { return running }
            let started = generation
            let task = Task.detached(priority: .utility) { () -> URL? in
                let temporary = URL.temporaryDirectory.appending(path: "story-\(UUID().uuidString)")
                // Whatever happens, nothing is left behind but the file in its place.
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
                      let handle = try? FileHandle(forWritingTo: temporary)
                else { return nil }
                do {
                    defer { try? handle.close() }
                    try await MediaHosts.download(url, session: session, limit: StoryFiles.maxFileBytes) { http in
                        http.statusCode == 200 && ["image/", "video/"].contains { http.mimeType?.hasPrefix($0) == true }
                    } take: { try handle.write(contentsOf: $0) }
                } catch {
                    return nil
                }
                // Not when everything was deleted meanwhile, as when logging out.
                return self.lock.withLock { () -> URL? in
                    guard self.generation == started else { return nil }
                    try? FileManager.default.removeItem(at: destination)
                    guard (try? FileManager.default.moveItem(at: temporary, to: destination)) != nil else { return nil }
                    return destination
                }
            }
            downloads[key] = task
            return task
        }
        let file = await task.value
        lock.withLock { downloads[key] = nil }
        return file
    }

    /// A story photo's bytes: from the phone, or downloaded onto it when `download` allows.
    func data(for url: URL, download: Bool) async -> Data? {
        if let file = file(for: url) { return try? Data(contentsOf: file) }
        guard download, let file = await self.download(url) else { return nil }
        return try? Data(contentsOf: file)
    }

    /// For a file that turned out unreadable: the next look downloads it again.
    func remove(_ url: URL) {
        let file = path(for: url)
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Each account's stories as Instagram sent them to `account`, the one logged in when they
    /// were asked for, so the next launch doesn't ask again for the ones with nothing new. Here,
    /// they go after a day like the rest. Once that login has ended or changed, they aren't kept.
    func saveReels(from data: Data, account: String?) {
        guard let account else { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        for reel in json?["reels_media"] as? [[String: Any]] ?? [] {
            let id = reel["id"] ?? (reel["user"] as? [String: Any])?["pk"]
            guard let id = id.map({ "\($0)" }), id.allSatisfy(\.isNumber),
                  let one = try? JSONSerialization.data(withJSONObject: reel)
            else { continue }
            guard account == SavedCopies.account else { return }
            try? one.write(to: reelFile(id, account: account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// The saved stories of these accounts, those still here, as Instagram sent them to the
    /// account logged in.
    func savedReels(ids: [String]) -> [Reel] {
        guard let account = SavedCopies.account else { return [] }
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: reelFile(id, account: account)) else { return nil }
            return try? InstagramAPI.decodeSaved(Reel.self, from: data)
        }
    }

    /// Who sees which stories depends on the account (Close Friends): each account's saved
    /// stories are files of their own, as in ResponseCache.
    private func reelFile(_ id: String, account: String) -> URL {
        folder.appending(path: "reel-" + CacheFolder.name(for: account + "\n" + id) + ".json")
    }

    /// What the folder holds, for the budget of loading ahead.
    var bytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    func removeAll() {
        lock.withLock { generation += 1 }
        let folder = folder
        queue.async {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Drops files saved more than a day ago, then the least recently watched past 100 MB.
    func clean() {
        let folder = folder
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: CacheFolder.keys + [.creationDateKey]
            )) ?? []
            var kept: [URL] = []
            for file in files {
                let saved = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if Date.now.timeIntervalSince(saved) > Self.maxAge {
                    try? FileManager.default.removeItem(at: file)
                } else {
                    kept.append(file)
                }
            }
            CacheFolder.prune(kept, maxAge: .infinity, maxBytes: Self.maxBytes)
        }
    }

    /// The extension stays: AVPlayer goes by it to know a video file.
    private func path(for url: URL) -> URL {
        let name = CacheFolder.name(for: ImageFiles.key(for: url))
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return folder.appending(path: name + ext)
    }
}

/// Tidying a folder of saved files, where a file's modification date is when it was last used.
private enum CacheFolder {
    static let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]

    /// A file name for a key: the start of its SHA-256.
    static func name(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Makes the folder, and says it's never to go into the phone's backups. iOS leaves the
    /// caches folder out already; this keeps it so wherever the folder is.
    static func create(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Deletes what's older than `maxAge`, then the least recently used past `maxEntries` or `maxBytes`.
    static func prune(_ files: [URL], maxAge: TimeInterval, maxEntries: Int = .max, maxBytes: Int = .max) {
        let entries = files
            .map { url -> (url: URL, used: Date, bytes: Int) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
            .sorted { $0.used > $1.used }
        var total = 0
        for (index, entry) in entries.enumerated() {
            total += entry.bytes
            if Date.now.timeIntervalSince(entry.used) > maxAge || index >= maxEntries || total > maxBytes {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
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

    /// Reads these conversations' saved copies into memory ahead, one after the other, so they
    /// open at once. Nothing goes to Instagram.
    static func warm(_ ids: [String]) async -> [DirectThread] {
        var threads: [DirectThread] = []
        for id in ids {
            if let thread = await load(id) { threads.append(thread) }
        }
        return threads
    }

    /// The conversation as Instagram just returned it to `account`, the one logged in when it was
    /// asked for, for next time. Once that login has ended or changed, it isn't kept.
    static func save(_ data: Data, thread: DirectThread, id: String, account: String?) {
        guard let account, account == SavedCopies.account else { return }
        ResponseCache.shared.store(data, for: key(id), account: account)
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

    /// Whether the item is there: nil when the Keychain can't tell right now, as on a phone that
    /// hasn't been unlocked since it started.
    static func contains(_ account: String) -> Bool? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    /// True once the Keychain has it (or, for nil, has nothing for `account`).
    @discardableResult
    static func set(_ data: Data?, for account: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard let data else { return true }
        var item = match
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
