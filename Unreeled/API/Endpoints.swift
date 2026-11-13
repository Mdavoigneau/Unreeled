import Foundation

/// A page of results and where the next one starts (nil at the end).
struct Page<Item> {
    var items: [Item]
    var cursor: String?
}

/// What each screen loads, with the queries and variables the mobile website uses.
extension InstagramAPI {
    /// The Following feed: posts from accounts you follow, newest first, with no suggestions
    /// (the website's instagram.com/?variant=following). The first page is small, as on the
    /// website, so it shows quickly.
    func timeline(cursor: String? = nil) async throws -> Page<Media> {
        try await timelinePage(from: timelineData(cursor: cursor), first: cursor == nil)
    }

    /// One page of the feed as Instagram sent it.
    func timelineData(cursor: String? = nil) async throws -> Data {
        let deviceID = await deviceID()
        let options: [String: Any] = [
            "device_id": deviceID,
            "is_async_ads_double_request": "0",
            "is_async_ads_in_headload_enabled": "0",
            "is_async_ads_rti": "0",
            "rti_delivery_backend": "0",
            "pagination_source": "following",
        ]
        let variables: [String: Any] = [
            "after": cursor.orNull,
            "before": NSNull(),
            "data": options,
            "first": cursor == nil ? 3 : 12,
            "last": NSNull(),
            "variant": "following",
        ]
        let name = cursor == nil ? "PolarisFeedTimelineRootV2Query" : "PolarisFeedRootPaginationCachedQuery_subscribe"
        return try await queryData(name, variables, at: ["xdt_api__v1__feed__timeline__connection"])
    }

    /// The posts in a page of the feed, without ads.
    func timelinePage(from data: Data, first: Bool) async throws -> Page<Media> {
        let feed = try await decoded(Connection<FeedNode>.self, from: data)
        let posts = feed.nodes.filter { !$0.isAd }.compactMap(\.media)
        #if DEBUG
        var summary: [String: Any] = [:]
        summary["page"] = first ? "first" : "next"
        summary["edges"] = feed.edges?.elements.count ?? 0
        summary["nodes"] = feed.nodes.count
        summary["ads"] = feed.nodes.filter(\.isAd).count
        summary["posts"] = posts.count
        summary["reels"] = posts.filter(\.isReel).count
        summary["notFollowing"] = posts.filter { $0.user?.friendshipStatus?.following == false }.count
        summary["hasNextPage"] = feed.nextCursor != nil
        summary["itemFields"] = feed.nodes.map { $0.fields.joined(separator: ",") }
        summary["mediaErrors"] = feed.nodes.compactMap(\.mediaError)
        summary["productTypes"] = posts.map { $0.productType ?? "?" }
        NetworkRecorder.append(["time": Date().ISO8601Format(), "timeline": summary])
        #endif
        return Page(items: posts, cursor: feed.nextCursor)
    }

    /// The pages of the feed loaded last, for showing them at once next time.
    func saveFeed(_ pages: [Data]) {
        guard !pages.isEmpty else { return }
        ResponseCache.shared.store(Data("[".utf8) + Data(pages.joined(separator: Data(",".utf8))) + Data("]".utf8), for: "feed")
    }

    /// The feed as it was last loaded, without ads. About a megabyte: read off the main thread.
    func cachedFeed() async -> [Media] {
        await Task.detached(priority: .userInitiated) { () -> [Media] in
            guard let data = ResponseCache.shared.data(for: "feed"),
                  let pages = try? InstagramAPI.decodeSaved([Connection<FeedNode>].self, from: data)
            else { return [] }
            return pages.flatMap(\.nodes).filter { !$0.isAd }.compactMap(\.media)
        }.value
    }

