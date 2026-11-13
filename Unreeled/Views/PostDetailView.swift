import SwiftUI

/// A single post with its comments.
struct PostDetailView: View {
    @Environment(Session.self) private var session
    @State private var post: Media
    @State private var comments: [Comment] = []
    @State private var cursor: String?
    @State private var isLoading = false
    @State private var error: ShownError?

    init(post: Media) {
        _post = State(initialValue: post)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PostCard(post: $post, showsCommentsLink: false)
                Theme.hairline.frame(height: 0.5)
                ForEach(comments) { comment in
                    CommentRow(comment: comment)
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else if let error {
                    ErrorRow(error: error) { Task { await loadComments() } }
                } else if cursor != nil {
                    Button("Load more comments") { Task { await loadComments() } }
                        .font(Theme.font(14, .medium))
                        .foregroundStyle(Theme.secondary)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                }
            }
        }
        .background(Color.white)
        .classicBar(showsBack: true, title: post.isVideo ? "Video" : "Photo")
        .task {
            if comments.isEmpty, (post.commentCount ?? 0) > 0 { await loadComments() }
        }
        .onReconnect { if error != nil { await loadComments() } }
    }

    private func loadComments() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await session.api.comments(mediaID: post.id, cursor: cursor)
            var seen = Set(comments.map(\.id))
            comments += page.items.filter { seen.insert($0.id).inserted }
            cursor = page.cursor
            error = nil
        } catch {
            self.error = ShownError(error)
        }
    }
}

/// Loads a post by its short code (the part after /p/ in its link), then shows it.
struct PostLoaderView: View {
    let code: String
    @Environment(Session.self) private var session
    @State private var post: Media?
    @State private var error: ShownError?

    var body: some View {
        if let post {
            PostDetailView(post: post)
        } else {
            Group {
                if let error {
                    ErrorRow(error: error) { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .classicBar(showsBack: true, title: "")
            .task { await load() }
            .onReconnect { if error != nil { await load() } }
        }
    }

    private func load() async {
        do {
            post = try await session.api.post(code: code)
            error = post == nil ? ShownError(message: "This post isn't available.") : nil
        } catch {
            self.error = ShownError(error)
        }
    }
}

private struct CommentRow: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let user = comment.user {
                NavigationLink(value: Route.profile(user)) {
                    Avatar(url: user.avatarURL, size: 32)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text(comment.user?.username ?? "").font(Theme.font(14, .medium))) \(comment.text ?? "")")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 12) {
                    if let date = comment.date {
                        Text(shortAge(of: date))
                    }
                    if let likes = comment.commentLikeCount, likes > 0 {
                        Text(likes == 1 ? "1 like" : "\(likes.formatted()) likes")
                    }
                    if let replies = comment.childCommentCount, replies > 0 {
                        Text(replies == 1 ? "1 reply" : "\(replies) replies")
                    }
                }
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
