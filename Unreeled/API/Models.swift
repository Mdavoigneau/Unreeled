import UIKit

// Instagram's JSON, decoded with .convertFromSnakeCase: `like_count` becomes `likeCount`.
// Nearly everything is optional, so a field Instagram drops doesn't break a whole screen.

struct User: Codable, Hashable, Identifiable {
    let pk: FlexibleID?
    let rawID: FlexibleID?
    let username: String
    let fullName: String?
    let profilePicUrl: String?
    let isVerified: Bool?
    let isPrivate: Bool?
    let friendshipStatus: Friendship?
    /// When their newest story was posted, if they have one.
    let latestReelMedia: Double?
    /// Their ID in Direct, which messages use to say who sent them.
    let interopMessagingUserFbid: String?

    var id: String { pk?.value ?? rawID?.value ?? username }
    var avatarURL: URL? { profilePicUrl.flatMap(URL.init(string:)) }
    var hasStory: Bool { (latestReelMedia ?? 0) > Date().timeIntervalSince1970 - 86_400 }
    var displayName: String { fullName?.isEmpty == false ? fullName! : username }

    enum CodingKeys: String, CodingKey {
        case pk, rawID = "id", username, fullName, profilePicUrl, isVerified, isPrivate, friendshipStatus, latestReelMedia,
             interopMessagingUserFbid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pk = try? container.decodeIfPresent(FlexibleID.self, forKey: .pk)
        rawID = try? container.decodeIfPresent(FlexibleID.self, forKey: .rawID)
        // Story items carry a stub of their owner without a username.
        username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
        fullName = try? container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicUrl = try? container.decodeIfPresent(String.self, forKey: .profilePicUrl)
        isVerified = try? container.decodeIfPresent(Bool.self, forKey: .isVerified)
        isPrivate = try? container.decodeIfPresent(Bool.self, forKey: .isPrivate)
        friendshipStatus = try? container.decodeIfPresent(Friendship.self, forKey: .friendshipStatus)
        latestReelMedia = try? container.decodeIfPresent(Double.self, forKey: .latestReelMedia)
        interopMessagingUserFbid = (try? container.decodeIfPresent(FlexibleID.self, forKey: .interopMessagingUserFbid))?.value
    }
}

struct Friendship: Codable, Hashable {
    let following: Bool?
}

/// A post: a photo, a video or a carousel of both.
struct Media: Decodable, Hashable, Identifiable {
    let pk: FlexibleID?
    let rawID: FlexibleID?
    /// The short code in post links: instagram.com/p/<code>/.
    let code: String?
    let takenAt: Double?
    /// 1 photo, 2 video, 8 carousel.
    let mediaType: Int?
    /// "clips" for reels.
    let productType: String?
    let user: User?
    let caption: Caption?
    var likeCount: Int?
    let commentCount: Int?
    var hasLiked: Bool?
    let imageVersions2: ImageVersions?
    let videoVersions: [Rendition]?
    let carouselMedia: Lossy<Media>?
    let originalWidth: Double?
    let originalHeight: Double?
    let location: Location?
    /// Sent back with likes, as the website does.
    let organicTrackingToken: String?
    let videoDuration: Double?

    enum CodingKeys: String, CodingKey {
        case pk, rawID = "id", code, takenAt, mediaType, productType, user, caption, likeCount, commentCount,
             hasLiked, imageVersions2, videoVersions, carouselMedia, originalWidth, originalHeight, location,
             organicTrackingToken, videoDuration
    }

    var id: String { pk?.value ?? rawID?.value ?? code ?? "" }
    var isReel: Bool { productType == "clips" }
    var isVideo: Bool { mediaType == 2 }
    var children: [Media] { carouselMedia?.elements ?? [] }
    var date: Date? { takenAt.map(Date.init(timeIntervalSince1970:)) }
    var webURL: URL? { code.flatMap { URL(string: "https://www.instagram.com/p/\($0)/") } }
    var videoURL: URL? { videoVersions?.first.flatMap { URL(string: $0.url) } }

