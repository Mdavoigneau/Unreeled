import AVFoundation
import PhotosUI
import SwiftUI

/// Stories: the tray of accounts you follow, what you've seen, and the viewer on screen.
@MainActor
@Observable
final class StoriesModel {
    struct Presentation: Identifiable {
        let id = UUID()
        let reelIDs: [String]
        let start: Int
    }

    var tray: [Reel] = []
    var presented: Presentation?
    /// Reels loaded with their items, by owner ID.
    private var loaded: [String: Reel] = [:]
    /// Loaded reels taken from what the phone saved, not from Instagram since launch: the viewer
    /// asks Instagram for one as it shows it, as the website does, and Instagram's answer
    /// replaces it.
    private var fromPhone: Set<String> = []
    /// When the newest item you saw in each reel was posted, as you watch.
    private var seenUpTo: [String: Double] = [:]

    func loadTray(api: InstagramAPI) async {
        // The tray as it was last time, at once, then Instagram's.
        if tray.isEmpty { tray = api.cachedStoriesTray() }
        guard let fresh = try? await api.storiesTray() else { return }
        // A reel loaded earlier that has something newer loads again when you open it.
        for reel in fresh {
            guard let old = loaded[reel.id] else { continue }
            let newest = old.latestReelMedia ?? old.items?.elements.compactMap(\.takenAt).max() ?? 0
            if (reel.latestReelMedia ?? 0) > newest { loaded[reel.id] = nil }
        }
        tray = fresh
        prefetch(api: api)
    }

    // MARK: Ahead of time

    /// Reels being loaded right now, so the viewer and loading ahead don't ask for them twice.
    private var reelsLoading: Set<String> = []
    private var isPrefetching = false
    /// Photos and videos to put on the phone, in the order you'd watch them.
    private var downloads: [URL] = []
    /// What the viewer is about to show: these load whatever the budget.
    private var urgent: Set<URL> = []
    private var isDownloading = false

    /// Accounts loaded ahead at launch: three batches. The others load while you watch, a batch
    /// ahead of where you are, as on the website.
    private static let accountsAhead = 9

    /// The accounts with something new: first from what the phone saved today, when an account has
    /// posted nothing since; then the first nine still missing, three at a time as the website's
    /// viewer loads them, a second apart. Their photos and videos are queued for the phone, and
    /// the first account's opening picture is decoded, so it opens at once.
    private func prefetch(api: InstagramAPI) {
        guard !isPrefetching else { return }
        isPrefetching = true
        let ids = tray.filter { ring(for: $0) == .unseen }.map(\.id)
        let newest = Dictionary(tray.map { ($0.id, $0.latestReelMedia ?? 0) }, uniquingKeysWith: max)
        Task {
            defer { isPrefetching = false }
            let saved = await Task.detached(priority: .userInitiated) { StoryFiles.shared.savedReels(ids: ids) }.value
            // Without the items whose day is over; one with none left isn't used.
            let current = saved.compactMap(Self.current).filter { reel in
                loadedReel(reel.id) == nil && (reel.items?.elements.compactMap(\.takenAt).max() ?? 0) >= (newest[reel.id] ?? .infinity)
            }
            for reel in current {
                loaded[reel.id] = reel
                fromPhone.insert(reel.id)
            }
            queueFiles(of: current)
            decodeOpeningPicture(of: ids)

            let missing = ids.prefix(Self.accountsAhead).filter { loadedReel($0) == nil && !reelsLoading.contains($0) }
            for (number, start) in stride(from: 0, to: missing.count, by: 3).enumerated() {
                if number > 0 { try? await Task.sleep(for: .seconds(1)) }
                let batch = Array(missing.dropFirst(start).prefix(3)).filter { loadedReel($0) == nil && !reelsLoading.contains($0) }
                guard !batch.isEmpty else { continue }
                guard (try? await load(batch, api: api)) != nil else { return }
                if number == 0 { decodeOpeningPicture(of: ids) }
            }
        }
    }

    /// The picture the first account with something new opens on, decoded ahead.
    private func decodeOpeningPicture(of ids: [String]) {
        guard let first = ids.first, let reel = loadedReel(first),
              let url = startItem(of: reel)?.imageURL(width: StoryViewer.imageWidth)
        else { return }
        Task { _ = await ImageCache.shared.image(for: url, store: .stories) }
    }

    /// Loads these reels with their items, and queues their photos and videos for the phone.
    /// Instagram's answer replaces what was loaded or saved before, so what the owner took down
    /// since goes, and an account that has nothing up any more has nothing loaded.
    @discardableResult
    private func load(_ ids: [String], api: InstagramAPI) async throws -> [Reel] {
        reelsLoading.formUnion(ids)
        defer { reelsLoading.subtract(ids) }
        let reels = try await api.stories(userIDs: ids)
        let answered = Set(reels.map(\.id))
        for id in ids where !answered.contains(id) { loaded[id] = nil }
        for reel in reels { loaded[reel.id] = reel }
        fromPhone.subtract(ids)
        queueFiles(of: reels)
        return reels
    }

