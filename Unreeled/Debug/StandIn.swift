#if DEBUG
import SwiftUI
import UIKit

/// -standInConversations YES: every conversation opens as a stand-in, a long made-up one whose
/// Instagram is played here, on the phone. The screen and its model are the real ones, so the
/// list, the field, sending, delivery, older pages, hearts and read marks can all be tried and
/// measured; nothing is asked of Instagram, nobody's messages open and nothing is marked read.
///
/// - `-standInMessages <n>`: how many messages it starts with (400; 0 for an empty conversation).
/// - `-standInGroup YES`: a group of three rather than one person.
/// - `-standInIncoming <seconds>`: someone writes every so many seconds.
/// - Sending the word `fail` isn't taken the first time, and is on a retry; `lost` is taken, and
///   the answer lost on the way back.
@MainActor
final class StandIn: ConversationSource {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "standInConversations") }

    /// A conversation whose Instagram is a stand-in, as the inbox would hand it over: its
    /// newest few messages, in short.
    static func conversation() -> ConversationModel {
        let standIn = StandIn()
        let model = ConversationModel(thread: standIn.thread(messages: 5, short: true) ?? standIn.empty)
        model.standIn = standIn
        return model
    }

    /// What `-openStandIn YES` opens at launch: a conversation that is nobody's.
    static var route: DirectThread? { decode(["thread_fbid": "stand-in"]) }

    /// With no login on the phone, `-openStandIn YES` shows the stand-in on its own (Harness).
    static var opensWithoutLogin: Bool { isOn && UserDefaults.standard.bool(forKey: "openStandIn") }

    /// The stand-in conversation on its own, for a simulator nobody is logged in on: the chat
    /// screen can be tried on any iOS version without an account.
    struct Harness: View {
        @Environment(PushNotifications.self) private var notifications

        var body: some View {
            if let thread = StandIn.route {
                NavigationStack { ConversationView(thread: thread).routes() }
                    // The tabs aren't there to say it's the conversation on screen: said here.
                    .onAppear { notifications.visibleThread = thread.ids }
            }
        }
    }

    private static let me = "1"
    private static let pageSize = 20

    private let people: [(id: String, username: String, name: String)]
    /// Oldest first, as Instagram would send each.
    private var messages: [[String: Any]] = []
    private var made = 0
    private var myRead: Int64 = 0
    private var theirRead: Int64 = 0
    private var failedOnce: Set<String> = []
    private var random = Generator(seed: 2016)
    private var writer: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        let isGroup = defaults.bool(forKey: "standInGroup")
        people = [("2", "stand_in", "Stand In")] + (isGroup ? [("3", "second_stand_in", "Second Stand In")] : [])
        Pictures.makeIfMissing()
        let count = defaults.string(forKey: "standInMessages").flatMap(Int.init) ?? 400
        // Mostly a minute or two apart, in runs; now and then hours, which starts a new day. All
        // of it in the past, the last one a minute ago.
        let gaps = (0..<max(count, 0)).map { index in
            index % 14 == 13 ? Int64(random.next(in: 2...20)) * 3_600_000 : Int64(random.next(in: 10...150)) * 1000
        }
        var time = Self.now - gaps.reduce(0, +) - 60_000
        for gap in gaps {
            time += gap
            let fromMe = random.next(in: 0...99) < 45
            let sender = fromMe ? Self.me : people[random.next(in: 0...(people.count - 1))].id
            messages.append(message(content(), from: sender, at: time))
        }
        // The last two from someone else are unread: opening the conversation marks them read.
        let incoming = messages.filter { $0["sender_fbid"] as? String != Self.me }.compactMap { ($0["timestamp_ms"] as? String).flatMap(Int64.init) }
        myRead = incoming.dropLast(2).last.map { $0 + 1 } ?? 0
        theirRead = messages.last.flatMap { ($0["timestamp_ms"] as? String).flatMap(Int64.init) }.map { $0 + 1 } ?? 0
        let every = defaults.double(forKey: "standInIncoming")
        if every > 0 {
            writer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(every))
                    guard let self else { return }
                    let sender = self.people[self.random.next(in: 0...(self.people.count - 1))].id
                    self.messages.append(self.message(self.content(), from: sender, at: Self.now))
                }
            }
        }
    }

    deinit { writer?.cancel() }

    // MARK: Instagram's part

    func thread(id: String) async throws -> DirectThread? {
        try await Task.sleep(for: .milliseconds(300))
        return thread(messages: Self.pageSize, short: false)
    }

    func olderMessages(threadID: String, cursor: String) async throws -> Page<DirectMessage> {
        try await Task.sleep(for: .milliseconds(500))
        let end = min(Int(cursor) ?? 0, messages.count)
        let start = max(end - Self.pageSize, 0)
        let page: Connection<DirectMessage>? = Self.decode(connection(start..<end))
        return Page(items: page?.nodes ?? [], cursor: page?.nextCursor)
    }

    func send(_ text: String, threadID: String, offlineID: String?) async throws -> SentMessage {
        try await Task.sleep(for: .milliseconds(700))
        // The words that test failures, whatever the keyboard capitalised.
        let word = text.lowercased()
        if word == "fail", failedOnce.insert(offlineID ?? "").inserted { throw URLError(.timedOut) }
        let sent = try take(["content_type": "TEXT", "text_body": text, "content": ["__typename": "SlideMessageText"]], offlineID: offlineID)
        if word == "lost" { throw URLError(.networkConnectionLost) }
        return sent
    }

    func sendMedia(_ data: Data, mimeType: String, threadID: String, offlineID: String?) async throws -> SentMessage {
        try await Task.sleep(for: .milliseconds(1500))
        guard mimeType.hasPrefix("image/"), let size = UIImage(data: data)?.size else {
            let cover = Pictures.all[0]
            let video = attachment("https://stand-in.invalid/video-\(made).mp4", preview: cover.url.absoluteString, width: cover.width, height: cover.height)
            return try take(["content_type": "VIDEO", "content": ["__typename": "SlideMessageVideoContent", "videos": [video]] as [String: Any]], offlineID: offlineID)
        }
        let url = URL(string: "https://stand-in.invalid/sent-\(made).jpg")!
        ImageFiles.shared.keep(data, for: url)
        return try take(photos([attachment(url.absoluteString, preview: url.absoluteString, width: Int(size.width), height: Int(size.height))]), offlineID: offlineID)
    }

    func sendVoice(pcm url: URL, threadID: String, offlineID: String?) async throws -> SentMessage {
        try await Task.sleep(for: .milliseconds(1500))
        return try take(voice(seconds: 3), offlineID: offlineID)
    }

    func react(_ emoji: String, to messageID: String, threadID: String, adding: Bool) async throws {
        NetworkRecorder.append(["time": Date().ISO8601Format(), "standInReact": adding ? "add" : "remove", "message": messageID])
        try await Task.sleep(for: .milliseconds(300))
        guard let index = messages.firstIndex(where: { $0["message_id"] as? String == messageID }) else { return }
        var reactions = (messages[index]["reactions"] as? [[String: Any]] ?? []).filter { $0["sender_fbid"] as? String != Self.me }
        if adding { reactions.append(["reaction": emoji, "sender_fbid": Self.me]) }
        messages[index]["reactions"] = reactions
    }

    func markRead(threadID: String, messageID: String, timestampMs: String) async throws -> Bool {
        try await Task.sleep(for: .milliseconds(300))
        myRead = max(myRead, Int64(timestampMs) ?? 0)
        NetworkRecorder.append(["time": Date().ISO8601Format(), "standInMarkRead": messageID])
        return true
    }

    // MARK: What it's made of

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// A message of yours as Instagram has it once sent: under an ID of its own, with the one it
    /// was sent with. A few seconds later the others have read it.
    private func take(_ content: [String: Any], offlineID: String?) throws -> SentMessage {
        var sent = message(content, from: Self.me, at: Self.now)
        if let offlineID { sent["offline_threading_id"] = offlineID }
        messages.append(sent)
        let time = (sent["timestamp_ms"] as? String).flatMap(Int64.init) ?? Self.now
        myRead = max(myRead, time + 1)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.theirRead = max(self?.theirRead ?? 0, time + 1)
        }
        guard let answer: SentMessage = Self.decode(["message_id": sent["message_id"] ?? NSNull(), "timestamp_ms": sent["timestamp_ms"] ?? NSNull()]) else {
            throw URLError(.cannotParseResponse)
        }
        return answer
    }

    private func message(_ content: [String: Any], from sender: String, at time: Int64) -> [String: Any] {
        made += 1
        var message = content
        message["id"] = "stand-in-\(made)"
        message["message_id"] = "stand-in-\(made)"
        message["timestamp_ms"] = String(time)
        message["sender_fbid"] = sender
        message["offline_threading_id"] = "9\(made)"
        return message
    }

    /// One message's content, of the kinds a conversation has, in about the proportions it has them.
    private func content() -> [String: Any] {
        let roll = random.next(in: 0...99)
        var message: [String: Any]
        switch roll {
        case 0..<50:
            message = text(Words.short[random.next(in: 0...(Words.short.count - 1))])
        case 50..<66:
            let sentences = (0..<random.next(in: 2...7)).map { _ in Words.long[random.next(in: 0...(Words.long.count - 1))] }
            message = text(sentences.joined(separator: " "))
        case 66..<78:
            let pictures = (0..<(roll == 77 ? 3 : 1)).map { _ in Pictures.all[random.next(in: 0...(Pictures.all.count - 1))] }
            message = photos(pictures.map { attachment($0.url.absoluteString, preview: $0.url.absoluteString, width: $0.width, height: $0.height) })
        case 78..<88:
            let picture = Pictures.all[random.next(in: 0...(Pictures.all.count - 1))]
            let card: [String: Any] = [
                "header_title_text": "stand_in_account", "header_icon": ["url": Pictures.avatar.absoluteString],
                "preview_image": ["url": picture.url.absoluteString, "width": picture.width, "height": picture.height] as [String: Any],
                // No link: a tap on it asks nothing of Instagram.
            ]
            let caption = Words.long[random.next(in: 0...(Words.long.count - 1))]
            message = ["content_type": "MESSAGE_INLINE_SHARE", "content": ["__typename": "SlideMessageXMAContent", "xma": card, "xma_text_body": caption] as [String: Any]]
        case 88..<92:
            message = voice(seconds: random.next(in: 2...40))
        case 92..<95:
            let picture = Pictures.all[random.next(in: 0...(Pictures.all.count - 1))]
            let card: [String: Any] = [
                "is_quoted": true,
                "preview_image": ["url": picture.url.absoluteString, "width": picture.width, "height": picture.height] as [String: Any],
            ]
            message = ["content_type": "MONTAGE_SHARE_XMA", "text_body": roll == 94 ? "😂" : Words.short[random.next(in: 0...(Words.short.count - 1))],
                       "content": ["__typename": "SlideMessageXMAContent", "xma": card] as [String: Any]]
        case 95..<97:
            message = ["content_type": "RAVEN_IMAGE", "content": ["__typename": "SlideMessageRavenImageContent"]]
        case 97:
            let line: [String: Any] = ["__typename": "SlideMessageAdminText", "text_fragments": [["plaintext": "Stand In changed the theme."]]]
            message = ["content_type": "ADMIN_TEXT", "content": line]
        default:
            message = ["content_type": "SOMETHING_NEW", "content": ["__typename": "SlideMessageSomethingNew"]]
        }
        if random.next(in: 0...99) < 9 {
            message["reactions"] = [["reaction": "\u{2764}", "sender_fbid": people[0].id]]
        }
        return message
    }

    private func text(_ body: String) -> [String: Any] {
        ["content_type": "TEXT", "text_body": body, "content": ["__typename": "SlideMessageText"]]
    }

    private func voice(seconds: Int) -> [String: Any] {
        let sound: [String: Any] = [
            "attachment_cdn_url": Pictures.tone.absoluteString, "playable_duration_ms": seconds * 1000,
            "waveform_data": (0..<64).map { abs(sin(Double($0 + seconds) * 0.6)) * 0.8 + 0.1 },
        ]
        return ["content_type": "AUDIO", "content": ["__typename": "SlideMessageAudioContent", "audio_attachments": [sound]] as [String: Any]]
    }

    private func photos(_ attachments: [[String: Any]]) -> [String: Any] {
        ["content_type": "IMAGES", "content": ["__typename": "SlideMessageImageContent", "attachments": attachments] as [String: Any]]
    }

    private func attachment(_ link: String, preview: String, width: Int, height: Int) -> [String: Any] {
        ["attachment_cdn_url": link, "preview_cdn_url": preview, "preview_width": width, "preview_height": height]
    }

    private var empty: DirectThread {
        Self.decode(["thread_fbid": "stand-in"])!
    }

    /// The conversation with its latest messages, newest first, as Instagram's answer has it.
    /// `short`: as the inbox has them, without what only the conversation's own copy carries.
    private func thread(messages count: Int, short: Bool) -> DirectThread? {
        let start = max(messages.count - count, 0)
        var page = connection(start..<messages.count)
        if short {
            page["edges"] = (page["edges"] as? [[String: Any]] ?? []).map { edge -> [String: Any] in
                var node = edge["node"] as? [String: Any] ?? [:]
                node["message_id"] = nil
                node["offline_threading_id"] = nil
                return ["node": node]
            }
        }
        return Self.decode([
            "thread_fbid": "stand-in", "thread_id": "stand-in-long", "thread_key": "stand-in",
            "thread_title": people.count > 1 ? "Stand-ins" as Any : NSNull(), "is_group": people.count > 1,
            "last_activity_timestamp_ms": messages.last?["timestamp_ms"] ?? "0",
            "viewer": ["interop_messaging_user_fbid": Self.me],
            "users": people.map { ["id": "stand-in-user-\($0.id)", "username": $0.username, "full_name": $0.name,
                                   "profile_pic_url": Pictures.avatar.absoluteString, "interop_messaging_user_fbid": $0.id] },
            "slide_messages": page,
            "slide_read_receipts": [["participant_fbid": Self.me, "watermark_timestamp_ms": String(myRead)]]
                + people.map { ["participant_fbid": $0.id, "watermark_timestamp_ms": String(theirRead)] },
        ] as [String: Any])
    }

    /// A page of messages, newest first, and where the page before it starts.
    private func connection(_ range: Range<Int>) -> [String: Any] {
        [
            "edges": messages[range].reversed().map { ["node": $0] },
            "page_info": ["end_cursor": String(range.lowerBound), "has_next_page": range.lowerBound > 0] as [String: Any],
        ]
    }

    private static func decode<T: Decodable>(_ json: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? InstagramAPI.decodeSaved(T.self, from: data)
    }

    /// The same made-up conversation at every launch.
    private struct Generator {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(in range: ClosedRange<Int>) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return range.lowerBound + Int(z % UInt64(range.count))
        }
    }

    private enum Words {
        static let short = [
            "ok", "On my way", "Did you see this?", "haha", "Sounds good", "What time?", "Almost there",
            "Call me when you can", "No way", "See you tomorrow then", "👍", "That was quick",
            "I'll bring the keys", "Where are you parked?", "Thanks for today",
        ]
        static let long = [
            "The train was late again, so I walked the last part along the river.",
            "We could meet at the market around ten and decide from there.",
            "I looked for the book you mentioned but the shop had already closed.",
            "It rained all morning and then cleared up just as we were leaving.",
            "Let me know if the others are coming, I can book a bigger table.",
            "The photos from the weekend turned out better than I expected.",
            "I think the second option is simpler, and it leaves the evening free.",
        ]
    }

    /// The stand-in's pictures and sound, made on the phone and put where downloaded ones would
    /// be, under addresses that lead nowhere: they show without a request to anyone.
    enum Pictures {
        struct Picture {
            let url: URL
            let width: Int
            let height: Int
        }

        static let all: [Picture] = [(1080, 1350), (1080, 1080), (1080, 608), (1080, 1920)].flatMap { width, height in
            (0..<5).map { Picture(url: URL(string: "https://stand-in.invalid/picture-\(width)x\(height)-\($0).jpg")!, width: width, height: height) }
        }

        static let avatar = URL(string: "https://stand-in.invalid/avatar.jpg")!
        static let tone = URL.cachesDirectory.appending(path: "stand-in-tone.wav")

        static func makeIfMissing() {
            for (index, picture) in all.enumerated() where !ImageFiles.shared.contains(picture.url) {
                if let data = drawn(width: picture.width, height: picture.height, number: index) { ImageFiles.shared.keep(data, for: picture.url) }
            }
            if !ImageFiles.shared.contains(avatar), let data = drawn(width: 320, height: 320, number: 99) {
                ImageFiles.shared.keep(data, for: avatar)
            }
            if !FileManager.default.fileExists(atPath: tone.path) { try? sine(seconds: 3).write(to: tone) }
        }

        /// A picture with enough in it to take a photo's time to decode.
        private static func drawn(width: Int, height: Int, number: Int) -> Data? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let size = CGSize(width: width, height: height)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let hue = CGFloat(number % 20) / 20
                let colors = [UIColor(hue: hue, saturation: 0.5, brightness: 0.9, alpha: 1).cgColor,
                              UIColor(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.5, alpha: 1).cgColor]
                if let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil) {
                    context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                }
                for step in 0..<220 {
                    let x = CGFloat((step * 7919 + number * 31) % width), y = CGFloat((step * 6007 + number * 17) % height)
                    UIColor(white: step.isMultiple(of: 2) ? 1 : 0, alpha: 0.12).setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: x, y: y, width: CGFloat(20 + step % 90), height: CGFloat(20 + step % 90)))
                }
                let text = "\(number)" as NSString
                text.draw(at: CGPoint(x: 40, y: 30), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 180), .foregroundColor: UIColor.white])
            }
            return image.jpegData(compressionQuality: 0.85)
        }

        /// A quiet tone as a WAV file, for voice messages to play.
        private static func sine(seconds: Int) -> Data {
            let rate = 16_000
            var samples = Data(capacity: rate * seconds * 2)
            for index in 0..<(rate * seconds) {
                let value = Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 6000)
                withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
            }
            var file = Data()
            func add<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
            file.append(contentsOf: Array("RIFF".utf8)); add(UInt32(36 + samples.count)); file.append(contentsOf: Array("WAVEfmt ".utf8))
            add(UInt32(16)); add(UInt16(1)); add(UInt16(1)); add(UInt32(rate)); add(UInt32(rate * 2)); add(UInt16(2)); add(UInt16(16))
            file.append(contentsOf: Array("data".utf8)); add(UInt32(samples.count))
            return file + samples
        }
    }
}

