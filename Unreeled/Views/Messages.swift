import AVKit
import PhotosUI
import SwiftUI

// MARK: - Inbox

/// Direct: your conversations, newest first.
struct InboxView: View {
    @Environment(Session.self) private var session
    @Environment(InboxModel.self) private var model
    @State private var search = ""
    /// The people Instagram's search found, best first, and what was searched.
    @State private var found: [DirectThread] = []
    @State private var foundFor = ""
    @State private var isSearching = false
    @FocusState private var isTypingSearch: Bool

    private var searchText: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            // The inbox stays underneath while you search, so clearing the search puts you back
            // where you were in it.
            ZStack {
                inbox
                    .opacity(searchText.isEmpty ? 1 : 0)
                    .allowsHitTesting(searchText.isEmpty)
                    .accessibilityHidden(!searchText.isEmpty)
                if !searchText.isEmpty { results }
            }
        }
        .background(Color.white)
        // Also when coming back from a conversation, for its new last message.
        .task { await model.load(api: session.api, force: false) }
        .task(id: searchText) { await searchInstagram(for: searchText) }
        .classicBar(showsBack: true, title: "Direct")
    }

    private var inbox: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.threads) { thread in
                    NavigationLink(value: Route.thread(thread)) {
                        ThreadRow(thread: thread)
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.loadMore(near: thread, api: session.api) }
                }
                if model.isLoading {
                    ProgressView().padding(24)
                } else if let error = model.error {
                    ErrorRow(message: error) { Task { await model.load(api: session.api) } }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.load(api: session.api) }
    }

    /// Your conversations that match first, then the other people Instagram's search found.
    private var results: some View {
        // What Instagram found for an earlier search shows only while you type on from it.
        let people = searchText.lowercased().hasPrefix(foundFor.lowercased()) ? found : []
        let match = model.search(searchText, found: people)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !match.conversations.isEmpty {
                    SearchSectionTitle(title: "Conversations")
                    ForEach(match.conversations) { thread in
                        NavigationLink(value: Route.thread(thread)) { ThreadRow(thread: thread) }
                            .buttonStyle(.plain)
                    }
                }
                if !match.more.isEmpty {
                    SearchSectionTitle(title: "More accounts")
                    ForEach(match.more) { person in
                        NavigationLink(value: Route.thread(person)) { PersonRow(thread: person) }
                            .buttonStyle(.plain)
                    }
                }
                if isSearching {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else if match.conversations.isEmpty && match.more.isEmpty {
                    Text("No one found")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondary)
            TextField("Search", text: $search)
                .focused($isTypingSearch)
                .font(Theme.font(15))
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.isEmpty {
                Button {
                    search = ""
                    isTypingSearch = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }

    /// Instagram's search, half a second after you stop typing, as on the website. Not again for
    /// the same text, when you come back from a conversation you opened from it.
    private func searchInstagram(for text: String) async {
        guard !text.isEmpty else {
            found = []
            foundFor = ""
            isSearching = false
            return
        }
        guard text != foundFor else { return }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        let people = (try? await session.api.searchDirect(text)) ?? []
        guard !Task.isCancelled else { return }
        found = people
        foundFor = text
        isSearching = false
    }
}

private struct SearchSectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(Theme.font(12, .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// Someone Instagram's search found: opens your conversation with them.
private struct PersonRow: View {
    let thread: DirectThread
    @Environment(StoriesModel.self) private var stories

    var body: some View {
        let person = thread.people.first
        HStack(spacing: 12) {
            StoryAvatar(
                url: person?.avatarURL,
                size: 52,
                ring: person.map { stories.ring(forUserID: $0.id, latestStory: $0.latestReelMedia) } ?? .none
            )
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(person?.displayName ?? thread.title)
                    .font(Theme.font(15, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let username = person?.username, !username.isEmpty {
                    Text(username)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

@MainActor
@Observable
final class InboxModel {
    var threads: [DirectThread] = []
    var isLoading = false
    var error: String?
    private var mailboxID: String?
    private var cursor: String?
    private var loadedAt: Date?
    private var isRefreshing = false
    private var isPrefetching = false

    /// Conversations with something new from someone else: the badge on Home's paper plane.
    var unreadCount: Int { threads.filter(\.isUnread).count }

    /// The saved inbox at once, then Instagram's. Without `force`, not again within ten seconds.
    func load(api: InstagramAPI, force: Bool = true) async {
        if threads.isEmpty, let saved = api.cachedInbox() {
            threads = saved.threads
            mailboxID = saved.mailboxID
            cursor = saved.cursor
        }
        if !force, let loadedAt, Date.now.timeIntervalSince(loadedAt) < 10 { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = threads.isEmpty
        defer {
            isRefreshing = false
            isLoading = false
        }
        do {
            let inbox = try await api.inbox()
            if threads.count > inbox.threads.count {
                // More pages are loaded below: keep them under Instagram's newest first page, so
                // the list doesn't shrink under you when you come back from a conversation.
                let fresh = Set(inbox.threads.map(\.id))
                threads = inbox.threads + threads.filter { !fresh.contains($0.id) }
            } else {
                threads = inbox.threads
                cursor = inbox.cursor
            }
            mailboxID = inbox.mailboxID
            loadedAt = .now
            error = nil
            prefetch(api: api)
        } catch {
            if threads.isEmpty { self.error = error.localizedDescription }
        }
    }

    /// Loaded conversations whose name or a username matches `text`, newest first, then those of
    /// the people Instagram's search `found`; the others found are `more`, to open by person.
    func search(_ text: String, found: [DirectThread]) -> (conversations: [DirectThread], more: [DirectThread]) {
        func matches(_ thread: DirectThread) -> Bool {
            ([thread.title] + thread.people.flatMap { [$0.username, $0.fullName ?? ""] })
                .contains { $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var conversations = threads.filter(matches)
        var more: [DirectThread] = []
        for person in found {
            guard let user = person.people.first else { continue }
            let isThem = { (other: User) in
                other.id == user.id || (other.interopMessagingUserFbid != nil && other.interopMessagingUserFbid == user.interopMessagingUserFbid)
            }
            if let existing = threads.first(where: { $0.isGroup != true && $0.people.count == 1 && isThem($0.people[0]) }) {
                if !conversations.contains(where: { $0.id == existing.id }) { conversations.append(existing) }
            } else {
                more.append(person)
            }
        }
        return (conversations, more)
    }

    /// A conversation was opened: the next look at the inbox loads it again.
    func invalidate() {
        loadedAt = nil
    }

    /// The four most recent conversations and the three you open most, loaded ahead a second
    /// apart whenever Instagram has something newer than the saved copy, with the pictures of
    /// the first three. Loading a conversation doesn't mark it read: only opening it does.
    private func prefetch(api: InstagramAPI) {
        guard !isPrefetching else { return }
        let favourites = Set(ChatStats.mostOpened(3))
        var seen = Set<String>()
        let picked = (Array(threads.prefix(4)) + threads.filter { favourites.contains($0.id) })
            .filter { seen.insert($0.id).inserted }
        isPrefetching = true
        Task {
            defer { isPrefetching = false }
            for (index, thread) in picked.enumerated() {
                var ready = await ThreadStore.load(thread.id)
                if (ready?.lastActivity ?? .distantPast) < (thread.lastActivity ?? .distantFuture) {
                    ready = try? await api.thread(id: thread.id)
                    try? await Task.sleep(for: .seconds(1))
                }
                if index < 3, let ready { Self.prefetchPictures(of: ready) }
            }
        }
    }

    /// The pictures in a conversation's latest messages: the newest few decoded so they show at
    /// once, the others onto disk.
    static func prefetchPictures(of thread: DirectThread) {
        var pictures: [URL] = []
        for message in (thread.slideMessages?.nodes ?? []).prefix(8) {
            pictures += message.attachments.filter { $0.kind != .audio }.compactMap(\.previewURL)
            if let preview = message.card?.previewImage?.url.flatMap(URL.init(string:)) { pictures.append(preview) }
        }
        ImageCache.shared.prefetch(thread.people.compactMap(\.avatarURL) + pictures.prefix(4), decode: true)
        ImageCache.shared.prefetch(Array(pictures.dropFirst(4)), decode: false)
    }

    func loadMore(near thread: DirectThread, api: InstagramAPI) {
        guard !isLoading, let cursor, let mailboxID,
              let index = threads.firstIndex(where: { $0.id == thread.id }), index >= threads.count - 3
        else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let page = try await api.moreThreads(mailboxID: mailboxID, cursor: cursor)
                var seen = Set(threads.map(\.id))
                threads += page.items.filter { seen.insert($0.id).inserted }
                self.cursor = page.cursor
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: DirectThread
    @Environment(StoriesModel.self) private var stories

    var body: some View {
        HStack(spacing: 12) {
            let person = thread.people.first
            StoryAvatar(
                url: person?.avatarURL,
                size: 52,
                ring: person.map { stories.ring(forUserID: $0.id, latestStory: $0.latestReelMedia) } ?? .none
            )
            // The same width with or without a ring, so names line up.
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(Theme.font(15, thread.isUnread ? .bold : .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(preview).lineLimit(1)
                    if let date = thread.lastActivity {
                        Text("· \(shortAge(of: date))").layoutPriority(1)
                    }
                }
                .font(Theme.font(14, thread.isUnread ? .medium : .regular))
                .foregroundStyle(thread.isUnread ? Theme.ink : Theme.secondary)
            }
            Spacer(minLength: 8)
            if thread.isUnread {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let last = thread.lastMessage else { return "" }
        return last.preview(mine: last.senderFbid == thread.viewerFbid)
    }
}

// MARK: - Conversation

/// A conversation: messages oldest to newest, and a field to reply.
struct ConversationView: View {
    @Environment(Session.self) private var session
    @Environment(InboxModel.self) private var inbox
    @State private var model: ConversationModel
    @State private var draft = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: MediaItem?
    @State private var viewOnce: DirectMessage?
    @State private var recorder = VoiceRecorder()
    @State private var micDenied = false
    /// Whether you're at the end of the conversation, where new messages scroll into view.
    @State private var atBottom = true

    init(thread: DirectThread) {
        _model = State(initialValue: ConversationModel(thread: thread))
    }

    var body: some View {
        // The field under the list rather than as an inset, so the list knows its height from
        // the start and opens on the newest message.
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if model.cursor != nil {
                            // One page each time you scroll up to here. The message you were reading
                            // stays in place as the page comes in above it, which moves this off
                            // screen until you scroll up through that page.
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .onScrollVisibilityChange(threshold: 0.5) { visible in
                                    if visible { model.loadOlder(api: session.api) }
                                }
                        }
                        let shown = model.shownMessages
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                            MessageRow(
                                message: message,
                                previous: index > 0 ? shown[index - 1] : nil,
                                next: index + 1 < shown.count ? shown[index + 1] : nil,
                                thread: model.thread,
                                status: index == shown.count - 1 ? model.lastMessageStatus : nil,
                                open: { viewing = $0 },
                                handOff: { viewOnce = $0 },
                                heart: { model.toggleHeart(on: message, api: session.api) },
                                retry: { Task { await model.retry(message, api: session.api) } }
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, phase in
                    // A scroll view moving on its own ignores where it's told to be: older messages
                    // wait until it stops.
                    model.isScrolling = phase != .idle
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY > geometry.contentSize.height - 80
                } action: { _, isAtBottom in
                    atBottom = isAtBottom
                }
                .onChange(of: model.olderPagesShown) {
                    // Back to the message you were reading, now under the page that came in above it.
                    if let id = model.keepInView { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: model.shownMessages.last?.id) { _, last in
                    // Yours, or theirs while you're at the end; not while you're reading further up.
                    guard let last, atBottom || model.shownMessages.last?.senderFbid == model.thread.viewerFbid else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            composer
        }
        .background(Color.white)
        .classicBar(showsBack: true) {
            HStack(spacing: 8) {
                Avatar(url: model.thread.people.first?.avatarURL, size: 26)
                Text(model.thread.title).font(Theme.font(16, .medium))
            }
        } trailing: {
            if model.thread.isGroup != true, let person = model.thread.people.first {
                NavigationLink(value: Route.profile(person)) {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Profile")
            }
        }
        .fullScreenCover(item: $viewing) { MediaViewer(item: $0) }
        .onDisappear { recorder.cancel() }
        .sheet(item: $viewOnce) { message in
            ViewOnceNote(name: firstName(of: message), isVideo: message.isVideo, threadID: model.thread.id)
        }
        .task {
            // Back in the inbox, its new messages and read state show.
            inbox.invalidate()
            await model.open(api: session.api)
            // New messages arrive through the website's live connection, which the app doesn't
            // have: look again every 15 seconds while the conversation is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled, UIApplication.shared.applicationState == .active {
                    await model.refresh(api: session.api)
                }
            }
        }
    }

    /// The sender's first name, for the view-once note.
    private func firstName(of message: DirectMessage) -> String {
        let people = model.thread.people
        let person = people.first { $0.interopMessagingUserFbid == message.senderFbid } ?? people.first
        if let first = person?.fullName?.split(separator: " ").first { return String(first) }
        return person?.username ?? "them"
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        Group {
            if recorder.isActive { recordingBar } else { typingBar }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
        .animation(.snappy(duration: 0.2), value: recorder.isActive)
        .alert("The microphone is off", isPresented: $micDenied) {
            Button("Open Settings") {
                if let settings = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(settings) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Turn on the microphone for Unreeled in Settings to send voice messages.")
        }
    }

    private var typingBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Photos and videos from the library, up to ten at a time, each sent as it's ready.
            PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send photos or videos")
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                model.send(items, api: session.api)
            }
            TextField("Write a message…", text: $draft, axis: .vertical)
                .font(Theme.font(15))
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline))
            if canSend {
                Button("Send") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft = ""
                    Task { await model.send(text, api: session.api) }
                }
                .font(Theme.font(15, .medium))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
                .padding(.bottom, 9)
            } else {
                // A voice message: tap to start; the bar that replaces this sends or deletes it.
                Button {
                    Task {
                        switch await recorder.start() {
                        case .started: break
                        case .denied: micDenied = true
                        case .failed: model.error = "Couldn't start recording."
                        }
                    }
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 21, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 34, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record a voice message")
            }
        }
    }

    /// While recording: delete, the time and the sound so far, and send.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button { recorder.cancel() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.like)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete the recording")
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.like)
                .symbolEffect(.pulse, isActive: recorder.isRecording)
                .opacity(recorder.isRecording ? 1 : 0.35)
            Text(Self.clock(recorder.elapsed))
                .font(Theme.font(15))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Waveform(levels: Array(recorder.levels.suffix(48)), progress: 1)
                .frame(height: 26)
            Button {
                if let recording = recorder.finish() {
                    Task { await model.send(recording, api: session.api) }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send the voice message")
        }
        .frame(minHeight: 40)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

@MainActor
@Observable
final class ConversationModel {
    private(set) var thread: DirectThread
    /// Oldest first.
    var messages: [DirectMessage]
    /// Where older messages start; nil when there are none, or before the first load.
    var cursor: String?
    /// Pages of older messages added so far, and the message to keep on screen as one comes in.
    private(set) var olderPagesShown = 0
    private(set) var keepInView: String?
    var error: String?
    private var hasCursor = false
    private var isLoadingOlder = false
    private var lastOlderPage = Date.distantPast
    private var markedRead: String?

    init(thread: DirectThread) {
        // The inbox's copy has the newest read receipts. Its few messages are short copies: their
        // photos and shares are only shapes until Instagram's full copy arrives.
        self.thread = thread
        let inbox = (thread.slideMessages?.nodes ?? []).reversed().map(Self.preview)
        if let saved = ThreadStore.cached(thread.id) {
            // As it was last time, pictures and all, with anything newer from the inbox.
            let kept = Array((saved.slideMessages?.nodes ?? []).reversed())
            let known = Set(kept.map(\.id))
            messages = (kept + inbox.filter { !known.contains($0.id) })
                .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            cursor = saved.slideMessages?.nextCursor
            hasCursor = true
        } else {
            messages = inbox
        }
    }

    private static func preview(_ message: DirectMessage) -> DirectMessage {
        var message = message
        message.isPreview = true
        return message
    }

    func open(api: InstagramAPI) async {
        ChatStats.recordOpen(thread.id)
        await refresh(api: api)
    }

    func refresh(api: InstagramAPI) async {
        do {
            guard let fresh = try await api.thread(id: thread.id) else { return }
            thread = fresh
            let latest = Array((fresh.slideMessages?.nodes ?? []).reversed())
            let shown = Set(messages.filter { !$0.isPending && !$0.isPreview }.map(\.id))
            if !shown.isEmpty, !latest.contains(where: { shown.contains($0.id) }), fresh.slideMessages?.nextCursor != nil {
                // More than a page came in since the saved copy: start again from Instagram's,
                // so nothing in between goes missing.
                messages.removeAll { !$0.isPending }
                cursor = fresh.slideMessages?.nextCursor
            }
            merge(latest)
            if !hasCursor {
                hasCursor = true
                cursor = fresh.slideMessages?.nextCursor
            }
            error = nil
            await markReadIfNeeded(api: api)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The page before the oldest message shown: one at a time, and at least a second apart,
    /// however often the scroll view says you've reached the top.
    func loadOlder(api: InstagramAPI) {
        guard let cursor, !isLoadingOlder, Date.now.timeIntervalSince(lastOlderPage) > 1 else { return }
        isLoadingOlder = true
        Task { await loadOlder(from: cursor, api: api) }
    }

    /// While the list moves (a fling, a bounce), a page that arrives waits for it to stop.
    var isScrolling = false {
        didSet { if !isScrolling { insertWaitingPage() } }
    }

    private var waitingPage: Page<DirectMessage>?

    private func loadOlder(from cursor: String, api: InstagramAPI) async {
        do {
            waitingPage = try await api.olderMessages(threadID: thread.id, cursor: cursor)
            if !isScrolling { insertWaitingPage() }
        } catch {
            self.error = error.localizedDescription
            isLoadingOlder = false
            lastOlderPage = .now
        }
    }

    private func insertWaitingPage() {
        guard let page = waitingPage else { return }
        waitingPage = nil
        let known = Set(messages.map(\.id))
        keepInView = messages.first?.id
        messages = page.items.reversed().filter { !known.contains($0.id) } + messages
        cursor = page.cursor
        olderPagesShown += 1
        isLoadingOlder = false
        lastOlderPage = .now
    }

    /// Where your latest message is, when it's the last one in the conversation.
    enum DeliveryStatus {
        case sending, delivered, seen, failed
    }

    /// The messages on screen: Instagram's "… reacted to your message" lines show as a heart on
    /// the message instead.
    var shownMessages: [DirectMessage] { messages.filter { !$0.isReactionLog } }

    var lastMessageStatus: DeliveryStatus? {
        guard let last = shownMessages.last, last.senderFbid == thread.viewerFbid, last.notice == nil else { return nil }
        if last.failed { return .failed }
        if last.isPending { return last.confirmedID == nil ? .sending : .delivered }
        let sent = last.timestamp ?? .infinity
        let seen = thread.slideReadReceipts?.contains { receipt in
            receipt.participantFbid != thread.viewerFbid && (receipt.watermarkTimestampMs.flatMap(Double.init) ?? 0) >= sent
        }
        return seen == true ? .seen : .delivered
    }

    /// Shows the message at once, sends it in the background, and marks it delivered when
    /// Instagram has it.
    func send(_ text: String, api: InstagramAPI) async {
        await deliver(DirectMessage(pending: text, from: thread.viewerFbid), api: api) {
            try await api.send(text, threadID: self.thread.id)
        }
    }

    /// Photos and videos from the library, in the order picked: each shows as soon as it's
    /// ready, then uploads in the background.
    func send(_ items: [PhotosPickerItem], api: InstagramAPI) {
        Task {
            for item in items {
                do {
                    let media = try await MediaPreparation.prepare(item)
                    await send(media, api: api)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    /// The prepared photos and videos, kept until they're delivered so a failed one can be retried.
    private var preparedMedia: [String: PreparedMedia] = [:]
    private var preparedVoice: [String: VoiceRecorder.Recording] = [:]

    /// A voice message: shows at once, playable from the phone, while it's encoded, uploaded and sent.
    func send(_ recording: VoiceRecorder.Recording, api: InstagramAPI) async {
        let pending = DirectMessage(
            pending: .init(url: recording.url, duration: recording.duration, levels: recording.levels),
            from: thread.viewerFbid
        )
        preparedVoice[pending.id] = recording
        await deliver(pending, api: api) {
            try await api.sendVoice(pcm: recording.url, threadID: self.thread.id)
        }
        if messages.first(where: { $0.id == pending.id })?.failed != true { preparedVoice[pending.id] = nil }
    }

    func send(_ media: PreparedMedia, api: InstagramAPI) async {
        let pending = DirectMessage(pending: .init(image: media.preview, isVideo: media.isVideo), from: thread.viewerFbid)
        preparedMedia[pending.id] = media
        await deliver(pending, api: api) {
            try await api.sendMedia(media.data, mimeType: media.mimeType, threadID: self.thread.id)
        }
        if messages.first(where: { $0.id == pending.id })?.failed != true { preparedMedia[pending.id] = nil }
    }

    private func deliver(_ pending: DirectMessage, api: InstagramAPI, sending: () async throws -> SentMessage) async {
        messages.append(pending)
        do {
            let sent = try await sending()
            if let index = messages.firstIndex(where: { $0.id == pending.id }) {
                messages[index].confirmedID = sent.messageId ?? ""
            }
            await refresh(api: api)
            // Like the website, mark the conversation read up to what you just sent.
            if let longID = thread.threadId, let messageID = sent.messageId, let timestamp = sent.timestampMs {
                markedRead = messageID
                try? await api.markRead(threadID: longID, messageID: messageID, timestampMs: timestamp)
            }
        } catch {
            if let index = messages.firstIndex(where: { $0.id == pending.id }) {
                messages[index].failed = true
            }
            self.error = error.localizedDescription
        }
    }

    /// A message that didn't go: send it again, in place of the failed one.
    func retry(_ message: DirectMessage, api: InstagramAPI) async {
        guard message.failed else { return }
        messages.removeAll { $0.id == message.id }
        if let media = preparedMedia.removeValue(forKey: message.id) {
            await send(media, api: api)
        } else if let recording = preparedVoice.removeValue(forKey: message.id) {
            await send(recording, api: api)
        } else if let text = message.textBody, !text.isEmpty {
            await send(text, api: api)
        }
    }

    /// Something new from someone else: mark it read, as the website does while you look at it.
    private func markReadIfNeeded(api: InstagramAPI) async {
        guard thread.isUnread, let longID = thread.threadId, let last = thread.lastMessage,
              let messageID = last.messageId, let timestamp = last.timestampMs, markedRead != messageID
        else { return }
        markedRead = messageID
        try? await api.markRead(threadID: longID, messageID: messageID, timestampMs: timestamp)
    }

    /// Adds the latest messages to the ones already shown, and drops pending ones Instagram now has.
    private func merge(_ latest: [DirectMessage]) {
        var byID: [String: DirectMessage] = [:]
        // The inbox's short copies go: Instagram's full ones replace them.
        for message in messages where !message.isPending && !message.isPreview { byID[message.id] = message }
        for message in latest { byID[message.id] = message }
        // A sent message's own copy replaces it once Instagram returns it.
        let arrived = Set(latest.map(\.id))
        let stillPending = messages.filter { $0.isPending && !arrived.contains($0.confirmedID ?? "") }
        messages = byID.values.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) } + stillPending
        // Hearts on their way stay as you set them, whatever this copy says.
        if let me = thread.viewerFbid {
            for (id, on) in pendingHearts { setHeart(on, messageID: id, me: me) }
        }
    }

    // MARK: Hearts

    /// Hearts sent and not yet confirmed: message ID to on or off.
    private var pendingHearts: [String: Bool] = [:]

    /// Double-tap: your heart on the message, or off again if you'd reacted already. Shows at
    /// once and goes to Instagram in the background; put back if Instagram refuses.
    func toggleHeart(on message: DirectMessage, api: InstagramAPI) {
        guard let me = thread.viewerFbid, let messageID = message.messageId,
              let current = messages.first(where: { $0.id == message.id })
        else { return }
        let mine = current.reactions.first { $0.senderFbid == me }
        let adding = mine == nil
        // Taking a reaction off sends the same emoji back, as the website does.
        let emoji = mine?.reaction ?? "\u{2764}"
        setHeart(adding, messageID: message.id, me: me)
        pendingHearts[message.id] = adding
        Task {
            do {
                try await api.react(emoji, to: messageID, threadID: thread.id, adding: adding)
            } catch {
                setHeart(!adding, messageID: message.id, me: me)
                self.error = error.localizedDescription
            }
            pendingHearts[message.id] = nil
        }
    }

    private func setHeart(_ on: Bool, messageID: String, me: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].reactions.removeAll { $0.senderFbid == me }
        if on { messages[index].reactions.append(.init(reaction: "\u{2764}", senderFbid: me)) }
    }
}

// MARK: - Messages

private struct MessageRow: View {
    let message: DirectMessage
    let previous: DirectMessage?
    let next: DirectMessage?
    let thread: DirectThread
    let status: ConversationModel.DeliveryStatus?
    let open: (MediaItem) -> Void
    let handOff: (DirectMessage) -> Void
    let heart: () -> Void
    let retry: () -> Void

    private var isMine: Bool { message.senderFbid == thread.viewerFbid }
    private var hasMyHeart: Bool { message.reactions.contains { $0.senderFbid == thread.viewerFbid } }
    private var sender: User? { thread.people.first { $0.interopMessagingUserFbid == message.senderFbid } }

    /// Their avatar goes next to the last message of a run.
    private var endsRun: Bool {
        guard let next, next.notice == nil else { return true }
        return next.senderFbid != message.senderFbid || (next.timestamp ?? 0) - (message.timestamp ?? 0) > 300_000
    }

    /// A time between messages more than half an hour apart.
    private var startsSection: Bool {
        guard let previous else { return true }
        return (message.timestamp ?? 0) - (previous.timestamp ?? 0) > 1_800_000
    }

    var body: some View {
        VStack(spacing: 3) {
            if startsSection, let date = message.date {
                Text(date.formatted(date: .abbreviated, time: .shortened).uppercased())
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.vertical, 10)
            }
            if let notice = message.notice {
                Text(notice)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                if thread.isGroup == true, !isMine, previous?.senderFbid != message.senderFbid {
                    Text(sender?.username ?? message.sender?.name ?? "")
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if isMine {
                        Spacer(minLength: 56)
                    } else {
                        Avatar(url: sender?.avatarURL ?? message.sender?.userDict?.avatarURL, size: 26)
                            .opacity(endsRun ? 1 : 0)
                    }
                    VStack(alignment: isMine ? .trailing : .leading, spacing: -5) {
                        MessageContent(message: message, isMine: isMine, thread: thread, open: open, handOff: handOff, heart: heart)
                        if !message.reactions.isEmpty {
                            ReactionPill(reactions: message.reactions)
                                .padding(.horizontal, 8)
                                .transition(.scale(scale: 0.3, anchor: isMine ? .topTrailing : .topLeading).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: message.reactions)
                    .sensoryFeedback(.impact(weight: .light), trigger: hasMyHeart) { _, on in on }
                    if !isMine { Spacer(minLength: 56) }
                }
                if let status { statusLine(status) }
            }
        }
    }
}

private extension MessageRow {
    /// Under your latest message: sending, then delivered, then seen. Quiet grey, except when it
    /// didn't go.
    @ViewBuilder
    func statusLine(_ status: ConversationModel.DeliveryStatus) -> some View {
        Group {
            switch status {
            case .sending:
                Text("Sending…")
            case .delivered:
                Label("Delivered", systemImage: "checkmark").labelStyle(StatusLabelStyle())
            case .seen:
                Text("Seen")
            case .failed:
                Button(action: retry) {
                    Text("Not sent · Tap to retry").foregroundStyle(Theme.like)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.font(11, .medium))
        .foregroundStyle(Theme.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
        .transition(.opacity)
        .animation(.snappy(duration: 0.2), value: status)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

/// A message's text, photos, videos, voice message or share. A double-tap anywhere puts your
/// heart on it, or takes it off.
private struct MessageContent: View {
    let message: DirectMessage
    let isMine: Bool
    let thread: DirectThread
    let open: (MediaItem) -> Void
    let handOff: (DirectMessage) -> Void
    let heart: () -> Void

    var body: some View {
        if let local = message.localMedia {
            LocalMediaView(media: local)
        } else if let local = message.localAudio {
            AudioBubble(url: local.url, durationMs: local.duration * 1000, levels: local.levels, isMine: isMine)
        } else if let audio = message.attachments.first(where: { $0.kind == .audio }) {
            AudioBubble(url: audio.url, durationMs: audio.playableDurationMs, levels: audio.waveform, isMine: isMine)
                .onTapGesture(count: 2, perform: heart)
        } else if !message.attachments.isEmpty {
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    if attachment.kind == .animated {
                        AnimatedMediaView(attachment: attachment)
                            .onTapGesture(count: 2, perform: heart)
                    } else {
                        AttachmentView(attachment: attachment, isVideo: attachment.isVideo, open: open, heart: heart)
                    }
                }
            }
        } else if message.isViewOnce {
            ViewOnceBubble(message: message, isMine: isMine, open: { handOff(message) }, heart: heart)
        } else if message.isStoryReply, let card = message.card {
            StoryReplyView(message: message, card: card, isMine: isMine, open: open, heart: heart)
        } else if let card = message.card {
            ShareCard(card: card, text: message.cardText, open: open, heart: heart)
        } else if let text = message.textBody, !text.isEmpty {
            Text(text)
                .font(Theme.font(15))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .bubble(isMine: isMine)
                .contentShape(RoundedRectangle(cornerRadius: 18))
                .onTapGesture(count: 2, perform: heart)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                }
        } else if message.isPreview {
            PreviewPlaceholder(message: message)
        } else {
            // Something the app can't show yet: the website can.
            NavigationLink(value: Route.web(path: "/direct/t/\(thread.id)/", title: thread.title)) {
                HStack(spacing: 6) {
                    Text(message.summary)
                    Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                }
                .font(Theme.font(14).italic())
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .bubble(isMine: false)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A photo, video, voice message or share from the inbox's short list, in its usual shape, until
/// the conversation's full copy replaces it.
private struct PreviewPlaceholder: View {
    let message: DirectMessage

    var body: some View {
        let type = message.contentType ?? ""
        Group {
            if message.isAudio {
                Capsule().fill(Theme.field).frame(width: 220, height: 44)
            } else if type.contains("SHARE") || type.contains("XMA") {
                RoundedRectangle(cornerRadius: 14).fill(Theme.field).frame(width: 220, height: 290)
            } else {
                RoundedRectangle(cornerRadius: 18).fill(Theme.field).frame(width: 200, height: 260)
            }
        }
        .accessibilityLabel(message.summary)
    }
}

/// Hearts and other reactions under a message: each emoji once, and how many when more than one.
private struct ReactionPill: View {
    let reactions: [DirectMessage.Reaction]

    var body: some View {
        var seen = Set<String>()
        let emojis = reactions.map(\.emoji).filter { !$0.isEmpty && seen.insert($0).inserted }
        HStack(spacing: 2) {
            Text(emojis.joined()).font(.system(size: 12))
            if reactions.count > 1 {
                Text("\(reactions.count)").font(Theme.font(11, .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .accessibilityLabel(emojis.joined(separator: " "))
    }
}

/// A reply or reaction to a story: what it answers, the story as it was, then the words (or the
/// emoji on the story, for a reaction).
private struct StoryReplyView: View {
    let message: DirectMessage
    let card: DirectMessage.Card
    let isMine: Bool
    let open: (MediaItem) -> Void
    let heart: () -> Void

    private var label: String {
        switch (isMine, message.isStoryReaction) {
        case (true, true): "You reacted to their story"
        case (true, false): "You replied to their story"
        case (false, true): "Reacted to your story"
        case (false, false): "Replied to your story"
        }
    }

    private var preview: URL? { card.previewImage?.url.flatMap(URL.init(string:)) }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            Text(label)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
            story
                .onTapGesture(count: 2, perform: heart)
                .onTapGesture {
                    if let preview { open(MediaItem(url: preview, isVideo: false)) }
                }
                .accessibilityAddTraits(.isButton)
            if message.isStoryReaction {
                // On the story when it's there; on its own once it has expired.
                if preview == nil, let emoji = message.textBody {
                    Text(emoji).font(.system(size: 34)).onTapGesture(count: 2, perform: heart)
                }
            } else if let text = message.textBody, !text.isEmpty {
                Text(text)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .bubble(isMine: isMine)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture(count: 2, perform: heart)
            }
        }
    }

    /// The story, small and tall, or a note once it has expired.
    @ViewBuilder
    private var story: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        if let preview {
            RemoteImage(preview)
                .frame(width: 112, height: 190)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
                .overlay(alignment: isMine ? .bottomLeading : .bottomTrailing) {
                    if message.isStoryReaction, let emoji = message.textBody {
                        Text(emoji).font(.system(size: 34)).offset(x: isMine ? -10 : 10, y: 10)
                    }
                }
        } else {
            Text("Story unavailable")
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondary)
                .frame(width: 112, height: 72)
                .background(Theme.field, in: shape)
        }
    }
}

private extension View {
    /// Yours in light grey, theirs white with a hairline, like the old app.
    func bubble(isMine: Bool) -> some View {
        background(isMine ? Theme.field : Color.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if !isMine { RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline) }
            }
    }
}

/// A photo or video, opened full screen with a tap.
private struct AttachmentView: View {
    let attachment: DirectMessage.Attachment
    let isVideo: Bool
    let open: (MediaItem) -> Void
    let heart: () -> Void

    var body: some View {
        let ratio = min(max(attachment.aspectRatio ?? 0.75, 0.56), 1.8)
        let width: CGFloat = ratio < 1 ? 200 : 240
        RemoteImage(attachment.previewURL)
            .frame(width: width, height: width / ratio)
            .overlay {
                if isVideo { PlayBadge() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture(count: 2, perform: heart)
            .onTapGesture {
                if let url = attachment.url { open(MediaItem(url: url, isVideo: isVideo)) }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isVideo ? "Video" : "Photo")
    }
}

private struct PlayBadge: View {
    var body: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.white, .black.opacity(0.35))
    }
}

/// A shared post, reel, story, profile or link. Posts and reels open on their own, in the app,
/// with nothing to scroll on to.
private struct ShareCard: View {
    let card: DirectMessage.Card
    let text: String?
    let open: (MediaItem) -> Void
    let heart: () -> Void
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL

    private enum Destination {
        case post(code: String)
        case story(URL)
        case instagram(path: String)
        case web(URL)
        case nothing
    }

    private var preview: URL? { card.previewImage?.url.flatMap(URL.init(string:)) }

    private var destination: Destination {
        guard let url = card.targetUrl.flatMap(URL.init(string:)) else { return .nothing }
        guard url.host()?.hasSuffix("instagram.com") == true else { return .web(url) }
        let parts = url.pathComponents.filter { $0 != "/" }
        if let index = parts.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }), index + 1 < parts.count {
            return .post(code: parts[index + 1])
        }
        if parts.first == "stories" { return preview.map(Destination.story) ?? .instagram(path: url.path()) }
        return .instagram(path: url.path())
    }

    private var isReel: Bool {
        card.targetUrl?.contains("/reel") == true
    }

    var body: some View {
        label
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture(count: 2, perform: heart)
            .onTapGesture(perform: activate)
            .accessibilityAddTraits(.isButton)
    }

    private func activate() {
        switch destination {
        case .post(let code): navigate(.postCode(code))
        case .story(let image): open(MediaItem(url: image, isVideo: false))
        case .instagram(let path): navigate(.web(path: path, title: card.headerTitleText ?? "Instagram"))
        case .web(let url): openURL(url)
        case .nothing: break
        }
    }

    private var label: some View {
        let width: CGFloat = 220
        let ratio = card.previewImage.flatMap { image -> Double? in
            guard let width = image.width, let height = image.height, width > 0, height > 0 else { return nil }
            return width / height
        }
        return VStack(alignment: .leading, spacing: 0) {
            if card.headerTitleText?.isEmpty == false || card.headerIcon?.url != nil {
                HStack(spacing: 8) {
                    if let icon = card.headerIcon?.url.flatMap(URL.init(string:)) {
                        Avatar(url: icon, size: 24)
                    }
                    Text(card.headerTitleText ?? "")
                        .font(Theme.font(14, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                .padding(10)
            }
            if let preview {
                RemoteImage(preview)
                    .frame(width: width, height: min(width / min(max(ratio ?? 1, 0.56), 1.9), 320))
                    .overlay {
                        if isReel { PlayBadge() }
                    }
            }
            if card.isExpired, preview == nil {
                Text("No longer available")
                    .font(Theme.font(13).italic())
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
            if let subtitle = card.headerSubtitleText, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            if let text, !text.isEmpty {
                Text(text)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .padding(10)
            }
        }
        .frame(width: width, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }
}

/// A view-once photo or video, which only Instagram's own app opens. Theirs opens a note on the
/// way there.
private struct ViewOnceBubble: View {
    let message: DirectMessage
    let isMine: Bool
    let open: () -> Void
    let heart: () -> Void

    private var thing: String { message.isVideo ? "video" : "photo" }

    var body: some View {
        if isMine {
            label(subtitle: "Only in Instagram's app")
                .onTapGesture(count: 2, perform: heart)
        } else {
            label(subtitle: "Opens in Instagram")
                .contentShape(RoundedRectangle(cornerRadius: 18))
                .onTapGesture(count: 2, perform: heart)
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Explains how to see it in Instagram's app")
        }
    }

    private func label(subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "1.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("View-once \(thing)")
                    .font(Theme.font(15, .medium))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 3) {
                    Text(subtitle)
                    if !isMine { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                }
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .bubble(isMine: isMine)
    }
}

/// Before going to Instagram for a view-once photo: why, how to get back without scrolling, and
/// how to avoid it next time.
private struct ViewOnceNote: View {
    let name: String
    let isVideo: Bool
    let threadID: String
    @Environment(\.dismiss) private var dismiss
    @State private var missing = false
    /// The note's own height, so the sheet fits it exactly.
    @State private var height: CGFloat = 460

    private var thing: String { isVideo ? "video" : "photo" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "1.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Open it in Instagram")
                    .font(Theme.font(19, .medium))
                    .foregroundStyle(Theme.ink)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("\(name) sent a view-once \(thing). Those only open in Instagram's own app.")
                Text("Look at it, then come straight back: tap ‹ Unreeled at the top left. Don't get tempted to scroll.")
                Text("Next time, ask \(name) to send \(thing)s normally in the chat. Then you'll see them right here in Unreeled.")
            }
            .font(Theme.font(15))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            if missing {
                Text("Instagram's app isn't on this phone.")
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.like)
            }
            VStack(spacing: 2) {
                Button {
                    Task {
                        if await InstagramHandOff.open(threadID: threadID) { dismiss() } else { missing = true }
                    }
                } label: {
                    Text("Open Instagram")
                        .font(Theme.font(15, .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                Button("Not now") { dismiss() }
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.white)
    }
}

/// A photo or video you're sending, from the phone, until Instagram's copy replaces it.
private struct LocalMediaView: View {
    let media: DirectMessage.LocalMedia

    var body: some View {
        let ratio = min(max(media.image.size.width / max(media.image.size.height, 1), 0.56), 1.8)
        let width: CGFloat = ratio < 1 ? 200 : 240
        Image(uiImage: media.image)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: width / ratio)
            .overlay {
                if media.isVideo { PlayBadge() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// A voice message: play and pause in place, with its waveform filling in as it plays and the
/// time left.
private struct AudioBubble: View {
    let url: URL?
    let durationMs: Double?
    let levels: [Double]?
    let isMine: Bool
    @State private var player: AVPlayer?
    @State private var observer: Any?
    @State private var isPlaying = false
    @State private var position: Double = 0

    private var duration: Double { max((durationMs ?? 0) / 1000, 0) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause voice message" : "Play voice message")
            Waveform(levels: levels, progress: duration > 0 ? position / duration : 0)
                .frame(width: 128, height: 26)
            Text(timeLabel)
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .bubble(isMine: isMine)
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            position = 0
            player?.seek(to: .zero)
        }
        .onDisappear(perform: stop)
    }

    /// The time left while playing, the length otherwise.
    private var timeLabel: String {
        let seconds = Int((isPlaying || position > 0 ? max(duration - position, 0) : duration).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func toggle() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        guard let url else { return }
        let player = self.player ?? AVPlayer(url: url)
        if self.player == nil {
            self.player = player
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
                MainActor.assumeIsolated { position = time.seconds }
            }
        }
        player.play()
        isPlaying = true
    }

    private func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        isPlaying = false
    }
}

/// Bars for a voice message's sound, darker up to where it has played. Flat bars when Instagram
/// didn't send its shape.
private struct Waveform: View {
    let levels: [Double]?
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let count = 32
            let bars = Self.resample(levels, to: count)
            let step = size.width / CGFloat(count)
            for (index, level) in bars.enumerated() {
                let height = max(3, size.height * level)
                let rect = CGRect(x: CGFloat(index) * step + 1, y: (size.height - height) / 2, width: max(step - 2, 1), height: height)
                let played = Double(index) / Double(count) < progress
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(played ? Theme.ink : Theme.secondary.opacity(0.45)))
            }
        }
        .accessibilityHidden(true)
    }

    private static func resample(_ levels: [Double]?, to count: Int) -> [Double] {
        guard let levels, !levels.isEmpty, let top = levels.max(), top > 0 else { return Array(repeating: 0.3, count: count) }
        return (0..<count).map { index in
            let start = index * levels.count / count
            let end = max(start + 1, (index + 1) * levels.count / count)
            let slice = levels[start..<min(end, levels.count)]
            return max(0.12, (slice.max() ?? 0) / top)
        }
    }
}

/// A GIF or sticker: loops silently, as in the app.
private struct AnimatedMediaView: View {
    let attachment: DirectMessage.Attachment

    var body: some View {
        let ratio = min(max(attachment.aspectRatio ?? 1, 0.56), 1.8)
        let width: CGFloat = attachment.isSticker == true ? 140 : 200
        Group {
            if let video = attachment.attachmentMp4Url.flatMap(URL.init(string:)) {
                LoopingVideo(url: video)
            } else {
                RemoteImage(attachment.previewURL)
            }
        }
        .frame(width: width, height: width / ratio)
        .clipShape(RoundedRectangle(cornerRadius: attachment.isSticker == true ? 0 : 18))
        .accessibilityLabel(attachment.isSticker == true ? "Sticker" : "GIF")
    }
}

/// A short silent video playing on a loop, for GIFs.
struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingPlayerView {
        LoopingPlayerView(url: url)
    }

    func updateUIView(_ view: LoopingPlayerView, context: Context) {}

    static func dismantleUIView(_ view: LoopingPlayerView, coordinator: ()) {
        view.stop()
    }

    final class LoopingPlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            super.init(frame: .zero)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            (layer as? AVPlayerLayer)?.player = player
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
            player.play()
        }

        required init?(coder: NSCoder) { nil }

        func stop() {
            player.pause()
            looper = nil
        }
    }
}

// MARK: - Full screen

struct MediaItem: Identifiable {
    let url: URL
    let isVideo: Bool
    var id: URL { url }
}

/// A photo or video on black. Pinch to zoom, swipe down or tap the cross to close.
private struct MediaViewer: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var zoom: CGFloat = 1
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Group {
                if item.isVideo {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { zoom = max(1, $0.magnification) }
                                .onEnded { _ in withAnimation(.snappy) { zoom = 1 } }
                        )
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: drag)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .accessibilityLabel("Close")
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { drag = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height > 120 {
                        dismiss()
                    } else {
                        withAnimation(.snappy) { drag = 0 }
                    }
                }
        )
        .task {
            if item.isVideo {
                let player = AVPlayer(url: item.url)
                self.player = player
                player.play()
            } else {
                image = await ImageCache.shared.image(for: item.url)
            }
        }
        .onDisappear { player?.pause() }
        .statusBarHidden()
    }
}