    /// The viewer reached `index`: the batch after it loads now, if it hasn't yet.
    func loadAhead(from index: Int, of ids: [String], api: InstagramAPI) {
        guard ids.indices.contains(index) else { return }
        let batch = ids[index...].prefix(3).filter { loadedReel($0) == nil && !reelsLoading.contains($0) }
        guard !batch.isEmpty else { return }
        Task { try? await load(Array(batch), api: api) }
    }

    /// The reel without the items whose day is over (a story lasts 24 hours from when it was
    /// posted), or nil when none is left: for a reel loaded a while ago, or saved on the phone.
    private static func current(_ reel: Reel) -> Reel? {
        let dayAgo = Date().timeIntervalSince1970 - 86_400
        var reel = reel
        reel.items?.elements.removeAll { ($0.takenAt ?? 0) <= dayAgo }
        return reel.items?.elements.isEmpty == false ? reel : nil
    }

    /// The item a reel opens on: the first you haven't seen.
    func startItem(of reel: Reel) -> Media? {
        let items = reel.items?.elements ?? []
        return items.first { ($0.takenAt ?? 0) > seen(reel) } ?? items.first
    }

    /// A story item's files: its picture (for a video, the cover that shows while it starts) and
    /// its video.
    static func files(of item: Media) -> [URL] {
        [item.imageURL(width: StoryViewer.imageWidth), item.isVideo ? item.videoURL : nil].compactMap { $0 }
    }

    /// Each reel's items from the first you haven't seen, eight at most, in order.
    private func queueFiles(of reels: [Reel]) {
        for reel in reels {
            let items = reel.items?.elements ?? []
            let start = items.firstIndex { ($0.takenAt ?? 0) > seen(reel) } ?? 0
            for item in items[start...].prefix(8) {
                downloads += Self.files(of: item).filter { !downloads.contains($0) }
            }
        }
        runDownloads()
    }

    /// What the viewer shows next goes first in line.
    func prioritize(_ items: [Media]) {
        let urls = items.flatMap(Self.files)
        guard !urls.isEmpty else { return }
        downloads.removeAll { urls.contains($0) }
        downloads.insert(contentsOf: urls, at: 0)
        urgent.formUnion(urls)
        runDownloads()
    }

