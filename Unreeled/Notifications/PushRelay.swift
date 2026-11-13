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
        let info = Bundle.main.infoDictionary
        guard let host = info?["UnreeledRelayHost"] as? String, !host.isEmpty,
              let url = URL(string: "https://\(host)")
        else { return nil }
        let token = info?["UnreeledRelayToken"] as? String
        return PushRelay(base: url, token: token?.isEmpty == false ? token : nil)
    }()

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

    /// The relay forgets the phone, and its push address stops working.
    func unpair(deviceID: String) async throws {
        do {
            _ = try await post("unpair", ["deviceId": deviceID])
        } catch Failure.refused(404) {
            // It had forgotten already.
        }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await Self.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { throw Failure.unreachable }
        guard status == 200 else { throw Failure.refused(status) }
        return data
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
