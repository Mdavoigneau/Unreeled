import SwiftUI

/// Home: stories on top, then posts from accounts you follow, newest first, without reels.
struct FeedView: View {
    @Environment(Session.self) private var session
    @Environment(StoriesModel.self) private var stories
    @Environment(InboxModel.self) private var inbox
    @Environment(\.displayScale) private var displayScale
    @AppStorage("showsReels") private var showsReels = false
    @State private var feed = FeedModel()
    @State private var width: CGFloat = 0
    /// The refresh under way, which the wordmark shows. Asking again meanwhile waits for it.
    @State private var refreshing: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                StoriesTray()
                ForEach($feed.posts) { $post in
                    PostCard(post: $post)
                        .onAppear {
                            feed.loadMore(near: post, api: session.api)
                            feed.prefetchImages(after: post, pixels: width * displayScale)
                        }
                }
                if feed.isLoading {
                    ProgressView().padding(32)
                } else if let error = feed.error {
                    if feed.posts.isEmpty {
                        ErrorRow(error: error) { Task { await retry() } }
                    } else {
                        RefreshNote(text: feed.failedLoadingMore ? "Couldn't load more posts." : "Couldn't refresh.", error: error) {
                            Task { await retry() }
                        }
                    }
                }
            }
        }
        // Home tapped at the top, and coming back to the app after a while: the latest posts.
        .scrollsToTopOnTabReselect(refreshesOnReturn: true) { await refresh() }
        .background(Color.white)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .refreshable { await refresh() }
        // Back online after a load that failed: again, without being asked.
        .onReconnect { if feed.error != nil { await retry() } }
        .task {
            feed.showsReels = showsReels
            // The saved feed shows at once, and Instagram's latest replaces it right away.
            if feed.posts.isEmpty { await refresh() }
        }
        .onChange(of: showsReels) {
            feed.showsReels = showsReels
            Task { await feed.reload(api: session.api) }
        }
        .classicBar {
            FillingWordmark(isLoading: refreshing != nil)
        } trailing: {
            NavigationLink(value: Route.inbox) {
                Image(systemName: "paperplane")
                    .overlay(alignment: .topTrailing) {
                        if inbox.unreadCount > 0 {
                            Text("\(inbox.unreadCount)")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(Theme.like, in: Capsule())
                                .offset(x: 9, y: -6)
                        }
                    }
            }
            .accessibilityLabel(inbox.unreadCount > 0 ? "Messages, \(inbox.unreadCount) unread" : "Messages")
        }
    }

    /// What failed, again: the next page when that was it, otherwise the whole feed.
    private func retry() async {
        if feed.failedLoadingMore {
            await feed.loadMoreAgain(api: session.api)
        } else {
            await refresh()
        }
    }

    /// Posts and stories from Instagram, the wordmark filling meanwhile. Once at a time.
    private func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task {
            async let posts: Void = feed.reload(api: session.api)
            async let tray: Void = stories.loadTray(api: session.api)
            _ = await (posts, tray)
        }
        refreshing = task
        await task.value
        refreshing = nil
    }
}

/// The wordmark, filling with ink from left to right while the feed loads: quickly at first,
/// then slower and slower, and the rest at once when the posts are in.
private struct FillingWordmark: View {
    var isLoading: Bool
    @State private var startedAt: Date?
    @State private var finish: Finish?

    private struct Finish {
        let at: Date
        let from: Double
    }

    private static let finishDuration: TimeInterval = 0.35

    var body: some View {
        TimelineView(.animation(paused: startedAt == nil)) { context in
            Wordmark(fill: fill(at: context.date))
        }
        .onChange(of: isLoading, initial: true) { _, isLoading in
            if isLoading {
                startedAt = .now
                finish = nil
            } else if let startedAt, finish == nil {
                let now = Date.now
                finish = Finish(at: now, from: Self.loadingFill(after: now.timeIntervalSince(startedAt)))
                Task {
                    try? await Task.sleep(for: .seconds(Self.finishDuration))
                    // Unless a new load started meanwhile.
                    if finish?.at == now {
                        self.startedAt = nil
                        finish = nil
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unreeled")
        .accessibilityValue(isLoading ? "Loading" : "")
    }

    private func fill(at date: Date) -> Double {
        guard let startedAt else { return 1 }
        guard let finish else { return Self.loadingFill(after: date.timeIntervalSince(startedAt)) }
        let progress = min(1, max(0, date.timeIntervalSince(finish.at) / Self.finishDuration))
        return finish.from + (1 - finish.from) * (1 - pow(1 - progress, 3))
    }

    /// Never quite full while loading: nearly half after a second, 80% after three.
    private static func loadingFill(after seconds: TimeInterval) -> Double {
        0.92 * (1 - exp(-max(0, seconds) / 1.5))
    }
}

/// The wordmark in light grey, with ink over it as far as `fill` (0 to 1), edged softly.
private struct Wordmark: View {
    let fill: Double
    private let edge: CGFloat = 16

    var body: some View {
        text
            .foregroundStyle(Theme.hairline)
            .overlay {
                text
                    .foregroundStyle(Theme.ink)
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            let reach = fill * (proxy.size.width + edge)
                            HStack(spacing: 0) {
                                Rectangle().frame(width: max(0, reach - edge))
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: edge)
                            }
                            .offset(x: min(0, reach - edge))
                        }
                    }
            }
    }

    /// With room around it for the script's flourishes, which reach past the text's own frame.
    private var text: some View {
        Text("Unreeled")
            .font(Theme.wordmark)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }
}

@MainActor
@Observable
final class FeedModel {
    var posts: [Media] = []
    var isLoading = false
    var error: ShownError?
    /// The error was in loading the next page, not the feed's first.
    private(set) var failedLoadingMore = false
    /// Reels from accounts you follow, as single videos. Off by default.
    var showsReels = false
    private var cursor: String?
    private var reachedEnd = false
    /// The furthest post that has come on screen, to load the next page well before the end.
    private var furthestSeen = 0
    /// Posts the last page added, so a page of only reels doesn't keep loading more on its own.
    private var lastPageAdded = 0
    /// Goes up with each reload, so a page asked for before it doesn't land in the new feed.
    private var generation = 0