    /// One file at a time. Loading ahead stops at 30 MB of stories on the phone (videos are most
    /// of it, a few MB each); what the viewer is about to show still loads.
    private func runDownloads() {
        guard !isDownloading else { return }
        isDownloading = true
        let account = SavedCopies.account
        Task {
            defer { isDownloading = false }
            var budget = StoryFiles.aheadBudget - (await Task.detached(priority: .utility) { StoryFiles.shared.bytes }.value)
            // What's queued was for the login it began in: it stops when that login ends.
            while !downloads.isEmpty, SavedCopies.account == account {
                let url = downloads.removeFirst()
                let isUrgent = urgent.remove(url) != nil
                guard StoryFiles.shared.file(for: url) == nil, isUrgent || budget > 0 else { continue }
                if let file = await StoryFiles.shared.download(url) {
                    budget -= (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                }
            }
        }
    }

    func open(_ reelIDs: [String], at start: Int = 0) {
        guard !reelIDs.isEmpty else { return }
        presented = Presentation(reelIDs: reelIDs, start: start)
    }

    /// Everyone else's stories in the tray, starting at the first reel with something new.
    func watchAll(except myID: String?) {
        let reels = tray.filter { $0.id != myID }
        let first = reels.firstIndex { ring(for: $0) == .unseen } ?? 0
        open(reels.map(\.id), at: first)
    }

    func seen(_ reel: Reel) -> Double {
        let inTray = tray.first { $0.id == reel.id }?.seen ?? 0
        return max(reel.seen ?? 0, seenUpTo[reel.id] ?? 0, loaded[reel.id]?.seen ?? 0, inTray)
    }

    func ring(for reel: Reel) -> StoryAvatar.Ring {
        (reel.latestReelMedia ?? 0) > seen(reel) ? .unseen : .seen
    }

    /// For an avatar outside the tray (a post's author, a profile).
    func ring(forUserID id: String, latestStory: Double?) -> StoryAvatar.Ring {
        guard let latestStory, latestStory > Date().timeIntervalSince1970 - 86_400 else { return .none }
        if let reel = tray.first(where: { $0.id == id }) { return ring(for: reel) }
        return latestStory > max(seenUpTo[id] ?? 0, loaded[id]?.seen ?? 0) ? .unseen : .seen
    }

    /// A reel already loaded, if it is, without the items whose day is over.
    func loadedReel(_ id: String) -> Reel? { loaded[id].flatMap(Self.current) }

    /// The loaded reel came from what the phone saved, not from Instagram since launch.
    func isFromPhone(_ id: String) -> Bool { fromPhone.contains(id) }

    /// Instagram's copy of a reel that came from what the phone saved: nil when the account has
    /// nothing up any more.
    func refreshFromPhone(_ id: String, api: InstagramAPI) async throws -> Reel? {
        guard fromPhone.contains(id), !reelsLoading.contains(id) else { return loadedReel(id) }
        try await load([id], api: api)
        return loadedReel(id)
    }

    /// A reel with its items, loading it along with the next couple, as the website does. Nil when
    /// the account has nothing up any more (expired, or just deleted).
    func reel(at index: Int, of ids: [String], api: InstagramAPI) async throws -> Reel? {
        let id = ids[index]
        // Already on its way (loading ahead): wait for it, up to five seconds, rather than ask again.
        var waited = 0
        while reelsLoading.contains(id), loaded[id] == nil, waited < 50 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        if let reel = loadedReel(id) { return reel }
        let batch = ids[index...].prefix(3).filter { loadedReel($0) == nil && !reelsLoading.contains($0) }
        try await load(Array(batch.isEmpty ? [id] : batch), api: api)
        if loadedReel(id) == nil { tray.removeAll { $0.id == id } }
        return loadedReel(id)
    }

    /// Marks an item seen once, like the website does about a second after showing it.
    func markSeen(_ item: Media, in reel: Reel, api: InstagramAPI) {
        let postedAt = item.takenAt ?? 0
        guard postedAt > seen(reel) else { return }
        seenUpTo[reel.id] = postedAt
        #if DEBUG
        // -noStorySeen YES: tests the viewer without putting you in anyone's list of viewers.
        if UserDefaults.standard.bool(forKey: "noStorySeen") { return }
        #endif
        Task { try? await api.markStorySeen(item, ownerID: reel.id) }
    }

    /// A reply on its way: shown at once, then ticked when Instagram has it.
    enum ReplyStatus: Equatable {
        case sending(to: String)
        case delivered(to: String)
        case failed(to: String)
    }

    /// Here rather than in the viewer, so the tick still shows if the viewer closes first.
    var replyStatus: ReplyStatus?

    /// Sends a reply in the background and follows it in `replyStatus`.
    func reply(_ text: String, to item: Media, in reel: Reel, api: InstagramAPI) {
        let ownerID = reel.user?.id ?? reel.id
        let owner = reel.user?.username ?? ""
        replyStatus = .sending(to: owner)
        Task {
            do {
                _ = try await api.replyToStory(text, item: item, ownerID: ownerID, reelID: reel.id)
                replyStatus = .delivered(to: owner)
            } catch {
                replyStatus = .failed(to: owner)
            }
            let shown = replyStatus
            try? await Task.sleep(for: .seconds(2.5))
            if replyStatus == shown { replyStatus = nil }
        }
    }

    // MARK: Your story

    /// Your avatar, for "Your Story" at the start of the tray.
    private(set) var myAvatarURL: URL?
    private var hasLoadedMe = false

    /// Last time's picture at once, then the current one (once a launch).
    func loadMe(userID: String, api: InstagramAPI) async {
        guard !hasLoadedMe else { return }
        hasLoadedMe = true
        if myAvatarURL == nil { myAvatarURL = api.cachedProfile(id: userID)?.avatarURL }
        if let profile = try? await api.profile(id: userID) {
            myAvatarURL = profile.avatarURL
        } else {
            hasLoadedMe = false
        }
    }

    /// Posting to or deleting from your story, in the background, with a note on screen.
    enum PostStatus: Equatable {
        case posting, posted, failed, deleted, deleteFailed
    }

    var postStatus: PostStatus?

    /// Posts a photo or video to your story in the background and follows it in `postStatus`.
    func post(_ media: PreparedMedia, userID: String, api: InstagramAPI) {
        postStatus = .posting
        Task {
            do {
                let mediaID: String
                if media.isVideo {
                    mediaID = try await api.postStoryVideo(
                        media.data, cover: media.coverJPEG ?? Data(), width: media.width, height: media.height,
                        durationMs: media.durationMs
                    )
                } else {
                    mediaID = try await api.postStoryPhoto(media.data, width: media.width, height: media.height)
                }
                #if DEBUG
                NetworkRecorder.append(["time": Date().ISO8601Format(), "storyPosted": mediaID])
                #endif
                loaded[userID] = nil
                await loadTray(api: api)
                show(.posted)
            } catch {
                #if DEBUG
                NetworkRecorder.append(["time": Date().ISO8601Format(), "storyPostFailed": error.localizedDescription])
                #endif
                show(.failed)
            }
        }
    }

    /// Deletes one of your story items. The viewer has already taken it off screen.
    func delete(_ item: Media, ownerID: String, api: InstagramAPI) {
        loaded[ownerID]?.items?.elements.removeAll { $0.id == item.id }
        let nothingLeft = loaded[ownerID]?.items?.elements.isEmpty ?? true
        // Instagram's tray takes a moment to catch up: update ours now.
        if nothingLeft { tray.removeAll { $0.id == ownerID } }
        Task {
            do {
                try await api.deleteStoryItem(item.id)
                if nothingLeft { loaded[ownerID] = nil }
                show(.deleted)
            } catch {
                #if DEBUG
                NetworkRecorder.append(["time": Date().ISO8601Format(), "storyDeleteFailed": error.localizedDescription])
                #endif
                loaded[ownerID] = nil
                show(.deleteFailed)
            }
        }
    }

    private func show(_ status: PostStatus) {
        postStatus = status
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if postStatus == status { postStatus = nil }
        }
    }