/// -frameMeter YES: counts the frames the main thread was late for, and logs the count every
/// five seconds in which there were any frames. A scripted scroll through the stand-in
/// conversation gives the same number to compare from one build to the next.
@MainActor
final class FrameMeter: NSObject {
    static let shared = FrameMeter()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var frames = 0
    private var late = 0
    private var lateTime: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0

    static func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: "frameMeter"), shared.link == nil else { return }
        let link = CADisplayLink(target: shared, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        shared.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { return started = now }
        let frame = link.targetTimestamp - link.timestamp
        let took = now - last
        frames += 1
        if took > frame * 1.5 {
            late += 1
            lateTime += took - frame
        }
        worst = max(worst, took)
        guard now - started >= 5, !isHeld else { return }
        report("frameMeter")
    }

    /// While a script runs, the count waits for the script's own report.
    private var isHeld = false

    func startCount() {
        isHeld = true
        (started, frames, late, lateTime, worst) = (last, 0, 0, 0, 0)
    }

    func report(_ name: String) {
        NetworkRecorder.append(["time": Date().ISO8601Format(), name: [
            "frames": frames, "late": late, "lateMs": Int(lateTime * 1000), "worstMs": Int(worst * 1000),
        ]])
        isHeld = false
        (started, frames, late, lateTime, worst) = (last, 0, 0, 0, 0)
    }
}

