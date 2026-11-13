import AVFoundation
import SwiftUI

@main
struct UnreeledApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = Session()

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

    var body: some View {
        ZStack {
            if acceptedNotice < Notice.version {
                WelcomeView { acceptedNotice = Notice.version }
            } else {
                content
            }
        }
        .background(alignment: .topLeading) {
            // The API's web view has to be in the window to keep running.
            APIWebView(api: session.api)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
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
        .onChange(of: session.isLoggedIn) { _, loggedIn in
            if !loggedIn {
                stories = StoriesModel()
                inbox = InboxModel()
            }
        }
        .preferredColorScheme(.light)
        .tint(Theme.accent)
        // Notifications follow the login: kept working while it lasts, undone when it ends,
        // however it ends.
        .task(id: session.state) { await followLogin() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await followLogin() } }
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
                if PushNotifications.isOffered, !askedNotifications, !notifications.isOn {
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
            MainView()
        }
        #else
        MainView()
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
    @State private var isTyping = false

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases, id: \.self) { tab in
                if opened.contains(tab) {
                    NavigationStack(path: path(for: tab)) { screen(for: tab).routes() }
                        .environment(\.navigate, NavigateAction(tab: tab) { route in paths[tab, default: []].append(route) })
                        .environment(\.tabReselections, reselections[tab] ?? 0)
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
        .onChange(of: tab) { opened.insert(tab) }
        .task {
            Self.cleanCaches()
            // Newer query IDs from the project, if Instagram changed any (at most every 6 hours).
            Task { await QueryUpdates.check(afterFailure: false) }
            // The saved inbox at once: the paper plane's count, and the latest conversations ready
            // to open. Instagram's a moment after the first screen.
            await inbox.showSaved(api: session.api)
            try? await Task.sleep(for: .seconds(2))
            await inbox.load(api: session.api, force: false)
        }
        .onChange(of: scenePhase) { _, phase in
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
        .onChange(of: visibleThread, initial: true) { notifications.visibleThread = visibleThread }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isTyping = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isTyping = false
        }
    }

    /// Saved screens, pictures and stories past their time or over their size, in the background.
    private static func cleanCaches() {
        ResponseCache.shared.clean()
        ImageFiles.shared.clean()
        StoryFiles.shared.clean()
    }

    /// Not in Direct, which gets the whole screen as in the old app, nor over the keyboard.
    private var showsTabBar: Bool {
        !isTyping && paths[tab]?.contains(where: \.isDirect) != true
    }

    private func path(for tab: AppTab) -> Binding<[Route]> {
        Binding { paths[tab] ?? [] } set: { paths[tab] = $0 }
    }

    /// The IDs of the conversation on screen, if one is.
    private var visibleThread: Set<String> {
        guard case .thread(let thread) = paths[tab]?.last else { return [] }
        return Set([thread.threadId, thread.threadFbid].compactMap { $0 })
    }

    /// Opens what a tapped notification was about: its conversation for a message, Activity
    /// for the rest.
    private func open(_ opened: InstagramPush.Routing) {
        notifications.opened = nil
        guard opened.isDirect else {
            tab = .activity
            paths[.activity] = []
            return
        }
        tab = .home
        if let thread = inbox.thread(withID: opened.threadID) {
            paths[.home] = [.inbox, .thread(thread)]
            return
        }
        // Not among the conversations loaded so far: the inbox now, and on to the conversation
        // once Instagram's list has it, if you're still there.
        paths[.home] = [.inbox]
        Task {
            await inbox.load(api: session.api)
            if tab == .home, paths[.home] == [.inbox], let thread = inbox.thread(withID: opened.threadID) {
                paths[.home]?.append(.thread(thread))
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .home: FeedView()
        case .search: SearchView()
        case .activity: ActivityView()
        case .profile: OwnProfileView()
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

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .profile(let id, let username): ProfileView(id: id, username: username)
            case .post(let post): PostDetailView(post: post)
            // Posts and reels sent in messages: the video starts on its own.
            case .postCode(let code): PostLoaderView(code: code).environment(\.autoplaysVideo, true)
            case .inbox: InboxView()
            case .thread(let thread):
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "standInConversations") {
                    StandInConversation(title: thread.title)
                } else {
                    ConversationView(thread: thread)
                }
                #else
                ConversationView(thread: thread)
                #endif
            case .followRequests(let users): FollowRequestsView(requests: users)
            case .settings: SettingsView()
            case .web(let path, let title): WebPageScreen(path: path, title: title)
            }
        }
    }
}