    /// Likes changed here, by item, over what the reel said when it loaded.
    private var likes: [String: Bool] = [:]

    func isLiked(_ item: Media) -> Bool {
        likes[item.id] ?? item.hasLiked ?? false
    }

    /// The heart changes at once; Instagram hears about it in the background, and the heart goes
    /// back if that fails.
    func toggleLike(_ item: Media, api: InstagramAPI) {
        let liked = !isLiked(item)
        likes[item.id] = liked
        Task {
            do {
                try await api.setStoryLiked(liked, item: item)
            } catch {
                likes[item.id] = !liked
            }
        }
    }
}

/// The row of stories on top of Home: yours first, with a + to add to it, then the accounts you
/// follow.
struct StoriesTray: View {
    @Environment(StoriesModel.self) private var stories
    @Environment(Session.self) private var session
    @State private var isPicking = false
    @State private var picked: PhotosPickerItem?
    @State private var isPreparing = false
    @State private var composing: PreparedMedia?

    private var myReel: Reel? { stories.tray.first { $0.id == session.userID } }
    private var others: [Reel] { stories.tray.filter { $0.id != session.userID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stories").font(Theme.font(14, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                if !others.isEmpty {
                    Button {
                        stories.watchAll(except: session.userID)
                    } label: {
                        Label("Watch All", systemImage: "play.fill")
                            .font(Theme.font(14, .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    yourStory
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, reel in
                        Button {
                            stories.open(others.map(\.id), at: index)
                        } label: {
                            VStack(spacing: 5) {
                                StoryAvatar(url: reel.user?.avatarURL, size: 56, ring: stories.ring(for: reel))
                                    .frame(width: 64, height: 64)
                                Text(reel.user?.username ?? "")
                                    .font(Theme.font(11))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .frame(width: 66)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 10)
        .background(Theme.tray)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
        .photosPicker(isPresented: $isPicking, selection: $picked, matching: .any(of: [.images, .videos]))
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            isPreparing = true
            Task {
                defer { isPreparing = false }
                composing = try? await MediaPreparation.prepare(item)
            }
        }
        .fullScreenCover(item: $composing) { media in
            StoryComposer(media: media) {
                if let me = session.userID { stories.post(media, userID: me, api: session.api) }
            }
        }
        .task {
            if let me = session.userID { await stories.loadMe(userID: me, api: session.api) }
        }
    }

    /// Your avatar: opens your story when you have one, the library otherwise. The + always
    /// adds to it.
    private var yourStory: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    if let myReel { stories.open([myReel.id]) } else { isPicking = true }
                } label: {
                    StoryAvatar(
                        url: stories.myAvatarURL ?? myReel?.user?.avatarURL, size: 56,
                        ring: myReel.map { stories.ring(for: $0) } ?? .none
                    )
                    .frame(width: 64, height: 64)
                    .overlay {
                        if isPreparing || stories.postStatus == .posting {
                            Circle().fill(.white.opacity(0.6)).frame(width: 56, height: 56)
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(myReel == nil ? "Add to your story" : "Your story")
                Button {
                    isPicking = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.tray, lineWidth: 2))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: 5)
                .accessibilityLabel("Add to your story")
            }
            Text("Your Story")
                .font(Theme.font(11))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .frame(width: 66)
        }
    }
}

/// Before anything goes up: the photo or video as it will be posted, and one button to share it.
struct StoryComposer: View {
    let media: PreparedMedia
    let share: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: media.preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if media.isVideo {
                Label(videoLength, systemImage: "video.fill")
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        share()
                        dismiss()
                    } label: {
                        Label("Share to Your Story", systemImage: "plus.circle.fill")
                            .font(Theme.font(15, .medium))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .statusBarHidden()
    }

