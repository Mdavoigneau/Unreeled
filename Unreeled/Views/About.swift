import SwiftUI

/// Where the project lives. The website also serves the privacy policy and the list of queries
/// the app keeps itself current with (see QueryUpdates).
enum Links {
    static let website = URL(string: "https://unreeled.app")!
    static let privacy = URL(string: "https://unreeled.app/privacy")!
    static let source = URL(string: "https://github.com/Mdavoigneau/Unreeled")!
    static let issues = URL(string: "https://github.com/Mdavoigneau/Unreeled/issues")!
}

/// What Unreeled is and what using it means for your account: shown once before anything else,
/// and any time from About.
enum Notice {
    /// Raise it when the notice changes enough that everyone should read it again.
    static let version = 1
    static let key = "acceptedNotice"
}

/// The three things to know, on the welcome screen and in About.
struct NoticePoints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            point(
                "person.2", "Just your friends",
                "Posts from the people you follow, newest first, their stories, and your messages. No Reels, no suggestions, no ads."
            )
            point(
                "exclamationmark.triangle", "Unofficial",
                "Unreeled isn't made or endorsed by Instagram or Meta. Instagram doesn't approve apps like this one, and it could restrict or disable an account that uses it. Use it at your own risk."
            )
            point(
                "lock", "Private",
                "You log in on Instagram's own page. Your login and everything you see go only between this phone and Instagram. No analytics, no tracking."
            )
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.font(15, .medium))
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The first screen, before logging in: what Unreeled is, and the risk to your account.
struct WelcomeView: View {
    let accept: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Unreeled")
                    .font(Theme.wordmark)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 64)
                Text("Your friends on Instagram, without the rabbit hole.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                NoticePoints()
                    .padding(.top, 40)
                Button(action: accept) {
                    Text("I Understand")
                        .font(Theme.font(16, .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(.top, 40)
                HStack(spacing: 20) {
                    Link("Privacy Policy", destination: Links.privacy)
                    Link("Source Code", destination: Links.source)
                }
                .font(Theme.font(13))
                .padding(.vertical, 20)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color.white)
    }
}

/// From the gear on your profile: the notice again, the version, and the project's links.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Unreeled")
                    .font(Theme.wordmark)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 28)
                Text("Version \(Self.version)")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 2)
                NoticePoints()
                    .padding(.top, 32)
                    .padding(.horizontal, 24)
                VStack(spacing: 0) {
                    row("Website", detail: "unreeled.app", url: Links.website)
                    row("Privacy Policy", url: Links.privacy)
                    row("Source Code", detail: "GitHub", url: Links.source)
                    row("Report a Problem", url: Links.issues)
                }
                .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
                .padding(.top, 32)
                if let test = PushTest.bundled {
                    PushTestRow(test: test)
                        .padding(.top, 28)
                }
                Text(Self.queriesStatus)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .background(Color.white)
        .classicBar {
            Text("About").font(Theme.font(16, .medium))
        } trailing: {
            Button("Done") { dismiss() }
                .font(Theme.font(16, .medium))
                .foregroundStyle(Theme.accent)
                .padding(.trailing, 8)
        }
    }

    private func row(_ title: String, detail: String? = nil, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                if let detail { Text(detail).foregroundStyle(Theme.secondary) }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.secondary)
            }
            .font(Theme.font(15))
            .padding(.horizontal, 24)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5).padding(.leading, 24) }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Whether the app runs on the query IDs it shipped with or on a newer list from the project.
    @MainActor private static var queriesStatus: String {
        guard let updated = QueryUpdates.updatedAt else { return "Instagram query IDs: as shipped with this version." }
        return "Instagram query IDs: updated \(updated.formatted(.relative(presentation: .named)))."
    }
}
