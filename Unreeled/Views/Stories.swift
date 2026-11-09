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

    /// The first three reels with something new, loaded ahead with the picture each starts on,
    /// so they open at once.
    private func prefetch(api: InstagramAPI) {
        let ids = tray.filter { ring(for: $0) == .unseen && loaded[$0.id] == nil }.prefix(3).map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            guard let reels = try? await api.stories(userIDs: ids) else { return }
            var first = true
            for reel in reels {
                if loaded[reel.id] == nil { loaded[reel.id] = reel }
                let items = reel.items?.elements ?? []
                let start = items.first { ($0.takenAt ?? 0) > seen(reel) } ?? items.first
                if let url = start?.imageURL(width: StoryViewer.imageWidth) {
                    ImageCache.shared.prefetch([url], decode: first)
                    first = false
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
        max(reel.seen ?? 0, seenUpTo[reel.id] ?? 0, loaded[reel.id]?.seen ?? 0)
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

    /// A reel already loaded, if it is.
    func loadedReel(_ id: String) -> Reel? { loaded[id] }

    /// A reel with its items, loading it along with the next couple, as the website does. Nil when
    /// the account has nothing up any more (expired, or just deleted).
    func reel(at index: Int, of ids: [String], api: InstagramAPI) async throws -> Reel? {
        let id = ids[index]
        if let reel = loaded[id] { return reel }
        let batch = ids[index...].prefix(3).filter { loaded[$0] == nil }
        for reel in try await api.stories(userIDs: Array(batch)) {
            loaded[reel.id] = reel
        }
        if loaded[id] == nil { tray.removeAll { $0.id == id } }
        return loaded[id]
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
struct StoryViewer: View {
    let presentation: StoriesModel.Presentation

    @Environment(StoriesModel.self) private var stories
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var reelIndex: Int
    @State private var reel: Reel?
    @State private var itemIndex = 0
    @State private var restarts = 0
    @State private var progress = 0.0
    @State private var isHolding = false
    @State private var touchStart: Date?
    @State private var dragOffset: CGFloat = 0
    @State private var player: AVPlayer?
    @State private var error: String?
    /// The current photo or video isn't on screen yet: the bar waits, and a spinner shows.
    @State private var isLoadingMedia = false
    @State private var reply = ""
    @FocusState private var isReplying: Bool
    @State private var confirmingDelete = false

    /// Holding a finger down, typing a reply, or deciding whether to delete.
    private var isPaused: Bool { isHolding || isReplying || confirmingDelete }

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
            ZStack {
                Color.black
                if let item {
                    StoryMedia(item: item, player: player)
                    if isLoadingMedia {
                        ProgressView().tint(.white).controlSize(.large)
                    }
                } else if let error {
                    Text(error)
                        .font(Theme.font(14))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(32)
                } else {
                    ProgressView().tint(.white)
                }
                // Keeps the header readable on bright stories.
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: geometry.safeAreaInsets.top + 110)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                // Touches anywhere below the header: tap, hold, or swipe down.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(touches(width: geometry.size.width))
                VStack(spacing: 10) {
                    bars
                    header
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, geometry.safeAreaInsets.top + 6)
            }
            .ignoresSafeArea()
            .clipShape(RoundedRectangle(cornerRadius: dragOffset > 0 ? 28 : 0))
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
        .onChange(of: isPaused) {
            if isPaused { player?.pause() } else { player?.play() }
        }
        .onDisappear { player?.pause() }
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

    private var bars: some View {
        HStack(spacing: 3) {
            ForEach(items.indices, id: \.self) { index in
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.35))
                        Capsule().fill(.white).frame(width: bar.size.width * fill(index))
                    }
                }
                .frame(height: 2)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Avatar(url: reel?.user?.avatarURL, size: 32)
            Text(reel?.user?.username ?? "").font(Theme.font(14, .medium))
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

    private func fill(_ index: Int) -> CGFloat {
        index < itemIndex ? 1 : index == itemIndex ? progress : 0
    }

    private func touches(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if touchStart == nil {
                    touchStart = .now
                    isHolding = true
                }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let quick = Date.now.timeIntervalSince(touchStart ?? .now) < 0.25
                let moved = abs(value.translation.width) > 12 || abs(value.translation.height) > 12
                touchStart = nil
                isHolding = false
                if isReplying {
                    // A touch on the story while typing just puts the keyboard away.
                    isReplying = false
                    withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
                    return
                }
                if value.translation.height > 120 || value.predictedEndTranslation.height > 400 {
                    slideAway()
                    return
                }
                withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
                // Nothing to move through until the story is on screen.
                if quick && !moved && reel != nil {
                    if value.location.x < width / 3 { previous() } else { next() }
                }
            }
    }

    /// Off the bottom of the screen, then gone, without the cover's own animation on top.
    private func slideAway() {
        player?.pause()
        withAnimation(.easeOut(duration: 0.2)) { dragOffset = 900 }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { stories.presented = nil }
        }
    }

    private func loadReel() async {
        error = nil
        progress = 0
        if let loaded = stories.loadedReel(presentation.reelIDs[reelIndex]) {
            show(loaded)
            return
        }
        reel = nil
        do {
            guard let loaded = try await stories.reel(at: reelIndex, of: presentation.reelIDs, api: session.api) else {
                return nextReel()
            }
            show(loaded)
        } catch {
            self.error = error.localizedDescription
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

    /// Shows the current item once it's loaded, for as long as it lasts, then moves on. The bar
    /// doesn't move while a photo is loading or a video is buffering.
    private func play() async {
        guard let reel, let item else { return }
        player?.pause()
        progress = 0
        var markedSeen = false
        func markSeen(after seconds: Double) {
            guard !markedSeen, seconds >= 1 else { return }
            markedSeen = true
            stories.markSeen(item, in: reel, api: session.api)
        }

        if item.isVideo, let url = item.videoURL {
            let player = AVPlayer(url: url)
            self.player = player
            if !isPaused { player.play() }
            preloadNext()
            let expected = max(item.videoDuration ?? 15, 1)
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                guard player.currentItem?.status != .failed else { break }
                let loaded = player.currentItem?.duration.seconds ?? .nan
                let total = loaded.isFinite && loaded > 0 ? loaded : expected
                let time = player.currentTime().seconds
                isLoadingMedia = !isPaused && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if isPaused { continue }
                progress = min(max(time / total, 0), 1)
                markSeen(after: time)
                if time >= total - 0.1 { break }
            }
            isLoadingMedia = false
        } else {
            player = nil
            if let url = item.imageURL(width: Self.imageWidth), ImageCache.shared.cached(url) == nil {
                isLoadingMedia = true
                _ = await ImageCache.shared.image(for: url)
                isLoadingMedia = false
                if Task.isCancelled { return }
            }
            preloadNext()
            var elapsed = 0.0
            while elapsed < 5 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if isPaused { continue }
                elapsed += 0.05
                progress = min(elapsed / 5, 1)
                markSeen(after: elapsed)
            }
        }
        next()
    }

    /// The next picture (this account's next item, or the next account's first new one),
    /// loaded while this one shows.
    private func preloadNext() {
        var upcoming: Media?
        if itemIndex + 1 < items.count {
            upcoming = items[itemIndex + 1]
        } else if reelIndex + 1 < presentation.reelIDs.count, let nextReel = stories.loadedReel(presentation.reelIDs[reelIndex + 1]) {
            let elements = nextReel.items?.elements ?? []
            let seen = stories.seen(nextReel)
            upcoming = elements.first { ($0.takenAt ?? 0) > seen } ?? elements.first
        }
        guard let url = upcoming?.imageURL(width: Self.imageWidth) else { return }
        Task { _ = await ImageCache.shared.image(for: url) }
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

/// A story photo or video, filling the screen.
private struct StoryMedia: View {
    let item: Media
    let player: AVPlayer?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RemoteImage(item.imageURL(width: StoryViewer.imageWidth), placeholder: .black)
                if item.isVideo, let player {
                    PlayerLayer(player: player)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}

/// A video without controls, filling its frame.
private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