    private var videoLength: String {
        let seconds = media.durationMs / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Full-screen stories: tap the right side for the next item, the left side for the previous,
/// hold to pause, swipe down to close. Moves on to the next account when one ends. At the bottom,
/// a field to reply and a heart to like, as on the website.
///
/// The story is a 9:16 card under the status bar, with the reply field below it, as in
/// Instagram's app; on a screen too short for that, it takes the whole screen.
struct StoryViewer: View {
    let presentation: StoriesModel.Presentation

    @Environment(StoriesModel.self) private var stories
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var reelIndex: Int
    @State private var reel: Reel?
    @State private var itemIndex = 0
    @State private var restarts = 0
    @State private var isHolding = false
    @State private var touchStart: Date?
    /// A swipe down, once the finger has clearly gone down: until then a touch is a tap or a
    /// hold, and the story doesn't move.
    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var playing: PlayingVideo?
    @State private var error: ShownError?
    /// The current photo or video isn't on screen yet: the bar waits, and a spinner shows.
    @State private var isLoadingMedia = false
    @State private var reply = ""
    @FocusState private var isReplying: Bool
    @State private var confirmingDelete = false
    /// Sliding away after a swipe down: nothing moves on meanwhile.
    @State private var isClosing = false
    /// How far the current item has played. Only the bars read it, every frame.
    @State private var clock = StoryClock()

    /// The video on screen, and which item it's for.
    struct PlayingVideo {
        let itemID: String
        let player: AVPlayer
    }

    /// Holding a finger down, typing a reply, deciding whether to delete, or closing.
    private var isPaused: Bool { isHolding || isReplying || confirmingDelete || isClosing }

    private var isMine: Bool { reel != nil && reel?.id == session.userID }

    /// Not on your own stories, nor when the owner turned replies off.
    private var canReact: Bool {
        guard let reel, item != nil else { return false }
        return reel.id != session.userID && reel.canReply != false
    }

    init(presentation: StoriesModel.Presentation) {
        self.presentation = presentation
        _reelIndex = State(initialValue: presentation.start)
    }

    /// Story pictures are loaded at this width, ahead of showing them.
    static let imageWidth: CGFloat = 1080

    private var items: [Media] { reel?.items?.elements ?? [] }
    private var item: Media? { items.indices.contains(itemIndex) ? items[itemIndex] : nil }

    /// Swiping down: how far, from 0 to 1.
    private var dragProgress: CGFloat { min(dragOffset / 500, 1) }
    private var playKey: String { "\(reel?.id ?? "-")/\(itemIndex)/\(restarts)" }

    var body: some View {
        GeometryReader { geometry in
            let card = Self.card(for: geometry)
            let isFullScreen = card.minY == 0
            VStack(spacing: 0) {
                story(width: card.width, headerInset: isFullScreen ? geometry.safeAreaInsets.top : 0)
                    .frame(width: card.width, height: card.height)
                    .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 28 * min(dragOffset / 60, 1) : 10))
                Spacer(minLength: 0)
            }
            .padding(.top, card.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .scaleEffect(1 - dragProgress * 0.12, anchor: .top)
            .offset(y: dragOffset)
        }
        // Outside the full-screen layer, so the keyboard pushes it up.
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if let status = stories.postStatus { StoryPostToast(status: status) }
                if let status = stories.replyStatus { ReplyToast(status: status) }
                if canReact { footer }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .offset(y: dragOffset)
            .animation(.snappy(duration: 0.2), value: stories.replyStatus)
            .animation(.snappy(duration: 0.2), value: stories.postStatus)
        }
        .background(Color.black.opacity(1 - dragProgress).ignoresSafeArea())
        .presentationBackground(.clear)
        .statusBarHidden()
        .task(id: reelIndex) { await loadReel() }
        .task(id: playKey) { await play() }
        .onReconnect { if error != nil { await loadReel() } }
        .onChange(of: isPaused) {
            if isPaused {
                playing?.player.pause()
                clock.pause()
            } else {
                playing?.player.play()
                clock.resume()
            }
        }
        .onDisappear {
            playing?.player.pause()
            StoryFiles.shared.clean()
        }
    }

    /// Where the story goes: 9:16 and as wide as the screen, under the status bar, with room below
    /// for the reply field. A screen too short for that gives it all of itself.
    private static func card(for geometry: GeometryProxy) -> CGRect {
        let insets = geometry.safeAreaInsets
        let screen = CGSize(
            width: geometry.size.width + insets.leading + insets.trailing,
            height: geometry.size.height + insets.top + insets.bottom
        )
        let height = (screen.width * 16 / 9).rounded()
        if insets.top + height + 50 + insets.bottom <= screen.height {
            return CGRect(x: 0, y: insets.top, width: screen.width, height: height)
        }
        return CGRect(origin: .zero, size: screen)
    }

