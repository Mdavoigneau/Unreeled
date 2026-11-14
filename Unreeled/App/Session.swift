import Observation
import UIKit
import WebKit

/// Whether you're logged in, and the store that keeps Instagram's cookies on the device.
///
/// What the app keeps for a login goes when the login ends, however it ends: Log Out, which asks
/// Instagram to end the session first; Instagram ending it (from another device, or with a new
/// password); its cookie gone; or another account logging in on one of the website's pages. It
/// goes too when the app's data came from another phone, in a backup or a copy.
@MainActor
@Observable
final class Session {
    /// The app's one session, which a reply sent from a notification uses too: iOS can wake the
    /// app for it in the background, before any screen exists.
    static let shared = Session()

    enum State: Equatable {
        case unknown
        case loggedOut
        case loggedIn(userID: String)
    }

    /// Cookies and website data. They stay on the device, across launches and reinstalls from
    /// Xcode, and out of its backups. Changing the ID starts from an empty store, logged out.
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1C3A52-8E0B-4C55-9A3E-2B7D1F0C9A11")!)

    /// The account logged in when the app last checked. A launch opens on its saved screens at
    /// once, without waiting for WebKit to read the cookies, and goes to the login page if they're
    /// gone.
    private static let lastUserKey = "loggedInUserID"

    /// This phone's mark: a random value in the Keychain, on this device only, and a note in the
    /// app's settings that it was made. A backup or a copy of the app's data carries the note but
    /// never the value, so the note without the value means the data came from another phone.
    /// An install from before the mark gets both at its first launch with it, logged in as it was.
    private static let markedKey = "phoneMarked"
    private static let markItem = "phone"

    private(set) var state: State
    let api = InstagramAPI(dataStore: Session.dataStore)

    /// A login being ended: what Instagram answers meanwhile changes nothing.
    @ObservationIgnored private var isEnding = false
    /// Goes up when a login ends, so cookies read before can't bring it back.
    @ObservationIgnored private var generation = 0
    /// The look at whether Instagram ended the login, while it runs, and when the last one began.
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var lastCheck: Date?

    var isLoggedIn: Bool {
        if case .loggedIn = state { return true }
        return false
    }

    var userID: String? {
        if case .loggedIn(let userID) = state { return userID }
        return nil
    }

    init() {
        let fromAnotherPhone = Self.cameFromAnotherPhone()
        let last = fromAnotherPhone ? nil : UserDefaults.standard.string(forKey: Self.lastUserKey)
        state = last.map { State.loggedIn(userID: $0) } ?? .unknown
        SavedCopies.account = last
        Task {
            if fromAnotherPhone {
                // Restored or copied from another phone: nothing of the login comes along.
                await forget(keepingCookies: false, then: .unknown)
                Self.markThisPhone()
            }
            await refresh()
            Self.keepWebsiteDataOutOfBackups()
        }
    }

    /// Logged in once Instagram has set its session cookie. At launch, whenever the app comes back,
    /// from the login page as its cookies change, after one of the website's pages, and when an
    /// answer from Instagram says the login may have ended. A login that ended, or another
    /// account's in its place, takes what the app kept for it along.
    func refresh() async {
        guard !isEnding else { return }
        let started = generation
        let found = await Self.loginInStore()
        // A login ended while the cookies were read: what was read is out of date.
        guard generation == started, !isEnding, found != state else { return }
        switch (state, found) {
        case (.loggedIn, .loggedOut):
            // Its cookie is gone: it ran out, Instagram took it back, or you logged out on the
            // website. Not while the phone is locked, when its files may not read.
            guard UIApplication.shared.isProtectedDataAvailable else { return }
            // Once more after a moment, since this deletes the cookies too: a store that answered
            // before it had loaded mustn't end a login that's still there.
            try? await Task.sleep(for: .seconds(1))
            guard generation == started, !isEnding, isLoggedIn, await Self.loginInStore() == .loggedOut else { return }
            await forget(keepingCookies: false, then: .loggedOut)
        case (.loggedIn, .loggedIn):
            // Another account, logged in on one of the website's pages: its cookies stay.
            await forget(keepingCookies: true, then: found)
        case (.unknown, .loggedOut):
            // No login at launch: no session values from an earlier one stay in the Keychain,
            // which outlives the app.
            api.reset()
            settle(found)
        default:
            settle(found)
        }
        if isLoggedIn { Self.keepWebsiteDataOutOfBackups() }
    }

    /// Settings > Log Out. Instagram is asked to end the session first, as the website's Log Out
    /// does, so a copy of its cookie stops working too. That gets five seconds at most, and
    /// whatever Instagram answers, the phone forgets the login.
    func logOut() async {
        guard !isEnding else { return }
        if let userID {
            isEnding = true
            settle(.unknown)
            await within(seconds: 5) { try? await self.api.endSession(userID: userID) }
        }
        await forget(keepingCookies: false, then: .loggedOut)
    }