    /// A profile's header. `keep` is for your own: its saved copy is kept apart from the other
    /// screens', so visiting profiles never pushes it out (see ResponseCache).
    func profile(id: String, keep: Bool = false) async throws -> Profile {
        let data = try await queryData("PolarisProfilePageContentQuery", ["enable_integrity_filters": true, "id": id], at: ["user"])
        let profile = try await decoded(Profile.self, from: data)
        ResponseCache.shared.store(data, for: keep ? Self.keptProfileKey : "profile-\(id)")
        return profile
    }

    /// A profile as it was last loaded.
    func cachedProfile(id: String) -> Profile? {
        ResponseCache.shared.data(for: "profile-\(id)").flatMap { try? decode(Profile.self, from: $0) }
    }

    private nonisolated static let keptProfileKey = "kept-profile"
    private nonisolated static let keptPostsKey = "kept-posts"

    /// Your own profile and first posts as they were last loaded, read off the main thread.
    func keptProfile() async -> (profile: Profile, posts: Page<Media>?)? {
        await Task.detached(priority: .userInitiated) { () -> (profile: Profile, posts: Page<Media>?)? in
            guard let data = ResponseCache.shared.data(for: Self.keptProfileKey),
                  let profile = try? InstagramAPI.decodeSaved(Profile.self, from: data)
            else { return nil }
            let posts = ResponseCache.shared.data(for: Self.keptPostsKey)
                .flatMap { try? InstagramAPI.decodeSaved(Connection<Media>.self, from: $0) }
                .map { Page(items: $0.nodes, cursor: $0.nextCursor) }
            return (profile, posts)
        }.value
    }

    /// A profile's posts, newest first. With `keep`, your own: see `profile(id:keep:)`.
    func posts(username: String, cursor: String? = nil, keep: Bool = false) async throws -> Page<Media> {
        let options: [String: Any] = [
            "count": 12,
            "include_reel_media_seen_timestamp": true,
            "include_relationship_info": true,
            "latest_besties_reel_media": true,
            "latest_reel_media": true,
        ]
        let posts: Connection<Media>
        if let cursor {
            posts = try await query(
                "PolarisProfilePostsTabContentQuery_connection",
                ["after": cursor, "before": NSNull(), "data": options, "first": 12, "include_multi_captions": true, "last": NSNull(), "username": username],
                at: ["xdt_api__v1__feed__user_timeline_graphql_connection"]
            )
        } else {
            let data = try await queryData(
                "PolarisProfilePostsQuery",
                ["data": options, "username": username],
                at: ["xdt_api__v1__feed__user_timeline_graphql_connection"]
            )
            posts = try await decoded(Connection<Media>.self, from: data)
            ResponseCache.shared.store(data, for: keep ? Self.keptPostsKey : "posts-\(username)")
        }
        return Page(items: posts.nodes, cursor: posts.nextCursor)
    }

    /// The first posts of a profile as they were last loaded.
    func cachedPosts(username: String) -> Page<Media>? {
        guard let data = ResponseCache.shared.data(for: "posts-\(username)"),
              let posts = try? decode(Connection<Media>.self, from: data)
        else { return nil }
        return Page(items: posts.nodes, cursor: posts.nextCursor)
    }

    /// A post by its short code, the part after /p/ in its link.
    func post(code: String) async throws -> Media? {
        try await query("PolarisPostRootQuery", ["shortcode": code], at: ["xdt_api__v1__media__shortcode__web_info"], as: PostInfo.self)
            .items?.elements.first
    }

    func comments(mediaID: String, cursor: String? = nil) async throws -> Page<Comment> {
        let comments: Connection<Comment>
        if let cursor {
            comments = try await query(
                "PolarisPostCommentsPaginationQuery",
                ["after": cursor, "first": 10, "is_mobile_web": true, "media_id": mediaID, "sort_order": "popular"],
                at: ["comments_media", "comments_connection"]
            )
        } else {
            comments = try await query("PolarisPostCommentsContainerQuery", ["media_id": mediaID], at: ["comments_media", "comments_connection"])
        }
        return Page(items: comments.nodes, cursor: comments.nextCursor)
    }