    /// The card: the photo or video, the bars and the header on top, and the touch area.
    private func story(width: CGFloat, headerInset: CGFloat) -> some View {
        ZStack {
            Color.black
            if let item {
                StoryMedia(item: item, player: playing?.itemID == item.id ? playing?.player : nil)
                    .equatable()
                    .id(item.id)
                if isLoadingMedia {
                    ProgressView().tint(.white).controlSize(.large)
                }
            } else if error == nil {
                ProgressView().tint(.white)
            }
            // Keeps the header readable on bright stories.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: headerInset + 110)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            // Touches anywhere below the header: tap, hold, or swipe down.
            Color.clear
                .contentShape(Rectangle())
                .gesture(touches(width: width))
            // Above the touches, so its button takes a tap; a tap anywhere else still moves on.
            if item == nil, let error {
                failure(error)
            }
            VStack(spacing: 10) {
                StoryBars(count: items.count, current: itemIndex, clock: clock, isRunning: !isPaused && !isLoadingMedia && item != nil)
                header
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, headerInset + 8)
        }
    }

    /// What went wrong loading this account's stories, and a way to try again. Back online, it
    /// tries again by itself.
    private func failure(_ error: ShownError) -> some View {
        VStack(spacing: 16) {
            Text(error.isConnection ? "Couldn't load these stories." : error.message)
                .font(Theme.font(15))
                .multilineTextAlignment(.center)
            Button {
                Task { await loadReel() }
            } label: {
                Text("Try Again")
                    .font(Theme.font(15, .medium))
                    .padding(.horizontal, 20)
                    .frame(height: 36)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.75), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            TextField("", text: $reply, prompt: Text("Send message").foregroundStyle(.white.opacity(0.8)))
                .font(Theme.font(15))
                .foregroundStyle(.white)
                .tint(.white)
                .focused($isReplying)
                .submitLabel(.send)
                .onSubmit(sendReply)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(.black.opacity(isReplying ? 0.35 : 0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.75), lineWidth: 1))
            if isReplying {
                Button("Send", action: sendReply)
                    .font(Theme.font(16, .medium))
                    .foregroundStyle(.white)
                    .opacity(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    .buttonStyle(.plain)
            } else if let item {
                let liked = stories.isLiked(item)
                Button {
                    stories.toggleLike(item, api: session.api)
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(liked ? Theme.like : .white)
                        .symbolEffect(.bounce, value: liked)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liked ? "Unlike" : "Like")
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 4)
    }

    /// The reply leaves at once: the field clears, the story goes on, and a note at the bottom
    /// follows it until Instagram has it.
    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let item, let reel else { return }
        reply = ""
        isReplying = false
        stories.reply(text, to: item, in: reel, api: session.api)
    }

    /// Whose stories these are: from the tray until they've loaded, so the header is never blank.
    private var owner: User? {
        reel?.user ?? stories.tray.first { $0.id == presentation.reelIDs[reelIndex] }?.user
    }

