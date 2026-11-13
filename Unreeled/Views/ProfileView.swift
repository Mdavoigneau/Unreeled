import SwiftUI

/// A profile: header and a grid of posts.
struct ProfileView: View {
    let id: String
    /// Known when coming from a post or a search; your own profile looks it up.
    var username: String?
    /// Your own profile: the root of the Profile tab, with settings.
    var isOwn = false

    @Environment(Session.self) private var session
    @Environment(StoriesModel.self) private var stories
    @Environment(\.tabSelections) private var tabSelections
    @State private var model: ProfileModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 3)

    /// `model`: for your own profile, the one the app filled with the saved copy at launch.
    init(id: String, username: String? = nil, isOwn: Bool = false, model: ProfileModel? = nil) {
        self.id = id
        self.username = username
        self.isOwn = isOwn
        _model = State(initialValue: model ?? ProfileModel())
    }

    var body: some View {
        ScrollView {
            if let profile = model.profile {
                ProfileHeader(profile: profile, isOwn: isOwn) {
                    stories.open([profile.id])
                }
                GridStrip()
            }
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(model.posts) { post in
                    NavigationLink(value: Route.post(post)) {
                        GridThumbnail(post: post)
                    }
                    .onAppear { model.loadMore(near: post, api: session.api) }
                }
            }
            if model.isLoading {
                ProgressView().padding(32)
            } else if let error = model.error {
                if model.profile == nil {
                    ErrorRow(error: error) { Task { await load() } }
                } else {
                    // The saved profile stays on screen; only a quiet line says it's not the latest.
                    RefreshNote(error: error) { Task { await load() } }
                }
            } else if model.profile?.isLocked(for: session.userID) == true {
                VStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 34, weight: .light))
                    Text("This Account is Private").font(Theme.font(16, .medium))
                    Text("Follow this account to see their photos and videos.")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.ink)
                .padding(40)
            }
        }
        .scrollsToTopOnTabReselect()
        .background(Color.white)
        .refreshable { await load() }
        .task { await loadIfNeeded() }
        .onReconnect { if model.error != nil { await load() } }
        // Your own, again when you come back to its tab after a while.
        .onChange(of: tabSelections) { Task { await loadIfNeeded() } }
        .classicBar(showsBack: !isOwn) {
            Text(model.profile?.username ?? username ?? "").font(Theme.font(16, .medium))
        } trailing: {
            if isOwn {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private func load() async {
        await model.load(id: id, username: username, viewerID: session.userID, isOwn: isOwn, api: session.api)
    }

    /// Someone else's the first time; your own whenever Instagram's copy is a few minutes old.
    private func loadIfNeeded() async {
        guard !model.isLoading, isOwn ? model.isStale : model.profile == nil else { return }
        await load()
    }
}

private struct ProfileHeader: View {
    let profile: Profile
    let isOwn: Bool
    let openStory: () -> Void

    @Environment(StoriesModel.self) private var stories

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                let ring = stories.ring(forUserID: profile.id, latestStory: profile.latestReelMedia)
                Button(action: openStory) {
                    StoryAvatar(url: profile.avatarURL, size: 80, ring: ring)
                }
                .buttonStyle(.plain)
                .disabled(ring == .none)

                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Stat(value: profile.mediaCount, label: "posts")
                        Stat(value: profile.followerCount, label: "followers")
                        Stat(value: profile.followingCount, label: "following")
                    }
                    actionButton
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let name = profile.fullName, !name.isEmpty {
                    Text(name).font(Theme.font(14, .medium))
                }
                if let bio = profile.biography, !bio.isEmpty {
                    Text(bio).font(Theme.font(14))
                }
                if let website = profile.websiteURL {
                    Link(website.host() ?? website.absoluteString, destination: website)
                        .font(Theme.font(14, .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(Theme.ink)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isOwn {
            NavigationLink(value: Route.web(path: "/accounts/edit/", title: "Edit Profile")) {
                Text("Edit Profile").outlinedButton()
            }
            .buttonStyle(.plain)
        } else if profile.friendshipStatus?.following == true {
            Text("Following").outlinedButton()
        } else {
            // Following isn't native yet: it happens on the website.
            NavigationLink(value: Route.web(path: "/\(profile.username)/", title: profile.username)) {
                Text("Follow")
                    .font(Theme.font(14, .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }
}

private extension View {
    func outlinedButton() -> some View {
        font(Theme.font(14, .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 30)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
    }
}

private struct Stat: View {
    let value: Int?
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value.map { $0.formatted(.number.notation(.compactName)) } ?? "–")
                .font(Theme.font(16, .medium))
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The strip above the grid, as profiles had it.
private struct GridStrip: View {
    var body: some View {
        Image(systemName: "square.grid.3x3")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }
}

private struct GridThumbnail: View {
    let post: Media

    /// The picture's size: a third of the screen's width, in pixels.
    static let pixels: CGFloat = 400

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(post.imageURL(width: Self.pixels)) }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
    }

    private var symbol: String? {
        if post.children.count > 1 { return "square.fill.on.square.fill" }
        if post.isVideo { return "play.fill" }
        return nil
    }
}

@MainActor
@Observable
final class ProfileModel {
    var profile: Profile?
    var posts: [Media] = []
    var isLoading = false
    var error: ShownError?
    private var cursor: String?
    /// When Instagram's copy last came.
    private var loadedAt: Date?

    /// Instagram's copy is more than five minutes old, or hasn't come since launch.
    var isStale: Bool {
        loadedAt.map { Date.now.timeIntervalSince($0) > 5 * 60 } ?? true
    }

    /// Your own profile as it was last time, read off the main thread, with the pictures of its
    /// first posts decoded from the phone: the Profile tab opens complete. Nothing goes to Instagram.
    func showSaved(userID: String?, api: InstagramAPI) async {
        guard profile == nil, let saved = await api.keptProfile(), saved.profile.id == userID, profile == nil else { return }
        profile = saved.profile
        if let page = saved.posts { show(page) }
        let pictures = [saved.profile.avatarURL] + posts.prefix(12).map { $0.imageURL(width: GridThumbnail.pixels) }
        ImageCache.shared.warm(pictures.compactMap { $0 })
    }

    func load(id: String, username: String?, viewerID: String?, isOwn: Bool, api: InstagramAPI) async {
        // As it was last time, at once; Instagram's copy replaces it.
        if profile == nil, isOwn { await showSaved(userID: viewerID, api: api) }
        if profile == nil, let saved = api.cachedProfile(id: id) {
            profile = saved
            if !saved.isLocked(for: viewerID), let page = api.cachedPosts(username: saved.username) { show(page) }
        }
        // Header and posts at once, when the username is known: given, or your saved profile's.
        let username = username ?? (isOwn ? profile?.username : nil)
        isLoading = true
        defer { isLoading = false }
        do {
            if let username {
                async let fresh = api.profile(id: id, keep: isOwn)
                async let page = api.posts(username: username, keep: isOwn)
                let profile = try await fresh
                self.profile = profile
                if profile.username == username {
                    show(try await page)
                } else if !profile.isLocked(for: viewerID) {
                    // Your username changed since last time.
                    show(try await api.posts(username: profile.username, keep: isOwn))
                }
            } else {
                let profile = try await api.profile(id: id, keep: isOwn)
                self.profile = profile
                if !profile.isLocked(for: viewerID) { show(try await api.posts(username: profile.username, keep: isOwn)) }
            }
            loadedAt = .now
            error = nil
        } catch {
            if profile?.isLocked(for: viewerID) != true { self.error = ShownError(error) }
        }
    }

    func loadMore(near post: Media, api: InstagramAPI) {
        guard !isLoading, let cursor, let username = profile?.username,
              let index = posts.firstIndex(where: { $0.id == post.id }), index >= posts.count - 6
        else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let page = try await api.posts(username: username, cursor: cursor)
                var seen = Set(posts.map(\.id))
                posts += page.items.filter { seen.insert($0.id).inserted }
                self.cursor = page.cursor
            } catch {
                self.error = ShownError(error)
            }
        }
    }

    private func show(_ page: Page<Media>) {
        posts = page.items
        cursor = page.cursor
    }
}