    /// How many posts before the end the next page starts loading: about six screens.
    private static let lookahead = 8

    private func belongs(_ post: Media) -> Bool {
        showsReels || !post.isReel
    }

    func reload(api: InstagramAPI) async {
        generation += 1
        // The feed as it was last time, at once; Instagram's replaces it when it arrives.
        if posts.isEmpty {
            let saved = await api.cachedFeed().filter(belongs)
            if posts.isEmpty { posts = saved }
        }
        cursor = nil
        reachedEnd = false
        furthestSeen = 0
        await load(api: api, replacing: true)
    }

    /// The next posts' first pictures: the next four decoded before they scroll into view, the four
    /// after onto the phone.
    func prefetchImages(after post: Media, pixels: CGFloat) {
        guard pixels > 0, let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        let next = posts.dropFirst(index + 1).prefix(8).compactMap { ($0.children.first ?? $0).imageURL(width: pixels) }
        ImageCache.shared.prefetch(Array(next.prefix(4)), decode: true)
        ImageCache.shared.prefetch(Array(next.dropFirst(4)), decode: false)
    }

    /// Fetches the next page once `post` is within the last eight, well before you reach the end.
    func loadMore(near post: Media, api: InstagramAPI) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        furthestSeen = max(furthestSeen, index)
        loadMoreIfNeeded(api: api)
    }

    private func loadMoreIfNeeded(api: InstagramAPI) {
        guard !isLoading, !reachedEnd, error == nil, furthestSeen >= posts.count - Self.lookahead else { return }
        Task {
            await load(api: api, replacing: false)
            // Still near the end (that page was mostly reels): the one after it, too.
            if lastPageAdded > 0 { loadMoreIfNeeded(api: api) }
        }
    }

    private func load(api: InstagramAPI, replacing: Bool) async {
        let generation = generation
        let account = SavedCopies.account
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            var fresh: [Media] = []
            var pages: [Data] = []
            var seen = Set(replacing ? [] : posts.map(\.id))
            var shownEarly = 0
            // Most of a page can be reels. Keep going (a little) until there are a few posts to show.
            repeat {
                let next = cursor
                let data = try await api.timelineData(cursor: next)
                let page = try await api.timelinePage(from: data, first: next == nil)
                // A reload started meanwhile: this page belongs to the feed it replaces.
                guard generation == self.generation else { return }
                pages.append(data)
                cursor = page.cursor
                reachedEnd = page.cursor == nil
                fresh += page.items.filter { belongs($0) && seen.insert($0.id).inserted }
                // An empty screen gets the first posts now, not after the next page.
                if replacing, posts.isEmpty, !fresh.isEmpty {
                    posts = fresh
                    shownEarly = fresh.count
                }
            } while fresh.count < 4 && !reachedEnd && pages.count < 4

            lastPageAdded = fresh.count
            if !replacing {
                posts += fresh
            } else if shownEarly > 0 {
                // Those stay as they are (you may have liked one meanwhile).
                posts += fresh.dropFirst(shownEarly)
            } else {
                posts = fresh
            }
            if replacing { api.saveFeed(pages, account: account) }
            error = nil
        } catch {
            if generation == self.generation {
                self.error = ShownError(error)
                failedLoadingMore = !replacing
            }
        }
    }

    /// The next page, after it failed to load.
    func loadMoreAgain(api: InstagramAPI) async {
        guard !isLoading else { return }
        error = nil
        await load(api: api, replacing: false)
    }
}
