import SwiftUI

// MARK: - Activity

/// Activity: follow requests on top, then what people did with your posts and stories, newest
/// first, by day.
struct ActivityView: View {
    @Environment(Session.self) private var session
    @State private var model = ActivityModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !model.requests.isEmpty {
                    NavigationLink(value: Route.followRequests(model.requests)) {
                        FollowRequestsRow(requests: model.requests)
                    }
                    .buttonStyle(.plain)
                    Theme.hairline.frame(height: 0.5)
                }
                ForEach(model.sections, id: \.title) { section in
                    Text(section.title)
                        .font(Theme.font(14, .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    ForEach(section.items) { item in
                        ActivityRow(item: item)
                    }
                }
                if model.items.isEmpty {
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(32)
                    } else if let error = model.error {
                        ErrorRow(message: error) { Task { await model.load(api: session.api, force: true) } }
                    } else if model.hasLoaded {
                        Text("Nothing yet. When people like or comment on your posts, you'll see it here.")
                            .font(Theme.font(14))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(32)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollsToTopOnTabReselect()
        .background(Color.white)
        .refreshable { await model.load(api: session.api, force: true) }
        // Again when coming back to the tab's first screen, but not more than every half minute.
        .task { await model.load(api: session.api, force: false) }
        .classicBar(title: "Activity")
    }
}

@MainActor
@Observable
final class ActivityModel {
    struct Section {
        let title: String
        let items: [ActivityItem]
    }

    /// Notification kinds that are Instagram talking, not people: "… has new followers" (40042),
    /// suggested Threads posts (1379), and account notices like the Meta account one (32658).
    private static let instagramPrompts: Set<Int> = [40042, 1379, 32658]

    private(set) var items: [ActivityItem] = []
    private(set) var requests: [User] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private var loadedAt: Date?

    func load(api: InstagramAPI, force: Bool) async {
        if !hasLoaded, items.isEmpty, let saved = api.cachedActivity() { show(saved) }
        if !force, let loadedAt, Date.now.timeIntervalSince(loadedAt) < 30 { return }
        isLoading = items.isEmpty
        defer { isLoading = false }
        do {
            show(try await api.activity())
            loadedAt = .now
            hasLoaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// What people did, without Instagram's own prompts: ones with no text, and the kinds listed
    /// above. Anything repeated shows once, the newest.
    private func show(_ feed: ActivityFeed) {
        var seen = Set<String>()
        items = feed.items
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !Self.instagramPrompts.contains($0.storyType ?? -1) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .filter { seen.insert($0.text).inserted }
        requests = feed.requests
    }

    /// Today, Yesterday, This Week, This Month, Earlier: the ones that have something.
    var sections: [Section] {
        let calendar = Calendar.current
        let now = Date.now
        func bucket(_ date: Date?) -> String {
            guard let date else { return "Earlier" }
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
            if days < 7 { return "This Week" }
            if days < 30 { return "This Month" }
            return "Earlier"
        }
        var order: [String] = []
        var grouped: [String: [ActivityItem]] = [:]
        for item in items.sorted(by: { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }) {
            let title = bucket(item.date)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(item)
        }
        return order.map { Section(title: $0, items: grouped[$0] ?? []) }
    }
}

// MARK: - Rows

private struct FollowRequestsRow: View {
    let requests: [User]

    var body: some View {
        HStack(spacing: 12) {
            Facepile(urls: requests.prefix(2).compactMap(\.avatarURL))
            VStack(alignment: .leading, spacing: 2) {
                Text("Follow Requests")
                    .font(Theme.font(14, .medium))
                    .foregroundStyle(Theme.ink)
                Text(summary)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var summary: String {
        guard let first = requests.first?.username else { return "" }
        let others = requests.count - 1
        return others == 0 ? first : "\(first) and \(others) \(others == 1 ? "other" : "others")"
    }
}

/// One notification. The avatar opens the person's story when there's one; the rest opens the post,
/// or the person's profile.
private struct ActivityRow: View {
    let item: ActivityItem
    @Environment(StoriesModel.self) private var stories
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            avatar
            linked {
                HStack(spacing: 12) {
                    Text(message)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let thumbnail = item.thumbnailURL {
                        RemoteImage(thumbnail)
                            .frame(width: 44, height: 44)
                            .clipped()
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var avatar: some View {
        let urls = item.avatarURLs
        if urls.count > 1 {
            linked { Facepile(urls: urls) }
        } else if let person = item.person {
            let ring = stories.ring(forUserID: person.id, latestStory: item.args?.latestReelMedia)
            Button {
                stories.open([person.id])
            } label: {
                StoryAvatar(url: urls.first ?? item.people.first?.avatarURL, size: 40, ring: ring)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(ring == .none)
            .accessibilityLabel(ring == .none ? person.username : "\(person.username)'s story")
        } else {
            Avatar(url: urls.first, size: 40).frame(width: 48, height: 48)
        }
    }

    /// The post when there is one, otherwise your stories when it's about them, otherwise the person.
    private var route: Route? {
        if item.destinationKind.contains("story") || item.destinationKind.contains("reel_viewer") {
            return nil
        }
        if let code = item.args?.media?.shortcode, !code.isEmpty { return .postCode(code) }
        if let person = item.person, !person.username.isEmpty { return .profile(id: person.id, username: person.username) }
        return nil
    }

    /// About one of your stories that's still up (they last a day).
    private var isAboutYourStory: Bool {
        guard item.destinationKind.contains("story") || item.destinationKind.contains("reel_viewer") else { return false }
        return (item.date ?? .distantPast) > Date.now.addingTimeInterval(-86_400)
    }

    @ViewBuilder
    private func linked(@ViewBuilder _ content: () -> some View) -> some View {
        if let route {
            NavigationLink(value: route, label: content).buttonStyle(.plain)
        } else if isAboutYourStory, let me = session.userID {
            Button(action: { stories.open([me]) }, label: content)
                .buttonStyle(.plain)
        } else {
            content()
        }
    }

    /// The text with names in bold, then how long ago. Instagram places names by Unicode
    /// character, so an emoji in a name counts once.
    private var message: AttributedString {
        let scalars = Array(item.text.unicodeScalars)
        func piece(_ range: Range<Int>) -> AttributedString {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return AttributedString(String(view))
        }
        var result = AttributedString()
        var cursor = 0
        let ranges = item.links
            .compactMap { link -> Range<Int>? in
                guard let start = link.start, let end = link.end, start >= 0, start < end, end <= scalars.count else { return nil }
                return start..<end
            }
            .sorted { $0.lowerBound < $1.lowerBound }
        for range in ranges where range.lowerBound >= cursor {
            if range.lowerBound > cursor { result += piece(cursor..<range.lowerBound) }
            var name = piece(range)
            name.font = Theme.font(14, .medium)
            result += name
            cursor = range.upperBound
        }
        if cursor < scalars.count { result += piece(cursor..<scalars.count) }
        if let date = item.date {
            var age = AttributedString(" \(shortAge(of: date))")
            age.foregroundColor = Theme.secondary
            result += age
        }
        return result
    }
}

/// Two avatars, one over the other, for notifications about several people.
private struct Facepile: View {
    let urls: [URL]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let first = urls.first {
                Avatar(url: first, size: urls.count > 1 ? 32 : 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: urls.count > 1 ? .topLeading : .center)
            }
            if urls.count > 1 {
                Avatar(url: urls[1], size: 32)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            }
        }
        .frame(width: 48, height: 48)
    }
}

// MARK: - Follow requests

/// People asking to follow you: confirm or delete. Both happen at once on screen and go to
/// Instagram in the background; a failed one comes back with a note.
struct FollowRequestsView: View {
    @Environment(Session.self) private var session
    @State private var requests: [User]
    @State private var confirmed: Set<String> = []
    @State private var failure: String?

    init(requests: [User]) {
        _requests = State(initialValue: requests)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let failure {
                    Text(failure)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.like)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                }
                ForEach(requests) { user in
                    row(user)
                }
                if requests.isEmpty {
                    Text("No requests.")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondary)
                        .padding(32)
                }
            }
        }
        .background(Color.white)
        .classicBar(showsBack: true, title: "Follow Requests")
        .animation(.snappy(duration: 0.2), value: requests)
        .animation(.snappy(duration: 0.2), value: confirmed)
    }

    private func row(_ user: User) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.profile(user)) {
                HStack(spacing: 12) {
                    Avatar(url: user.avatarURL, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.username).font(Theme.font(14, .medium)).foregroundStyle(Theme.ink)
                        if let name = user.fullName, !name.isEmpty {
                            Text(name).font(Theme.font(14)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if confirmed.contains(user.id) {
                Text("Confirmed")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondary)
            } else {
                Button("Confirm") { respond(to: user, approve: true) }
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)
                Button("Delete") { respond(to: user, approve: false) }
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func respond(to user: User, approve: Bool) {
        let position = requests.firstIndex(of: user) ?? requests.count
        failure = nil
        if approve {
            confirmed.insert(user.id)
        } else {
            requests.removeAll { $0.id == user.id }
        }
        Task {
            do {
                try await session.api.respondToFollowRequest(from: user.id, approve: approve)
            } catch {
                if approve {
                    confirmed.remove(user.id)
                } else {
                    requests.insert(user, at: min(position, requests.count))
                }
                failure = "Couldn't \(approve ? "confirm" : "delete") \(user.username)'s request. Try again."
            }
        }
    }
}