    /// Width over height, within the range Instagram shows in the feed (4:5 to 1.91:1).
    var aspectRatio: CGFloat {
        let source = children.first ?? self
        let largest = source.imageVersions2?.candidates?.max { ($0.width ?? 0) < ($1.width ?? 0) }
        let width = source.originalWidth ?? largest?.width ?? 1
        let height = source.originalHeight ?? largest?.height ?? 1
        guard width > 0, height > 0 else { return 1 }
        return min(max(width / height, 0.8), 1.91)
    }

    /// The smallest image at least `pixels` wide, or the largest there is, in the media's own
    /// shape. Instagram also lists square crops (a 9:16 story comes with 1080×1080 and 640×640
    /// ones), which would show zoomed in.
    func imageURL(width pixels: CGFloat) -> URL? {
        let source = imageVersions2?.candidates == nil ? children.first ?? self : self
        let all = source.imageVersions2?.candidates ?? []
        let shape = source.shape ?? all.max { $0.area < $1.area }?.shape
        let inShape = all.filter { candidate in
            guard let shape, let own = candidate.shape else { return true }
            return abs(own - shape) / shape < 0.04
        }
        let candidates = (inShape.isEmpty ? all : inShape).sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let image = candidates.first { ($0.width ?? 0) >= pixels } ?? candidates.last
        return image.flatMap { URL(string: $0.url) }
    }

    /// Width over height, as posted.
    var shape: CGFloat? {
        guard let width = originalWidth, let height = originalHeight, width > 0, height > 0 else { return nil }
        return CGFloat(width / height)
    }
}

struct Caption: Decodable, Hashable {
    let text: String?
}

struct ImageVersions: Decodable, Hashable {
    let candidates: [Rendition]?
}

/// One size of an image or video.
struct Rendition: Decodable, Hashable {
    let url: String
    let width: Double?
    let height: Double?

    var area: Double { (width ?? 0) * (height ?? 0) }

    /// Width over height.
    var shape: CGFloat? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGFloat(width / height)
    }
}

struct Location: Decodable, Hashable {
    let name: String?
}

struct Comment: Decodable, Hashable, Identifiable {
    let pk: FlexibleID?
    let text: String?
    let createdAt: Double?
    let user: User?
    let commentLikeCount: Int?
    let childCommentCount: Int?

    var id: String { pk?.value ?? "\(createdAt ?? 0)-\(user?.username ?? "")" }
    var date: Date? { createdAt.map(Date.init(timeIntervalSince1970:)) }
}

/// A profile's header.
struct Profile: Decodable, Hashable {
    struct Picture: Decodable, Hashable {
        let url: String?
    }

    struct BioLink: Decodable, Hashable {
        let title: String?
        let url: String?
    }

    let pk: FlexibleID?
    let rawID: FlexibleID?
    let username: String
    let fullName: String?
    let biography: String?
    let profilePicUrl: String?
    let hdProfilePicUrlInfo: Picture?
    let externalUrl: String?
    let bioLinks: [BioLink]?
    let isPrivate: Bool?
    let isVerified: Bool?
    let followerCount: Int?
    let followingCount: Int?
    let mediaCount: Int?
    let friendshipStatus: Friendship?
    let latestReelMedia: Double?

    enum CodingKeys: String, CodingKey {
        case pk, rawID = "id", username, fullName, biography, profilePicUrl, hdProfilePicUrlInfo, externalUrl,
             bioLinks, isPrivate, isVerified, followerCount, followingCount, mediaCount, friendshipStatus,
             latestReelMedia
    }