    private var header: some View {
        HStack(spacing: 8) {
            Avatar(url: owner?.avatarURL, size: 32)
            Text(owner?.username ?? "").font(Theme.font(14, .medium))
            if let date = item?.date {
                Text(shortAge(of: date)).font(Theme.font(14)).opacity(0.7)
            }
            Spacer()
            if isMine, item != nil {
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .light))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete from your story")
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .light))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 4)
        .confirmationDialog("Delete this from your story?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteCurrent)
        }
    }

    /// Off screen at once; Instagram deletes it in the background.
    private func deleteCurrent() {
        guard let reel, let item else { return }
        stories.delete(item, ownerID: reel.id, api: session.api)
        var remaining = reel
        remaining.items?.elements.removeAll { $0.id == item.id }
        let count = remaining.items?.elements.count ?? 0
        if count == 0 {
            dismiss()
        } else {
            self.reel = remaining
            itemIndex = min(itemIndex, count - 1)
            restarts += 1
        }
    }

    private func touches(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if touchStart == nil {
                    touchStart = .now
                    isHolding = true
                }
                let down = value.translation.height
                if !isDragging, down > 10, down > abs(value.translation.width) {
                    isDragging = true
                }
                // From where the swipe started, so the story doesn't jump under the finger.
                if isDragging { dragOffset = max(0, down - 10) }
            }
            .onEnded { value in
                let quick = Date.now.timeIntervalSince(touchStart ?? .now) < 0.25
                let moved = abs(value.translation.width) > 12 || abs(value.translation.height) > 12
                let wasDragging = isDragging
                touchStart = nil
                isHolding = false
                isDragging = false
                if isReplying {
                    // A touch on the story while typing just puts the keyboard away.
                    isReplying = false
                    withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
                    return
                }
                if wasDragging, value.translation.height > 120 || value.predictedEndTranslation.height > 400 {
                    slideAway()
                    return
                }
                withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                // Nothing to move through until the story is on screen.
                if quick && !moved && reel != nil {
                    if value.location.x < width / 3 { previous() } else { next() }
                }
            }
    }

    /// Off the bottom of the screen, then gone, without the cover's own animation on top.
    private func slideAway() {
        isClosing = true
        playing?.player.pause()
        withAnimation(.easeOut(duration: 0.22)) { dragOffset = 1000 }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { stories.presented = nil }
        }
    }

    private func loadReel() async {
        error = nil
        let id = presentation.reelIDs[reelIndex]
        if let loaded = stories.loadedReel(id) {
            show(loaded)
            // Saved on the phone: Instagram's copy takes its place as soon as it comes.
            guard stories.isFromPhone(id) else { return }
            do {
                let fresh = try await stories.refreshFromPhone(id, api: session.api)
                guard !Task.isCancelled else { return }
                replace(with: fresh)
            } catch {
                // Not now: the saved copy stays.
            }
            return
        }
        reel = nil
        do {
            let loaded = try await stories.reel(at: reelIndex, of: presentation.reelIDs, api: session.api)
            // Moved on to another account meanwhile: this one is kept for later, not shown.
            guard !Task.isCancelled else { return }
            guard let loaded else { return nextReel() }
            show(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = ShownError(error)
        }
    }

    /// Starts at the first item you haven't seen.
    private func show(_ loaded: Reel) {
        let elements = loaded.items?.elements ?? []
        guard !elements.isEmpty else { return nextReel() }
        let seen = stories.seen(loaded)
        itemIndex = elements.firstIndex { ($0.takenAt ?? 0) > seen } ?? 0
        reel = loaded
    }

    /// Instagram's copy in place of the saved one on screen: the item on screen stays if it's
    /// still up, and what the owner took down since goes. Nothing left up: on to the next account.
    private func replace(with fresh: Reel?) {
        guard let fresh, let items = fresh.items?.elements, !items.isEmpty else { return nextReel() }
        let shown = item?.id
        reel = fresh
        if let shown, let index = items.firstIndex(where: { $0.id == shown }) {
            itemIndex = index
        } else {
            itemIndex = min(itemIndex, items.count - 1)
            restarts += 1
        }
    }

    /// Shows the current item once it's ready, for as long as it lasts, then moves on. The bar
    /// doesn't move while a photo is loading or a video is buffering.
    private func play() async {
        guard let reel, let item else { return }
        playing?.player.pause()
        var markedSeen = false
        func markSeen(after seconds: Double) {
            guard !markedSeen, seconds >= 1 else { return }
            markedSeen = true
            stories.markSeen(item, in: reel, api: session.api)
        }
        prepareNext()

        if item.isVideo, let url = item.videoURL,
           let source = StoryFiles.shared.file(for: url) ?? (MediaHosts.allows(url) ? url : nil) {
            // From the phone when it was loaded ahead, which starts at once; streamed otherwise,
            // from Instagram's servers only. A video from anywhere else shows as its cover.
            let player = AVPlayer(url: source)
            playing = PlayingVideo(itemID: item.id, player: player)
            clock.start(duration: item.videoDuration ?? 15, player: player)
            if !isPaused { player.play() }
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                guard player.currentItem?.status != .failed else { break }
                let waiting = !isPaused && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if waiting != isLoadingMedia { isLoadingMedia = waiting }
                if isPaused { continue }
                let time = clock.elapsed
                markSeen(after: time)
                if time >= clock.total - 0.1 { break }
            }
            if isLoadingMedia { isLoadingMedia = false }
        } else {
            playing = nil
            if let url = item.imageURL(width: Self.imageWidth), ImageCache.shared.cached(url) == nil {
                isLoadingMedia = true
                _ = await ImageCache.shared.image(for: url, store: .stories)
                isLoadingMedia = false
                if Task.isCancelled { return }
            }
            clock.start(duration: 5)
            if !isPaused { clock.resume() }
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if isPaused { continue }
                let time = clock.elapsed
                markSeen(after: time)
                if time >= 5 { break }
            }
        }
        next()
    }

    /// What comes next, ready before it's needed: this account's next two items and the next
    /// account's first new one go first in line for the phone, and the next picture is decoded.
    /// The next accounts' stories load now if they haven't yet.
    private func prepareNext() {
        var upcoming = Array(items.dropFirst(itemIndex + 1).prefix(2))
        let nextIndex = reelIndex + 1
        if presentation.reelIDs.indices.contains(nextIndex) {
            if let nextReel = stories.loadedReel(presentation.reelIDs[nextIndex]) {
                if let first = stories.startItem(of: nextReel) { upcoming.append(first) }
            } else {
                stories.loadAhead(from: nextIndex, of: presentation.reelIDs, api: session.api)
            }
        }
        stories.prioritize(upcoming)
        if let url = upcoming.first?.imageURL(width: Self.imageWidth) {
            Task { _ = await ImageCache.shared.image(for: url, store: .stories) }
        }
    }

    private func next() {
        if itemIndex + 1 < items.count {
            itemIndex += 1
        } else {
            nextReel()
        }
    }

    private func nextReel() {
        if reelIndex + 1 < presentation.reelIDs.count {
            reelIndex += 1
        } else {
            dismiss()
        }
    }

    private func previous() {
        if itemIndex > 0 {
            itemIndex -= 1
        } else if reelIndex > presentation.start {
            reelIndex -= 1
        } else {
            restarts += 1
        }
    }
}

