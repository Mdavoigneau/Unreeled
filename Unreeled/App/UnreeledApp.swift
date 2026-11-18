import AVFoundation
import SwiftUI

@main
struct UnreeledApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = Session.shared

    init() {
        // Play video sound even when the phone is on silent, as Safari does. Off the main thread:
        // it takes a few dozen milliseconds, which the first screen shouldn't wait for.
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
        }
        // Pictures are kept by ImageFiles now. URLCache, which kept them before, stored a copy
        // under each new link Instagram gave the same picture: what it holds is cleared once.
        URLCache.shared = URLCache(memoryCapacity: 4 << 20, diskCapacity: 20 << 20)
        if !UserDefaults.standard.bool(forKey: "clearedPictureURLCache") {
            UserDefaults.standard.set(true, forKey: "clearedPictureURLCache")
            DispatchQueue.global(qos: .utility).async { URLCache.shared.removeAllCachedResponses() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(PushNotifications.shared)
        }
    }
}

/// The notice the first time, then Instagram's login page until you're logged in, then the
/// native app. A build that can have notifications asks about them once, before the app.
struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(PushNotifications.self) private var notifications
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Notice.key) private var acceptedNotice = 0
    @AppStorage(PushNotifications.askedKey) private var askedNotifications = false
    @State private var stories = StoriesModel()
    @State private var inbox = InboxModel()
    /// The account whose stories and inbox these are.
    @State private var account: String?

    var body: some View {
        ZStack {
            #if DEBUG
            if StandIn.opensWithoutLogin, !session.isLoggedIn {
                // -standInConversations YES -openStandIn YES on a phone with no login: the
                // stand-in conversation alone, which needs none and asks Instagram nothing.
                StandIn.Harness()
            } else if acceptedNotice < Notice.version {
                WelcomeView { acceptedNotice = Notice.version }
            } else {
                content
            }
            #else
            if acceptedNotice < Notice.version {
                WelcomeView { acceptedNotice = Notice.version }
            } else {
                content
            }
            #endif
        }
        .fullScreenCover(item: $stories.presented) { presentation in
            StoryViewer(presentation: presentation)
        }
        // A story reply still on its way when the viewer closed, or your story going up.
        .overlay(alignment: .bottom) {
            if stories.presented == nil {
                VStack(spacing: 8) {
                    if let status = stories.postStatus { StoryPostToast(status: status) }
                    if let status = stories.replyStatus { ReplyToast(status: status) }
                }
                .padding(.bottom, 64)
            }
        }
        .animation(.snappy(duration: 0.2), value: stories.replyStatus)
        .animation(.snappy(duration: 0.2), value: stories.postStatus)
        // Outside the cover, so the story viewer gets it too.
        .environment(stories)
        .environment(inbox)
        // A login that ends, or another account's: nothing of the last one stays on screen. The
        // screens wait for this (see content), so that they load into the new account's.
        .onChange(of: session.userID, initial: true) { _, userID in
            guard userID != account else { return }
            account = userID
            stories = StoriesModel()
            inbox = InboxModel()
        }
        .preferredColorScheme(.light)
        .tint(Theme.accent)
        // Notifications follow the login: kept working while it lasts, undone when it ends,
        // however it ends. Coming back to the app, the cookies are checked first: the login may
        // have ended meanwhile.
        .task(id: session.state) { await followLogin() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await session.refresh()
                    await followLogin()
                }
            }
        }
        #if DEBUG
        .task(id: session.isLoggedIn) {
            if session.isLoggedIn { await DebugProbe.runIfRequested(api: session.api) }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch session.state {
            case .unknown:
                ProgressView()
            case .loggedOut:
                LoginView()
            case .loggedIn:
                if account != session.userID {
                    // A moment, until the stories and inbox are this account's: screens made
                    // before would load into the last ones, which are then replaced.
                    Color.white
                } else if PushNotifications.isOffered, !askedNotifications, !notifications.isOn {
                    NotificationsOffer { askedNotifications = true }
                } else {
                    home
                }
            }
        }
    }

    private func followLogin() async {
        switch session.state {
        case .loggedIn(let userID): await notifications.refresh(api: session.api, userID: userID)
        case .loggedOut: await notifications.turnOff()
        case .unknown: break
        }
    }

    /// Made anew for each account, so no screen of one is left for the next.
    @ViewBuilder
    private var home: some View {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "web") {
            // Debug builds: -web <path> shows that instagram.com page instead,
            // e.g. to record the API calls it makes.
            WebScreen(path: path)
        } else if let code = UserDefaults.standard.string(forKey: "post") {
            // -post <code> opens that post natively.
            NavigationStack { PostLoaderView(code: code).routes() }
        } else {
            MainView().id(session.userID)
        }
        #else
        MainView().id(session.userID)
        #endif
    }
}

