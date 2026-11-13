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
    /// Home tapped again at the top: the feed loads again, with a spinner above it.
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isRefreshing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .transition(.opacity)
                }
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
                    ErrorRow(message: error) {
                        Task { await reload() }
                    }
                }
            }
        }
        .scrollsToTopOnTabReselect { await refreshFromTab() }
        .background(Color.white)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .refreshable { await reload() }
        .task {
            feed.showsReels = showsReels
            if feed.posts.isEmpty { await reload() }
        }
        .onChange(of: showsReels) {
            feed.showsReels = showsReels
            Task { await feed.reload(api: session.api) }
        }
        .classicBar {
            Text("Unreeled").font(Theme.wordmark)
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

    private func reload() async {
        async let posts: Void = feed.reload(api: session.api)
        async let tray: Void = stories.loadTray(api: session.api)
        _ = await (posts, tray)
    }

    private func refreshFromTab() async {
        guard !isRefreshing else { return }
        withAnimation(.snappy(duration: 0.2)) { isRefreshing = true }
        await reload()
        withAnimation(.snappy(duration: 0.2)) { isRefreshing = false }
    }
}

@MainActor
@Observable
final class FeedModel {
    var posts: [Media] = []
    var isLoading = false
    var error: String?
    /// Reels from accounts you follow, as single videos. Off by default.
    var showsReels = false
    private var cursor: String?
    private var reachedEnd = false
    /// The furthest post that has come on screen, to load the next page well before the end.
    private var furthestSeen = 0
    /// Posts the last page added, so a page of only reels doesn't keep loading more on its own.
    private var lastPageAdded = 0

    /// How many posts before the end the next page starts loading: about six screens.
    private static let lookahead = 8

    private func belongs(_ post: Media) -> Bool {
        showsReels || !post.isReel
    }

    func reload(api: InstagramAPI) async {
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
        isLoading = true
        defer { isLoading = false }
        do {
            var fresh: [Media] = []
            var pages: [Data] = []
            var seen = Set(replacing ? [] : posts.map(\.id))
            var shownEarly = 0
            // Most of a page can be reels. Keep going (a little) until there are a few posts to show.
            repeat {
                let data = try await api.timelineData(cursor: cursor)
                let page = try await api.timelinePage(from: data, first: cursor == nil)
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
            if replacing { api.saveFeed(pages) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
