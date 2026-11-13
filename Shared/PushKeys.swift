import CryptoKit
import Foundation
import Security

/// The keys Instagram encrypts this phone's notifications for: a P-256 key pair and a 16-byte
/// `auth` secret, as a browser makes for a push subscription.
///
/// They're made when notifications are turned on and kept in the Keychain, on this device only,
/// readable once the phone has been unlocked since it started, so a notification can be read
/// while the phone is locked. The app makes and deletes them; the notification extension, which
/// shares the app's Keychain group, only reads them. Nothing else ever has them: Instagram gets
/// the public key and `auth`, the relay gets neither.
struct PushKeys {
    let privateKey: P256.KeyAgreement.PrivateKey
    let auth: Data

    /// The public key as a browser's subscription lists it: base64url of 65 bytes.
    var p256dh: String { WebPushCrypto.base64url(privateKey.publicKey.x963Representation) }
    /// The `auth` secret as a browser's subscription lists it.
    var authString: String { WebPushCrypto.base64url(auth) }

    /// The keys on this phone, if notifications were turned on.
    static func load() -> PushKeys? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 48,
              let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data.prefix(32))
        else { return nil }
        return PushKeys(privateKey: privateKey, auth: Data(data.suffix(16)))
    }

    /// True when the Keychain has no keys at all, as opposed to keys it can't hand over right
    /// now: on a phone that hasn't been unlocked since it started.
    static var areGone: Bool {
        SecItemCopyMatching(item as CFDictionary, nil) == errSecItemNotFound
    }

    /// New keys, replacing any there were.
    static func create() throws -> PushKeys {
        var auth = Data(count: 16)
        let status = auth.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        let keys = PushKeys(privateKey: P256.KeyAgreement.PrivateKey(), auth: auth)

        delete()
        var new = item
        new[kSecValueData as String] = keys.privateKey.rawRepresentation + keys.auth
        new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(new as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
        return keys
    }

    static func delete() {
        SecItemDelete(item as CFDictionary)
    }

    enum Failure: Error {
        case keychain(OSStatus)
    }

    /// One Keychain item holds both: the private key's 32 bytes, then `auth`. The name is the
    /// same in the app and in the extension, whose bundle IDs differ.
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "UnreeledPush",
        kSecAttrAccount as String: "keys",
    ]
}
