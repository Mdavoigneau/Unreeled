import CryptoKit
import Foundation

/// Decrypts a web push message on the phone.
///
/// The phone's P-256 private key and its `auth` secret never leave it (see PushKeys): the relay
/// only passes the ciphertext on and can't read it. Instagram uses the legacy `aesgcm` encoding,
/// where the salt and the sender's public key travel in the `encryption` and `crypto-key` header
/// fields. The standard `aes128gcm` encoding (RFC 8188 with RFC 8291), where both travel at the
/// start of the body, is read too, should Instagram move to it.
///
/// The `aesgcm` half follows mautrix/meta's `pushcrypto/decrypt.go`. Both are checked against
/// what the `web-push` library produces: see relay/tools/sample-push.mjs.
enum WebPushCrypto {
    /// A push as the relay forwards it: the body, and the header fields that came with it.
    struct Envelope {
        /// The body: ciphertext with its 16-byte tag, after a header of its own in `aes128gcm`.
        let body: Data
        /// `aesgcm` or `aes128gcm`.
        let encoding: String
        /// The `encryption` field (`salt=…`), in `aesgcm`.
        let encryption: String?
        /// The `crypto-key` field (`dh=…;p256ecdsa=…`), in `aesgcm`.
        let cryptoKey: String?
    }

    enum Failure: Error {
        case unsupportedEncoding
        case missingField
        case badKeyLength
        case shortCiphertext
        case decryptFailed
        case badPadding
    }

    /// The message a push carries: for Instagram, a notification as JSON.
    static func decrypt(_ envelope: Envelope, privateKey: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        switch envelope.encoding.lowercased() {
        case "aesgcm":
            guard let salt = envelope.encryption.flatMap({ value($0, name: "salt") }),
                  let senderKey = envelope.cryptoKey.flatMap({ value($0, name: "dh") })
            else { throw Failure.missingField }
            return try decryptLegacy(envelope.body, salt: salt, senderKey: senderKey, privateKey: privateKey, auth: auth)
        case "aes128gcm":
            return try decryptStandard(envelope.body, privateKey: privateKey, auth: auth)
        default:
            throw Failure.unsupportedEncoding
        }
    }

    // MARK: aesgcm

    private static func decryptLegacy(
        _ body: Data, salt: Data, senderKey: Data, privateKey: P256.KeyAgreement.PrivateKey, auth: Data
    ) throws -> Data {
        let ownKey = privateKey.publicKey.x963Representation // 65 bytes: 0x04, X, Y
        let prk = hmac(key: salt, data: try inputKey(senderKey: senderKey, privateKey: privateKey, auth: auth, info: bytes("Content-Encoding: auth", 0x00)))
        let key = hmac(key: prk, data: legacyInfo("Content-Encoding: aesgcm", ownKey, senderKey) + [0x01]).prefix(16)
        let nonce = hmac(key: prk, data: legacyInfo("Content-Encoding: nonce", ownKey, senderKey) + [0x01]).prefix(12)
        let plaintext = try open(body, key: Data(key), nonce: Data(nonce))

        // Two bytes giving the padding's length, the padding, then the message.
        guard plaintext.count >= 2 else { throw Failure.badPadding }
        let padding = Int(plaintext[plaintext.startIndex]) << 8 | Int(plaintext[plaintext.startIndex + 1])
        guard 2 + padding <= plaintext.count else { throw Failure.badPadding }
        return Data(plaintext.dropFirst(2 + padding))
    }

    /// `label`, 0x00, "P-256", 0x00, then each key after its length in two bytes: the phone's
    /// key first, then the sender's.
    private static func legacyInfo(_ label: String, _ ownKey: Data, _ senderKey: Data) -> Data {
        var info = bytes(label, 0x00) + bytes("P-256", 0x00)
        for key in [ownKey, senderKey] {
            info.append(contentsOf: [UInt8(key.count >> 8), UInt8(key.count & 0xFF)])
            info.append(key)
        }
        return info
    }

    // MARK: aes128gcm

    private static func decryptStandard(_ body: Data, privateKey: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        // The body's header: a 16-byte salt, the record size in four bytes, the length of the
        // sender's key in one, and that key.
        let body = Data(body)
        guard body.count > 21 else { throw Failure.shortCiphertext }
        let salt = body.prefix(16)
        let recordSize = body[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let keyLength = Int(body[20])
        guard recordSize > 17, body.count > 21 + keyLength else { throw Failure.shortCiphertext }
        let senderKey = body[21..<21 + keyLength]
        let records = body[(21 + keyLength)...]

        let ownKey = privateKey.publicKey.x963Representation
        let info = bytes("WebPush: info", 0x00) + ownKey + senderKey
        let prk = hmac(key: Data(salt), data: try inputKey(senderKey: Data(senderKey), privateKey: privateKey, auth: auth, info: info))
        let key = Data(hmac(key: prk, data: bytes("Content-Encoding: aes128gcm", 0x00, 0x01)).prefix(16))
        let nonce = [UInt8](hmac(key: prk, data: bytes("Content-Encoding: nonce", 0x00, 0x01)).prefix(12))

        var message = Data()
        var index = 0
        var start = records.startIndex
        while start < records.endIndex {
            let end = min(start + recordSize, records.endIndex)
            // Each record's nonce is the first one with the record's number folded into its end.
            var recordNonce = nonce
            for byte in 0..<8 { recordNonce[11 - byte] ^= UInt8((index >> (8 * byte)) & 0xFF) }
            let plaintext = try open(Data(records[start..<end]), key: key, nonce: Data(recordNonce))
            // The message, a delimiter (2 in the last record, 1 before it), then zero padding.
            guard let delimiter = plaintext.lastIndex(where: { $0 != 0 }),
                  plaintext[delimiter] == (end == records.endIndex ? 2 : 1)
            else { throw Failure.badPadding }
            message.append(plaintext[plaintext.startIndex..<delimiter])
            index += 1
            start = end
        }
        return message
    }

    // MARK: Shared steps

    /// The key material both encodings start from: the secret the two key pairs share, mixed
    /// with the `auth` secret and `info`.
    private static func inputKey(senderKey: Data, privateKey: P256.KeyAgreement.PrivateKey, auth: Data, info: Data) throws -> Data {
        guard senderKey.count == 65, let key = try? P256.KeyAgreement.PublicKey(x963Representation: senderKey) else {
            throw Failure.badKeyLength
        }
        guard let shared = try? privateKey.sharedSecretFromKeyAgreement(with: key) else { throw Failure.decryptFailed }
        let secret = shared.withUnsafeBytes { Data($0) }
        return hmac(key: hmac(key: auth, data: secret), data: info + [0x01])
    }

    /// AES-128-GCM, the 16-byte tag at the end of `sealed`.
    private static func open(_ sealed: Data, key: Data, nonce: Data) throws -> Data {
        guard sealed.count > 16 else { throw Failure.shortCiphertext }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: sealed.dropLast(16),
                tag: sealed.suffix(16)
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw Failure.decryptFailed
        }
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// A string's UTF-8 bytes followed by `trailing`.
    private static func bytes(_ string: String, _ trailing: UInt8...) -> Data {
        Data(string.utf8) + trailing
    }

    // MARK: Header fields

    /// A base64url value by name in a `name=value;other=…` field, such as `salt=…` or `dh=…`.
    static func value(_ field: String, name: String) -> Data? {
        for part in field.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name {
                return base64url(pair[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func base64url(_ string: String) -> Data? {
        var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