    var id: String { pk?.value ?? rawID?.value ?? "" }
    var hasStory: Bool { (latestReelMedia ?? 0) > Date().timeIntervalSince1970 - 86_400 }
    var avatarURL: URL? { (hdProfilePicUrlInfo?.url ?? profilePicUrl).flatMap(URL.init(string:)) }
    var websiteURL: URL? {
        guard let link = [externalUrl, bioLinks?.first?.url].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return URL(string: link)
    }
    /// Private, and you don't follow them (and it isn't you): their posts can't be loaded.
    func isLocked(for viewerID: String?) -> Bool {
        isPrivate == true && friendshipStatus?.following != true && id != viewerID
    }
}

// MARK: - GraphQL shapes

/// A page of a GraphQL list: edges holding nodes, and where the next page starts.
struct Connection<Node: Decodable>: Decodable {
    struct Edge: Decodable {
        let node: Node?
    }

    struct PageInfo: Decodable {
        let endCursor: String?
        let hasNextPage: Bool?
    }

    let edges: Lossy<Edge>?
    let pageInfo: PageInfo?

    var nodes: [Node] { edges?.elements.compactMap(\.node) ?? [] }
    var nextCursor: String? { pageInfo?.hasNextPage == true ? pageInfo?.endCursor : nil }
}

extension Connection: Equatable where Node: Equatable {}
extension Connection: Hashable where Node: Hashable {}
extension Connection.Edge: Equatable where Node: Equatable {}
extension Connection.Edge: Hashable where Node: Hashable {}
extension Connection.PageInfo: Hashable {}

/// An item in the home feed: a post, an ad, or a block of suggestions (which have no `media`).
struct FeedNode: Decodable {
    let media: Media?
    let isAd: Bool
    #if DEBUG
    /// The item's fields that aren't null, and why `media` didn't decode, for diagnosing the feed.
    let fields: [String]
    let mediaError: String?
    #endif

    enum CodingKeys: String, CodingKey {
        case media, ad
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAd = (try? container.decodeNil(forKey: .ad)) == false
        #if DEBUG
        do {
            media = try container.decodeIfPresent(Media.self, forKey: .media)
            mediaError = nil
        } catch {
            media = nil
            mediaError = String(describing: error).prefix(300).description
        }
        let all = try decoder.container(keyedBy: AnyKey.self)
        fields = all.allKeys.filter { (try? all.decodeNil(forKey: $0)) == false }.map(\.stringValue).sorted()
        #else
        media = try? container.decodeIfPresent(Media.self, forKey: .media)
        #endif
    }
}

/// Any key, for reading fields by name.
struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct LikeResult: Decodable {
    let hasLiked: Bool?
}

/// One account's stories. Instagram calls it a reel; its ID is the account's user ID.
struct Reel: Decodable, Hashable, Identifiable {
    let rawID: FlexibleID?
    let user: User?
    /// When the newest item was posted.
    let latestReelMedia: Double?
    /// When the newest item you've seen was posted (0 if none).
    let seen: Double?
    /// Only in reels loaded for viewing, not in the tray.
    var items: Lossy<Media>?
    /// False when the owner turned replies off.
    let canReply: Bool?

    enum CodingKeys: String, CodingKey {
        case rawID = "id", user, latestReelMedia, seen, items, canReply
    }

    var id: String { rawID?.value ?? user?.id ?? "" }
}

struct ReelsTray: Decodable {
    let tray: Lossy<Reel>?
}

struct ReelsMedia: Decodable {
    let reelsMedia: Lossy<Reel>?
}

struct PostInfo: Decodable {
    let items: Lossy<Media>?
}

// MARK: - Direct

/// A conversation.
struct DirectThread: Decodable, Hashable, Identifiable {
    let threadFbid: String?
    /// The long ID that read receipts use.
    let threadId: String?
    let threadTitle: String?
    let isGroup: Bool?
    let markedAsUnread: Bool?
    let lastActivityTimestampMs: FlexibleID?
    let users: Lossy<User>?
    let viewer: DirectViewer?
    /// The latest messages, newest first.
    let slideMessages: Connection<DirectMessage>?
    let slideReadReceipts: [ReadReceipt]?

