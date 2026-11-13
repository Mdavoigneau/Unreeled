import SwiftUI

/// A flat top bar: title in the middle, a back button when pushed, an optional button on the right.
struct ClassicBar<Title: View, Trailing: View>: View {
    var showsBack: Bool
    let title: Title
    let trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            title
                .lineLimit(1)
                .padding(.horizontal, 56)
            HStack {
                if showsBack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .regular))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                Spacer()
                trailing
                    .font(Theme.icon)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 44)
        .foregroundStyle(Theme.ink)
        .buttonStyle(.plain)
        .background(Color.white)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }
}

extension View {
    /// Puts a ClassicBar on top of the screen, in place of the system navigation bar.
    func classicBar<Title: View, Trailing: View>(
        showsBack: Bool = false,
        @ViewBuilder title: () -> Title,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let bar = ClassicBar(showsBack: showsBack, title: title(), trailing: trailing())
        return safeAreaInset(edge: .top, spacing: 0) { bar }
            .toolbar(.hidden, for: .navigationBar)
    }

    func classicBar(showsBack: Bool = false, title: String) -> some View {
        classicBar(showsBack: showsBack) {
            Text(title).font(Theme.font(16, .medium))
        } trailing: {
            EmptyView()
        }
    }
}

/// A page that says one thing and waits for an answer: what it says sits in the middle of the
/// space above, and its buttons at the bottom. It scrolls when the text is taller than the screen.
struct AnswerPage<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) { actions }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .background(Color.white)
        }
        .background(Color.white)
    }
}

extension View {
    /// The look of a page's main button: filled, as wide as the page.
    func filledButton() -> some View {
        font(Theme.font(16, .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}

enum AppTab: CaseIterable, Hashable {
    case home, search, activity, profile

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .activity: "heart"
        case .profile: "person"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .activity: "heart.fill"
        case .profile: "person.fill"
        }
    }

    var name: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .activity: "Activity"
        case .profile: "Profile"
        }
    }
}

/// A flat tab bar: icons only, filled when selected, a hairline on top.
struct ClassicTabBar: View {
    @Binding var selection: AppTab
    /// Tapping the open tab again: back to its first screen, or to the top of it.
    var reselect: (AppTab) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    if selection == tab { reselect(tab) } else { selection = tab }
                } label: {
                    Image(systemName: selection == tab ? tab.selectedSymbol : tab.symbol)
                        .font(.system(size: 23, weight: selection == tab ? .semibold : .light))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.name)
            }
        }
        .background(Color.white.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
    }
}

extension EnvironmentValues {
    /// Goes up each time the open tab's button is tapped while its first screen shows.
    @Entry var tabReselections = 0
    /// Goes up each time you switch to the tab, so its first screen can bring what's out of date
    /// up to date.
    @Entry var tabSelections = 0
}

extension View {
    /// For a tab's first screen: back to the top when the tab's button is tapped again, and when
    /// it's already at the top, `refresh` if there is one (Home loads its feed again).
    ///
    /// With `refreshesOnReturn`, coming back to the app refreshes too: after a minute away if the
    /// screen is at the top, and after ten minutes from the top, wherever it was.
    func scrollsToTopOnTabReselect(refreshesOnReturn: Bool = false, refresh: (() async -> Void)? = nil) -> some View {
        modifier(ScrollsToTopOnTabReselect(refreshesOnReturn: refreshesOnReturn, refresh: refresh))
    }
}

private struct ScrollsToTopOnTabReselect: ViewModifier {
    var refreshesOnReturn: Bool
    var refresh: (() async -> Void)?
    @Environment(\.tabReselections) private var reselections
    @Environment(\.scenePhase) private var scenePhase
    @State private var position = ScrollPosition(edge: .top)
    @State private var isAtTop = true
    @State private var leftAt: Date?

    /// Away this long, a screen at the top refreshes when the app comes back.
    private static let refreshAtTopAfter: TimeInterval = 60
    /// Away this long, it goes back to the top and refreshes, like a new start.
    private static let startOverAfter: TimeInterval = 10 * 60

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= -geometry.contentInsets.top + 1
            } action: { _, atTop in
                isAtTop = atTop
            }
            .onChange(of: reselections) {
                if isAtTop, let refresh {
                    Task { await refresh() }
                } else {
                    withAnimation(.snappy(duration: 0.35)) { position.scrollTo(edge: .top) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard refreshesOnReturn, let refresh else { return }
                switch phase {
                case .background:
                    if leftAt == nil { leftAt = .now }
                case .active:
                    guard let leftAt else { return }
                    self.leftAt = nil
                    let away = Date.now.timeIntervalSince(leftAt)
                    if away >= Self.startOverAfter {
                        position.scrollTo(edge: .top)
                        Task { await refresh() }
                    } else if away >= Self.refreshAtTopAfter, isAtTop {
                        Task { await refresh() }
                    }
                default:
                    break
                }
            }
    }
}

/// A round avatar with a ring when the account has a story.
struct StoryAvatar: View {
    enum Ring {
        case none, unseen, seen
    }

    let url: URL?
    var size: CGFloat
    var ring: Ring

    var body: some View {
        Avatar(url: url, size: size)
            .padding(ring == .none ? 0 : (size > 40 ? 4 : 3))
            .overlay {
                switch ring {
                case .unseen: Circle().strokeBorder(Theme.storyRing, lineWidth: size > 40 ? 2 : 1.5)
                case .seen: Circle().strokeBorder(Theme.hairline, lineWidth: 1)
                case .none: EmptyView()
                }
            }
    }
}

/// An instagram.com page, with the app's bar on top.
struct WebPageScreen: View {
    let path: String
    let title: String

    var body: some View {
        WebScreen(path: path)
            .classicBar(showsBack: true, title: title)
    }
}
