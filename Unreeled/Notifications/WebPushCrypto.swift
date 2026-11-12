import Foundation
import CryptoKit

/// Decrypts an Instagram web-push message (legacy `aesgcm` content-encoding) on the device.
///
/// In Unreeled's end-to-end design, the device's P-256 private key and the `auth` secret live only
/// here (in the Keychain); the central relay only ever handles the ciphertext and cannot read it.
/// This mirrors mautrix/meta `pushcrypto/decrypt.go` (RFC 8291's legacy `aesgcm` scheme, where the
/// salt and the server's public key arrive in the push body's `encryption` / `crypto-key` fields,
/// not in HTTP headers).
///
/// NOT YET VERIFIED against a real captured payload — this must be checked in Gate 3 before shipping.
enum WebPushCrypto {

    /// The three pieces the relay forwards from the web-push message.
    struct Message {
        /// The `data` field: AES-GCM ciphertext with the 16-byte tag appended.
        let ciphertext: Data
        /// From the `encryption` field (`salt=…`).
        let salt: Data
        /// From the `crypto-key` field (`dh=…`): the server public key, 65 bytes (0x04‖X‖Y).
        let serverPublicKey: Data
    }

    enum Failure: Error { case badKeyLength, shortCiphertext, decryptFailed, badPadding }

    /// Decrypts to the raw notification JSON (`{type, time, message, href, t, n, ppu, params}`).
    static func decrypt(_ message: Message,
                        privateKey: P256.KeyAgreement.PrivateKey,
                        auth: Data) throws -> Data {
        let clientPublicKey = privateKey.publicKey.x963Representation  // 65 bytes, 0x04‖X‖Y
        guard message.serverPublicKey.count == 65, clientPublicKey.count == 65 else {
            throw Failure.badKeyLength
        }

        // ECDH shared secret — the raw 32-byte X coordinate (as mautrix uses it).
        let serverKey = try P256.KeyAgreement.PublicKey(x963Representation: message.serverPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: serverKey)
        let sharedData = shared.withUnsafeBytes { Data($0) }

        // Legacy aesgcm key derivation (an HMAC-SHA256 chain).
        let prkKey = hmac(key: auth, data: sharedData)
        let ikm = hmac(key: prkKey, data: bytes("Content-Encoding: auth", 0x00, 0x01))
        let prk = hmac(key: message.salt, data: ikm)

        var keyInfo = legacyInfo("Content-Encoding: aesgcm", clientPublicKey, message.serverPublicKey)
        keyInfo.append(0x01)
        let aesKey = Data(hmac(key: prk, data: keyInfo).prefix(16))

        var nonceInfo = legacyInfo("Content-Encoding: nonce", clientPublicKey, message.serverPublicKey)
        nonceInfo.append(0x01)
        let nonce = Data(hmac(key: prk, data: nonceInfo).prefix(12))

        // AES-128-GCM: the trailing 16 bytes of `ciphertext` are the tag.
        guard message.ciphertext.count > 16 else { throw Failure.shortCiphertext }
        let body = Data(message.ciphertext.prefix(message.ciphertext.count - 16))
        let tag = Data(message.ciphertext.suffix(16))
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: aesKey))
        } catch {
            throw Failure.decryptFailed
        }

        // Strip the 2-byte big-endian padding length, then that many padding bytes.
        let p = [UInt8](plaintext)
        guard p.count >= 2 else { throw Failure.badPadding }
        let padLength = Int(p[0]) << 8 | Int(p[1])
        let start = 2 + padLength
        guard start <= p.count else { throw Failure.badPadding }
        return Data(p[start...])
    }

    // MARK: Parsing the forwarded header fields

    /// Extracts a base64url value by name from a `name=value;other=…` field (e.g. `salt=…`, `dh=…`).
    static func value(_ field: String, name: String) -> Data? {
        for part in field.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == name {
                return base64url(String(kv[1]))
            }
        }
        return nil
    }

    static func base64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    // MARK: Helpers

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// A UTF-8 string followed by raw bytes.
    private static func bytes(_ string: String, _ trailing: UInt8...) -> Data {
        var d = Data(string.utf8)
        d.append(contentsOf: trailing)
        return d
    }

    /// buildLegacyInfo: `label` ‖ 0x00 ‖ "P-256" ‖ 0x00, then for each key a two-byte length prefix
    /// (0x00 0x41 = 65) and the 65-byte key — client public key first, then the server `dh` key.
    private static func legacyInfo(_ label: String, _ clientPublicKey: Data, _ serverPublicKey: Data) -> Data {
        var out = Data(label.utf8)
        out.append(0x00)
        out.append(contentsOf: "P-256".utf8)
        out.append(0x00)
        for key in [clientPublicKey, serverPublicKey] {
            out.append(0x00); out.append(0x41)  // 65, big-endian
            out.append(key)
        }
        return out
    }
}