    /// Accounts matching `text`. One `sessionID` per visit to the search screen, as on the website.
    func search(_ text: String, sessionID: String) async throws -> [User] {
        let variables: [String: Any] = [
            "data": [
                "context": "blended",
                "include_reel": "true",
                "query": text,
                "rank_token": "",
                "search_session_id": sessionID,
                "search_surface": "web_top_search",
            ],
            "hasQuery": true,
        ]
        let results = try await query("PolarisSearchBoxRefetchableQuery", variables, at: ["xdt_api__v1__fbsearch__topsearch_connection"], as: TopSearch.self)
        return results.users?.elements.map(\.user) ?? []
    }

    // MARK: Stories

    /// Accounts you follow that have stories, in the website's order.
    func storiesTray() async throws -> [Reel] {
        let data = try await queryData(
            "PolarisStoriesV3TrayContainerQuery",
            ["data": ["is_following_feed": false, "reason": "web_home"]],
            at: ["xdt_api__v1__feed__reels_tray"]
        )
        let tray = try await decoded(ReelsTray.self, from: data)
        ResponseCache.shared.store(data, for: "tray")
        return tray.tray?.elements ?? []
    }

    /// The stories tray as it was last loaded.
    func cachedStoriesTray() -> [Reel] {
        guard let data = ResponseCache.shared.data(for: "tray") else { return [] }
        return (try? decode(ReelsTray.self, from: data))?.tray?.elements ?? []
    }

