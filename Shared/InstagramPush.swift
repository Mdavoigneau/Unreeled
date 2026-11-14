import Foundation
import UserNotifications

/// One of Instagram's notifications, as its web push carries it once decrypted: JSON with `type`
/// (`direct_v2_text`, `direct_v2_media_share`, …), `message` (what the notification says), `t`
/// (the conversation's name, for a message), `ppu` (the sender's picture), `n` (the message's
/// ID) and `params`, some thirty more values of which `t_id` is the conversation's ID.
struct InstagramPush {
    let type: String
    let message: String
    let title: String?
    let picture: URL?
    let threadID: String?
    /// The message it shows, to find its notification again should the message be unsent.
    let messageID: String?

    /// About a message, rather than a like, a comment or a follow.
    var isDirect: Bool { type.hasPrefix("direct") }

    init?(json: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let message = object["message"] as? String, !message.isEmpty
        else { return nil }
        self.message = message
        type = object["type"] as? String ?? ""
        title = (object["t"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        picture = (object["ppu"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        let params = object["params"] as? [String: Any]
        threadID = params?["t_id"].flatMap { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
        messageID = object["n"].flatMap { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
    }

    // MARK: From an Apple push

    /// Where the relay puts Instagram's push in the Apple push it sends:
    /// `wp: { data, headers: { encoding, encryption, crypto_key } }`, as Mozilla's push service
    /// delivered them. `data` is base64url.
    static let envelopeKey = "wp"

    enum Failure: Error {
        case noEnvelope
        case notANotification
    }

    /// Decrypts the push the relay forwarded in an Apple push's `userInfo`.
    static func decrypt(userInfo: [AnyHashable: Any], keys: PushKeys) throws -> InstagramPush {
        guard let envelope = userInfo[envelopeKey] as? [String: Any],
              let body = (envelope["data"] as? String).flatMap(WebPushCrypto.base64url)
        else { throw Failure.noEnvelope }
        let headers = envelope["headers"] as? [String: Any] ?? [:]
        // Mozilla names them with underscores; a push service's own names have hyphens.
        func header(_ names: String...) -> String? {
            names.lazy.compactMap { headers[$0] as? String }.first
        }
        let json = try WebPushCrypto.decrypt(
            WebPushCrypto.Envelope(
                body: body,
                encoding: header("encoding", "content-encoding", "content_encoding") ?? "aesgcm",
                encryption: header("encryption"),
                cryptoKey: header("crypto_key", "crypto-key")
            ),
            privateKey: keys.privateKey,
            auth: keys.auth
        )
        guard let push = InstagramPush(json: json) else { throw Failure.notANotification }
        return push
    }

    // MARK: The notification it becomes

    /// Puts what the push in `content` says in place of the relay's own words, and leaves the
    /// app what it needs to open the right screen. Nil when the push can't be read: the keys
    /// aren't on this phone, or it isn't one of Instagram's. The relay's words stay then, but
    /// nothing in the Apple push that could make it look like a message to answer: whoever writes
    /// that push could have added a conversation and the Reply action to words of their own.
    ///
    /// This is the notification extension's work. It's here so that the app can do the same
    /// where the extension didn't run.
    @discardableResult
    static func rewrite(_ content: UNMutableNotificationContent) -> InstagramPush? {
        guard let keys = PushKeys.load(), let push = try? decrypt(userInfo: content.userInfo, keys: keys) else {
            content.userInfo[routingKey] = nil
            content.categoryIdentifier = ""
            return nil
        }
        content.title = push.title ?? ""
        // Instagram's notifications have none: a line under the title could only be the relay's.
        content.subtitle = ""
        content.body = push.message
        // One stack per conversation, and one for everything else of a kind.
        content.threadIdentifier = push.threadID ?? push.type
        content.userInfo[routingKey] = push.routing
        // A message can be answered from the notification (the app registers the action), and
        // nothing else can.
        content.categoryIdentifier = push.isDirect && push.threadID != nil ? messageCategory : ""
        // The encrypted copy stays: what a tap or Reply does is read from it again (see Routing).
        return push
    }

    // MARK: Replying

    /// The kind of notification a message gets, which offers Reply.
    static let messageCategory = "message"
    /// Its Reply action, which sends what you type there to the conversation.
    static let replyAction = "reply"

    // MARK: What the app needs when the notification is tapped

    /// Under this key the extension leaves, in the notification it shows, the push's `type`, its
    /// conversation's ID and its message's: what finds the notification again. The app writes
    /// the same in a notification of its own, with the login it's for. In one that came from
    /// Apple it's only a hint, since whoever sends the Apple push could have written it too:
    /// what a tap or Reply does is read from the push itself (see Routing).
    static let routingKey = "unreeled"

    var routing: [String: String] {
        var routing = ["type": type]
        routing["thread"] = threadID
        routing["message"] = messageID
        return routing
    }

    /// What a notification is about, read only where it can't have been made up: in one that
    /// came from Apple, from the push itself, decrypted, since the relay writes everything else
    /// in it; in one the app added itself, from what the app wrote. Nil when neither can be read.
    struct Routing: Equatable {
        /// Where it was read.
        enum Source: Equatable {
            /// A notification the app added itself, such as one about a reply that didn't go.
            case app
            /// The push, decrypted. `shown` when the notification says what the push says, as the
            /// extension wrote it; not when it shows other words, such as the relay's when the
            /// extension didn't run.
            case push(shown: Bool)
            /// What a build before 14 November 2026 wrote in a notification delivered at this
            /// date: it kept no copy of the push to read it from again. The app trusts it as that
            /// build did only if it came before this build took over.
            case earlierBuild(Date)
        }

        let isDirect: Bool
        let threadID: String?
        /// The message it shows, when it's one.
        let messageID: String?
        /// The login it's for, when the app wrote it. A push doesn't say: it's for the login the
        /// keys that decrypt it were made for.
        let account: String?
        let source: Source

        /// Reply can answer it: it shows what the push or the app said, so what you answer is
        /// what you read.
        var isAnswerable: Bool { source != .push(shown: false) }

        init?(_ notification: UNNotification) {
            let content = notification.request.content
            let written = content.userInfo[routingKey] as? [String: String]
            if !(notification.request.trigger is UNPushNotificationTrigger) {
                guard let written else { return nil }
                self.init(written, source: .app)
            } else if let keys = PushKeys.load(), let push = try? InstagramPush.decrypt(userInfo: content.userInfo, keys: keys) {
                // Also when the extension didn't get to it (iOS stopped it, or never ran it) and
                // the notification shows the relay's words: the push is still in it.
                self.init(push.routing, source: .push(shown: content.title == (push.title ?? "") && content.body == push.message))
            } else if content.userInfo[envelopeKey] == nil, let written {
                self.init(written, source: .earlierBuild(notification.date))
            } else {
                return nil
            }
        }

        private init?(_ routing: [String: String], source: Source) {
            guard let type = routing["type"] else { return nil }
            isDirect = type.hasPrefix("direct")
            threadID = routing["thread"]
            messageID = routing["message"]
            account = routing["account"]
            self.source = source
        }
    }
}
