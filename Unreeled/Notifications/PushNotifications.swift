import SwiftUI
import UserNotifications

/// Instagram's notifications on this phone while Unreeled is closed (docs/NOTIFICATIONS.md).
///
/// Turning them on makes keys that stay on this phone (PushKeys), pairs the phone with the relay
/// to get a push address (PushRelay), and registers that address and the public key with
/// Instagram from your own login, as the website does for a browser. Instagram then encrypts
/// each notification for this phone and sends it to that address; the relay passes it on
/// through Apple, and the notification extension decrypts it.
///
/// Nothing happens unless you turn them on, and logging out undoes all of it.
@MainActor
@Observable
final class PushNotifications: NSObject {
    static let shared = PushNotifications()

    /// Whether this build can have notifications: it was made with a relay.
    static var isOffered: Bool { PushRelay.configured != nil }
    /// Whether the app has asked about notifications, once, after logging in.
    static let askedKey = "notificationsAsked"

    /// What turning notifications on left with the relay and with Instagram.
    struct Registration: Codable {
        /// The relay's name for this phone.
        var deviceID: String
        /// The relay that has it, by its address: where it's retired. Nil only in one carried
        /// over by a build without a relay.
        var relay: String?
        /// The push address Instagram sends to.
        var endpoint: String
        /// The login it was registered from.
        var userID: String
        /// This phone's address at Apple, as the relay has it.
        var appleToken: String
        /// When notifications were turned on.
        var since: Date
        /// When Instagram last took the address.
        var registeredAt: Date
        /// When the relay last confirmed the address.
        var checkedAt: Date?
        /// When this build took it over from a build before 14 November 2026, which kept it in
        /// UserDefaults: what that build left in its notifications is trusted, as it trusted it,
        /// in those delivered before then (see `routing(of:)`).
        var carriedOverAt: Date?
        /// Debug builds: made in a dry run, so Instagram never had it.
        var isDryRun: Bool?

        /// Where it's retired.
        var record: RelayRecord { RelayRecord(deviceID: deviceID, relay: relay ?? PushRelay.configured?.address) }
    }

    /// The relay's record of this phone, as the app keeps it to retire it: the relay's name for
    /// the phone, and the relay's address.
    struct RelayRecord: Codable, Equatable {
        let deviceID: String
        let relay: String?
    }

    /// Kept in the Keychain (PushStore), where it stays on this phone.
    private(set) var registration: Registration? {
        didSet { Self.keep(registration) }
    }
    /// False once you've refused notifications for Unreeled in iOS, or switched them off there.
    private(set) var isAllowed = true
    private(set) var isWorking = false
    private var isRefreshing = false
    private var isRetiring = false
    /// Why turning them on didn't work, in words for the screen.
    private(set) var failure: String?

    /// A notification you tapped, until the app has opened what it's about.
    var opened: InstagramPush.Routing?
    /// Goes up when a notification arrives while the app is open, for screens to look again.
    private(set) var arrivals = 0
    /// The IDs of the conversation on screen: its notifications don't show on top of it, and
    /// those already in Notification Centre go, since it shows their messages itself.
    var visibleThread: Set<String> = [] {
        didSet { if visibleThread != oldValue { clearDelivered(threads: visibleThread) } }
    }

    var isOn: Bool { registration != nil }

    /// Where builds before 14 November 2026 kept the registration and the pairings to retire:
    /// UserDefaults, which go into the phone's backups. Read once, to carry them over.
    private static let registrationKey = "pushRegistration"
    private static let retiredKey = "pushRetired"
    /// Their names in the Keychain (PushStore), with the pairings just made, until they're in
    /// the registration or retired.
    private static let registrationItem = "registration"
    private static let retiredItem = "retired"
    private static let pendingItem = "pending"
    /// Instagram is given the address again this often, in case it dropped it.
    private static let reassertInterval: TimeInterval = 7 * 24 * 3600
    /// The relay is asked this often whether the address is still the one it has: after it
    /// lost its records, or Mozilla its channels, the phone has a new one.
    private static let checkInterval: TimeInterval = 24 * 3600

