import Observation
import WebKit

/// Whether you're logged in, and the store that keeps Instagram's cookies on the device.
@MainActor
@Observable
final class Session {
    enum State: Equatable {
        case unknown
        case loggedOut
        case loggedIn(userID: String)
    }

    /// Cookies and website data. They stay on the device, across launches and reinstalls from Xcode.
    /// Changing the ID starts from an empty store, logged out.
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1C3A52-8E0B-4C55-9A3E-2B7D1F0C9A11")!)

    private(set) var state = State.unknown
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
        if cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }),
           let userID = cookies.first(where: { $0.name == "ds_user_id" })?.value {
            state = .loggedIn(userID: userID)
        } else {
            state = .loggedOut
        }
    }

    func logOut() async {
        await Self.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        UserDefaults.standard.removeObject(forKey: "username")
        // Nothing of the account stays: saved screens and conversations, pictures, and the
        // website's session values.
        ResponseCache.shared.removeAll()
        ThreadStore.removeAll()
        ChatStats.removeAll()
        ImageCache.shared.removeAll()
        URLCache.shared.removeAllCachedResponses()
        api.reset()
        state = .loggedOut
    }
}
