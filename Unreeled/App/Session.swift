import Observation
import WebKit

/// Whether you're logged in, and the store that keeps Instagram's cookies on the device.
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

    /// Cookies and website data. They stay on the device, across launches and reinstalls from Xcode.
    /// Changing the ID starts from an empty store, logged out.
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1C3A52-8E0B-4C55-9A3E-2B7D1F0C9A11")!)

    /// The account logged in when the app last checked. A launch opens on its saved screens at
    /// once, without waiting for WebKit to read the cookies, and goes to the login page if they're
    /// gone.
    private static let lastUserKey = "loggedInUserID"

    private(set) var state = UserDefaults.standard.string(forKey: Session.lastUserKey).map { State.loggedIn(userID: $0) } ?? .unknown
    let api = InstagramAPI(dataStore: Session.dataStore)

    var isLoggedIn: Bool {
        if case .loggedIn = state { return true }
        return false
    }

    var userID: String? {
        if case .loggedIn(let userID) = state { return userID }
        return nil
    }

    init() {
        Task { await refresh() }
    }

    /// Logged in once Instagram has set its session cookie.
    func refresh() async {
        let cookies = await Self.dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("instagram.com") }
        let found: State
        if cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }),
           let userID = cookies.first(where: { $0.name == "ds_user_id" })?.value {
            found = .loggedIn(userID: userID)
            UserDefaults.standard.set(userID, forKey: Self.lastUserKey)
        } else {
            found = .loggedOut
            UserDefaults.standard.removeObject(forKey: Self.lastUserKey)
        }
        if state != found { state = found }
    }

    func logOut() async {
        await Self.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        UserDefaults.standard.removeObject(forKey: "username")
        UserDefaults.standard.removeObject(forKey: Self.lastUserKey)
        // Nothing of the account stays: saved screens and conversations, pictures, and the
        // website's session values.
        ResponseCache.shared.removeAll()
        ThreadStore.removeAll()
        ChatStats.removeAll()
        ImageCache.shared.removeAll()
        ImageFiles.shared.removeAll()
        StoryFiles.shared.removeAll()
        URLCache.shared.removeAllCachedResponses()
        api.reset()
        state = .loggedOut
    }
}