    var id: String { threadFbid ?? threadId ?? "" }
    var people: [User] { users?.elements ?? [] }
    var viewerFbid: String? { viewer?.interopMessagingUserFbid }
    var lastMessage: DirectMessage? { slideMessages?.nodes.first }
    var lastActivity: Date? { lastActivityTimestampMs.flatMap { Double($0.value) }.map { Date(timeIntervalSince1970: $0 / 1000) } }

    var title: String {
        if let threadTitle, !threadTitle.isEmpty { return threadTitle }
        return people.map(\.displayName).joined(separator: ", ")
    }

    /// The newest message is from someone else and you haven't read it.
    var isUnread: Bool {
        if markedAsUnread == true { return true }
        guard let last = lastMessage, last.senderFbid != viewerFbid, let sent = last.timestamp else { return false }
        let read = slideReadReceipts?.first { $0.participantFbid == viewerFbid }?.watermarkTimestampMs.flatMap(Double.init) ?? 0
        return sent > read
    }

}

struct DirectViewer: Decodable, Hashable {
    let interopMessagingUserFbid: String?
}

struct ReadReceipt: Decodable, Hashable {
    let participantFbid: String?
    let watermarkTimestampMs: String?
}

/// One message.
struct DirectMessage: Decodable, Hashable, Identifiable {
    struct Sender: Decodable, Hashable {
        let name: String?
        let userDict: User?
    }

    /// A share: a post, a reel, a story, a profile, a link.
    struct Card: Decodable, Hashable {
        struct Image: Decodable, Hashable {
            let url: String?
            let width: Double?
            let height: Double?
        }

        let headerTitleText: String?
        let headerSubtitleText: String?
        let headerIcon: Image?
        let previewImage: Image?
        let targetUrl: String?
        /// The card quotes what the message answers: the story someone replied to.
        let isQuoted: Bool?
        let typename: String?

        enum CodingKeys: String, CodingKey {
            case headerTitleText, headerSubtitleText, headerIcon, previewImage, targetUrl, isQuoted
            case typename = "__typename"
        }

        /// What it showed is gone: a story after a day, a deleted post. Instagram keeps only a
        /// note in its place.
        var isExpired: Bool { typename == "SlideMessageExpiredPlaceholderXMA" }
    }

    /// Someone's reaction to the message, like a heart.
    struct Reaction: Decodable, Hashable {
        let reaction: String?
        let senderFbid: String?

        /// The heart as it displays: Instagram stores it without the emoji style mark.
        var emoji: String { reaction == "\u{2764}" ? "\u{2764}\u{FE0F}" : (reaction ?? "") }
    }

    /// A photo, video, voice message or GIF sent in the conversation.
    struct Attachment: Decodable, Hashable {
        enum Kind: Hashable {
            case photo, video, audio, animated
        }

        /// Set from where it was found in the message.
        var kind: Kind = .photo
        let attachmentCdnUrl: String?
        let attachmentCdnFallbackUrl: String?
        let previewCdnUrl: String?
        let previewWidth: Double?
        let previewHeight: Double?
        /// Voice messages: how long, and the shape of the sound.
        let playableDurationMs: Double?
        let waveform: [Double]?
        /// GIFs and stickers.
        let attachmentMp4Url: String?
        let attachmentWebpUrl: String?
        let isSticker: Bool?

        private enum CodingKeys: String, CodingKey {
            case attachmentCdnUrl, attachmentCdnFallbackUrl, previewCdnUrl, previewWidth, previewHeight,
                 playableDurationMs, waveformData, attachmentMp4Url, attachmentWebpUrl, isSticker
        }