/// The four tabs, each with its own navigation, under a flat tab bar. A tab's screen is created
/// the first time you open it and stays alive, so switching back is instant.
struct MainView: View {
    @Environment(Session.self) private var session
    @Environment(InboxModel.self) private var inbox
    @Environment(PushNotifications.self) private var notifications
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.home
    @State private var opened: Set<AppTab> = [.home]
    /// The screens each tab has open on top of its first one.
    @State private var paths: [AppTab: [Route]] = [:]
    /// Taps on the open tab's button while its first screen shows, which take it back to the top.
    @State private var reselections: [AppTab: Int] = [:]
    /// Switches to each tab, for the screens that refresh when you come back to them.
    @State private var selections: [AppTab: Int] = [:]
    /// Your profile, filled from the saved copy at launch so its tab opens complete.
    @State private var ownProfile = ProfileModel()
    /// A keyboard covers the bottom of the screen, as the layout itself has it: the safe area
    /// there is far taller than the home indicator's. The tab bar goes by this, since the layout
    /// is also what would lift it above the keyboard: the two can't disagree.
    @State private var keyboardIsUp = false
    /// A keyboard on its way up, which iOS announces a moment before the layout follows, so the
    /// tab bar goes at once rather than riding up first. Only for that moment: an announcement
    /// with no keyboard after it, or a keyboard that left without one, can't keep the bar away.
    @State private var keyboardIsComing = false
    @State private var keyboardAnnounced: Task<Void, Never>?

    /// Taller than any bar at the bottom of the screen, shorter than any keyboard.
    private static let keyboardInset: CGFloat = 120

