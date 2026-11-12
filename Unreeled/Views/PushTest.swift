import SwiftUI
import UserNotifications

/// The push test's values (see relay/README.md): the address and keys to register, in a
/// PushTest.json that only a build made for the test carries. No other build has one.
struct PushTest: Decodable {
    let endpoint: String
    let p256dh: String
    let auth: String

    static let bundled: PushTest? = Bundle.main.url(forResource: "PushTest", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(PushTest.self, from: $0) }

    /// Whether the app has asked about the test yet.
    static let askedKey = "pushTestAsked"
    /// When Instagram last took the registration, in seconds since 1970. Zero: never.
    static let registeredKey = "pushTestRegistered"

    enum Outcome {
        case on
        /// Notifications are off for the app in iOS Settings, so nothing was registered.
        case notAllowed
    }

    /// Turns the test on. iOS asks whether Unreeled may send notifications, the first time, and
    /// if it may, this login is registered with the test's relay.
    @MainActor
    func turnOn(api: InstagramAPI) async throws -> Outcome {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .badge, .sound]) else { return .notAllowed }
        if !Self.isDryRun {
            try await api.registerWebPush(endpoint: endpoint, p256dh: p256dh, auth: auth)
        }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.registeredKey)
        return .on
    }

    /// Debug builds launched with -pushTestDryRun YES do everything but the registration, to try
    /// these screens without writing to an account.
    private static var isDryRun: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "pushTestDryRun")
        #else
        false
        #endif
    }
}

/// Asked once, before the app's first screen, in a build made for the push test: whether to turn
/// the test on. Saying yes brings up iOS's own question about notifications.
struct PushTestOffer: View {
    let test: PushTest
    @Environment(Session.self) private var session
    @AppStorage(PushTest.askedKey) private var asked = false
    @State private var isTurningOn = false
    @State private var failure: String?

    var body: some View {
        AnswerPage {
            VStack(spacing: 0) {
                Image(systemName: "bell")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Push Test")
                    .font(Theme.font(22, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 20)
                Text("Unreeled is testing notifications. Turn the test on, and Instagram sends an encrypted copy of each of your notifications to Unreeled's relay, which records that it arrived.")
                    .padding(.top, 12)
                Text("They don't show on this phone yet.")
                    .padding(.top, 10)
                if let failure {
                    Text(failure)
                        .foregroundStyle(Theme.like)
                        .padding(.top, 16)
                }
            }
            .font(Theme.font(15))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
        } actions: {
            Button(action: turnOn) {
                Text(isTurningOn ? "Turning On…" : "Turn On").filledButton()
            }
            .buttonStyle(.plain)
            .disabled(isTurningOn)
            .opacity(isTurningOn ? 0.5 : 1)
            Button("Not Now") { asked = true }
                .font(Theme.font(15))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .disabled(isTurningOn)
        }
    }

    private func turnOn() {
        isTurningOn = true
        failure = nil
        Task {
            do {
                // Allowed or not, the question is answered: Settings has the rest.
                _ = try await test.turnOn(api: session.api)
                asked = true
            } catch {
                failure = error.localizedDescription
            }
            isTurningOn = false
        }
    }
}

/// In Settings, in a build made for the push test: whether the test is on, and turning it on.
struct PushTestRow: View {
    let test: PushTest
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PushTest.registeredKey) private var registered = 0.0
    @State private var isAllowed = true
    @State private var isTurningOn = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Push Test")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button(action: isAllowed ? turnOn : openSettings) {
                    Text(isAllowed ? (registered > 0 ? "Turn On Again" : "Turn On") : "Open Settings")
                        .font(Theme.font(15, .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isTurningOn)
                .opacity(isTurningOn ? 0.5 : 1)
            }
            Text(status)
                .font(Theme.font(13))
                .foregroundStyle(failure == nil ? Theme.secondary : Theme.like)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Again when you come back from iOS Settings.
        .task(id: scenePhase) { await readPermission() }
    }

    private var status: String {
        if let failure { return failure }
        if isTurningOn { return "Turning on…" }
        if !isAllowed { return "Notifications are off for Unreeled in iOS Settings." }
        guard registered > 0 else {
            return "Instagram sends an encrypted copy of each notification to Unreeled's relay. They don't show on this phone yet."
        }
        let since = Date(timeIntervalSince1970: registered).formatted(date: .abbreviated, time: .shortened)
        return "On since \(since). Notifications don't show on this phone yet."
    }

    private func readPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAllowed = settings.authorizationStatus != .denied
    }

    private func turnOn() {
        isTurningOn = true
        failure = nil
        Task {
            do {
                _ = try await test.turnOn(api: session.api)
            } catch {
                failure = error.localizedDescription
            }
            await readPermission()
            isTurningOn = false
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
