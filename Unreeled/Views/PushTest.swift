import SwiftUI

/// The push test's values (see relay/README.md): the address and keys to register, in a
/// PushTest.json that only a build made for the test carries. No other build has one.
struct PushTest: Decodable {
    let endpoint: String
    let p256dh: String
    let auth: String

    static let bundled: PushTest? = Bundle.main.url(forResource: "PushTest", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(PushTest.self, from: $0) }
}

/// In About, in a build made for the push test: registers this login with the test's relay, so
/// Instagram sends the relay an encrypted copy of each notification. Nothing shows on the phone.
struct PushTestRow: View {
    let test: PushTest
    @Environment(Session.self) private var session
    /// When Instagram last took the registration, in seconds since 1970. Zero: never.
    @AppStorage("pushTestRegistered") private var registered = 0.0
    @State private var isRegistering = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 10) {
            Text("Push Test")
                .font(Theme.font(15, .medium))
                .foregroundStyle(Theme.ink)
            Text(status)
                .font(Theme.font(13))
                .foregroundStyle(failure == nil ? Theme.secondary : Color.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: register) {
                Text(registered > 0 ? "Turn On Again" : "Turn On")
                    .font(Theme.font(15, .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(isRegistering || !session.isLoggedIn)
            .opacity(isRegistering ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
    }

    private var status: String {
        if let failure { return failure }
        if isRegistering { return "Asking Instagram…" }
        guard registered > 0 else {
            return "Sends an encrypted copy of your Instagram notifications to the test's relay. Nothing shows on this phone."
        }
        let since = Date(timeIntervalSince1970: registered).formatted(date: .abbreviated, time: .shortened)
        return "On since \(since). Nothing shows on this phone."
    }

    private func register() {
        isRegistering = true
        failure = nil
        Task {
            do {
                try await session.api.registerWebPush(endpoint: test.endpoint, p256dh: test.p256dh, auth: test.auth)
                registered = Date.now.timeIntervalSince1970
            } catch {
                failure = error.localizedDescription
            }
            isRegistering = false
        }
    }
}
