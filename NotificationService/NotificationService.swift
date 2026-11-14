import UniformTypeIdentifiers
import UserNotifications

/// Runs when an Apple push from the relay reaches the phone, before the notification shows. The
/// push carries one of Instagram's notifications, still encrypted for this phone's keys; this
/// decrypts it and puts what it says in its place.
///
/// When that isn't possible (the keys are gone, or the push isn't one of Instagram's), the
/// relay's own words stay: "New notification on Instagram".
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private let lock = NSLock()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        deliver = contentHandler
        self.content = content

        guard let push = InstagramPush.rewrite(content), let picture = push.picture else { return finish() }
        Task {
            if let attachment = await Self.attachment(from: picture) {
                self.content?.attachments = [attachment]
            }
            self.finish()
        }
    }

    /// iOS is about to stop the extension: show what there is.
    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    /// Once: the picture's download and iOS's deadline can both get here.
    private func finish() {
        lock.lock()
        let deliver = self.deliver
        self.deliver = nil
        lock.unlock()
        if let deliver, let content { deliver(content) }
    }

    /// The sender's picture, to show beside the notification. Small, and not worth waiting long
    /// for: without it the notification shows as text.
    private static func attachment(from url: URL) async -> UNNotificationAttachment? {
        guard let (file, response) = try? await session.download(from: url) else { return nil }
        // Whatever isn't handed to iOS below goes: the download, and the picture if iOS refuses it.
        defer { try? FileManager.default.removeItem(at: file) }
        // By the size of what arrived: a server needn't say beforehand.
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
        guard (response as? HTTPURLResponse)?.statusCode == 200, size < 4 << 20 else { return nil }
        // An attachment's kind comes from its file's extension.
        let kind = response.mimeType.flatMap { UTType(mimeType: $0) } ?? .jpeg
        let named = file.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(kind.preferredFilenameExtension ?? "jpg")
        guard (try? FileManager.default.moveItem(at: file, to: named)) != nil else { return nil }
        guard let attachment = try? UNNotificationAttachment(identifier: "picture", url: named) else {
            try? FileManager.default.removeItem(at: named)
            return nil
        }
        return attachment
    }

    /// One for every picture while the extension runs: no cookies, nothing kept, and six seconds
    /// at most for a download, which bounds how much can arrive.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration)
    }()
}