    /// Instagram answered a request as if the login had ended (InstagramAPI.Failure.loginRequired).
    /// An error page on the way can read the same, so that alone deletes nothing: the login has
    /// ended when its session cookie is gone, or when one more request gets Instagram's own answer
    /// that it has. A passing outage changes nothing. Once a minute at most, however many requests
    /// failed together.
    func loginMayHaveEnded() {
        guard let userID, !isEnding, checking == nil else { return }
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 60 { return }
        lastCheck = .now
        checking = Task {
            defer { checking = nil }
            // The cookie gone: refresh() ends the login.
            await refresh()
            guard self.userID == userID, !isEnding else { return }
            if await api.loginHasEnded() == true, self.userID == userID, !isEnding {
                await forget(keepingCookies: false, then: .loggedOut)
            } else {
                // That answer may have taken the cookie back.
                await refresh()
            }
        }
    }

    /// Everything the app keeps for the login that's ending, then `next`: the website's data (its
    /// cookies too, unless they hold another account's login), the saved copies, conversations,
    /// pictures and stories, on the phone and in memory, the voice messages you recorded, which
    /// conversations you open most, the website's session values, and the ID Direct knows this
    /// phone by. Screens give way meanwhile, and nothing is read or kept for that login.
    private func forget(keepingCookies: Bool, then next: State) async {
        isEnding = true
        generation += 1
        settle(.unknown)
        // Requests under way stop first, so none brings a cookie back.
        api.reset()
        var types = WKWebsiteDataStore.allWebsiteDataTypes()
        if keepingCookies { types.remove(WKWebsiteDataTypeCookies) }
        await Self.dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        UserDefaults.standard.removeObject(forKey: "username")
        ResponseCache.shared.removeAll()
        ThreadStore.removeAll()
        ChatStats.removeAll()
        ImageCache.shared.removeAll()
        ImageFiles.shared.removeAll()
        StoryFiles.shared.removeAll()
        URLCache.shared.removeAllCachedResponses()
        VoiceRecorder.removeAll()
        InstagramAPI.forgetDirectDeviceID()
        api.reset()
        isEnding = false
        settle(next)
    }

    /// The state, with what follows from it: the account remembered for the next launch, and
    /// whose saved copies are read and kept.
    private func settle(_ new: State) {
        switch new {
        case .loggedIn(let userID):
            UserDefaults.standard.set(userID, forKey: Self.lastUserKey)
            SavedCopies.account = userID
        case .loggedOut:
            UserDefaults.standard.removeObject(forKey: Self.lastUserKey)
            SavedCopies.account = nil
        case .unknown:
            SavedCopies.account = nil
        }
        if state != new { state = new }
    }

    /// `work`, for `seconds` at most: after that it's left to finish, or to stop with the other
    /// requests under way.
    private func within(seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        let finished = Finished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finished.continuation = continuation
            Task { @MainActor in
                await work()
                finished.end()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finished.end()
            }
        }
    }

    /// The login the website's cookies hold: instagram.com's session cookie, and the account's ID,
    /// from the same domain when there's a choice. Nothing from another domain counts, nor a
    /// cookie that has run out.
    private static func loginInStore() async -> State {
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { isInstagram($0.domain) && ($0.expiresDate.map { $0 > .now } ?? true) }
        guard let session = cookies.first(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return .loggedOut }
        let ids = cookies.filter { $0.name == "ds_user_id" && !$0.value.isEmpty }
        guard let userID = (ids.first { $0.domain == session.domain } ?? ids.first)?.value else { return .loggedOut }
        return .loggedIn(userID: userID)
    }

    /// instagram.com itself, or a name under it.
    private static func isInstagram(_ domain: String) -> Bool {
        let domain = domain.lowercased()
        return domain == "instagram.com" || domain.hasSuffix(".instagram.com")
    }

    /// True when the app's data came from another phone: a backup restored onto this one, or a
    /// copy of the app's files. Its settings say the phone was marked, but the Keychain, which
    /// keeps the mark on the phone it was made on, doesn't have it. A launch without the note
    /// makes the mark, whatever the app holds: an update keeps its login.
    private static func cameFromAnotherPhone() -> Bool {
        guard UserDefaults.standard.bool(forKey: markedKey) else {
            markThisPhone()
            return false
        }
        // Only a Keychain that says it has no mark counts, not one that can't say right now.
        return SecureStore.contains(markItem) == false
    }

    /// The note is kept only once the mark is in the Keychain: a mark that couldn't be made is
    /// made at the next launch, never taken for another phone's.
    private static func markThisPhone() {
        UserDefaults.standard.set(SecureStore.set(Data(UUID().uuidString.utf8), for: markItem), forKey: markedKey)
    }

    /// The website's data, its cookies included, stays out of the phone's backups, as the saved
    /// copies do: a backup is no way to take the login to another phone, or to read it on a
    /// computer. WebKit keeps it in Library/WebKit, from the first time it writes there, so this
    /// runs at every launch and login.
    private static func keepWebsiteDataOutOfBackups() {
        var folder = URL.libraryDirectory.appending(path: "WebKit", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}

/// Whichever of a request and its time limit ends first.
@MainActor
private final class Finished {
    var continuation: CheckedContinuation<Void, Never>?

    func end() {
        continuation?.resume()
        continuation = nil
    }
}
