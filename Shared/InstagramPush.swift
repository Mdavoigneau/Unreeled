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
    /// app what it needs to open the right screen. Nil, with `content` untouched, when the push
    /// can't be read: the keys aren't on this phone, or it isn't one of Instagram's.
    ///
    /// This is the notification extension's work. It's here so that the app can do the same
    /// where the extension didn't run.
    @discardableResult
    static func rewrite(_ content: UNMutableNotificationContent) -> InstagramPush? {
        guard let keys = PushKeys.load(), let push = try? decrypt(userInfo: content.userInfo, keys: keys) else { return nil }
        content.title = push.title ?? ""
        content.body = push.message
        // One stack per conversation, and one for everything else of a kind.
        content.threadIdentifier = push.threadID ?? push.type
        content.userInfo[routingKey] = push.routing
        // A message can be answered from the notification (the app registers the action).
        if push.isDirect, push.threadID != nil { content.categoryIdentifier = messageCategory }
        // The encrypted copy has done its job.
        content.userInfo[envelopeKey] = nil
        return push
    }

    // MARK: Replying

    /// The kind of notification a message gets, which offers Reply.
    static let messageCategory = "message"
    /// Its Reply action, which sends what you type there to the conversation.
    static let replyAction = "reply"

    // MARK: What the app needs when the notification is tapped

    /// Under this key the extension leaves, in the notification it shows, what the app needs to
    /// open the right screen: the push's `type` and, for a message, its conversation's ID.
    static let routingKey = "unreeled"

    var routing: [String: String] {
        var routing = ["type": type]
        routing["thread"] = threadID
        return routing
    }

    /// What a tapped notification was about. Nil for one the extension couldn't read.
    struct Routing: Equatable {
        let isDirect: Bool
        let threadID: String?

        init?(userInfo: [AnyHashable: Any]) {
            if let routing = userInfo[routingKey] as? [String: String], let type = routing["type"] {
                isDirect = type.hasPrefix("direct")
                threadID = routing["thread"]
            } else if let keys = PushKeys.load(), let push = try? InstagramPush.decrypt(userInfo: userInfo, keys: keys) {
                // The extension didn't get to this one (iOS stopped it, or never ran it), and
                // the notification showed the relay's words: the push is still in it.
                isDirect = push.isDirect
                threadID = push.threadID
            } else {
                return nil
            }
        }
    }
}
