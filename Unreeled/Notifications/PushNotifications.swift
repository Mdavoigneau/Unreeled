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
        /// Debug builds: made in a dry run, so Instagram never had it.
        var isDryRun: Bool?
    }

    private(set) var registration: Registration? {
        didSet { UserDefaults.standard.set(registration.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.registrationKey) }
    }
    /// False once you've refused notifications for Unreeled in iOS, or switched them off there.
    private(set) var isAllowed = true
    private(set) var isWorking = false
    private var isRefreshing = false
    /// Why turning them on didn't work, in words for the screen.
    private(set) var failure: String?

    /// A notification you tapped, until the app has opened what it's about.
    var opened: InstagramPush.Routing?
    /// Goes up when a notification arrives while the app is open, for screens to look again.
    private(set) var arrivals = 0
    /// The IDs of the conversation on screen: its notifications don't show on top of it.
    var visibleThread: Set<String> = []

    var isOn: Bool { registration != nil }

    private static let registrationKey = "pushRegistration"
    private static let retiredKey = "pushRetired"
    /// Instagram is given the address again this often, in case it dropped it.
    private static let reassertInterval: TimeInterval = 7 * 24 * 3600
    /// The relay is asked this often whether the address is still the one it has: after it
    /// lost its records, or Mozilla its channels, the phone has a new one.
    private static let checkInterval: TimeInterval = 24 * 3600

    private override init() {
        registration = UserDefaults.standard.data(forKey: Self.registrationKey)
            .flatMap { try? JSONDecoder().decode(Registration.self, from: $0) }
        super.init()
        if registration != nil, PushKeys.areGone {
            // The keys didn't come along, as on a phone restored from a backup: the old phone,
            // if it's still in use, keeps its pairing.
            registration = nil
        } else if registration == nil {
            // The Keychain outlives a deleted app.
            PushKeys.delete()
        }
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
            do {
                let keys = try PushKeys.create()
                try await register(pairing.endpoint, keys: keys, api: api)
            } catch {
                // No keys, or Instagram didn't take the address: leave nothing behind.
                PushKeys.delete()
                retire(pairing.deviceId)
                throw error
            }
            registration = Registration(
                deviceID: pairing.deviceId, endpoint: pairing.endpoint, userID: userID,
                appleToken: token, since: .now, registeredAt: .now, checkedAt: .now
            )
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
    /// back; it stops sending once the address stops answering.
    func turnOff() async {
        guard let registration else { return }
        failure = nil
        self.registration = nil
        PushKeys.delete()
        retire(registration.deviceID)
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
        do {
            let token = try await appleToken()
            let isDue = Date.now.timeIntervalSince(registration.registeredAt) > Self.reassertInterval
            let isUnchecked = Date.now.timeIntervalSince(registration.checkedAt ?? .distantPast) > Self.checkInterval
            guard token != registration.appleToken || isUnchecked || isDue else { return }
            let pairing = try await relay.pair(appleToken: token, deviceID: registration.deviceID)
            if pairing.endpoint != registration.endpoint || isDue {
                try await register(pairing.endpoint, keys: keys, api: api)
                registration.registeredAt = .now
            }
            registration.deviceID = pairing.deviceId
            registration.endpoint = pairing.endpoint
            registration.appleToken = token
            registration.checkedAt = .now
            // Unless they were turned off meanwhile.
            if self.registration != nil { self.registration = registration }
        } catch {
            // Next time.
        }
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

    /// Tells the relay to forget the phones this one was, now and at each launch until it has
    /// heard: a relay that can't be reached when you log out mustn't keep sending here.
    private func retire(_ deviceID: String? = nil) {
        var waiting = UserDefaults.standard.stringArray(forKey: Self.retiredKey) ?? []
        if let deviceID { waiting.append(deviceID) }
        UserDefaults.standard.set(waiting, forKey: Self.retiredKey)
        guard let relay = PushRelay.configured, !waiting.isEmpty else { return }
        Task {
            for deviceID in waiting {
                guard (try? await relay.unpair(deviceID: deviceID)) != nil else { continue }
                let left = (UserDefaults.standard.stringArray(forKey: Self.retiredKey) ?? []).filter { $0 != deviceID }
                UserDefaults.standard.set(left, forKey: Self.retiredKey)
            }
        }
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
        // place, so the whole path after Apple can be tried in the simulator.
        if notification.request.content.userInfo[InstagramPush.envelopeKey] != nil,
           let content = notification.request.content.mutableCopy() as? UNMutableNotificationContent,
           InstagramPush.rewrite(content) != nil {
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return completionHandler([])
        }
        #endif
        let routing = InstagramPush.Routing(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            arrivals += 1
            if let thread = routing?.threadID, visibleThread.contains(thread) {
                completionHandler([])
            } else {
                completionHandler([.banner, .list, .sound])
            }
        }
    }

    /// You tapped a notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let routing = InstagramPush.Routing(userInfo: response.notification.request.content.userInfo)
        let isTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if isTap { opened = routing }
            completionHandler()
        }
    }
}

/// SwiftUI apps have no app delegate of their own, and iOS answers a request for the phone's
/// address at Apple only through one.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Before launch ends, so a tap that opened the app is heard.
        UNUserNotificationCenter.current().delegate = PushNotifications.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.answerToken(.success(deviceToken.map { String(format: "%02x", $0) }.joined()))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.answerToken(.failure(PushNotifications.Failure.noAppleToken))
    }
}