        private struct Waveform: Decodable {
            let amplitudes: [Double]?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func string(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
            func number(_ key: CodingKeys) -> Double? {
                (try? container.decodeIfPresent(Double.self, forKey: key)) ?? string(key).flatMap(Double.init)
            }
            attachmentCdnUrl = string(.attachmentCdnUrl)
            attachmentCdnFallbackUrl = string(.attachmentCdnFallbackUrl)
            previewCdnUrl = string(.previewCdnUrl)
            previewWidth = number(.previewWidth)
            previewHeight = number(.previewHeight)
            playableDurationMs = number(.playableDurationMs)
            attachmentMp4Url = string(.attachmentMp4Url)
            attachmentWebpUrl = string(.attachmentWebpUrl)
            isSticker = try? container.decodeIfPresent(Bool.self, forKey: .isSticker)
            // A list of levels, an object holding one, or either as a JSON string.
            if let levels = try? container.decodeIfPresent([Double].self, forKey: .waveformData) {
                waveform = levels
            } else if let object = try? container.decodeIfPresent(Waveform.self, forKey: .waveformData) {
                waveform = object.amplitudes
            } else if let text = string(.waveformData), let data = text.data(using: .utf8) {
                waveform = (try? JSONDecoder().decode([Double].self, from: data))
                    ?? (try? JSONDecoder().decode(Waveform.self, from: data))?.amplitudes
            } else {
                waveform = nil
            }
        }

        var url: URL? { (attachmentCdnUrl ?? attachmentCdnFallbackUrl ?? attachmentMp4Url).flatMap(URL.init(string:)) }
        var previewURL: URL? { (previewCdnUrl ?? attachmentWebpUrl ?? attachmentCdnUrl).flatMap(URL.init(string:)) }
        var isVideo: Bool {
            kind == .video || (kind == .photo && ["mp4", "mov"].contains(url?.pathExtension.lowercased() ?? ""))
        }

        var aspectRatio: Double? {
            guard let previewWidth, let previewHeight, previewWidth > 0, previewHeight > 0 else { return nil }
            return previewWidth / previewHeight
        }
    }

    /// A photo or video you're sending, shown from the phone until Instagram has it.
    struct LocalMedia: Hashable {
        let image: UIImage
        let isVideo: Bool
    }

    /// A voice message you're sending, played from the phone until Instagram has it.
    struct LocalAudio: Hashable {
        let url: URL
        /// Seconds.
        let duration: Double
        /// 0 to 1.
        let levels: [Double]
    }

    private struct Fragment: Decodable {
        let plaintext: String?
    }

    let rawID: String?
    let messageId: String?
    /// TEXT, IMAGES, MESSAGE_INLINE_SHARE (a post or reel), MONTAGE_SHARE_XMA (a story), …
    let contentType: String?
    /// The content's GraphQL type, like SlideMessageImageContent.
    let kind: String?
    let textBody: String?
    let timestampMs: String?
    let senderFbid: String?
    let sender: Sender?
    let card: Card?
    let cardText: String?
    /// Photos, videos, voice messages and GIFs, in order.
    let attachments: [Attachment]
    /// Hearts and other reactions, one per person.
    var reactions: [Reaction]
    /// Instagram's "… reacted to your message" line, shown on the message itself instead.
    let isReactionLog: Bool
    /// A line from Instagram rather than a message, like who reacted to what.
    let notice: String?
    /// Sent from here and shown before Instagram returns its own copy.
    var isPending = false
    /// The ID Instagram gave a message sent from here, once it has it.
    var confirmedID: String?
    var failed = false
    var localMedia: LocalMedia?
    var localAudio: LocalAudio?
    /// From the inbox's short list: a photo, video or share there is only its kind, until the
    /// conversation's full copy arrives.
    var isPreview = false

    enum CodingKeys: String, CodingKey {
        case rawID = "id", messageId, contentType, textBody, timestampMs, senderFbid, sender, content, reactions
    }

