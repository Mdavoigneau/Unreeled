import Foundation

/// The relay that passes Instagram's notifications on to this phone (relay/README.md). The app
/// tells it two things: this phone's address at Apple, to get a push address for Instagram in
/// return, and later that the phone no longer wants notifications. It never tells it who you
/// are on Instagram, and never gives it the keys.
struct PushRelay {
    let base: URL
    /// The relay's pairing token, if it asks for one.
    let token: String?

    /// The relay this build was made for: UNREELED_RELAY_HOST in Config/Local.xcconfig. Nil in
    /// a build without one, which then doesn't offer notifications.
    static let configured: PushRelay? = {
        #if DEBUG
        // Debug builds: -relay <address> uses that relay, such as http://localhost:8787.
        if let address = UserDefaults.standard.string(forKey: "relay"), let url = URL(string: address) {
            return PushRelay(base: url, token: UserDefaults.standard.string(forKey: "relayToken"))
        }
        #endif
        return built
    }()

    /// The relay in the build's settings, even when a Debug launch uses another.
    private static let built: PushRelay? = {
        let info = Bundle.main.infoDictionary
        guard let host = info?["UnreeledRelayHost"] as? String, !host.isEmpty,
              let url = URL(string: "https://\(host)")
        else { return nil }
        let token = info?["UnreeledRelayToken"] as? String
        return PushRelay(base: url, token: token?.isEmpty == false ? token : nil)
    }()

    /// What the app keeps to find this relay again: a pairing is retired where it was made.
    var address: String { base.absoluteString }

    /// The relay a pairing was made with, to retire it there: the one this launch uses, the one
    /// in the build's settings, or one an earlier build or a Debug launch used, asked with this
    /// launch's token. Nil for a build without a relay, which leaves pairings to a later build
    /// that has one.
    static func at(_ address: String?) -> PushRelay? {
        guard let configured else { return nil }
        guard let address, address != configured.address else { return configured }
        if let built, address == built.address { return built }
        return URL(string: address).map { PushRelay(base: $0, token: configured.token) }
    }

    struct Pairing: Decodable {
        /// The relay's name for this phone, to pair again or to leave with.
        let deviceId: String
        /// The push address to give Instagram.
        let endpoint: String
    }

    enum Failure: Error {
        case unreachable
        case refused(Int)
    }

    /// Pairs this phone, or with `deviceID` tells the relay its address at Apple again. The
    /// relay answers with the same push address as long as it still knows the phone.
    func pair(appleToken: String, deviceID: String?) async throws -> Pairing {
        var body: [String: Any] = [
            "apnsToken": appleToken,
            "sandbox": Self.usesAppleSandbox,
            "topic": Bundle.main.bundleIdentifier ?? "",
        ]
        body["deviceId"] = deviceID
        let data = try await post("pair", body)
        guard let pairing = try? JSONDecoder().decode(Pairing.self, from: data) else { throw Failure.refused(200) }
        return pairing
    }

    /// The relay forgets the phone, and its push address stops working. Returns once the relay has
    /// answered for good: it forgot the phone, it didn't know it, or it won't take this build's
    /// token, which asking again won't change. Throws when it couldn't be asked or may answer
    /// otherwise later, to be asked again.
    func unpair(deviceID: String) async throws {
        let (data, status) = try await send("unpair", ["deviceId": deviceID])
        switch status {
        case 200:
            return
        case 404 where (try? JSONDecoder().decode([String: String].self, from: data))?["error"] == "unknown device":
            // It had forgotten already, or never knew it. Its own answer, not just any address
            // that isn't there, such as a relay that has moved.
            return
        case 401:
            // It wants another token than this build has, as a relay an earlier build used may.
            return
        default:
            throw Failure.refused(status)
        }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        let (data, status) = try await send(path, body)
        guard status == 200 else { throw Failure.refused(status) }
        return data
    }

    private func send(_ path: String, _ body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await Self.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { throw Failure.unreachable }
        return (data, status)
    }

    /// No cookies and nothing kept: each request stands alone.
    private static let session = URLSession(configuration: .ephemeral)

    /// Apple has two push services, and an address from one doesn't work at the other. A build
    /// run from Xcode gets its address from the sandbox one, a distributed build from the real
    /// one: the build's provisioning profile says which. The relay has to know.
    static let usesAppleSandbox: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        // The profile is a signed file with a property list in the middle of it. A build from
        // the App Store has none.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url),
              let start = profile.range(of: Data("<plist".utf8)),
              let end = profile.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return false }
        return entitlements["aps-environment"] as? String == "development"
        #endif
    }()
}