    private override init() {
        let found = PushStore.read(Self.registrationItem)
        var kept: Registration?
        // One this build can't read, as a later build might write.
        var unreadable: Leftover?
        if case .found(let data) = found {
            kept = try? JSONDecoder().decode(Registration.self, from: data)
            if kept == nil { unreadable = try? JSONDecoder().decode(Leftover.self, from: data) }
        }
        // Where builds before 14 November 2026 kept it. One there with another pairing than the
        // Keychain's is the newer: such a build ran since, and turned notifications on again.
        let earlier = UserDefaults.standard.data(forKey: Self.registrationKey)
            .flatMap { try? JSONDecoder().decode(Registration.self, from: $0) }
            .flatMap { $0.deviceID == kept?.deviceID ? nil : $0 }
        registration = earlier ?? kept
        super.init()
        // The phone hasn't been unlocked since it started: nothing is changed on what can't be
        // read yet.
        if case .locked = found { return }

        if let unreadable {
            // Notifications are off as far as this build can tell, so the relay forgets the phone.
            retire(RelayRecord(deviceID: unreadable.deviceID, relay: unreadable.relay ?? PushRelay.configured?.address))
            PushStore.write(nil, Self.registrationItem)
        }
        if earlier != nil, let kept {
            // Replaced by the earlier build's, and of no use without the keys it had.
            retire(kept.record)
        }
        if let stored = registration, PushKeys.areGone {
            // From UserDefaults, the keys didn't come along, as on a phone restored from a backup:
            // the old phone, if it's still in use, keeps its pairing. From the Keychain, which
            // stays on this phone, the pairing is this phone's, and of no use without its keys.
            if earlier == nil { retire(stored.record) }
            registration = nil
            // didSet doesn't run in an initializer, so the Keychain and UserDefaults are told here.
            Self.keep(nil)
        } else if registration == nil {
            // The Keychain outlives a deleted app.
            PushKeys.delete()
        } else if var carried = earlier {
            // Into the Keychain, with the relay this build has, which made it as far as can be
            // known. UserDefaults keep it until the Keychain has it.
            carried.relay = carried.relay ?? PushRelay.configured?.address
            carried.carriedOverAt = .now
            registration = carried
            // didSet doesn't run in an initializer: written to the Keychain here, at the first
            // launch, so that carriedOverAt stays the time of the update.
            Self.keep(carried)
        } else {
            // A copy of the Keychain's that UserDefaults still had.
            UserDefaults.standard.removeObject(forKey: Self.registrationKey)
        }

        // Pairings to retire that an earlier build kept, by name only: made with this build's
        // relay too, as far as can be known.
        if let names = UserDefaults.standard.stringArray(forKey: Self.retiredKey) {
            let waiting = Self.records(Self.retiredItem)
            let carried = names.map { RelayRecord(deviceID: $0, relay: PushRelay.configured?.address) }
            if Self.keep(waiting + carried.filter { !waiting.contains($0) }, as: Self.retiredItem) {
                UserDefaults.standard.removeObject(forKey: Self.retiredKey)
            }
        }
        // Pairings that a launch which ended early made but neither kept nor retired.
        let held = Self.records(Self.pendingItem)
        if !held.isEmpty {
            let waiting = Self.records(Self.retiredItem)
            let left = held.filter { $0.deviceID != registration?.deviceID && !waiting.contains($0) }
            if Self.keep(waiting + left, as: Self.retiredItem) { Self.keep([], as: Self.pendingItem) }
        }
    }

    /// What can be read of a registration this build can't decode: enough to retire it.
    private struct Leftover: Decodable {
        let deviceID: String
        let relay: String?
    }

    // MARK: On and off