    /// The stories of several accounts at once, by user ID, as the website loads them.
    func stories(userIDs: [String]) async throws -> [Reel] {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "storiesBatch": userIDs.count])
        #endif
        let data = try await queryData(
            "PolarisStoriesV3ReelPageStandaloneQuery",
            ["reel_ids_arr": userIDs],
            at: ["xdt_api__v1__feed__reels_media"]
        )
        let media = try await decoded(ReelsMedia.self, from: data)
        Task.detached(priority: .utility) { StoryFiles.shared.saveReels(from: data) }
        return media.reelsMedia?.elements ?? []
    }

    /// Tells Instagram you saw a story item, which shows you in its viewers, as on the website.
    func markStorySeen(_ item: Media, ownerID: String) async throws {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "storySeen": item.id, "owner": ownerID])
        #endif
        _ = try await graphQL("PolarisStoriesV3SeenMutation", [
            "reelId": ownerID,
            "reelMediaId": item.id,
            "reelMediaOwnerId": ownerID,
            "reelMediaTakenAt": Int(item.takenAt ?? 0),
            "viewSeenAt": Int(Date().timeIntervalSince1970),
        ])
    }

    // MARK: Messages

    /// Your conversations, newest first, and what pages through the rest.
    func inbox() async throws -> (threads: [DirectThread], mailboxID: String?, cursor: String?) {
        let data = try await queryData(
            "PolarisDirectInboxMobileQuery",
            ["device_id_for_iris_subscription": Self.directDeviceID],
            at: ["get_slide_mailbox_for_iris_subscription"]
        )
        let inbox = Self.page(of: try await decoded(Mailbox.self, from: data))
        ResponseCache.shared.store(data, for: "inbox")
        return inbox
    }

    /// People matching `query`, best first, as the website's inbox search finds them. Each comes
    /// as a one-to-one conversation to open: the website opens it by the person's Direct ID, and
    /// so does the conversation query.
    func searchDirect(_ query: String) async throws -> [DirectThread] {
        let payload = try await cometGET(
            "/api/v1/direct_v2/ranked_recipients/",
            [("mode", "universal"), ("query", query), ("show_threads", "true")],
            route: "comet.igweb.PolarisDirectInboxMobileRoute"
        )
        let items = (payload as? [String: Any])?["ranked_recipients"] as? [[String: Any]] ?? []
        var people: [DirectThread] = []
        for item in items {
            guard let user = item["user"] as? [String: Any],
                  let fbid = user["interop_messaging_user_fbid"].map({ "\($0)" }), !fbid.isEmpty
            else { continue }
            let json: [String: Any] = ["thread_fbid": fbid, "is_group": false, "users": [user]]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let thread = try? decode(DirectThread.self, from: data) {
                people.append(thread)
            }
        }
        #if DEBUG
        // Group conversations come as threads: their fields, to open them some day. Never values.
        let groups = items.compactMap { $0["thread"] as? [String: Any] }
        NetworkRecorder.append([
            "time": Date().ISO8601Format(), "directSearch": items.count, "people": people.count,
            "groups": groups.count, "groupFields": groups.first.map { Array($0.keys).sorted() } ?? [],
        ])
        #endif
        return people
    }

    /// The inbox as it was last loaded.
    func cachedInbox() -> (threads: [DirectThread], mailboxID: String?, cursor: String?)? {
        ResponseCache.shared.data(for: "inbox").flatMap { try? Self.page(of: Self.decodeSaved(Mailbox.self, from: $0)) }
    }

    /// The same, read off the main thread.
    func savedInbox() async -> (threads: [DirectThread], mailboxID: String?, cursor: String?)? {
        await Task.detached(priority: .userInitiated) {
            ResponseCache.shared.data(for: "inbox").flatMap { try? InstagramAPI.page(of: InstagramAPI.decodeSaved(Mailbox.self, from: $0)) }
        }.value
    }

    private nonisolated static func page(of mailbox: Mailbox) -> (threads: [DirectThread], mailboxID: String?, cursor: String?) {
        (mailbox.threadsByFolder?.nodes.compactMap(\.asIgDirectThread) ?? [], mailbox.id, mailbox.threadsByFolder?.nextCursor)
    }

    func moreThreads(mailboxID: String, cursor: String) async throws -> Page<DirectThread> {
        let mailbox = try await query(
            "IGDThreadListOffMsysPaginationQuery",
            ["count": 10, "cursor": cursor, "folder": "INBOX", "newer_than_timestamp_ms": NSNull(), "id": mailboxID],
            at: ["fetch__SlideMailbox"],
            as: Mailbox.self
        )
        return Page(items: mailbox.threadsByFolder?.nodes.compactMap(\.asIgDirectThread) ?? [], cursor: mailbox.threadsByFolder?.nextCursor)
    }

    /// A conversation with its latest messages. Reading it doesn't mark it read.
    func thread(id threadFbid: String) async throws -> DirectThread? {
        let data = try await queryData(
            "IGDThreadDetailQuery",
            ["min_uq_seq_id": NSNull(), "thread_fbid": threadFbid],
            at: ["get_slide_thread_nullable"]
        )
        guard let thread = try await decoded(ThreadDetail.self, from: data).asIgDirectThread else { return nil }
        ThreadStore.save(data, thread: thread, id: threadFbid)
        return thread
    }

    /// The messages before `cursor`, newest first.
    func olderMessages(threadID threadFbid: String, cursor: String) async throws -> Page<DirectMessage> {
        let messages = try await query(
            "IGDMessageListOffMsysQuery",
            [
                "after": cursor, "before": NSNull(), "first": 20, "last": NSNull(),
                "newer_than_message_id": NSNull(), "older_than_message_id": NSNull(), "id": threadFbid,
            ],
            at: ["fetch__SlideThread", "as_ig_direct_thread", "slide_messages"],
            as: Connection<DirectMessage>.self
        )
        return Page(items: messages.nodes, cursor: messages.nextCursor)
    }

    /// Sends a text message. `offlineID` is the message's own ID (`newOfflineID`): sending again
    /// with the same one lets Instagram recognise the message rather than take it twice.
    func send(_ text: String, threadID threadFbid: String, offlineID: String? = nil) async throws -> SentMessage {
        let offlineID = offlineID ?? Self.newOfflineID()
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "directSend": ["characters": text.count, "thread": threadFbid]])
        #endif
        return try await query(
            "IGDirectTextSendMutation",
            [
                "ig_thread_igid": threadFbid,
                "offline_threading_id": offlineID,
                "recipient_igids": NSNull(),
                "replied_to_client_context": NSNull(),
                "replied_to_item_id": NSNull(),
                "reply_to_message_id": NSNull(),
                "sampled": NSNull(),
                "text": ["sensitive_string_value": text],
                "mentions": [Any](),
                "mentioned_user_ids": [Any](),
                "commands": NSNull(),
                "forwarded_from_thread_id": NSNull(),
                "is_forwarded_from_own_message": NSNull(),
                "send_attribution": "igd_web_chat_tab:in_thread",
            ],
            at: ["xig_direct_text_send_with_slide_messaging_response"],
            as: SentMessage.self
        )
    }

    /// A reaction on a message, as the website's double-tap sends it: the heart to add it, the
    /// same emoji again to take it off.
    func react(_ emoji: String, to messageID: String, threadID threadFbid: String, adding: Bool) async throws {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "directReaction": adding ? "add" : "remove", "thread": threadFbid])
        #endif
        let data = try await graphQL("IGDirectReactionSendMutation", ["input": [
            "emoji": emoji, "item_id": "", "message_id": messageID,
            "reaction_status": adding ? "created" : "deleted", "thread_id": threadFbid,
        ]])
        let response = data["xig_direct_reaction_send_with_slide_messaging_response"] as? [String: Any]
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "directReactionSuccess": response?["success"] ?? NSNull()])
        #endif
        if response?["success"] as? Bool == false { throw Failure.query("Instagram didn't take the reaction.") }
    }

    /// Marks a conversation read up to a message, which shows the others you've seen it,
    /// as the website does when you open a conversation or send in it.
    func markRead(threadID longID: String, messageID: String, timestampMs: String) async throws {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "directMarkRead": longID])
        #endif
        let metadata = ["ig_thread_igid": longID]
        _ = try await graphQL("useIGDMarkThreadAsReadMutation", ["metadata": metadata, "data": ["item_id": "", "message_id": messageID]])
        _ = try await graphQL(
            "useIGDMarkThreadAsReadValidationMutation",
            ["metadata": metadata, "data": ["message_id": messageID, "message_timestamp_ms": timestampMs]]
        )
    }

    /// The website's own ID for a message it sends: the time in milliseconds, shifted, plus random bits.
    nonisolated static func newOfflineID() -> String {
        String((UInt64(Date().timeIntervalSince1970 * 1000) << 22) | UInt64.random(in: 0..<(1 << 22)))
    }

    /// Identifies this install to Direct, like the website's per-browser ID.
    private static var directDeviceID: String {
        if let id = UserDefaults.standard.string(forKey: "directDeviceID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "directDeviceID")
        return id
    }

    // MARK: Photos and videos in messages

    /// Sends a photo (JPEG) or video (MP4) in a conversation: uploaded first, then sent, as the
    /// website's chat does.
    func sendMedia(_ data: Data, mimeType: String, threadID threadFbid: String, offlineID: String? = nil) async throws -> SentMessage {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "directMediaSend": ["bytes": data.count, "mime": mimeType, "thread": threadFbid]])
        #endif
        let attachmentID = try await uploadForDirect(data, mimeType: mimeType, fileName: mimeType == "video/mp4" ? "video.mp4" : "image.jpg")
        return try await sendAttachment(attachmentID, threadID: threadFbid, offlineID: offlineID)
    }

    /// Sends a voice message the way the website's recorder does: Opus in an Ogg file named
    /// `audioclip-<time>-<length>.ogg`, uploaded with its waveform, then sent like a photo.
    func sendVoice(pcm url: URL, threadID threadFbid: String, offlineID: String? = nil) async throws -> SentMessage {
        let encoded = try await Task.detached(priority: .userInitiated) { try OggOpus.encode(pcm: url) }.value
        let lengthMs = Int((encoded.duration * 1000).rounded())
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "directVoiceSend": ["bytes": encoded.data.count, "ms": lengthMs, "thread": threadFbid]])
        #endif
        let waveform: [String: Any] = [
            "amplitudes": encoded.amplitudes,
            "sampling_freq": Int((Double(encoded.amplitudes.count) / max(encoded.duration, 0.1)).rounded()),
        ]
        let waveformJSON = String(decoding: try JSONSerialization.data(withJSONObject: waveform), as: UTF8.self)
        let attachmentID = try await uploadForDirect(
            encoded.data, mimeType: "audio/ogg",
            fileName: "audioclip-\(Int(Date().timeIntervalSince1970 * 1000))-\(lengthMs).ogg",
            fields: [("voice_clip", "true"), ("voice_clip_waveform_data", waveformJSON)]
        )
        return try await sendAttachment(attachmentID, threadID: threadFbid, offlineID: offlineID)
    }

    private func sendAttachment(_ attachmentID: String, threadID threadFbid: String, offlineID: String?) async throws -> SentMessage {
        try await query(
            "IGDirectMediaSendMutation",
            [
                "attachment_fbid": attachmentID,
                "forwarded_from_thread_id": NSNull(),
                "is_forwarded_from_own_message": NSNull(),
                "offline_threading_id": offlineID ?? Self.newOfflineID(),
                "reply_to_message_id": NSNull(),
                "thread_id": threadFbid,
            ],
            at: ["xig_direct_media_send_with_slide_messaging_response"],
            as: SentMessage.self
        )
    }

    // MARK: Posting stories

    /// Posts a photo to your story, as the website's story camera does. Returns the story item's ID.
    func postStoryPhoto(_ jpeg: Data, width: Int, height: Int) async throws -> String {
        let uploadID = Self.newUploadID()
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "storyPost": ["kind": "photo", "bytes": jpeg.count]])
        #endif
        try await ruploadForStory(
            kind: "igphoto", entityName: "fb_uploader_\(uploadID)", data: jpeg, mimeType: "image/jpeg",
            params: ["media_type": 1, "upload_id": uploadID, "upload_media_height": height, "upload_media_width": width]
        )
        return try await publishStory(uploadID: uploadID)
    }

    /// Posts a video to your story: the video, then a cover frame under the same upload ID.
    func postStoryVideo(_ mp4: Data, cover: Data, width: Int, height: Int, durationMs: Int) async throws -> String {
        let uploadID = Self.newUploadID()
        let entityName = "story_\(uploadID)"
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "storyPost": ["kind": "video", "bytes": mp4.count, "ms": durationMs]])
        #endif
        try await ruploadForStory(
            kind: "igvideo", entityName: entityName, data: mp4, mimeType: "video/mp4",
            params: [
                "client-passthrough": "1", "is_unified_video": "0", "for_album": true, "is_sidecar": "0",
                "media_type": 2, "upload_id": uploadID, "upload_media_duration_ms": durationMs,
                "upload_media_height": height, "upload_media_width": width, "video_format": "video/mp4",
                "video_transform": NSNull(),
            ]
        )
        try await ruploadForStory(
            kind: "igphoto", entityName: entityName, data: cover, mimeType: "image/jpeg",
            params: ["media_type": 2, "upload_id": uploadID, "upload_media_height": height, "upload_media_width": width]
        )
        // Instagram may still be processing the video: give it a few seconds.
        var attempt = 0
        while true {
            do {
                return try await publishStory(uploadID: uploadID)
            } catch where attempt < 5 {
                attempt += 1
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func publishStory(uploadID: String) async throws -> String {
        let data = try await send("POST", "/api/v1/media/configure_to_story/", form: [
            "caption": "", "configure_mode": "1", "share_to_facebook": "", "share_to_fb_destination_id": "",
            "share_to_fb_destination_type": "USER", "upload_id": uploadID,
        ])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let pk = (json?["media"] as? [String: Any])?["pk"]
        if let pk = pk as? String, !pk.isEmpty, pk != "0" { return pk }
        if let pk = pk as? NSNumber, pk.int64Value != 0 { return pk.stringValue }
        throw Failure.query((json?["error_title"] as? String) ?? (json?["message"] as? String) ?? "Instagram didn't post the story.")
    }

    /// Deletes one of your story items, as the website does.
    func deleteStoryItem(_ mediaID: String) async throws {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "storyDelete": mediaID])
        #endif
        let data = try await send("POST", "/api/v1/web/create/\(mediaID)/delete/")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard json?["did_delete"] as? Bool == true else { throw Failure.query("Instagram didn't delete it.") }
    }

    /// The website's upload IDs: the time in milliseconds, never twice the same.
    private static var lastUploadID = 0

    private static func newUploadID() -> String {
        lastUploadID = max(Int(Date().timeIntervalSince1970 * 1000), lastUploadID + 1)
        return String(lastUploadID)
    }

    // MARK: Activity

    /// Notifications about you, newest first, and the follow requests waiting for you. Reading
    /// them marks nothing seen, as on the website. What's kept of them is in `ActivityLog`.
    func activity() async throws -> ActivityFeed {
        let data = try await queryData(
            "PolarisActivityFeedStoriesViewQuery",
            ["inbox_request_data": [String: Any](), "pending_request_data": [String: Any]()],
            at: []
        )
        let feed = try await decoded(ActivityFeed.self, from: data)
        #if DEBUG
        // Kinds of notification only (type, destination, whether there's a post), to route taps.
        let kinds = Set(feed.items.map {
            "\($0.storyType ?? -1)/\($0.type ?? -1)/\($0.destinationKind)/\($0.args?.media?.shortcode == nil ? "-" : "code")"
        })
        NetworkRecorder.append(["time": Date().ISO8601Format(), "activityKinds": kinds.sorted(), "requests": feed.requests.count])
        #endif
        return feed
    }

    /// Accepts or turns down a follow request, with the website's own calls.
    func respondToFollowRequest(from userID: String, approve: Bool) async throws {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "followRequest": approve ? "approve" : "ignore", "user": userID])
        #endif
        _ = try await send(
            "POST",
            "/api/v1/friendships/\(approve ? "approve" : "ignore")/\(userID)/",
            form: approve ? ["has_seen_uk_osa_prompt": "false"] : [:]
        )
    }

    // MARK: Story likes and replies

    /// Likes or unlikes a story item, with the mutations of the website's stories viewer.
    func setStoryLiked(_ liked: Bool, item: Media) async throws {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "storyLike": liked, "mediaID": item.id])
        #endif
        do {
            _ = try await graphQL(
                liked ? "usePolarisStoriesV4LikeMutationLikeMutation" : "usePolarisStoriesV4LikeMutationUnlikeMutation",
                ["input": ["media_id": item.id]]
            )
            #if DEBUG
            NetworkRecorder.append(["time": Date().ISO8601Format(), "storyLikeConfirmed": liked])
            #endif
        } catch {
            #if DEBUG
            NetworkRecorder.append(["time": Date().ISO8601Format(), "storyLikeFailed": error.localizedDescription])
            #endif
            throw error
        }
    }

    /// Replies to a story item: a message to its owner with the story attached, sent the way the
    /// website's viewer sends it.
    func replyToStory(_ text: String, item: Media, ownerID: String, reelID: String) async throws -> SentMessage {
        let offlineID = Self.newOfflineID()
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "storyReply": ["characters": text.count, "owner": ownerID]])
        #endif
        do {
            let sent = try await storyShareReply(text, item: item, ownerID: ownerID, reelID: reelID, offlineID: offlineID)
            #if DEBUG
            NetworkRecorder.append(["time": Date().ISO8601Format(), "storyReplyDelivered": sent.messageId != nil])
            #endif
            return sent
        } catch {
            #if DEBUG
            NetworkRecorder.append(["time": Date().ISO8601Format(), "storyReplyFailed": error.localizedDescription])
            #endif
            throw error
        }
    }

    private func storyShareReply(_ text: String, item: Media, ownerID: String, reelID: String, offlineID: String) async throws -> SentMessage {
        try await query(
            "IGDirectStoryShareReplyMutation",
            [
                "data": [
                    "is_shh_mode": false,
                    // The media's pk alone, as the website's current stories viewer sends it.
                    "media_id": item.id,
                    "reaction_emoji": NSNull(),
                    "reel_id": reelID,
                    "sampled": false,
                    "share_client_context": offlineID,
                    "text": ["sensitive_string_value": text],
                ],
                "send_data": [
                    "forwarded_from_thread_id": NSNull(),
                    "is_forwarded_from_own_message": NSNull(),
                    "offline_threading_id": offlineID,
                    "recipient_users": "[\"\(ownerID)\"]",
                    "thread_id": NSNull(),
                ],
            ],
            at: ["direct_story_share_reply_with_slide_message_response"],
            as: SentMessage.self
        )
    }

    // MARK: Likes

    /// Likes or unlikes a post with the website's own mutations. `container` is where it happened,
    /// as the website reports it: "feed_timeline" or "single_post".
    func setLiked(_ liked: Bool, post: Media, container: String) async throws {
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "like": liked, "mediaID": post.id])
        #endif
        mutationCount += 1
        var input: [String: Any] = [
            "actor_id": "{viewer}",
            "client_mutation_id": String(mutationCount),
            "media_id": post.id,
            "tracking_token": post.organicTrackingToken ?? "",
        ]
        if liked { input["container_module"] = container }
        let result: LikeResult
        do {
            result = try await query(
                liked ? "usePolarisLikeMediaXIGLikeMutation" : "usePolarisLikeMediaXIGUnlikeMutation",
                ["input": input],
                at: [liked ? "xig_media_like" : "xig_media_unlike", "media"]
            )
        } catch {
            #if DEBUG
            NetworkRecorder.append(["time": Date().ISO8601Format(), "likeFailed": error.localizedDescription])
            #endif
            throw error
        }
        #if DEBUG
        NetworkRecorder.append(["time": Date().ISO8601Format(), "likeConfirmed": result.hasLiked.map { $0 as Any } ?? NSNull()])
        #endif
        guard result.hasLiked == liked else {
            throw Failure.query("Instagram didn't \(liked ? "like" : "unlike") the post.")
        }
    }

    // MARK: Push

    /// Registers a web push address for this login, as the website does once a browser allows
    /// notifications (`registerPushClient`). Instagram then posts each notification to
    /// `endpoint`, encrypted for the two keys, which are base64url as a browser gives them.
    func registerWebPush(endpoint: String, p256dh: String, auth: String) async throws {
        let data = try await send("POST", "/api/v1/web/push/register/", form: [
            "device_token": endpoint,
            "device_type": "web_vapid",
            "mid": await machineID(),
            // The keys as a browser's subscription lists them.
            "subscription_keys": #"{"p256dh":"\#(p256dh)","auth":"\#(auth)"}"#,
            "jazoest": await formChecksum(),
        ])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard json?["status"] as? String == "ok" else {
            throw Failure.query("Instagram didn't take the push address.")
        }
    }
}

private extension Optional where Wrapped == String {
    /// The string, or JSON null.
    var orNull: Any {
        if let self { return self }
        return NSNull()
    }
}
