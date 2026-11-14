import UIKit

/// Sending you to Instagram's own app for what only it can open: view-once photos and videos.
enum InstagramHandOff {
    /// Opens the conversation in Instagram's app, or its inbox, or the app. False when
    /// Instagram's app isn't on the phone.
    @MainActor
    static func open(threadID: String) async -> Bool {
        let ways: [(URL?, [UIApplication.OpenExternalURLOptionsKey: Any])] = [
            // The website's link to the conversation, which Instagram's app opens directly. The ID
            // is Instagram's: should it ever not make a link, the inbox will do.
            (URL(string: "https://www.instagram.com/direct/t/\(threadID)/"), [.universalLinksOnly: true]),
            (URL(string: "instagram://direct-inbox"), [:]),
            (URL(string: "instagram://app"), [:]),
        ]
        for case let (url?, options) in ways where await UIApplication.shared.open(url, options: options) {
            return true
        }
        return false
    }
}