/// How far the current item has played: a video's own time, or how long a photo has been on screen
/// without counting pauses. The bars read it every frame; it isn't observed, so the viewer doesn't
/// redraw with it.
@MainActor
final class StoryClock {
    private var player: AVPlayer?
    private var duration: Double = 5
    private var shown: Double = 0
    private var resumedAt: Date?

    /// A new item, paused: a photo, or a video with its player.
    func start(duration: Double, player: AVPlayer? = nil) {
        self.player = player
        self.duration = max(duration, 0.1)
        shown = 0
        resumedAt = nil
    }

    func resume() {
        if resumedAt == nil { resumedAt = .now }
    }

    func pause() {
        if let resumedAt { shown += Date.now.timeIntervalSince(resumedAt) }
        resumedAt = nil
    }

    /// Seconds played so far.
    var elapsed: Double { elapsed(at: .now) }

    /// The video's length once it's known, otherwise the length expected.
    var total: Double {
        if let seconds = player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 { return seconds }
        return duration
    }

    func fraction(at date: Date) -> Double {
        min(max(elapsed(at: date) / total, 0), 1)
    }

    private func elapsed(at date: Date) -> Double {
        if let player {
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : 0
        }
        return shown + (resumedAt.map { date.timeIntervalSince($0) } ?? 0)
    }
}

/// One bar per item, the current one filling as it plays: redrawn every frame on their own, so
/// the story under them doesn't redraw with them.
private struct StoryBars: View {
    let count: Int
    let current: Int
    let clock: StoryClock
    let isRunning: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isRunning)) { context in
            let progress = clock.fraction(at: context.date)
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let fill: CGFloat = index < current ? 1 : index == current ? progress : 0
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).scaleEffect(x: fill, y: 1, anchor: .leading)
                        }
                        .frame(height: 2)
                }
            }
        }
    }
}

/// Where a story reply is: sending, delivered, or not sent.
struct ReplyToast: View {
    let status: StoriesModel.ReplyStatus

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .sending(let owner):
                ProgressView().controlSize(.small).tint(.white)
                Text("Sending to \(owner)")
            case .delivered(let owner):
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                Text("Delivered to \(owner)")
            case .failed(let owner):
                Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .semibold))
                Text("Couldn't send to \(owner)")
            }
        }
        .font(Theme.font(14, .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.7), in: Capsule())
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// Posting to or deleting from your story.
struct StoryPostToast: View {
    let status: StoriesModel.PostStatus

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .posting:
                ProgressView().controlSize(.small).tint(.white)
                Text("Posting to your story")
            case .posted:
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                Text("Added to your story")
            case .failed:
                Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .semibold))
                Text("Couldn't post your story")
            case .deleted:
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                Text("Deleted from your story")
            case .deleteFailed:
                Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .semibold))
                Text("Couldn't delete it")
            }
        }
        .font(Theme.font(14, .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.7), in: Capsule())
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// A story photo or video in the card: filling it when it's 9:16, as nearly all stories are, and
/// fitted on black otherwise. Equatable, so the viewer redrawing (a swipe, the reply field)
/// leaves it alone.
private struct StoryMedia: View, Equatable {
    let item: Media
    let player: AVPlayer?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id && lhs.player === rhs.player
    }

    private var fills: Bool {
        guard let shape = item.shape else { return true }
        return abs(shape - 9 / 16) / (9 / 16) < 0.08
    }

    var body: some View {
        ZStack {
            RemoteImage(
                item.imageURL(width: StoryViewer.imageWidth), placeholder: .black, contentMode: fills ? .fill : .fit,
                store: .stories
            )
            if item.isVideo, let player {
                PlayerLayer(player: player, gravity: fills ? .resizeAspectFill : .resizeAspect)
            }
        }
        .clipped()
    }
}

/// A video without controls. Hidden until its first frame is ready, so the cover under it shows
/// instead of black.
private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var gravity = AVLayerVideoGravity.resizeAspectFill

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = gravity
        view.show(player)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.videoGravity = gravity
        if view.playerLayer.player !== player { view.show(player) }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var readiness: NSKeyValueObservation?

        func show(_ player: AVPlayer) {
            playerLayer.player = player
            isHidden = !playerLayer.isReadyForDisplay
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                let isReady = layer.isReadyForDisplay
                DispatchQueue.main.async { self?.isHidden = !isReady }
            }
        }
    }
}