    private enum ContentKeys: String, CodingKey {
        case kind = "__typename", xma, xmaTextBody, attachment, attachments, videos, audioAttachments,
             orderedPhotoVideoAttachments, animatedMedia, attachmentMp4Url, textFragments, isReactionActionLog
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawID = (try? container.decodeIfPresent(FlexibleID.self, forKey: .rawID))?.value
        messageId = try? container.decodeIfPresent(String.self, forKey: .messageId)
        contentType = try? container.decodeIfPresent(String.self, forKey: .contentType)
        textBody = try? container.decodeIfPresent(String.self, forKey: .textBody)
        timestampMs = (try? container.decodeIfPresent(FlexibleID.self, forKey: .timestampMs))?.value
        senderFbid = (try? container.decodeIfPresent(FlexibleID.self, forKey: .senderFbid))?.value
        sender = try? container.decodeIfPresent(Sender.self, forKey: .sender)
        let content = try? container.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
        kind = try? content?.decodeIfPresent(String.self, forKey: .kind)
        card = try? content?.decodeIfPresent(Card.self, forKey: .xma)
        cardText = try? content?.decodeIfPresent(String.self, forKey: .xmaTextBody)

        func list(_ key: ContentKeys, as kind: Attachment.Kind?) -> [Attachment] {
            let found = (try? content?.decodeIfPresent(Lossy<Attachment>.self, forKey: key))?.elements ?? []
            return found.map { item in
                var item = item
                if let kind { item.kind = kind } else if ["mp4", "mov"].contains(item.url?.pathExtension.lowercased() ?? "") { item.kind = .video }
                return item
            }
        }
        var media = list(.attachments, as: nil)
            + list(.videos, as: .video)
        // A view-once photo or video: Instagram only includes it when the website may show it
        // (the website shows it then too); for one sent to you, it never does.
        if var single = (try? content?.decodeIfPresent(Attachment.self, forKey: .attachment)) ?? nil {
            if ["mp4", "mov"].contains(single.url?.pathExtension.lowercased() ?? "") { single.kind = .video }
            media.append(single)
        }
        media += list(.orderedPhotoVideoAttachments, as: nil) + list(.audioAttachments, as: .audio)
        // A GIF or sticker: its own object, or fields on the content itself.
        if var animated = (try? content?.decodeIfPresent(Attachment.self, forKey: .animatedMedia)) ?? nil {
            animated.kind = .animated
            media.append(animated)
        } else if (try? content?.decodeIfPresent(String.self, forKey: .attachmentMp4Url)) != nil,
                  let contentDecoder = try? container.superDecoder(forKey: .content),
                  var animated = try? Attachment(from: contentDecoder) {
            animated.kind = .animated
            media.append(animated)
        }
        attachments = media
        reactions = (try? container.decodeIfPresent(Lossy<Reaction>.self, forKey: .reactions))?.elements ?? []
        isReactionLog = ((try? content?.decodeIfPresent(Bool.self, forKey: .isReactionActionLog)) ?? nil) ?? false
        let fragments = (try? content?.decodeIfPresent(Lossy<Fragment>.self, forKey: .textFragments))?.elements ?? []
        let notice = fragments.compactMap(\.plaintext).joined()
        self.notice = notice.isEmpty ? nil : notice
    }

    /// A message you're sending, until Instagram confirms it.
    init(pending text: String, from senderFbid: String?) {
        rawID = "local-\(UUID().uuidString)"
        messageId = nil
        contentType = "TEXT"
        kind = nil
        textBody = text
        timestampMs = String(Int(Date().timeIntervalSince1970 * 1000))
        self.senderFbid = senderFbid
        sender = nil
        card = nil
        cardText = nil
        attachments = []
        reactions = []
        isReactionLog = false
        notice = nil
        isPending = true
    }

    /// A photo or video you're sending, until Instagram confirms it.
    init(pending media: LocalMedia, from senderFbid: String?) {
        self.init(pending: "", from: senderFbid)
        localMedia = media
    }

    /// A voice message you're sending, until Instagram confirms it.
    init(pending audio: LocalAudio, from senderFbid: String?) {
        self.init(pending: "", from: senderFbid)
        localAudio = audio
    }

