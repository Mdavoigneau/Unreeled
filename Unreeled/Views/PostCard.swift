import AVKit
import SwiftUI

/// A post as the feed shows it: author, media, actions, likes, caption, time.
struct PostCard: View {
    @Binding var post: Media
    var showsCommentsLink = true

    @Environment(Session.self) private var session
    @Environment(StoriesModel.self) private var stories
    @State private var page = 0
    @State private var captionExpanded = false
    @State private var showsHeart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MediaView(post: post, page: $page)
                .onTapGesture(count: 2) { doubleTapped() }
                .overlay { heart }
            actions
            details
        }
        .padding(.bottom, 18)
        .background(Color.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let user = post.user {
                let ring = stories.ring(forUserID: user.id, latestStory: user.latestReelMedia)
                // The avatar opens their story when they have one, like it used to.
                Button {
                    stories.open([user.id])
                } label: {
                    StoryAvatar(url: user.avatarURL, size: 32, ring: ring)
                }
                .buttonStyle(.plain)
                .disabled(ring == .none)

                NavigationLink(value: Route.profile(user)) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(user.username).font(Theme.font(14, .medium))
                            if user.isVerified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        if let place = post.location?.name {
                            Text(place).font(Theme.font(12))
                        }
                    }
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let link = post.webURL {
                Menu {
                    ShareLink(item: link)
                    Link(destination: link) {
                        Label("Open in Safari", systemImage: "safari")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 56)
    }

    private var actions: some View {
        ZStack {
            HStack(spacing: 18) {
                Button(action: toggleLike) {
                    Image(systemName: post.hasLiked == true ? "heart.fill" : "heart")
                        .foregroundStyle(post.hasLiked == true ? Theme.like : Theme.ink)
                }
                .accessibilityLabel(post.hasLiked == true ? "Unlike" : "Like")
                NavigationLink(value: Route.post(post)) {
                    Image(systemName: "bubble.right")
                }
                .accessibilityLabel("Comments")
                if let link = post.webURL {
                    ShareLink(item: link) {
                        Image(systemName: "paperplane")
                    }
                }
                Spacer()
            }
            if post.children.count > 1 {
                PageDots(count: post.children.count, current: page)
            }
        }
        .font(Theme.icon)
        .foregroundStyle(Theme.ink)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .sensoryFeedback(.impact(weight: .light), trigger: post.hasLiked)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let likes = post.likeCount, likes > 0 {
                Text(likes == 1 ? "1 like" : "\(likes.formatted()) likes")
                    .font(Theme.font(14, .medium))
            }
            if let text = post.caption?.text, !text.isEmpty, let user = post.user {
                Text("\(Text(user.username).font(Theme.font(14, .medium))) \(text)")
                    .font(Theme.font(14))
                    .lineLimit(captionExpanded ? nil : 2)
                    .onTapGesture { captionExpanded.toggle() }
            }
            if showsCommentsLink, let count = post.commentCount, count > 0 {
                NavigationLink(value: Route.post(post)) {
                    Text(count == 1 ? "View 1 comment" : "View all \(count.formatted()) comments")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            if let date = post.date {
                Text(date.formatted(.relative(presentation: .named)).uppercased())
                    .font(Theme.font(10))
                    .kerning(0.3)
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14)
    }

    private var heart: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 90))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 10)
            .scaleEffect(showsHeart ? 1 : 0.5)
            .opacity(showsHeart ? 1 : 0)
            .animation(.snappy(duration: 0.25), value: showsHeart)
            .allowsHitTesting(false)
    }

    private func doubleTapped() {
        showsHeart = true
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            showsHeart = false
        }
        if post.hasLiked != true { toggleLike() }
    }

    /// Updates the post right away and reverts it if Instagram refuses.
    private func toggleLike() {
        let liked = post.hasLiked != true
        let target = post
        let container = showsCommentsLink ? "feed_timeline" : "single_post"
        setLiked(liked)
        Task {
            do {
                try await session.api.setLiked(liked, post: target, container: container)
            } catch {
                setLiked(!liked)
            }
        }
    }

    private func setLiked(_ liked: Bool) {
        guard (post.hasLiked == true) != liked else { return }
        post.hasLiked = liked
        post.likeCount = max(0, (post.likeCount ?? 0) + (liked ? 1 : -1))
    }
}

/// A post's photo, video or carousel, at the post's aspect ratio.
struct MediaView: View {
    let post: Media
    @Binding var page: Int

    var body: some View {
        let slides = post.children.isEmpty ? [post] : post.children
        Group {
            if slides.count == 1 {
                Slide(media: slides[0])
            } else {
                TabView(selection: $page) {
                    ForEach(slides.indices, id: \.self) { index in
                        Slide(media: slides[index]).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay(alignment: .topTrailing) {
                    Text("\(page + 1)/\(slides.count)")
                        .font(Theme.font(12, .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(post.aspectRatio, contentMode: .fit)
        .background(Theme.field)
    }
}

/// One photo or video. Videos show their cover and play inline when tapped.
extension EnvironmentValues {
    /// Videos start on their own, for a post opened by itself, like a reel someone sent you.
    @Entry var autoplaysVideo = false
}

private struct Slide: View {
    let media: Media
    @Environment(\.displayScale) private var displayScale
    @Environment(\.autoplaysVideo) private var autoplaysVideo
    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                        .onDisappear { player.pause() }
                } else {
                    RemoteImage(media.imageURL(width: geometry.size.width * displayScale))
                    if media.isVideo, let url = media.videoURL {
                        Button {
                            play(url)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 56, weight: .light))
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                        .accessibilityLabel("Play video")
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onAppear {
            if autoplaysVideo, player == nil, media.isVideo, let url = media.videoURL { play(url) }
        }
    }

    private func play(_ url: URL) {
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }
}

/// Carousel position, under the media like it used to be.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(count, 12), id: \.self) { index in
                Circle()
                    .fill(index == current ? Theme.accent : Color(hex: 0xA8A8A8))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
