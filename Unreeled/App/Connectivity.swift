import Network
import SwiftUI

/// Whether the phone has a way out to the internet, as iOS sees it. A weak connection still counts
/// as one: requests find out about those themselves (WebRequests tries them again).
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOnline = true
    /// Goes up each time the phone is back online, for screens that couldn't load to try again.
    private(set) var returns = 0

    private let monitor = NWPathMonitor()
    private var pathIsOnline = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "Unreeled.Connectivity", qos: .utility))
        #if DEBUG
        Faults.startOfflineSpell { [weak self] in self?.refresh() }
        #endif
    }

    private func update(_ online: Bool) {
        pathIsOnline = online
        refresh()
    }

    private func refresh() {
        var online = pathIsOnline
        #if DEBUG
        if Faults.isOffline { online = false }
        #endif
        guard online != isOnline else { return }
        isOnline = online
        if online { returns += 1 }
    }

    /// Waits for the phone to be back online, `seconds` at most. True when it is.
    func waitUntilOnline(seconds: Double) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !isOnline, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return isOnline
    }
}

extension View {
    /// Runs `action` whenever the phone is back online: for a screen whose last load failed.
    func onReconnect(perform action: @escaping () async -> Void) -> some View {
        modifier(OnReconnect(action: action))
    }
}

private struct OnReconnect: ViewModifier {
    let action: () async -> Void

    func body(content: Content) -> some View {
        content.onChange(of: Connectivity.shared.returns) {
            Task { await action() }
        }
    }
}

#if DEBUG
/// Debug builds only: a poor connection on demand, to try the app on one without leaving the desk.
///
/// - `-flakyNetwork 0.5` fails half the requests, as a dropped connection would. A request that
///   changes something fails before it leaves the phone, so nothing is ever sent twice, or at all,
///   by this.
/// - `-slowNetwork 3` holds every request back that many seconds first.
/// - `-offlineFor 20` acts as if the phone had no connection for the first 20 seconds.
@MainActor
enum Faults {
    private static let launched = Date.now

    static var isOffline: Bool {
        let seconds = UserDefaults.standard.double(forKey: "offlineFor")
        return seconds > 0 && Date.now.timeIntervalSince(launched) < seconds
    }

    /// Tells `changed` when the pretend time offline ends.
    static func startOfflineSpell(changed: @escaping @MainActor () -> Void) {
        let seconds = UserDefaults.standard.double(forKey: "offlineFor")
        guard seconds > 0 else { return }
        Task { @MainActor in
            changed()
            try? await Task.sleep(for: .seconds(seconds - Date.now.timeIntervalSince(launched) + 0.1))
            changed()
        }
    }

    static func inject(purpose: WebRequests.Purpose, url: URL) async throws {
        let delay = UserDefaults.standard.double(forKey: "slowNetwork")
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if isOffline { throw URLError(.notConnectedToInternet) }
        let chance = UserDefaults.standard.double(forKey: "flakyNetwork")
        guard chance > 0, Double.random(in: 0..<1) < chance else { return }
        NetworkRecorder.append(["time": Date().ISO8601Format(), "faultInjected": url.path])
        // Reading: as if the answer was lost on its way back. Anything else: as if it never left.
        throw URLError(purpose == .read ? .networkConnectionLost : .cannotConnectToHost)
    }
}
#endif