    /// A token for this launch, which iOS keeps with the window and hands back only when it
    /// ended the app itself, in the background, to free memory; closing the app yourself from
    /// the app switcher forgets it, as in Apple's apps. Where you were is kept with the saved
    /// copies (`Place`), out of the phone's backups and deleted at logout: iOS's copy of the
    /// window holds nothing of the account, only this token, to say the place may be taken back.
    @SceneStorage("launch") private var sceneLaunch: String?
    /// This launch's token.
    @State private var launch = UUID().uuidString

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases, id: \.self) { tab in
                if opened.contains(tab) {
                    NavigationStack(path: path(for: tab)) { screen(for: tab).routes() }
                        .environment(\.navigate, NavigateAction(tab: tab) { route in paths[tab, default: []].append(route) })
                        .environment(\.tabReselections, reselections[tab] ?? 0)
                        .environment(\.tabSelections, selections[tab] ?? 0)
                        .opacity(self.tab == tab ? 1 : 0)
                        .allowsHitTesting(self.tab == tab)
                        .accessibilityHidden(self.tab != tab)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsTabBar {
                ClassicTabBar(selection: $tab) { tab in
                    // With a screen open on top, back to the first one; on the first one, back to the top.
                    if paths[tab]?.isEmpty == false {
                        paths[tab] = []
                    } else {
                        reselections[tab, default: 0] += 1
                    }
                }
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy(duration: 0.25), value: showsTabBar)
        .onChange(of: tab) {
            opened.insert(tab)
            selections[tab, default: 0] += 1
        }
        .task {
            #if DEBUG
            // -standInConversations YES -openStandIn YES: straight to the stand-in conversation,
            // without a tap anywhere near the feed, stories or anyone's conversation.
            if StandIn.isOn, UserDefaults.standard.bool(forKey: "openStandIn"), let thread = StandIn.route {
                paths[.home] = [.inbox, .thread(thread)]
            }
            #endif
            // The token iOS handed back, if it did, then this launch's in its place.
            let ended = sceneLaunch
            sceneLaunch = launch
            await reopenPlace(endedLaunch: ended)
            Self.cleanCaches()
            // Newer query IDs from the project, if Instagram changed any (at most every 6 hours).
            Task { await QueryUpdates.check(afterFailure: false) }
            // The saved inbox at once: the paper plane's count, and the latest conversations ready
            // to open. Instagram's a moment after the first screen.
            await inbox.showSaved(api: session.api)
            // Your profile as it was, with its pictures, for when you open its tab.
            await ownProfile.showSaved(userID: session.userID, api: session.api)
            try? await Task.sleep(for: .seconds(2))
            await inbox.load(api: session.api, force: false)
        }
        // Where you are, noted as you move and again as the app starts to leave the screen
        // (before iOS takes what it keeps of the window), should iOS end the app meanwhile.
        .onChange(of: tab) { notePlace() }
        .onChange(of: paths) { notePlace() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive { notePlace() }
            // Leaving the screen: what the app keeps on the phone is trimmed, to stay light.
            if phase == .background { Self.cleanCaches() }
            guard phase == .active else { return }
            Task { await QueryUpdates.check(afterFailure: false) }
            Task { await inbox.load(api: session.api, force: false) }
        }
        .onChange(of: notifications.opened, initial: true) { _, opened in
            if let opened { open(opened) }
        }
        .onChange(of: notifications.arrivals) {
            // A notification while the app is open: the paper plane's count is out of date.
            Task { await inbox.load(api: session.api) }
        }
        // Back online: the paper plane's count, and the list, from Instagram again.
        .onReconnect { await inbox.load(api: session.api, force: false) }
        .onChange(of: visibleThread, initial: true) { notifications.visibleThread = visibleThread }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.safeAreaInsets.bottom > Self.keyboardInset
        } action: { isUp in
            keyboardIsUp = isUp
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsComing = true
            keyboardAnnounced?.cancel()
            keyboardAnnounced = Task {
                // By then the layout has the keyboard, if there is one.
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { keyboardIsComing = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardAnnounced?.cancel()
            keyboardIsComing = false
        }
    }

    /// Back where you were, if iOS ended the app in the background less than ten minutes ago:
    /// the tab, and its screens without the slide of each opening. Not over a notification you
    /// tapped to launch the app, which leads somewhere itself, nor when the place is older.
    private func reopenPlace(endedLaunch: String?) async {
        guard let endedLaunch, let place = await Place.saved() else { return }
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "reopenPlace": [
            "tab": place.tab.rawValue, "screens": place.paths.mapValues(\.count).map { "\($0.key.rawValue):\($0.value)" },
            "secondsAgo": Int(Date.now.timeIntervalSince(place.at)), "sameLaunch": place.launch == endedLaunch,
        ] as [String: Any]])
        #endif
        // The place noted by the launch iOS ended, and recent.
        guard place.launch == endedLaunch, Date.now.timeIntervalSince(place.at) < 10 * 60,
              notifications.opened == nil, paths.values.allSatisfy(\.isEmpty)
        else { return }
        // Each place once: should reopening it stop the app, the next launch starts afresh.
        guard UserDefaults.standard.string(forKey: Self.reopenedKey) != endedLaunch else { return }
        UserDefaults.standard.set(endedLaunch, forKey: Self.reopenedKey)
        // Conversations are found among the saved ones, read off the main thread.
        if place.paths.values.joined().contains(where: \.isConversation) { await inbox.showSaved(api: session.api) }
        guard notifications.opened == nil, paths.values.allSatisfy(\.isEmpty) else { return }
        var restored: [AppTab: [Route]] = [:]
        for (tab, steps) in place.paths {
            var routes: [Route] = []
            for step in steps {
                // A screen that can't come back (a conversation no longer among the saved ones)
                // ends the way back there.
                guard let route = step.route(inbox: inbox) else { break }
                routes.append(route)
            }
            if !routes.isEmpty { restored[tab] = routes }
        }
        var instantly = Transaction()
        instantly.disablesAnimations = true
        withTransaction(instantly) {
            opened.formUnion(Set(restored.keys).union([place.tab]))
            paths = restored
            tab = place.tab
        }
    }

    /// Notes where you are, with the time and this launch's token: what `reopenPlace` takes back.
    private func notePlace() {
        Place(tab: tab, paths: paths, launch: launch).save()
    }

    /// The token of the last launch whose place was reopened, so that none is reopened twice.
    private static let reopenedKey = "reopenedLaunch"

    /// Saved screens, pictures and stories past their time or over their size, in the background.
    private static func cleanCaches() {
        ResponseCache.shared.clean()
        ImageFiles.shared.clean()
        StoryFiles.shared.clean()
    }

    /// Not in Direct, which gets the whole screen as in the old app, nor over the keyboard.
    private var showsTabBar: Bool {
        !keyboardIsUp && !keyboardIsComing && paths[tab]?.contains(where: \.isDirect) != true
    }

    private func path(for tab: AppTab) -> Binding<[Route]> {
        Binding { paths[tab] ?? [] } set: { paths[tab] = $0 }
    }

    /// The IDs of the conversation on screen, if one is.
    private var visibleThread: Set<String> {
        guard case .thread(let thread) = paths[tab]?.last else { return [] }
        return thread.ids
    }

    /// Opens what a tapped notification was about: its conversation for a message, Activity
    /// for the rest.
    private func open(_ opened: InstagramPush.Routing) {
        notifications.opened = nil
        guard opened.isDirect else {
            // Activity, brought up to date even when it's already the open tab.
            if tab == .activity { selections[.activity, default: 0] += 1 } else { tab = .activity }
            paths[.activity] = []
            return
        }
        tab = .home
        // Already the conversation on screen: it brings itself up to date, with what's typed in
        // it left alone.
        if let id = opened.threadID, case .thread(let shown) = paths[.home]?.last, shown.ids.contains(id) {
            return
        }
        if showConversation(withID: opened.threadID) { return }
        Task {
            // A launch from the notification gets here before the saved inbox is read: that
            // first, which takes a moment and no connection.
            await inbox.showSaved(api: session.api)
            if tab == .home, showConversation(withID: opened.threadID) { return }
            // Not among the conversations the phone has: the inbox now, and on to the
            // conversation once Instagram's list has it, if you're still there.
            paths[.home] = [.inbox]
            await inbox.load(api: session.api)
            if tab == .home, paths[.home] == [.inbox], let thread = inbox.thread(withID: opened.threadID) {
                paths[.home]?.append(.thread(thread))
            }
        }
    }

    /// Opens the conversation with this ID over the inbox, when it's among those loaded.
    private func showConversation(withID id: String?) -> Bool {
        guard let thread = inbox.thread(withID: id) else { return false }
        paths[.home] = [.inbox, .thread(thread)]
        return true
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .home: FeedView()
        case .search: SearchView()
        case .activity: ActivityView()
        case .profile: ProfileView(id: session.userID ?? "", isOwn: true, model: ownProfile)
        }
    }
}

