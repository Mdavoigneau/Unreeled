import AVFoundation
import SwiftUI

@main
struct UnreeledApp: App {
    @State private var session = Session()

    init() {
        // Play video sound even when the phone is on silent, as Safari does.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        // Keep downloaded images on disk, so scrolling back and relaunching don't fetch them again.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

/// The notice the first time, then Instagram's login page until you're logged in, then the
/// native app. A build made for the push test asks about it once, before the app.
struct RootView: View {
    @Environment(Session.self) private var session
    @AppStorage(Notice.key) private var acceptedNotice = 0
    @AppStorage(PushTest.askedKey) private var askedPushTest = false
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
                if let test = PushTest.bundled, !askedPushTest {
                    PushTestOffer(test: test)
                } else {
                    home
                }
            }
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.home
    @State private var opened: Set<AppTab> = [.home]
    /// The screens each tab has open on top of its first one.
    @State private var paths: [AppTab: [Route]] = [:]
    @State private var isTyping = false

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases, id: \.self) { tab in
                if opened.contains(tab) {
                    NavigationStack(path: path(for: tab)) { screen(for: tab).routes() }
                        .environment(\.navigate, NavigateAction(tab: tab) { route in paths[tab, default: []].append(route) })
                        .opacity(self.tab == tab ? 1 : 0)
                        .allowsHitTesting(self.tab == tab)
                        .accessibilityHidden(self.tab != tab)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsTabBar {
                ClassicTabBar(selection: $tab) { paths[$0] = [] }
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy(duration: 0.25), value: showsTabBar)
        .onChange(of: tab) { opened.insert(tab) }
        .task {
            ResponseCache.shared.clean()
            // Newer query IDs from the project, if Instagram changed any (at most every 6 hours).
            Task { await QueryUpdates.check(afterFailure: false) }
            // The inbox, a moment after the first screen: the paper plane's count, and the latest
            // conversations ready to open.
            try? await Task.sleep(for: .seconds(2))
            await inbox.load(api: session.api, force: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await QueryUpdates.check(afterFailure: false) }
            Task { await inbox.load(api: session.api, force: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isTyping = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isTyping = false
        }
    }

    /// Not in Direct, which gets the whole screen as in the old app, nor over the keyboard.
    private var showsTabBar: Bool {
        !isTyping && paths[tab]?.contains(where: \.isDirect) != true
    }

    private func path(for tab: AppTab) -> Binding<[Route]> {
        Binding { paths[tab] ?? [] } set: { paths[tab] = $0 }
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
