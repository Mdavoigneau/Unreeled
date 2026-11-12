# Unreeled push notifications — design & runbook

**Status (2026-11-12): receiving side validated end-to-end. The sending side (APNs) is pending the Apple Developer Program.**

A central, **opt-in**, **end-to-end-encrypted** service that gives Unreeled instant notifications (DMs, likes, follows, …) on the iPhone while the app is closed — without Instagram's app and without its addictive surface. The receiver uses **Mozilla's open push service**, which turned out to be far simpler and more maintainable than Google's FCM.

> See [Legitimate use & scope](#legitimate-use--scope) for why this is built the way it is.

---

## Principles

1. **Opt-in only**, after an explicit risk disclosure.
2. **End-to-end encrypted** — the central service forwards ciphertext only; the decryption key never leaves the user's phone.
3. **Instagram-facing actions stay on the user's own device** — each user's own login registers the push address, so the service never talks to Instagram (only to Mozilla).
4. **Cheap & maintainable** — one small box serves many users; the receiver is a documented WebSocket protocol, not reverse-engineering.

---

## What's proven (2026-11-12)

- Instagram delivers web push only to a real browser push service. **Google FCM** works; **Apple's** doesn't; a plain relay address doesn't.
- A **headless server browser** can receive Instagram's push end-to-end (Gates 1/1.5/2) — but a browser *decrypts*, so it can't be a private central service.
- **Mozilla's push service is the answer (the chosen receiver):**
  - **Stage A ✓** — a non-browser Node client (`ws` dependency only, ~150 lines) registers a VAPID-restricted channel on `wss://push.services.mozilla.com` and receives a push (self-test).
  - **Stage B ✓** — **Instagram delivers real pushes to a Mozilla endpoint.** Registered from the account, the client received **4 real Instagram notifications over an hour** — all `aesgcm`, every header carrying Instagram's VAPID key (`p256ecdsa=BIBn3E_…`). Reconnect held across 2 socket drops.
  - **Crypto ✓** — the legacy `aesgcm` decryption was validated in Node against `web-push`'s output (exact match), using the same algorithm as the on-phone extension ([`WebPushCrypto.swift`](../Unreeled/Notifications/WebPushCrypto.swift)).

**Why Mozilla over FCM:** FCM would need a reverse-engineered client (its registration endpoint was even removed in 2024) and outbound ports 5228-5230. Mozilla is an **open, documented WebSocket protocol**, needs only outbound **443**, and has a maintained reference client ([Bitwarden's `autopush-manager`](https://github.com/bitwarden/autopush-manager)). The FCM port is **no longer needed**; it remains only a theoretical fallback.

---

## Architecture

```
  ┌───────────┐  encrypts to the PHONE's keys,   ┌──────────────────────────────┐
  │ Instagram │  POSTs to the Mozilla endpoint    │ Mozilla push (autopush, wss) │
  │ (web push)│ ───────────────────────────────▶ │                              │
  └───────────┘                                   └───────────────┬──────────────┘
        ▲                                                         │ delivers ciphertext
        │ registerWebPush({endpoint, p256dh, auth})               ▼  over the WebSocket
        │ (from the user's OWN login, on the phone)      ┌────────────────────────┐
        │                                                │ Central service (Node, │
  ┌─────┴───────────────┐    pair: {APNs token}          │  on Oracle)            │
  │  iPhone (Unreeled)  │ ─────────────────────────────▶ │ • Mozilla client/user  │
  │  • P-256 key (Kchn) │ ◀───────────────────────────── │ • endpoint→APNs map     │
  │  • NSE decrypts     │   {Mozilla endpoint for device} │ • forwards ciphertext   │
  └─────────────────────┘                                └───────────┬────────────┘
        ▲   shows notification                                       │ APNs (HTTP/2, .p8)
        └────────────────────────────────────────────────────────────┘  ciphertext in payload
```

**The split that keeps it private:**

| Piece | Owner | Purpose |
|------|-------|---------|
| **Mozilla endpoint** (the push URL + its channel) | **Central service** | Holds the WebSocket and receives the bytes |
| **ECDH keypair + `auth`** (`p256dh`/`auth`) | **The phone** (Keychain) | The only thing that can decrypt the content |

Instagram encrypts to the phone's keys and POSTs to the service's Mozilla endpoint, so the service receives ciphertext it cannot read and relays it. Only the phone decrypts.

---

## Components

### 1. iPhone (the Unreeled app)
- On first opt-in: generate a **P-256 keypair** + random **16-byte `auth`**; private key stays in the **Keychain**.
- Obtain an **APNs device token** (needs the Apple Developer Program).
- **Pair** with the service: send `{apnsToken}`; receive `{endpoint}` (the Mozilla address for this device).
- **Register with Instagram from the user's own login**: `registerWebPush(endpoint, p256dh, auth)`.
- A **Notification Service Extension** decrypts the forwarded `aesgcm` ciphertext ([`WebPushCrypto.swift`](../Unreeled/Notifications/WebPushCrypto.swift)) and shows it.
- On **logout / opt-out**: tell the service to drop the device (Instagram has no unregister call, so the endpoint just goes stale).

### 2. Central service (Node, on the Oracle box)
- One **Mozilla autopush client per user** (a WebSocket; see the protocol below). Holds the connection, receives, acks.
- Maps **Mozilla endpoint → APNs device token**.
- On a push: forward the raw web-push fields (`data` ciphertext + `headers`) to the phone via APNs. **No decryption.**
- Stores only **transport identifiers** (the per-user autopush identity + APNs token). No ECDH private keys, no `auth`, no plaintext.
- **Staleness watch:** Instagram can silently stop delivering (mautrix/meta#454) — detect gaps and have the app re-assert on open.
- Reference implementation: Bitwarden's `autopush-manager` (GPL-3.0). We ship our **own** small client (no GPL, and it forwards raw ciphertext instead of decrypting).

### 3. APNs forwarder
- Token auth (`.p8` key + team/key IDs), HTTP/2 to APNs (`apns2` or native `http2`). In the central model the **project** holds one Apple key, so users need no Apple account.
- Payload: `mutable-content: 1` + the ciphertext/headers in a custom field for the NSE, plus a minimal fallback alert.

---

## The receiver protocol (Mozilla autopush) — and how to keep it running

Connect to `wss://push.services.mozilla.com` and speak JSON:

| Direction | Message |
|-----------|---------|
| → hello | `{"messageType":"hello","use_webpush":true,"uaid":<saved or null>,"channelIDs":[<saved>]}` |
| ← hello | `{"messageType":"hello","uaid":"…","status":200}` — **save the `uaid`** |
| → register | `{"messageType":"register","channelID":"<uuidv4>","key":"<Instagram VAPID public key>"}` |
| ← register | `{"messageType":"register","channelID":"…","status":200,"pushEndpoint":"https://updates.push.services.mozilla.com/wpush/v2/…"}` |
| ← notification | `{"messageType":"notification","channelID":"…","version":"…","data":"<base64url ciphertext>","headers":{"encoding":"aesgcm","encryption":"salt=…","crypto_key":"dh=…;p256ecdsa=…"}}` |
| → ack | `{"messageType":"ack","updates":[{"channelID":"…","version":"…"}]}` |

**Operational rules (learned from testing — these are the whole maintenance story):**
- **Keepalive:** send a WebSocket ping every ~60s.
- **Reconnect:** Mozilla drops the socket about every ~20 min (close code 1006). On reconnect, send `hello` with the **saved `uaid`** and **`channelIDs`** — this *resumes the same endpoint* (no re-registration). Messages that arrived while offline are queued by Mozilla (web-push TTL) and delivered on resume. This is proven: the test client lost the socket twice and still received every notification.
- **Persist** `uaid`, `channelID`, and (on the phone) the ECDH private key + `auth`, so a restart resumes the same endpoint.
- **Header field names** arrive as `crypto_key` (underscore), `encryption`, `encoding` — note the underscore.
- **Ports:** outbound **443** only. No special ports.

---

## The crypto (legacy `aesgcm`) — validated

From the forwarded push: `data` (ciphertext + 16-byte GCM tag), `encryption`→`salt`, `crypto_key`→`dh` (server public key, 65 bytes). The phone holds `private`, `auth`, and its own public key `clientPub`.

```
shared  = ECDH(private, dh)
prkKey  = HMAC_SHA256(auth,  shared)
ikm     = HMAC_SHA256(prkKey, "Content-Encoding: auth\0" || 0x01)
prk     = HMAC_SHA256(salt,  ikm)
keyInfo = "Content-Encoding: aesgcm\0" "P-256\0" ‖ 0x00 0x41 ‖ clientPub ‖ 0x00 0x41 ‖ dh
aesKey  = HMAC_SHA256(prk, keyInfo || 0x01)[0..16]
nonce   = HMAC_SHA256(prk, ("Content-Encoding: nonce\0P-256\0"‖…) || 0x01)[0..12]
plain   = AES_128_GCM_open(data, aesKey, nonce)           # tag appended
payload = plain[2 + big_endian_u16(plain[0..2]) ..]       # strip 2-byte pad length + padding → JSON
```

Validated in Node against `web-push`'s `aesgcm` output (exact match). The on-phone port is [`WebPushCrypto.swift`](../Unreeled/Notifications/WebPushCrypto.swift) (CryptoKit).

---

## Data model & privacy

Per device the service stores: a random `deviceId`, the per-user autopush identity (`uaid` + `channelID`) it needs for transport, the Mozilla endpoint, and the APNs device token. It never stores the ECDH private key, the `auth` secret, or any decrypted content; in transit it holds only ciphertext. A full compromise leaks transport metadata + ciphertext, never message content. Log nothing from the forwarded body.

---

## Legitimate use & scope

This feature gives people their **own** Instagram notifications on their **own** phone, without Instagram's addictive app. It is built to be defensible and must stay that way:

- **Consent & ownership.** Opt-in only; each person enrolls their *own* account from their *own* login. The service only handles notifications Instagram already sends *that* person.
- **End-to-end encryption.** The service forwards ciphertext; only the phone decrypts. The operator cannot read messages.
- **No third-party harm.** No scraping, mass-messaging, targeting, or acting on anyone.
- **User control.** Off anytime; logout retires it. Minimal metadata; nothing from the body logged.
- **Honest about risk.** It uses Instagram's web push and Mozilla's push service in ways neither formally supports for this; disclosed, and the user accepts the account / ToS / fragility risk before enabling.
- **Open, documented technique.** Receiving web push outside a browser via Mozilla's autopush is a documented protocol with a maintained reference client; it is not the exploit of a security vulnerability.

It is **not** for evading detection to harm anyone, reaching data a user isn't entitled to, or operating on accounts without consent, and must not be repurposed for those.

---

## Deployment (Oracle Always-Free) — how-to

- The Mozilla client is tiny per user (one WebSocket + a few KB), so the **1 GB AMD x86** Always-Free box serves many users. Use AMD x86 (not ARM — unrelated to the receiver now, but keep it standard).
- Only outbound **443** is needed (no 5228-5230). Oracle's default egress is fine.
- Oracle reclaims Always-Free VMs idle <20% CPU/network over 7 days — keep a token workload.
- Run under systemd; persist per-user identities in SQLite; re-open WebSockets on boot.

---

## Risks (much reduced vs the FCM path)

1. **Mozilla or Instagram change/stop delivering** — staleness watch + re-register from the app. Lower risk than FCM (open protocol, no reverse-engineered registration).
2. **Apple Developer Program** — blocks APNs + the NSE. (Enrolling after the gates are cleared.)
3. **Instagram account risk** — unsanctioned; disclosed to users.
4. **Connection churn** — handled by keepalive + reconnect (proven).

---

## Build plan

1. ✅ **Validate the receiver (Mozilla) + the crypto** — done.
2. **Central service** — the Mozilla client + pairing API + APNs forwarder + SQLite, with a README/runbook. *(In progress; needs no Apple account.)*
3. **iOS** — keypair/Keychain, APNs registration, opt-in + risk UI, pairing, `registerWebPush`, wire up the NSE. *(Needs the Apple Developer Program.)*
4. **Deploy** to Oracle; end-to-end test on the iPhone. *(Needs Apple.)*
5. **Harden** — staleness watch, retirement on logout, minimal metrics.

---

## Runbook (filled out as the service is built)

- **Prototype receiver:** `scratchpad/mozilla-receive.mjs` (Stage B test client) and `scratchpad/mozilla-selftest.mjs` (Stage A) — the basis for the production client.
- **Register a device to Instagram (test):** launch the Debug app with `-probe "PUSH <endpoint> <p256dh> <auth>"`; the app's `Library/Caches/network-log.jsonl` shows `{"pushRegistration":"updates.push.services.mozilla.com","status":"ok"}`.
- **Troubleshooting:** no notifications → check the app registered (network log) and the WebSocket is connected; dropped socket → reconnect handles it; stale endpoint → re-register from the app.
- *(Service install, device pairing, APNs setup, and rotation/retirement how-tos land here with step 2.)*