/// Opens a screen on the current tab, for taps that can't be links (a card that also takes a
/// double-tap). Compared by tab, so views reading it don't redraw on every update.
struct NavigateAction: Equatable {
    let tab: AppTab?
    let perform: (Route) -> Void

    func callAsFunction(_ route: Route) { perform(route) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.tab == rhs.tab }
}

extension EnvironmentValues {
    @Entry var navigate = NavigateAction(tab: nil) { _ in }
}

/// Screens a navigation stack can open.
enum Route: Hashable {
    case profile(id: String, username: String)
    case post(Media)
    /// A post by the code in its link, loaded when opened.
    case postCode(String)
    case inbox
    case thread(DirectThread)
    case followRequests([User])
    case settings
    case web(path: String, title: String)

    static func profile(_ user: User) -> Route {
        .profile(id: user.id, username: user.username)
    }

    var isDirect: Bool {
        switch self {
        case .inbox, .thread: true
        default: false
        }
    }
}

/// Where you were, as `MainView` keeps it for iOS to hand back (SceneStorage): each screen by
/// what reopens it, not by everything it showed.
struct Place: Codable {
    enum Step: Codable {
        case profile(id: String, username: String)
        case post(code: String)
        case inbox
        case conversation(id: String)
        case settings
        case web(path: String, title: String)