    var id: String { messageId ?? rawID ?? "\(timestampMs ?? "")-\(senderFbid ?? "")" }
    var timestamp: Double? { timestampMs.flatMap(Double.init) }
    var date: Date? { timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } }

    var isVideo: Bool {
        localMedia?.isVideo == true || kind?.contains("Video") == true || contentType?.contains("VIDEO") == true
            || attachments.contains(where: \.isVideo)
    }

    var isAudio: Bool {
        localAudio != nil || kind?.contains("Audio") == true || contentType.map { $0.contains("AUDIO") || $0.contains("VOICE") } == true
            || attachments.contains { $0.kind == .audio }
    }

    var isAnimated: Bool { attachments.contains { $0.kind == .animated } }

    /// A reply to a story: the story's card, with what was said in `textBody`. The website's
    /// rule is a quoted card on a story share. Once the story has expired the card is only a
    /// placeholder, without that mark, and the words are what show it was a reply.
    var isStoryReply: Bool {
        guard contentType == "MONTAGE_SHARE_XMA", let card else { return false }
        return card.isQuoted == true || (card.isExpired && textBody?.isEmpty == false)
    }

    /// A story reaction: one of Instagram's quick emojis instead of words.
    var isStoryReaction: Bool { isStoryReply && Self.storyReactions.contains(textBody ?? "") }

    /// The quick reactions under a story, as the website lists them.
    static let storyReactions: Set<String> = ["🔥", "😢", "👏", "😮", "😂", "😍", "🎉"]

    /// A view-once (or replay-once) photo or video, which only Instagram's own app can open.
    var isViewOnce: Bool {
        kind?.hasPrefix("SlideMessageRaven") == true || contentType?.hasPrefix("RAVEN") == true
    }

    /// What the message is, in a few words: its text, or what was sent.
    var summary: String {
        if isStoryReaction, let emoji = textBody { return "Reacted \(emoji) to your story" }
        if isStoryReply, let text = textBody { return "Replied to your story: \(text)" }
        if let text = textBody, !text.isEmpty { return text }
        if let notice { return notice }
        let type = contentType ?? ""
        if isAudio { return "Sent a voice message" }
        if isViewOnce, attachments.isEmpty { return isVideo ? "Sent a view-once video" : "Sent a view-once photo" }
        if isAnimated { return attachments.contains { $0.isSticker == true } ? "Sent a sticker" : "Sent a GIF" }
        if isVideo { return attachments.count > 1 ? "Sent \(attachments.count) videos" : "Sent a video" }
        if type == "IMAGES" || type.hasPrefix("RAVEN") || kind?.contains("Image") == true || localMedia != nil {
            return attachments.count > 1 ? "Sent \(attachments.count) photos" : "Sent a photo"
        }
        if type.contains("STICKER") || type.contains("ANIMATED") || type.contains("GIF") { return "Sent a sticker" }
        if type == "MONTAGE_SHARE_XMA" { return "Shared a story" }
        if let link = card?.targetUrl, link.contains("/reel") { return "Shared a reel" }
        if type.contains("SHARE") || card != nil { return "Shared a post" }
        if type.contains("REACTION") { return "Reacted to a message" }
        if type.contains("LIKE") { return "\u{2764}\u{FE0F}" }
        return "Sent something"
    }

    /// One line for the inbox.
    func preview(mine: Bool) -> String {
        guard mine, notice == nil else { return summary }
        if isStoryReaction, let emoji = textBody { return "You reacted \(emoji) to their story" }
        if isStoryReply, let text = textBody { return "You replied to their story: \(text)" }
        if let text = textBody, !text.isEmpty { return "You: \(text)" }
        let line = summary
        return line.first?.isLetter == true ? "You " + line.prefix(1).lowercased() + line.dropFirst() : "You: \(line)"
    }

}