    /// Turns notifications on, after iOS has asked whether Unreeled may show them. True when
    /// the question is settled: they're on, or iOS said no. False with `failure` set otherwise.
    func turnOn(api: InstagramAPI, userID: String) async -> Bool {
        guard let relay = PushRelay.configured, !isWorking else { return false }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            isAllowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard isAllowed else { return true }
            let token = try await appleToken()
            let pairing = try await relay.pair(appleToken: token, deviceID: nil)
            let made = RelayRecord(deviceID: pairing.deviceId, relay: relay.address)
            // Kept at once: if the app ends before it's saved below, the next launch retires it.
            Self.hold(made)
            do {
                let keys = try PushKeys.create()
                try await register(pairing.endpoint, keys: keys, api: api)
            } catch {
                // No keys, or Instagram didn't take the address: leave nothing behind.
                PushKeys.delete()
                abandon(made)
                throw error
            }
            registration = Registration(
                deviceID: pairing.deviceId, relay: relay.address, endpoint: pairing.endpoint, userID: userID,
                appleToken: token, since: .now, registeredAt: .now, checkedAt: .now
            )
            Self.release(made)
            #if DEBUG
            if Self.isDryRun { registration?.isDryRun = true }
            #endif
            return true
        } catch {
            failure = Self.describe(error)
            return false
        }
    }

    /// The page that asks is on screen again: what went wrong last time is old news.
    func forgetFailure() {
        failure = nil
    }

    /// Turns notifications off: the keys are deleted, so nothing sent from now on can be read,
    /// and the relay is told to forget this phone. Instagram has no call to take an address
    /// back; it stops sending once the address stops answering. The notifications already shown
    /// go too: what they quote is this login's. Logging out comes here, by any route.
    func turnOff() async {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        guard let registration else {
            // Off already, as while logged out: a relay that couldn't be reached last time is
            // asked again.
            return retire()
        }
        failure = nil
        self.registration = nil
        PushKeys.delete()
        retire(registration.record)
    }

    /// At launch and when the app comes back: keeps what was turned on working. The relay is
    /// told this phone's address at Apple when it has changed, and otherwise asked once a day
    /// whether the push address still stands. Instagram is given the push address again when
    /// it has changed or a week has passed.
    func refresh(api: InstagramAPI, userID: String) async {
        retire()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAllowed = settings.authorizationStatus != .denied
        guard var registration, !isWorking, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard registration.userID == userID else {
            // Another login: its notifications aren't this one's.
            return await turnOff()
        }
        #if DEBUG
        // What a dry run left must never reach Instagram from a launch that isn't one.
        if registration.isDryRun == true, !Self.isDryRun { return await turnOff() }
        #endif
        guard isAllowed, let relay = PushRelay.configured, let keys = PushKeys.load() else { return }
        // Paired with a relay this build doesn't use: it pairs with its own now, and leaves the other.
        let hasMoved = registration.record.relay != relay.address
        // A pairing made here, until it's saved or retired.
        var made: RelayRecord?
        do {
            let token = try await appleToken()
            // Whenever the app waits, notifications can be turned off, or off and on again: then
            // what was copied above isn't this phone's any more, and nothing is done with it.
            guard isCurrent(registration) else { return }
            let isDue = Date.now.timeIntervalSince(registration.registeredAt) > Self.reassertInterval
            let isUnchecked = Date.now.timeIntervalSince(registration.checkedAt ?? .distantPast) > Self.checkInterval
            guard token != registration.appleToken || isUnchecked || isDue || hasMoved else { return }
            let pairing = try await relay.pair(appleToken: token, deviceID: hasMoved ? nil : registration.deviceID)
            if hasMoved || pairing.deviceId != registration.deviceID {
                // A new one, as when the relay had lost its record: kept before anything else, so
                // that if the app ends first, the next launch retires it.
                let record = RelayRecord(deviceID: pairing.deviceId, relay: relay.address)
                Self.hold(record)
                made = record
            }
            guard isCurrent(registration) else { return abandon(made) }
            if pairing.endpoint != registration.endpoint || isDue {
                try await register(pairing.endpoint, keys: keys, api: api)
                registration.registeredAt = .now
                guard isCurrent(registration) else { return abandon(made) }
            }
            let replaced = registration.record
            registration.deviceID = pairing.deviceId
            registration.relay = relay.address
            registration.endpoint = pairing.endpoint
            registration.appleToken = token
            registration.checkedAt = .now
            self.registration = registration
            if let made {
                Self.release(made)
                // The record it replaces is retired where it was made.
                retire(replaced)
            }
        } catch {
            // Next time. A pairing made meanwhile is retired, so none is left that nothing names.
            abandon(made)
        }
    }

    /// Whether `copy` is still the registration, after the app waited.
    private func isCurrent(_ copy: Registration) -> Bool {
        registration?.deviceID == copy.deviceID
    }

    /// Gives Instagram the push address and this phone's public key and `auth`, from your login.
    private func register(_ endpoint: String, keys: PushKeys, api: InstagramAPI) async throws {
        #if DEBUG
        if Self.isDryRun {
            // What Instagram would have been given, for relay/tools/sample-push.mjs to send to.
            let would = ["endpoint": endpoint, "keys": ["p256dh": keys.p256dh, "auth": keys.authString]] as [String: Any]
            try? JSONSerialization.data(withJSONObject: would).write(to: Self.dryRunURL)
            return
        }
        #endif
        try await api.registerWebPush(endpoint: endpoint, p256dh: keys.p256dh, auth: keys.authString)
    }

    #if DEBUG
    /// Debug builds launched with -pushDryRun YES do everything but register with Instagram, to
    /// try the screens, the relay and the extension without writing to an account. What would
    /// have been registered is written to Library/Caches/push-dry-run.json instead.
    private static var isDryRun: Bool { UserDefaults.standard.bool(forKey: "pushDryRun") }
    private static let dryRunURL = URL.cachesDirectory.appending(path: "push-dry-run.json")
    #endif

    // MARK: Leaving the relay

    /// Tells relays to forget the phones this one was, now and at each launch and return to the
    /// app until each has answered, logged in or not: a relay that can't be reached when you log
    /// out mustn't keep sending here. Each is told at the relay that made it, which may not be
    /// this build's.
    private func retire(_ record: RelayRecord? = nil) {
        var waiting = Self.records(Self.retiredItem)
        if let record, !waiting.contains(record) {
            waiting.append(record)
            Self.keep(waiting, as: Self.retiredItem)
        }
        // A round already under way gets to what was just added.
        guard !waiting.isEmpty, !isRetiring else { return }
        isRetiring = true
        Task {
            defer { isRetiring = false }
            var asked: [RelayRecord] = []
            while let record = Self.records(Self.retiredItem).first(where: { !asked.contains($0) }) {
                asked.append(record)
                guard let relay = PushRelay.at(record.relay),
                      (try? await relay.unpair(deviceID: record.deviceID)) != nil
                else { continue }
                Self.keep(Self.records(Self.retiredItem).filter { $0 != record }, as: Self.retiredItem)
            }
        }
    }

    /// A pairing just made, kept until it's in the registration or retired.
    private static func hold(_ record: RelayRecord) {
        keep(records(pendingItem) + [record], as: pendingItem)
    }

    private static func release(_ record: RelayRecord) {
        keep(records(pendingItem).filter { $0 != record }, as: pendingItem)
    }

    /// A pairing made for nothing: retired, and no longer held.
    private func abandon(_ record: RelayRecord?) {
        guard let record else { return }
        retire(record)
        Self.release(record)
    }

    // MARK: Kept in the Keychain

    private static func records(_ name: String) -> [RelayRecord] {
        guard case .found(let data) = PushStore.read(name) else { return [] }
        return (try? JSONDecoder().decode([RelayRecord].self, from: data)) ?? []
    }

    @discardableResult
    private static func keep(_ records: [RelayRecord], as name: String) -> Bool {
        PushStore.write(records.isEmpty ? nil : (try? JSONEncoder().encode(records)), name)
    }

    /// Once the Keychain has the registration, the copy an earlier build kept in UserDefaults
    /// goes. Turned off, it goes in any case, so that it can't come back.
    private static func keep(_ registration: Registration?) {
        let isKept = PushStore.write(registration.flatMap { try? JSONEncoder().encode($0) }, registrationItem)
        if isKept || registration == nil { UserDefaults.standard.removeObject(forKey: registrationKey) }
    }

    // MARK: This phone's address at Apple

    private var tokenWaiters: [CheckedContinuation<String, Error>] = []
    private var tokenRequests = 0

    /// Asks iOS for this phone's address at Apple's push service. It answers through the app
    /// delegate, or not at all in a build that isn't signed for push.
    private func appleToken() async throws -> String {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                tokenWaiters.append(continuation)
                guard tokenWaiters.count == 1 else { return }
                tokenRequests += 1
                let request = tokenRequests
                UIApplication.shared.registerForRemoteNotifications()
                Task {
                    // No answer at all: give up, unless a later request is the one waiting now.
                    try? await Task.sleep(for: .seconds(12))
                    if request == tokenRequests { answerToken(.failure(Failure.noAppleToken)) }
                }
            }
        } catch {
            #if DEBUG
            // A simulator that can't reach Apple still gets through a dry run.
            if Self.isDryRun { return String(repeating: "0", count: 64) }
            #endif
            throw error
        }
    }

    fileprivate func answerToken(_ result: Result<String, Error>) {
        let waiting = tokenWaiters
        tokenWaiters = []
        for continuation in waiting { continuation.resume(with: result) }
    }

    // MARK: Words for what went wrong

    enum Failure: Error {
        case noAppleToken
        /// A reply with no conversation it can go to.
        case noConversation
        /// A reply Instagram hadn't confirmed in time.
        case timedOut
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case Failure.noAppleToken:
            "Apple didn't give this phone an address for notifications. This build may not be signed for them."
        case PushRelay.Failure.unreachable:
            "Couldn't reach Unreeled's relay. Check your connection and try again."
        case PushRelay.Failure.refused(let status):
            "Unreeled's relay didn't accept this phone (\(status))."
        case is PushKeys.Failure:
            "Couldn't keep the keys for notifications on this phone."
        default:
            error.localizedDescription
        }
    }
}