        init?(_ route: Route) {
            switch route {
            case .profile(let id, let username): self = .profile(id: id, username: username)
            case .post(let post):
                guard let code = post.code else { return nil }
                self = .post(code: code)
            case .postCode(let code): self = .post(code: code)
            case .inbox: self = .inbox
            case .thread(let thread): self = .conversation(id: thread.id)
            case .settings: self = .settings
            case .web(let path, let title): self = .web(path: path, title: title)
            case .followRequests: return nil
            }
        }

        var isConversation: Bool {
            if case .conversation = self { return true }
            return false
        }

        /// The screen again. A conversation is found among the inbox's.
        @MainActor
        func route(inbox: InboxModel) -> Route? {
            switch self {
            case .profile(let id, let username): .profile(id: id, username: username)
            case .post(let code): .postCode(code)
            case .inbox: .inbox
            case .conversation(let id): inbox.thread(withID: id).map(Route.thread)
            case .settings: .settings
            case .web(let path, let title): .web(path: path, title: title)
            }
        }
    }

    let tab: AppTab
    let paths: [AppTab: [Step]]
    let at: Date
    /// The launch that noted it (`MainView.launch`).
    let launch: String

    init(tab: AppTab, paths: [AppTab: [Route]], launch: String) {
        self.tab = tab
        self.launch = launch
        // Each tab's screens up to the first that can't be kept.
        self.paths = paths.compactMapValues { routes in
            var steps: [Step] = []
            for route in routes {
                guard let step = Step(route) else { break }
                steps.append(step)
            }
            return steps.isEmpty ? nil : steps
        }
        at = .now
    }

    private static let key = "kept-place"

    /// Kept with the account's saved copies (ResponseCache): out of the phone's backups, each
    /// account's its own, deleted at logout.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        ResponseCache.shared.store(data, for: Self.key, account: SavedCopies.account)
    }

    /// The account's last place, read off the main thread.
    static func saved() async -> Place? {
        await Task.detached(priority: .userInitiated) {
            ResponseCache.shared.data(for: key).flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        }.value
    }
}

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .profile(let id, let username): ProfileView(id: id, username: username)
            case .post(let post): PostDetailView(post: post)
            // Posts and reels sent in messages: the video starts on its own.
            case .postCode(let code): PostLoaderView(code: code).environment(\.autoplaysVideo, true)
            case .inbox: InboxView()
            case .thread(let thread): ConversationView(thread: thread)
            case .followRequests(let users): FollowRequestsView(requests: users)
            case .settings: SettingsView()
            case .web(let path, let title): WebPageScreen(path: path, title: title)
            }
        }
    }
}
