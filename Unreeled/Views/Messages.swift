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
                        ThreadRow(thread: thread, sentLine: model.sentLines[thread.id])
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.loadMore(near: thread, api: session.api) }
                }
                if model.isLoading {
                    ProgressView().padding(24)
                } else if let error = model.error {
                    if model.threads.isEmpty {
                        ErrorRow(error: error) { Task { await model.load(api: session.api) } }
                    } else {
                        RefreshNote(text: "Couldn't load more conversations.", error: error) {
                            Task { await model.load(api: session.api) }
                        }
                    }
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
                        NavigationLink(value: Route.thread(thread)) { ThreadRow(thread: thread, sentLine: model.sentLines[thread.id]) }
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
    var error: ShownError?
    /// Your latest message in a conversation, once Instagram confirmed it, for its row until a
    /// copy of the conversation from Instagram has it: the row is right even when the inbox
    /// couldn't load after you sent.
    private(set) var sentLines: [String: SentLine] = [:]

    struct SentLine: Equatable {
        let preview: String
        /// When Instagram has it, by its own clock.
        let date: Date
    }
    private var mailboxID: String?
    private var cursor: String?
    private var loadedAt: Date?
    /// Instagram's list on its way.
    private var refreshing: Task<Void, Never>?
    /// Conversations marked read from here, by how far (the message's time, in milliseconds),
    /// and when. Instagram's list can come back from before a mark reached it: the row stays
    /// read meanwhile, for two minutes at most, so a look at a conversation isn't undone by
    /// the list that loads as you come back.
    private var readMarks: [String: (upTo: Double, at: Date)] = [:]
    private var isPrefetching = false

    /// Conversations with something new from someone else: the badge on Home's paper plane.
    var unreadCount: Int { threads.filter(\.isUnread).count }

    /// The saved inbox at launch, read off the main thread: the paper plane's count and the
    /// conversations before Instagram answers. Then what's ready on the phone, decoded ahead.
    func showSaved(api: InstagramAPI) async {
        guard threads.isEmpty, let saved = await api.savedInbox(), threads.isEmpty else { return }
        threads = saved.threads
        mailboxID = saved.mailboxID
        cursor = saved.cursor
        // Everyone's picture in the list, the saved copies of the 8 most recent conversations and
        // the 3 you open most, and the newest pictures of the first three: they open complete.
        // All from the phone; nothing goes to Instagram.
        ImageCache.shared.warm(threads.compactMap { $0.people.first?.avatarURL })
        var seen = Set<String>()
        let ids = (threads.prefix(8).map(\.id) + ChatStats.mostOpened(3)).filter { seen.insert($0).inserted }
        for thread in await ThreadStore.warm(ids).prefix(3) {
            ImageCache.shared.warm(
                thread.people.compactMap(\.avatarURL) + Self.latestPictures(of: thread).prefix(4), fitting: MessageRow.largestPicture
            )
        }
    }

    /// The saved inbox at once, then Instagram's. Without `force`, not again within ten seconds.
    /// Asked again while Instagram's is on its way, it waits for that one: whoever asked finds
    /// the list as new as it gets when this returns.
    func load(api: InstagramAPI, force: Bool = true) async {
        if threads.isEmpty, let saved = api.cachedInbox() {
            threads = saved.threads
            mailboxID = saved.mailboxID
            cursor = saved.cursor
        }
        if !force, let loadedAt, Date.now.timeIntervalSince(loadedAt) < 10 { return }
        if let refreshing { return await refreshing.value }
        let task = Task { await refresh(api: api) }
        refreshing = task
        await task.value
        if refreshing == task { refreshing = nil }
    }

    private func refresh(api: InstagramAPI) async {
        isLoading = threads.isEmpty
        defer { isLoading = false }
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
            applyReadMarks()
            forgetSentLines()
            ImageCache.shared.warm(threads.compactMap { $0.people.first?.avatarURL })
            prefetch(api: api)
        } catch {
            if threads.isEmpty { self.error = ShownError(error) }
        }
    }

    /// A conversation on screen, as Instagram just sent it: its row shows the same messages, read.
    func update(from conversation: DirectThread) {
        guard let index = threads.firstIndex(where: { $0.id == conversation.id }) else { return }
        let old = threads[index]
        // Only a copy at least as new as the row's.
        guard (conversation.lastMessage?.timestamp ?? 0) >= (old.lastMessage?.timestamp ?? 0) else { return }
        place(old.updated(with: conversation).readByViewer(), at: index)
        forgetSentLines()
    }

    /// A conversation being marked read up to a message's time: its row shows read, and stays
    /// so while Instagram's copy is behind.
    func markingRead(_ threadID: String, upTo time: Double) {
        readMarks[threadID] = (time, .now)
        applyReadMarks()
    }

    /// Instagram didn't take the mark: what it says shows again at the next load.
    func markNotTaken(_ threadID: String, upTo time: Double) {
        if readMarks[threadID]?.upTo == time { readMarks[threadID] = nil }
    }

    /// Rows whose conversation was marked read here, and Instagram's copy doesn't say so yet.
    private func applyReadMarks() {
        guard !readMarks.isEmpty else { return }
        for (id, mark) in readMarks {
            guard Date.now.timeIntervalSince(mark.at) < 120, let index = threads.firstIndex(where: { $0.id == id }) else {
                readMarks[id] = nil
                continue
            }
            let row = threads[index]
            if row.readUpTo >= mark.upTo, row.markedAsUnread != true {
                // Instagram has it.
                readMarks[id] = nil
            } else if (row.lastMessage?.timestamp ?? 0) <= mark.upTo, row.isUnread {
                threads[index] = row.readByViewer()
            }
        }
    }

    /// You opened the conversation: it shows read at once, as in Instagram's app.
    func showRead(_ threadID: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index] = threads[index].readByViewer()
    }

    /// Instagram confirmed a message you sent: its row says so, and moves up.
    func showDelivered(_ preview: String, at date: Date, in threadID: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        sentLines[threadID] = SentLine(preview: preview, date: date)
        place(threads[index].readByViewer(), at: index)
    }

    /// Moves a row to where its latest activity puts it, newest first.
    private func place(_ thread: DirectThread, at index: Int) {
        threads.remove(at: index)
        let date = activity(of: thread)
        let position = threads.firstIndex { activity(of: $0) < date } ?? threads.endIndex
        threads.insert(thread, at: position)
    }

    private func activity(of thread: DirectThread) -> Date {
        max(thread.lastActivity ?? .distantPast, sentLines[thread.id]?.date ?? .distantPast)
    }

    /// Lines Instagram's copies have caught up with: they show your message, or something newer.
    private func forgetSentLines() {
        sentLines = sentLines.filter { id, line in
            (thread(withID: id)?.lastActivity ?? .distantPast) < line.date
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

    /// The loaded conversation with this ID, in any of the forms Instagram uses (`DirectThread.ids`).
    func thread(withID id: String?) -> DirectThread? {
        guard let id, !id.isEmpty else { return nil }
        return threads.first { $0.ids.contains(id) }
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
        let pictures = latestPictures(of: thread)
        ImageCache.shared.prefetch(thread.people.compactMap(\.avatarURL) + pictures.prefix(4), decode: true, fitting: MessageRow.largestPicture)
        ImageCache.shared.prefetch(Array(pictures.dropFirst(4)), decode: false)
    }

    /// Photos, video covers and shared posts in the latest messages, newest first. None from a
    /// view-once message: those are never loaded ahead.
    private static func latestPictures(of thread: DirectThread) -> [URL] {
        var pictures: [URL] = []
        for message in (thread.slideMessages?.nodes ?? []).prefix(8) where !message.isViewOnce {
            pictures += message.attachments.filter { $0.kind != .audio }.compactMap(\.previewURL)
            if let preview = message.card?.previewImage?.url.flatMap(URL.init(string:)) { pictures.append(preview) }
        }
        return pictures
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
                self.error = ShownError(error)
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: DirectThread
    /// What you just sent, when this copy of the conversation is older than it.
    var sentLine: InboxModel.SentLine?
    @Environment(StoriesModel.self) private var stories

    private var line: InboxModel.SentLine? {
        sentLine.flatMap { (thread.lastActivity ?? .distantPast) < $0.date ? $0 : nil }
    }

    private var isUnread: Bool { line == nil && thread.isUnread }

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
                    .font(Theme.font(15, isUnread ? .bold : .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(preview).lineLimit(1)
                    if let date = line?.date ?? thread.lastActivity {
                        Text("· \(shortAge(of: date))").layoutPriority(1)
                    }
                }
                .font(Theme.font(14, isUnread ? .medium : .regular))
                .foregroundStyle(isUnread ? Theme.ink : Theme.secondary)
            }
            Spacer(minLength: 8)
            if isUnread {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var preview: String {
        if let line { return line.preview }
        guard let last = thread.lastMessage else { return "" }
        return last.preview(mine: last.senderFbid == thread.viewerFbid)
    }
}

// MARK: - Conversation

/// A conversation: messages oldest to newest, and a field to reply.
struct ConversationView: View {
    @Environment(Session.self) private var session
    @Environment(InboxModel.self) private var inbox
    @Environment(PushNotifications.self) private var notifications
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    @State private var model: ConversationModel
    @State private var viewing: MediaItem?
    @State private var viewOnce: DirectMessage?
    @State private var recorder = VoiceRecorder()
    @State private var voice = VoicePlayer()
    /// From appearing until it goes, or until a screen opens over it.
    @State private var isShown = false
    /// The IDs it was opened with, which the tabs know it by (`PushNotifications.visibleThread`).
    private let ids: Set<String>

    init(thread: DirectThread) {
        #if DEBUG
        // -standInConversations YES: the screen as it is, on a made-up conversation (StandIn).
        _model = State(initialValue: StandIn.isOn ? StandIn.conversation() : ConversationModel(thread: thread))
        #else
        _model = State(initialValue: ConversationModel(thread: thread))
        #endif
        ids = thread.ids
    }

    /// The open tab shows it, with nothing on top of it.
    private var isInOpenTab: Bool { !notifications.visibleThread.isDisjoint(with: ids) }

    /// You're looking at it: up in the open tab, with the app in front. A conversation left in a
    /// tab you switched away from stays alive, unseen: it neither looks for new messages then
    /// nor marks them read.
    private var isOnScreen: Bool { isShown && isInOpenTab && scenePhase == .active }

    var body: some View {
        // The list and, under it, the field: one UIKit screen, down to the bottom edge, which
        // makes room for the keyboard itself (MessageList).
        MessageList(
            rows: model.rows,
            hasOlder: model.cursor != nil,
            voice: voice,
            composer: AnyView(Composer(model: model, recorder: recorder).environment(session).tint(Theme.accent)),
            handlers: MessageHandlers(
                // One page each time the list comes near its top. What you were reading stays
                // in place as the page comes in above it.
                reachedTop: { model.loadOlder(api: session.api) },
                open: { viewing = $0 },
                handOff: { viewOnce = $0 },
                heart: { model.toggleHeart(on: $0, api: session.api) },
                retry: { message in Task { await model.retry(message, api: session.api) } },
                navigate: { navigate($0) },
                openURL: { openURL($0) },
                showOnWebsite: { navigate(.web(path: "/direct/t/\(model.thread.id)/", title: model.thread.title)) }
            )
        )
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
        .onAppear { isShown = true }
        .onDisappear {
            isShown = false
            recorder.cancel()
            voice.stop()
        }
        .sheet(item: $viewOnce) { message in
            ViewOnceNote(name: firstName(of: message), isVideo: message.isVideo, threadID: model.thread.id)
        }
        .task {
            // Back in the inbox, its new messages and read state show.
            model.inbox = inbox
            inbox.invalidate()
            inbox.showRead(model.thread.id)
            model.open()
            #if DEBUG
            ScrollScript.runIfRequested()
            #endif
            // New messages arrive through the website's live connection, which the app doesn't
            // have: look again every 15 seconds while the conversation is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: model.looksEvery)
                if !Task.isCancelled, model.isOnScreen {
                    await model.refresh(api: session.api)
                }
            }
        }
        // Each time it comes into view (opened, or back from another tab, from a screen opened
        // over it or from another app): what came meanwhile, read now that you see it.
        .onChange(of: isOnScreen) { _, onScreen in
            model.isOnScreen = onScreen
            if onScreen { Task { await model.refresh(api: session.api) } }
        }
        // Taken to another tab by a notification you tapped: a recording under way stops, as it
        // does when you leave the conversation, and so does a voice message playing.
        .onChange(of: isInOpenTab) { _, inOpenTab in
            if !inOpenTab {
                recorder.cancel()
                voice.stop()
            }
        }
        // With notifications on, one arriving says there's something new right away.
        .onChange(of: notifications.arrivals) {
            if model.isOnScreen { Task { await model.refresh(api: session.api) } }
        }
        // The inbox's row follows what's on screen, even if the inbox can't load meanwhile.
        .onChange(of: model.thread) { inbox.update(from: model.thread) }
        .onChange(of: model.lastDelivered) {
            if let delivered = model.lastDelivered {
                inbox.showDelivered(delivered.preview, at: delivered.date, in: model.thread.id)
            }
        }
        // Back online: what came meanwhile, and the read receipt if it didn't go.
        .onReconnect { if model.isOnScreen { await model.refresh(api: session.api) } }
    }

    /// The sender's first name, for the view-once note.
    private func firstName(of message: DirectMessage) -> String {
        let people = model.thread.people
        let person = people.first { $0.interopMessagingUserFbid == message.senderFbid } ?? people.first
        if let first = person?.fullName?.split(separator: " ").first { return String(first) }
        return person?.username ?? "them"
    }
}

/// The field at the bottom: text, photos and videos, and voice messages. A view of its own, so
/// typing redraws only this, not the conversation above it.
struct Composer: View {
    let model: ConversationModel
    let recorder: VoiceRecorder
    @Environment(Session.self) private var session
    @State private var draft: MessageDraft
    @State private var picked: [PhotosPickerItem] = []
    @State private var micDenied = false

    init(model: ConversationModel, recorder: VoiceRecorder) {
        self.model = model
        self.recorder = recorder
        _draft = State(initialValue: MessageDraft(conversation: model.thread.id))
    }

    var body: some View {
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
            MessageField(draft: draft, placeholder: "Write a message…")
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline))
            if draft.hasText {
                Button("Send") {
                    // What the field shows, taken out of it: nothing is left behind.
                    let text = draft.take()
                    guard !text.isEmpty else { return }
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
                        case .failed: model.error = ShownError(message: "Couldn't start recording.")
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

/// What a conversation asks of Instagram. The app's API answers; in a Debug build a stand-in
/// can instead (StandIn), which plays Instagram's part on the phone and reaches no one.
@MainActor
protocol ConversationSource: AnyObject {
    func thread(id: String) async throws -> DirectThread?
    func olderMessages(threadID: String, cursor: String) async throws -> Page<DirectMessage>
    func send(_ text: String, threadID: String, offlineID: String?) async throws -> SentMessage
    func sendMedia(_ data: Data, mimeType: String, threadID: String, offlineID: String?) async throws -> SentMessage
    func sendVoice(pcm url: URL, threadID: String, offlineID: String?) async throws -> SentMessage
    func react(_ emoji: String, to messageID: String, threadID: String, adding: Bool) async throws
    func markRead(threadID: String, messageID: String, timestampMs: String) async throws -> Bool
}

extension InstagramAPI: ConversationSource {}

@MainActor
@Observable
final class ConversationModel {
    private(set) var thread: DirectThread {
        didSet { if thread != oldValue { updateRows() } }
    }
    /// Oldest first.
    var messages: [DirectMessage] {
        didSet { updateRows() }
    }
    /// The messages on screen, each as its row shows it. Set again only when a row would show
    /// something else: a look at Instagram that changes nothing leaves the list alone.
    private(set) var rows: [Row] = []
    /// Where older messages start; nil when there are none, or before the first load.
    var cursor: String?
    var error: ShownError?
    /// You're looking at the conversation, as its view says: only then is what's new marked read.
    var isOnScreen = false
    /// Your latest message Instagram confirmed, for the inbox's row.
    private(set) var lastDelivered: Delivered?
    private var hasCursor = false
    private var isLoadingOlder = false
    private var lastOlderPage = Date.distantPast
    private var markedRead: String?
    private var markingRead: String?

    struct Delivered: Equatable {
        let preview: String
        let date: Date
    }

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
        updateRows()
    }

    /// How often it looks for new messages while it's on screen.
    var looksEvery: Duration {
        #if DEBUG
        // The stand-in answers from the phone: often, so a test doesn't wait.
        if standIn != nil { return .seconds(3) }
        #endif
        return .seconds(15)
    }

    private static func preview(_ message: DirectMessage) -> DirectMessage {
        var message = message
        message.isPreview = true
        return message
    }

    /// Counted among the conversations you open most. Its messages load as it comes into view
    /// (`refresh`, from the view).
    func open() {
        #if DEBUG
        if standIn != nil { return }
        #endif
        ChatStats.recordOpen(thread.id)
    }

    #if DEBUG
    /// The stand-in conversation's Instagram (-standInConversations YES): everything this
    /// conversation would ask of Instagram or send to it goes there instead, and stays on the phone.
    @ObservationIgnored var standIn: (any ConversationSource)?
    #endif

    /// Instagram, or in a Debug build the stand-in playing it.
    private func source(_ api: InstagramAPI) -> any ConversationSource {
        #if DEBUG
        if let standIn { return standIn }
        #endif
        return api
    }

    func refresh(api: InstagramAPI) async {
        // What's on screen already is read from the moment you look at it, without waiting for
        // Instagram's copy: a look too short for that to arrive, or a slow connection, counts.
        // On its own, so that it goes even if you leave meanwhile.
        Task { await markReadIfNeeded(api: api) }
        do {
            guard let fresh = try await source(api).thread(id: thread.id) else { return }
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
            self.error = ShownError(error)
        }
    }

    /// The page before the oldest message shown: one at a time, and at least a second apart,
    /// however often the list says it's near its top. The list keeps what you were reading in
    /// place as the page comes in above it.
    func loadOlder(api: InstagramAPI) {
        guard let cursor, !isLoadingOlder, Date.now.timeIntervalSince(lastOlderPage) > 1 else { return }
        isLoadingOlder = true
        Task {
            defer {
                isLoadingOlder = false
                lastOlderPage = .now
            }
            do {
                let page = try await source(api).olderMessages(threadID: thread.id, cursor: cursor)
                // Not onto a conversation that started again from Instagram's copy meanwhile.
                guard self.cursor == cursor else { return }
                let known = Set(messages.map(\.id))
                messages = page.items.reversed().filter { !known.contains($0.id) } + messages
                self.cursor = page.cursor
            } catch {
                self.error = ShownError(error)
            }
        }
    }

    /// Where your latest message is, when it's the last one in the conversation.
    enum DeliveryStatus {
        case sending, delivered, seen, failed
    }

    /// The messages on screen: Instagram's "… reacted to your message" lines show as a heart on
    /// the message instead.
    var shownMessages: [DirectMessage] { messages.filter { !$0.isReactionLog } }

    /// A message on screen with all its row shows: the message, and what its place among the
    /// others adds (the time above it, whose it is, their picture, where it is on its way).
    /// Rows are compared whole, so one that would show the same is left as it is.
    ///
    /// A row goes by its message's ID, except for a message you sent from here: Instagram's
    /// copy of it comes with an ID of its own, and takes over the row the message was shown in
    /// while it was on its way. To the list it's the same row throughout, which it neither
    /// makes again nor scrolls to as the message is delivered.
    struct Row: Identifiable, Equatable {
        let id: String
        let message: DirectMessage
        let isMine: Bool
        /// Your heart is on it.
        let hasMyHeart: Bool
        /// The time above it, when it comes more than half an hour after the message before.
        let date: Date?
        /// In a group, who sent it, above the first message of their run.
        let senderName: String?
        /// Their picture, which shows next to the last message of a run.
        let avatar: URL?
        let endsRun: Bool
        /// Where your latest message is, under it when it's the conversation's last.
        let status: DeliveryStatus?
    }

    private func updateRows() {
        let shown = shownMessages
        let viewer = thread.viewerFbid
        let people = thread.people
        let isGroup = thread.isGroup == true
        let status = lastMessageStatus
        let new = shown.indices.map { index -> Row in
            let message = shown[index]
            let previous = index > 0 ? shown[index - 1] : nil
            let next = index + 1 < shown.count ? shown[index + 1] : nil
            let isMine = message.senderFbid == viewer
            let sender = people.first { $0.interopMessagingUserFbid == message.senderFbid }
            // A time between messages more than half an hour apart.
            let startsSection = previous.map { (message.timestamp ?? 0) - ($0.timestamp ?? 0) > 1_800_000 } ?? true
            // A run ends with a change of sender, a line from Instagram, or five minutes.
            let endsRun = next.map {
                $0.notice != nil || $0.senderFbid != message.senderFbid || ($0.timestamp ?? 0) - (message.timestamp ?? 0) > 300_000
            } ?? true
            let startsRun = previous?.senderFbid != message.senderFbid
            return Row(
                id: rowID(of: message), message: message, isMine: isMine,
                hasMyHeart: message.reactions.contains { $0.senderFbid == viewer },
                date: startsSection ? message.date : nil,
                senderName: isGroup && !isMine && message.notice == nil && startsRun ? sender?.username ?? message.sender?.name ?? "" : nil,
                avatar: sender?.avatarURL ?? message.sender?.userDict?.avatarURL,
                endsRun: endsRun,
                status: index == shown.count - 1 ? status : nil
            )
        }
        if new != rows { rows = new }
    }

    /// Instagram's ID for a message sent from here, to the ID of the row it was shown in.
    private var sentRows: [String: String] = [:]

    private func rowID(of message: DirectMessage) -> String {
        sentRows[message.id] ?? message.id
    }

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
    /// Instagram has it. `offlineID` is the message's own ID: a retry sends the same one, so
    /// Instagram recognises a message whose first answer was lost.
    func send(_ text: String, api: InstagramAPI, offlineID: String? = nil) async {
        let offlineID = offlineID ?? InstagramAPI.newOfflineID()
        await deliver(DirectMessage(pending: text, from: thread.viewerFbid, offlineID: offlineID), api: api) {
            try await self.source(api).send(text, threadID: self.thread.id, offlineID: offlineID)
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
                    self.error = ShownError(error)
                }
            }
        }
    }

    /// The prepared photos and videos, kept until they're delivered so a failed one can be retried.
    private var preparedMedia: [String: PreparedMedia] = [:]
    private var preparedVoice: [String: VoiceRecorder.Recording] = [:]

    /// A voice message: shows at once, playable from the phone, while it's encoded, uploaded and sent.
    func send(_ recording: VoiceRecorder.Recording, api: InstagramAPI, offlineID: String? = nil) async {
        let offlineID = offlineID ?? InstagramAPI.newOfflineID()
        let pending = DirectMessage(
            pending: .init(url: recording.url, duration: recording.duration, levels: recording.levels),
            from: thread.viewerFbid, offlineID: offlineID
        )
        preparedVoice[pending.id] = recording
        await deliver(pending, api: api) {
            try await self.source(api).sendVoice(pcm: recording.url, threadID: self.thread.id, offlineID: offlineID)
        }
        if messages.first(where: { $0.id == pending.id })?.failed != true { preparedVoice[pending.id] = nil }
    }

    func send(_ media: PreparedMedia, api: InstagramAPI, offlineID: String? = nil) async {
        let offlineID = offlineID ?? InstagramAPI.newOfflineID()
        let pending = DirectMessage(
            pending: .init(image: media.preview, isVideo: media.isVideo), from: thread.viewerFbid, offlineID: offlineID
        )
        preparedMedia[pending.id] = media
        await deliver(pending, api: api) {
            try await self.source(api).sendMedia(media.data, mimeType: media.mimeType, threadID: self.thread.id, offlineID: offlineID)
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
            let sentAt = sent.timestampMs.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
            lastDelivered = Delivered(preview: pending.preview(mine: true), date: sentAt)
            await refresh(api: api)
            // Like the website, mark the conversation read up to what you just sent.
            if let longID = thread.threadId, let messageID = sent.messageId, let timestamp = sent.timestampMs {
                markedRead = messageID
                _ = try? await source(api).markRead(threadID: longID, messageID: messageID, timestampMs: timestamp)
            }
        } catch {
            // Still here unless Instagram's copy turned up with it meanwhile (see `merge`).
            if let index = messages.firstIndex(where: { $0.id == pending.id }) {
                messages[index].failed = true
            }
            self.error = ShownError(error)
        }
    }

    /// A message that didn't go: send it again, in place of the failed one.
    func retry(_ message: DirectMessage, api: InstagramAPI) async {
        guard message.failed else { return }
        messages.removeAll { $0.id == message.id }
        let offlineID = message.offlineThreadingId
        if let media = preparedMedia.removeValue(forKey: message.id) {
            await send(media, api: api, offlineID: offlineID)
        } else if let recording = preparedVoice.removeValue(forKey: message.id) {
            await send(recording, api: api, offlineID: offlineID)
        } else if let text = message.textBody, !text.isEmpty {
            await send(text, api: api, offlineID: offlineID)
        }
    }

    /// The latest message from someone else among those on screen, when you haven't read up to
    /// it: marked read, as the website does while you look at the conversation, and only then.
    /// The website marks with that message's `id` and the conversation's long ID. If it doesn't
    /// reach Instagram, the next look tries again; if Instagram answers without marking, three
    /// tries at most.
    private func markReadIfNeeded(api: InstagramAPI) async {
        guard isOnScreen, let longID = thread.threadId,
              let latest = messages.last(where: { !$0.isPending && $0.senderFbid != thread.viewerFbid }),
              let timestamp = latest.timestampMs, let sent = latest.timestamp,
              thread.markedAsUnread == true || sent > thread.readUpTo,
              markedRead != latest.id, markingRead != latest.id
        else { return }
        markingRead = latest.id
        defer { markingRead = nil }
        let threadID = thread.id
        inbox?.markingRead(threadID, upTo: sent)
        guard let took = try? await source(api).markRead(threadID: longID, messageID: latest.id, timestampMs: timestamp) else {
            inbox?.markNotTaken(threadID, upTo: sent)
            return
        }
        if !took { inbox?.markNotTaken(threadID, upTo: sent) }
        unansweredMarks = took ? 0 : unansweredMarks + 1
        if took || unansweredMarks >= 3 {
            markedRead = latest.id
            unansweredMarks = 0
        }
    }

    /// Times in a row Instagram answered a read mark without marking anything.
    private var unansweredMarks = 0

    /// The inbox, whose row shows the conversation read while a mark is on its way.
    @ObservationIgnored weak var inbox: InboxModel?

    /// Adds the latest messages to the ones already shown, and drops pending ones Instagram now has.
    private func merge(_ latest: [DirectMessage]) {
        var byID: [String: DirectMessage] = [:]
        let arrived = Set(latest.map(\.id))
        // Instagram's latest messages are all there is since the oldest of them: one shown from
        // before that's newer but no longer among them was unsent, and goes too.
        let since = latest.compactMap(\.timestamp).min()
        // The inbox's short copies go: Instagram's full ones replace them.
        for message in messages where !message.isPending && !message.isPreview {
            if let since, let sent = message.timestamp, sent > since, !arrived.contains(message.id) { continue }
            byID[message.id] = message
        }
        for message in latest { byID[message.id] = message }
        // A sent message's own copy replaces it once Instagram returns it, found by Instagram's ID
        // for it or by the ID it was sent with: one whose answer was lost, shown as failed, too.
        let arrivedOffline = Set(latest.compactMap(\.offlineThreadingId))
        let stillPending = messages.filter { message in
            message.isPending && !arrived.contains(message.confirmedID ?? "")
                && message.offlineThreadingId.map { arrivedOffline.contains($0) } != true
        }
        // Instagram's copy takes over the row of the message it replaces (see `rows`), and the
        // photo it was shown with, so the picture doesn't blink while Instagram's own loads.
        for sent in messages where sent.isPending {
            guard let copy = latest.first(where: { copy in
                copy.id == sent.confirmedID
                    || (copy.offlineThreadingId != nil && copy.offlineThreadingId == sent.offlineThreadingId)
            }) else { continue }
            sentRows[copy.id] = rowID(of: sent)
            if let photo = sent.localMedia?.image, let shown = copy.attachments.first?.previewURL {
                ImageCache.shared.seed(photo, for: shown)
            }
        }
        // By time, and by ID where two share one: the same order at every refresh.
        messages = byID.values.sorted {
            let (first, second) = ($0.timestamp ?? 0, $1.timestamp ?? 0)
            return first != second ? first < second : $0.id < $1.id
        } + stillPending
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
                try await source(api).react(emoji, to: messageID, threadID: thread.id, adding: adding)
            } catch {
                setHeart(!adding, messageID: message.id, me: me)
                self.error = ShownError(error)
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

/// A message's row in the list: the message, with the time above it, whose it is and where
/// it is on its way, as the conversation worked them out (`ConversationModel.Row`).
struct MessageRow: View {
    let row: ConversationModel.Row
    let actions: MessageActions
    let voice: VoicePlayer
    /// The reaction pill's size as your heart goes on.
    @State private var heartPop: CGFloat = 1

    private var message: DirectMessage { row.message }

    var body: some View {
        VStack(spacing: 3) {
            if let date = row.date {
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
                if let name = row.senderName {
                    Text(name)
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if row.isMine {
                        Spacer(minLength: 56)
                    } else {
                        // Their avatar goes next to the last message of a run.
                        Avatar(url: row.avatar, size: 26)
                            .opacity(row.endsRun ? 1 : 0)
                    }
                    VStack(alignment: row.isMine ? .trailing : .leading, spacing: -5) {
                        MessageContent(row: row, actions: actions, voice: voice)
                        if !message.reactions.isEmpty {
                            // Pops in when your heart goes on, from where it's anchored. Not an
                            // insertion transition: the row is in a cell the list reuses, and a
                            // transition started there can stop at its first frame, invisible.
                            ReactionPill(reactions: message.reactions)
                                .scaleEffect(heartPop, anchor: row.isMine ? .topTrailing : .topLeading)
                                .padding(.horizontal, 8)
                        }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: row.hasMyHeart) { _, on in on }
                    .onChange(of: row.hasMyHeart) { _, on in
                        guard on else { return }
                        heartPop = 0.3
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { heartPop = 1 }
                    }
                    if !row.isMine { Spacer(minLength: 56) }
                }
                if let status = row.status { statusLine(status) }
            }
        }
        // The whole width, whatever the row holds: the list places rows, not their content.
        .frame(maxWidth: .infinity)
    }

    /// The pictures a row shows, for the list to read ahead of rows about to scroll in. None
    /// from a view-once message: those are never loaded ahead.
    static func pictures(in row: ConversationModel.Row) -> [URL] {
        let message = row.message
        guard !message.isViewOnce else { return [] }
        var pictures = message.attachments.filter { $0.kind != .audio }.compactMap(\.previewURL)
        if let preview = message.card?.previewImage?.url.flatMap(URL.init(string:)) { pictures.append(preview) }
        if !row.isMine, row.endsRun, let avatar = row.avatar { pictures.append(avatar) }
        return pictures
    }

    /// The largest a picture shows in a row, in points: what pictures read ahead are made to fit.
    static let largestPicture = CGSize(width: 240, height: 430)
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
                Button { actions.handlers.retry(message) } label: {
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
    let row: ConversationModel.Row
    let actions: MessageActions
    let voice: VoicePlayer

    private var message: DirectMessage { row.message }
    private var isMine: Bool { row.isMine }

    private func open(_ item: MediaItem) { actions.handlers.open(item) }
    private func heart() { actions.handlers.heart(message) }

    var body: some View {
        if let local = message.localMedia {
            LocalMediaView(media: local)
        } else if let local = message.localAudio {
            AudioBubble(id: row.id, url: local.url, durationMs: local.duration * 1000, levels: local.levels, isMine: isMine, voice: voice)
        } else if message.isViewOnce, !isMine || message.attachments.isEmpty {
            // Someone else's view-once photo or video opens only in Instagram's app, even if
            // Instagram's copy ever came with it. Yours shows here when it does, as on the website.
            ViewOnceBubble(message: message, isMine: isMine, open: { actions.handlers.handOff(message) }, heart: heart)
        } else if let audio = message.attachments.first(where: { $0.kind == .audio }) {
            AudioBubble(id: row.id, url: audio.url, durationMs: audio.playableDurationMs, levels: audio.waveform, isMine: isMine, voice: voice)
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
        } else if message.isStoryReply, let card = message.card {
            StoryReplyView(message: message, card: card, isMine: isMine, open: open, heart: heart)
        } else if let card = message.card {
            ShareCard(
                card: card, text: message.cardText, open: open, heart: heart,
                navigate: { actions.handlers.navigate($0) }, openURL: { actions.handlers.openURL($0) }
            )
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
            Button { actions.handlers.showOnWebsite() } label: {
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
    /// A row in the list is on its own, without the screen's environment: the screen's way to
    /// another screen and to Safari are handed to it.
    let navigate: (Route) -> Void
    let openURL: (URL) -> Void

    private enum Destination {
        case post(code: String)
        case story(URL)
        case instagram(path: String)
        case web(URL)
        case nothing
    }

    private var preview: URL? { card.previewImage?.url.flatMap(URL.init(string:)) }

    /// Only a web link leads anywhere: a share's link is the sender's choice. Instagram's pages
    /// open in the app, on www.instagram.com whatever their path (WebPage), others in Safari.
    private var destination: Destination {
        guard let url = URL(webLink: card.targetUrl) else { return .nothing }
        guard url.isInstagram else { return .web(url) }
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
/// time left. The conversation's player does the playing (VoicePlayer): the bubble shows where
/// it is when the message is the one playing.
private struct AudioBubble: View {
    /// The row's ID, which the player knows the message by.
    let id: String
    let url: URL?
    let durationMs: Double?
    let levels: [Double]?
    let isMine: Bool
    let voice: VoicePlayer

    /// Seconds; none when the length given isn't a number, or is endless.
    private var duration: Double {
        guard let durationMs, durationMs.isFinite else { return 0 }
        return max(durationMs / 1000, 0)
    }

    var body: some View {
        // Only the bubble of the message that's playing follows the player's progress.
        let isCurrent = voice.current == id
        let isPlaying = isCurrent && voice.isPlaying
        let position = isCurrent ? voice.position : 0
        HStack(spacing: 10) {
            Button { voice.toggle(id, url: url) } label: {
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
            Text(timeLabel(playing: isPlaying, position: position))
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .bubble(isMine: isMine)
    }

    /// The time left while playing, the length otherwise. A time too long to count in seconds
    /// reads 0:00, where turning it into a whole number would stop the app.
    private func timeLabel(playing: Bool, position: Double) -> String {
        let seconds = Int(exactly: (playing || position > 0 ? max(duration - position, 0) : duration).rounded()) ?? 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Plays the conversation's voice messages, one at a time. It belongs to the screen, not to a
/// row: a message goes on playing while its row scrolls away, and its bubble shows where it is
/// when it scrolls back.
@MainActor
@Observable
final class VoicePlayer {
    /// The row of the message that's playing, or paused part-way.
    private(set) var current: String?
    private(set) var isPlaying = false
    /// Seconds into it.
    private(set) var position: Double = 0
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var ticks: Any?
    @ObservationIgnored private var ended: NSObjectProtocol?

    /// Plays the message, or pauses it if it's the one playing. Another one playing stops.
    func toggle(_ id: String, url: URL?) {
        if current == id, let player {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
            return
        }
        // A voice message being sent plays from the phone; one received only from Instagram's
        // servers (MediaHosts).
        guard let url, url.isFileURL || MediaHosts.allows(url) else { return }
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        ticks = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            // A time the player can't tell reads as NaN: the last one stays.
            guard time.seconds.isFinite else { return }
            MainActor.assumeIsolated { self?.position = time.seconds }
        }
        ended = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        current = id
        position = 0
        isPlaying = true
        player.play()
    }

    /// Stops what's playing, back to its start: when it ends, and when you leave the conversation.
    func stop() {
        player?.pause()
        if let ticks { player?.removeTimeObserver(ticks) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
        (ticks, ended, player) = (nil, nil, nil)
        (current, isPlaying, position) = (nil, false, 0)
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
    /// The row is on screen. A row that scrolled away stays alive to be used again: its GIF
    /// shouldn't go on playing there.
    @Environment(CellDisplay.self) private var display: CellDisplay?

    var body: some View {
        let ratio = min(max(attachment.aspectRatio ?? 1, 0.56), 1.8)
        let width: CGFloat = attachment.isSticker == true ? 140 : 200
        Group {
            if let video = attachment.attachmentMp4Url.flatMap(URL.init(string:)), MediaHosts.allows(video) {
                LoopingVideo(url: video, isPaused: display?.isShown == false)
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
    var isPaused = false

    func makeUIView(context: Context) -> LoopingPlayerView {
        LoopingPlayerView(url: url)
    }

    func updateUIView(_ view: LoopingPlayerView, context: Context) {
        view.setPaused(isPaused)
    }

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

        func setPaused(_ paused: Bool) {
            if paused { player.pause() } else if player.rate == 0 { player.play() }
        }

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
                guard MediaHosts.allows(item.url) else { return }
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
