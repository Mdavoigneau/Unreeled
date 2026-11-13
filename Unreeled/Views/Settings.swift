import SwiftUI

/// From the gear on your profile: what you can change, and logging out. About is at the top right.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @AppStorage("showsReels") private var showsReels = false
    @State private var showsAbout = false
    @State private var confirmsLogOut = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SettingsSection(title: "Home") {
                    Toggle(isOn: $showsReels) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reels from Accounts You Follow")
                                .font(Theme.font(15))
                                .foregroundStyle(Theme.ink)
                            Text("One at a time, with no feed to swipe.")
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                if PushNotifications.isOffered {
                    SettingsSection(title: "Notifications") {
                        NotificationsSettings()
                    }
                }
                SettingsSection(title: "Account") {
                    Button { confirmsLogOut = true } label: {
                        Text("Log Out")
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.like)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.white)
        .classicBar(showsBack: true) {
            Text("Settings").font(Theme.font(16, .medium))
        } trailing: {
            Button("About") { showsAbout = true }
                .font(Theme.font(15))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
        }
        .sheet(isPresented: $showsAbout) { AboutView() }
        .confirmationDialog("Log out of Unreeled?", isPresented: $confirmsLogOut, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) {
                Task { await session.logOut() }
            }
        } message: {
            Text("What the app saved on this phone is deleted: screens, conversations and pictures.")
        }
    }
}

/// A titled group of settings between two hairlines.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 8)
            Theme.hairline.frame(height: 0.5)
            content
            Theme.hairline.frame(height: 0.5)
        }
    }
}