/// -standInScroll YES (with -frameMeter YES): three seconds after a conversation opens, scrolls
/// it up at a fling's pace for six seconds, as far as the messages loaded by then go, and back
/// down for six; then logs the frames that came late meanwhile, as `scrollScript`. The same
/// motion at every run, whatever the list is made of, to compare one build with another.
@MainActor
enum ScrollScript {
    private static var started = false

    /// For a list that holds itself at the end of the conversation: lets go of it, as a finger would.
    static var releaseFromEnd: ((UIScrollView) -> Void)?
    private static var largestRowInset: CGFloat = 0

    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "standInScroll"), !started else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let list = listOnScreen() else { return }
            FrameMeter.shared.startCount()
            let up = await move(list, by: -3000, for: 6)
            try? await Task.sleep(for: .seconds(1))
            let down = await move(list, by: 3000, for: 6)
            FrameMeter.shared.report("scrollScript")
            // Then slowly, a third of a point at a time, so that every row's edge passes every
            // place on the way: a row that asks for another height depending on where it is
            // would show here.
            let slowly = await move(list, by: -20, for: 12)
            NetworkRecorder.append(["time": Date().ISO8601Format(), "scrolled": [
                "up": Int(up), "down": Int(down), "slowly": Int(slowly), "largestRowInset": Double(largestRowInset),
            ]])
        }
    }

    /// Moves the list `speed` points a second for `seconds`, a step at every frame, within what
    /// it has to show. Returns how far it went.
    private static func move(_ list: UIScrollView, by speed: CGFloat, for seconds: Double) async -> CGFloat {
        let ticker = Ticker()
        var travelled: CGFloat = 0
        var last = CACurrentMediaTime()
        let end = last + seconds
        while last < end {
            await ticker.next()
            let now = CACurrentMediaTime()
            let top = -list.adjustedContentInset.top
            let bottom = max(list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height, top)
            let target = min(max(list.contentOffset.y + speed * CGFloat(now - last), top), bottom)
            travelled += abs(target - list.contentOffset.y)
            releaseFromEnd?(list)
            list.contentOffset.y = target
            last = now
            // No row is ever to be told that part of it is outside the screen's safe part.
            for cell in (list as? UICollectionView)?.visibleCells ?? [] {
                largestRowInset = max(largestRowInset, cell.safeAreaInsets.top, cell.safeAreaInsets.bottom)
            }
        }
        ticker.stop()
        return travelled
    }

    /// The list under the middle of the screen.
    private static func listOnScreen() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) else { return nil }
        var view = window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: nil)
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.bounds.height > 300 { return scroll }
            view = current.superview
        }
        return nil
    }

    /// One step per frame.
    private final class Ticker: NSObject {
        private var link: CADisplayLink?
        private var waiting: CheckedContinuation<Void, Never>?

        func next() async {
            if link == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            await withCheckedContinuation { waiting = $0 }
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            waiting?.resume()
            waiting = nil
        }
    }
}
#endif
