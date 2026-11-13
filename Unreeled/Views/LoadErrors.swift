import SwiftUI

/// What went wrong with a load, as a screen says it.
struct ShownError: Equatable {
    let message: String
    /// The connection failed, not Instagram: the screen loads again by itself once the phone is
    /// back online, and the website wouldn't do any better meanwhile.
    let isConnection: Bool

    /// Nil for a load that was stopped on purpose, which isn't something to show.
    init?(_ error: Error) {
        switch error {
        case is CancellationError:
            return nil
        case let failure as InstagramAPI.Failure:
            message = failure.errorDescription ?? "Something went wrong."
            isConnection = failure.isConnection
        case let error as URLError:
            if error.code == .cancelled { return nil }
            let failure = InstagramAPI.Failure(error)
            message = failure.errorDescription ?? "Couldn't reach Instagram."
            isConnection = true
        default:
            message = error.localizedDescription
            isConnection = false
        }
    }

    init(message: String) {
        self.message = message
        isConnection = false
    }
}

/// In place of a screen's content when it couldn't load and there's nothing saved to show.
struct ErrorRow: View {
    let error: ShownError
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(error.message)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                if let retry {
                    Button("Try Again", action: retry)
                }
                if !error.isConnection {
                    NavigationLink("Open Website", value: Route.web(path: "/", title: "Instagram"))
                }
            }
            .font(Theme.font(14, .medium))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Under a screen that still shows its saved copy when the newer one didn't come: one quiet line.
struct RefreshNote: View {
    /// What didn't happen, for a connection that failed.
    var text = "Couldn't refresh."
    let error: ShownError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(error.isConnection ? text : error.message)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            Button("Try Again", action: retry)
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
        }
        .font(Theme.font(13))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}

/// A grey strip under the top bar while the phone has no connection, as the old app had.
struct OfflineStrip: View {
    var body: some View {
        if !Connectivity.shared.isOnline {
            Text("No Internet Connection")
                .font(Theme.font(13, .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(Theme.secondary)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