// MARK: - What iOS tells the app

extension PushNotifications: UNUserNotificationCenterDelegate {
    /// A notification arrived while the app is open. It shows, unless it's about the
    /// conversation on screen, which shows the message itself.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        #if DEBUG
        // `xcrun simctl push` puts a push straight into Notification Centre without running the
        // extension. Debug builds do the extension's work here and show the result in its
        // place, so the whole path after Apple can be tried in the simulator. (What the
        // extension did show keeps the push too, beside what it wrote.)
        if notification.request.content.userInfo[InstagramPush.envelopeKey] != nil,
           notification.request.content.userInfo[InstagramPush.routingKey] == nil,
           let content = notification.request.content.mutableCopy() as? UNMutableNotificationContent,
           InstagramPush.rewrite(content) != nil {
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return completionHandler([])
        }
        #endif
        Task { @MainActor in
            arrivals += 1
            if let thread = routing(of: notification)?.threadID, visibleThread.contains(thread) {
                completionHandler([])
            } else {
                completionHandler([.banner, .list, .sound])
            }
        }
    }

    /// You tapped a notification, or answered a message with Reply.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notification = response.notification
        let isTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let reply = response.actionIdentifier == InstagramPush.replyAction ? (response as? UNTextInputNotificationResponse)?.userText : nil
        Task { @MainActor in
            let routing = routing(of: notification)
            if isTap, let routing, isForThisLogin(routing) { opened = routing }
            if let reply { await answer(reply, to: routing, conversation: notification.request.content.title) }
            completionHandler()
        }
    }

    /// What a notification is about (InstagramPush.Routing). What a build before this one wrote
    /// counts only in a notification delivered before this build took over: one delivered since
    /// can't be that build's.
    private func routing(of notification: UNNotification) -> InstagramPush.Routing? {
        guard let routing = InstagramPush.Routing(notification) else { return nil }
        if case .earlierBuild(let delivered) = routing.source {
            guard let carriedOverAt = registration?.carriedOverAt, delivered < carriedOverAt else { return nil }
        }
        return routing
    }

    /// Whether a notification is for the login now: the one the app wrote it for, or for one
    /// from a push, the one notifications were turned on from, whose keys read it.
    private func isForThisLogin(_ routing: InstagramPush.Routing) -> Bool {
        guard let userID = Session.shared.userID else { return false }
        return (routing.account ?? registration?.userID) == userID
    }
}