struct Mailbox: Decodable {
    struct Node: Decodable {
        let asIgDirectThread: DirectThread?
    }

    let id: String?
    let threadsByFolder: Connection<Node>?
}

struct ThreadDetail: Decodable {
    let asIgDirectThread: DirectThread?
}

struct SentMessage: Decodable {
    let messageId: String?
    let timestampMs: String?
}

/// The Activity tab's query: notifications about you, and follow requests.
struct ActivityFeed: Decodable {
    struct Inbox: Decodable {
        let newStories: Lossy<ActivityItem>?
        let oldStories: Lossy<ActivityItem>?
    }

    struct Pending: Decodable {
        let users: Lossy<User>?
    }

    let xdtActivityInbox: Inbox?
    let xdtApiV1FriendshipsPending: Pending?

    var items: [ActivityItem] {
        (xdtActivityInbox?.newStories?.elements ?? []) + (xdtActivityInbox?.oldStories?.elements ?? [])
    }

    var requests: [User] { xdtApiV1FriendshipsPending?.users?.elements ?? [] }
}

/// One notification: who did what, and on which post or story.
struct ActivityItem: Codable, Hashable, Identifiable {
    /// A name in the text, by its position in it (UTF-16).
    struct Link: Codable, Hashable {
        let start: Int?
        let end: Int?
        let id: FlexibleID?
        let username: String?
        let type: String?
    }

    struct Thumbnail: Codable, Hashable {
        struct Image: Codable, Hashable {
            let url: String?
        }

        let id: FlexibleID?
        let shortcode: String?
        let image: Image?
    }

    struct Args: Codable, Hashable {
        let text: String?
        let links: Lossy<Link>?
        let media: Thumbnail?
        let profileId: FlexibleID?
        let profileImage: String?
        let secondProfileImage: String?
        let timestamp: Double?
        let destination: String?
        let latestReelMedia: Double?
        let users: Lossy<User>?
    }

    let pk: FlexibleID?
    let storyType: Int?
    let type: Int?
    let args: Args?

    /// Instagram can send the same notification (and pk) more than once, at different times.
    var id: String { "\(pk?.value ?? "-")-\(args?.timestamp ?? 0)" }
    var date: Date? { args?.timestamp.map(Date.init(timeIntervalSince1970:)) }
    var text: String { args?.text ?? "" }
    var links: [Link] { args?.links?.elements ?? [] }
    var people: [User] { args?.users?.elements ?? [] }
    var thumbnailURL: URL? { args?.media?.image?.url.flatMap(URL.init(string:)) }
    var avatarURLs: [URL] {
        [args?.profileImage, args?.secondProfileImage].compactMap { $0.flatMap(URL.init(string:)) }
    }

    /// What the notification points at, from its destination: "media", "user", "story_viewer_list"…
    var destinationKind: String {
        guard let destination = args?.destination else { return "" }
        return String(destination.prefix { $0 != "?" && $0 != ":" && $0 != "/" })
    }

    /// The first person named in it.
    var person: (id: String, username: String)? {
        if let link = links.first(where: { $0.type == "user" }), let id = link.id?.value, let username = link.username {
            return (id, username)
        }
        if let user = people.first { return (user.id, user.username) }
        if let id = args?.profileId?.value { return (id, "") }
        return nil
    }
}

struct TopSearch: Decodable {
    struct Result: Decodable {
        let user: User
    }

    let users: Lossy<Result>?
}

// MARK: - Helpers

/// Instagram sends IDs as numbers in some responses and as strings in others.
struct FlexibleID: Codable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int64.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// An array that drops the elements it can't decode.
struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skip.self)
            }
        }
        self.elements = elements
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// Saved as a plain array, which decodes back the same way.
extension Lossy: Encodable where Element: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(contentsOf: elements)
    }
}

extension Lossy: Equatable where Element: Equatable {}
extension Lossy: Hashable where Element: Hashable {}
