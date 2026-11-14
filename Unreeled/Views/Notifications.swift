import SwiftUI

/// The question about notifications, with what saying yes means: asked once after logging in,
/// and again from Settings when you switch them on. Saying yes brings up iOS's own question.
struct NotificationsOffer: View {
    /// Called once the question is answered, either way.
    let done: () -> Void
    @Environment(Session.self) private var session
    @Environment(PushNotifications.self) private var notifications

    var body: some View {
        AnswerPage {
            VStack(spacing: 0) {
                Image(systemName: "bell")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Notifications")
                    .font(Theme.font(22, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 16)
                Text("Messages, likes and follows from Instagram, while Unreeled is closed.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 22) {
                    NoticePoint(
                        symbol: "arrow.triangle.swap", title: "Through a relay",
                        text: "Instagram encrypts each notification for this phone and sends it to Unreeled's relay, which passes it on through Apple."
                    )
                    NoticePoint(
                        symbol: "lock", title: "Only this phone can read them",
                        text: "The keys never leave it. The relay sees this phone's address at Apple and when a notification passes, never what it says or which account it's for."
                    )
                    NoticePoint(
                        symbol: "exclamationmark.triangle", title: "Unofficial",
                        text: "Instagram doesn't offer notifications to apps like Unreeled, so this may stop working one day. As with the rest of the app, use it at your own risk."
                    )
                }
                .padding(.top, 36)
                Link("How this works, in a short video", destination: Links.notifications)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    .padding(.top, 14)
                if let failure = notifications.failure {
                    Text(failure)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.like)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
            }
        } actions: {
            Button(action: turnOn) {
                Text(notifications.isWorking ? "Turning On…" : "Turn On").filledButton()
            }
            .buttonStyle(.plain)
            .disabled(notifications.isWorking)
            .opacity(notifications.isWorking ? 0.5 : 1)
            Button("Not Now", action: done)
                .font(Theme.font(15))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .disabled(notifications.isWorking)
        }
        .onAppear { notifications.forgetFailure() }
    }

    private func turnOn() {
        guard let userID = session.userID else { return }
        Task {
            // Refused by iOS or on: either way the question is answered, and Settings has the rest.
            if await notifications.turnOn(api: session.api, userID: userID) { done() }
        }
    }
}

/// In Settings: notifications on or off, and what's in the way when they can't show.
struct NotificationsSettings: View {
    @Environment(PushNotifications.self) private var notifications
    @State private var showsOffer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notifications")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.ink)
                    Text(status)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(notifications.isWorking)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if notifications.isOn {
                if !notifications.isAllowed {
                    row("Allow Them in iOS Settings") {
                        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
                // Instagram's own page for which notifications it sends, with "Messages only".
                NavigationLink(value: Route.web(path: "/push/web/settings/", title: "Notifications")) {
                    rowLabel("Choose What Instagram Sends")
                }
                .buttonStyle(.plain)
            }
        }
        .fullScreenCover(isPresented: $showsOffer) {
            NotificationsOffer { showsOffer = false }
        }
    }

    /// Switching on asks first; switching off needs no question.
    private var isOn: Binding<Bool> {
        Binding {
            notifications.isOn
        } set: { on in
            if on {
                showsOffer = true
            } else {
                Task { await notifications.turnOff() }
            }
        }
    }

    private var status: String {
        guard let registration = notifications.registration else {
            return "Messages, likes and follows, while Unreeled is closed."
        }
        guard notifications.isAllowed else { return "Notifications are off for Unreeled in iOS Settings." }
        return "On since \(registration.since.formatted(date: .abbreviated, time: .shortened))."
    }

    private func row(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(15))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5).padding(.leading, 16) }
    }
}