// MARK: - Replying from a notification

extension PushNotifications {
    /// What a message's notification offers when you press it, or open it on a Mac that shows
    /// the iPhone's notifications: Reply, which sends what you type without opening the app.
    static let categories: Set<UNNotificationCategory> = [
        UNNotificationCategory(
            identifier: InstagramPush.messageCategory,
            actions: [
                UNTextInputNotificationAction(
                    identifier: InstagramPush.replyAction,
                    title: "Reply",
                    options: [],
                    icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Message…"
                ),
            ],
            intentIdentifiers: [],
            options: []
        ),
    ]

    /// Reply on a notification. It goes only to the conversation the push or the app named, as
    /// the notification shows it, and only from the login it's for: never to a conversation the
    /// relay could have chosen, and never from another login.
    private func answer(_ reply: String, to routing: InstagramPush.Routing?, conversation: String) async {
        // Another login's, or nobody's: it isn't sent, and nothing it said is shown again.
        if let routing, !isForThisLogin(routing) { return }
        let threadID = routing.flatMap { $0.isAnswerable && $0.isDirect ? $0.threadID : nil }
        await send(reply: reply, threadID: threadID, conversation: conversation)
    }

    /// Sends a reply typed in a notification. iOS may have woken the app in the background for
    /// it: it keeps running until Instagram has the message. When the reply doesn't go, a
    /// notification says so, with Reply again, and a tap opens the conversation.
    func send(reply: String, threadID: String?, conversation: String) async {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nobody to send it from, logged out since: nothing it said is shown again either.
        guard !text.isEmpty, Session.shared.isLoggedIn else { return }
        let notice = "unsent-\(UUID().uuidString)"
        let time = BackgroundTime("Reply") { [weak self] in
            // iOS stops the app before Instagram answered: the request stops too, as below.
            Session.shared.api.abandonRequests()
            self?.sayUnsent(text, threadID: threadID, conversation: conversation, id: notice, certain: false)
        }
        defer { time.end() }
        do {
            guard let threadID else { throw Failure.noConversation }
            let api = Session.shared.api
            // An app woken for a notification gets seconds, not minutes, and a weak connection
            // can take longer than that.
            try await within(seconds: 20) {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "replyDryRun") {
                    // Debug builds with replyDryRun set send nothing: a request that only reads
                    // goes the same way instead, to try replying without writing to an account.
                    NetworkRecorder.append(["time": Date().ISO8601Format(), "replyDryRun": ["characters": text.count, "thread": threadID]])
                    _ = try await api.activity()
                    NetworkRecorder.append(["time": Date().ISO8601Format(), "replyDryRunDone": true])
                    return
                }
                #endif
                _ = try await api.send(text, threadID: threadID)
            }
            // In case the slower notice above showed meanwhile.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notice])
            // The inbox and an open conversation look again.
            arrivals += 1
        } catch Failure.timedOut {
            // Out of time: whatever was being sent stops here, and isn't tried again later, rather
            // than going out hours later when the app next runs.
            if UIApplication.shared.applicationState != .active { Session.shared.api.abandonRequests() }
            sayUnsent(text, threadID: threadID, conversation: conversation, id: notice, certain: false)
        } catch {
            sayUnsent(text, threadID: threadID, conversation: conversation, id: notice, certain: true)
        }
    }

    /// `work`, unless it takes longer than `seconds`: then `Failure.timedOut`, and `work` is
    /// left to finish unwatched.
    private func within(seconds: Double, _ work: @escaping @MainActor () async throws -> Void) async throws {
        let outcome = Outcome()
        try await withCheckedThrowingContinuation { continuation in
            outcome.continuation = continuation
            Task { @MainActor in
                do {
                    try await work()
                    outcome.settle(.success(()))
                } catch {
                    outcome.settle(.failure(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                outcome.settle(.failure(Failure.timedOut))
            }
        }
    }

    #if DEBUG
    /// Debug builds with both `replyTest` and `replyDryRun` set in the app's defaults reply to a
    /// stand-in conversation each time the app goes to the background, as a notification's Reply
    /// would: iOS's own Reply can't be pressed from a script in the simulator. The dry run means
    /// nothing is sent. Also logs the notification categories iOS has for the app.
    func startReplyTest() {
        Task {
            let categories = await UNUserNotificationCenter.current().notificationCategories()
            let described = categories.map { "\($0.identifier): \($0.actions.map(\.identifier).joined(separator: ","))" }
            NetworkRecorder.append(["time": Date().ISO8601Format(), "notificationCategories": described])
        }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "replyTest"), defaults.bool(forKey: "replyDryRun") else { return }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                _ = Task { await PushNotifications.shared.send(reply: "Dry run", threadID: "dry-run-thread", conversation: "Test conversation") }
            }
        }
    }
    #endif

    /// A notification about a reply that didn't go, which offers Reply again.
    private func sayUnsent(_ text: String, threadID: String?, conversation: String, id: String, certain: Bool) {
        let content = UNMutableNotificationContent()
        content.title = conversation
        content.body = certain
            ? "Your reply wasn't sent: “\(text)”. Reply again, or open the conversation."
            : "Your reply may not have been sent: “\(text)”. Open the conversation to check."
        if let threadID {
            content.threadIdentifier = threadID
            // With the login it was sent from: Reply again answers only from that one.
            let routing = ["type": "direct_v2_text", "thread": threadID, "account": Session.shared.userID]
            content.userInfo[InstagramPush.routingKey] = routing.compactMapValues { $0 }
            content.categoryIdentifier = InstagramPush.messageCategory
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - Notifications already shown

extension PushNotifications {
    /// Takes a conversation's notifications out of Notification Centre: it's open, and shows
    /// their messages itself. `threads` are its IDs, in either of Instagram's two forms.
    func clearDelivered(threads: Set<String>) {
        guard !threads.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let shown = await center.deliveredNotifications()
            let ids = shown.filter { threads.contains($0.request.content.threadIdentifier) }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Takes back the notifications that quote these messages, ones their sender unsent, once
    /// the app has found them gone from their conversation. A notification knows its message by
    /// the ID Instagram's push gave it (`n`): one that doesn't match is left alone.
    func withdraw(messageIDs: Set<String>) {
        guard !messageIDs.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let shown = await center.deliveredNotifications()
            let ids = shown.filter { notification in
                let routing = notification.request.content.userInfo[InstagramPush.routingKey] as? [String: String]
                return routing?["message"].map(messageIDs.contains) == true
            }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}

/// Where PushNotifications keeps the relay's records of this phone: in the Keychain beside the
/// keys (PushKeys), and like them on this device only, readable once the phone has been
/// unlocked since it started. The relay's name for this phone is all it asks to forget the
/// phone, or to send its notifications to another, so it mustn't leave the phone in a backup,
/// as UserDefaults do.
private enum PushStore {
    enum Read {
        case found(Data)
        case missing
        /// Not now: the phone hasn't been unlocked since it started.
        case locked
    }

    static func read(_ name: String) -> Read {
        var query = item(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return (result as? Data).map(Read.found) ?? .missing
        case errSecItemNotFound: return .missing
        default: return .locked
        }
    }

    /// Replaces what's kept under `name`, or with nil removes it. False when the Keychain
    /// refused, which leaves what it had.
    @discardableResult
    static func write(_ data: Data?, _ name: String) -> Bool {
        let match = item(name)
        guard let data else {
            let status = SecItemDelete(match as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var new = match
        new[kSecValueData as String] = data
        new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(new as CFDictionary, nil) == errSecSuccess
    }

    /// Under the keys' service, by name: `registration`, `retired`, `pending`.
    private static func item(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "UnreeledPush", kSecAttrAccount as String: name]
    }
}

/// Whichever of a reply's send and its time limit finishes first.
@MainActor
private final class Outcome {
    var continuation: CheckedContinuation<Void, Error>?

    func settle(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Keeps the app running in the background until `end()`. If iOS needs it to stop first,
/// `expired` runs.
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String, expired: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // iOS calls this on the main thread.
            MainActor.assumeIsolated {
                expired()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// SwiftUI apps have no app delegate of their own, and iOS answers a request for the phone's
/// address at Apple only through one.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Before launch ends, so a tap that opened the app is heard, and a reply that woke it.
        UNUserNotificationCenter.current().delegate = PushNotifications.shared
        UNUserNotificationCenter.current().setNotificationCategories(PushNotifications.categories)
        #if DEBUG
        PushNotifications.shared.startReplyTest()
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.answerToken(.success(deviceToken.map { String(format: "%02x", $0) }.joined()))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.answerToken(.failure(PushNotifications.Failure.noAppleToken))
    }
}
