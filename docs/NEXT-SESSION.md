# Next session — Unreeled push notifications

**Status (2026-11-12):** The approach is **fully validated** and the **central relay is built and tested** (dry-run). What remains is the **iOS app side** and **going live on APNs**, both of which need the **Apple Developer Program** — enroll now, since every gate is cleared.

---

## What's already done

- **All gates passed** (details in [`NOTIFICATIONS.md`](NOTIFICATIONS.md) → *What's proven*):
  - Instagram delivers web push to **Mozilla's open push service** (4 real pushes received on a Mozilla endpoint, VAPID-signed by Instagram).
  - A non-browser **Mozilla autopush client** registers a VAPID channel and receives — with keepalive + reconnect proven across drops.
  - **`aesgcm` decryption validated** against the on-phone algorithm (exact match).
- **Central relay built + tested (dry-run):** [`../relay/`](../relay/) — Node, one dependency (`ws`). One Mozilla WebSocket (many channels) → forwards **ciphertext** to APNs. Pairing API, JSON store, APNs forwarder (native HTTP/2 + ES256), runbook. Verified: `/pair` returns a real Mozilla endpoint; `/health` works; forward path runs in dry-run.
- **On-phone decryptor written:** [`../Unreeled/Notifications/WebPushCrypto.swift`](../Unreeled/Notifications/WebPushCrypto.swift) (legacy `aesgcm`, CryptoKit). Algorithm validated; **not yet wired into a Notification Service Extension**.
- **Design + runbook:** [`NOTIFICATIONS.md`](NOTIFICATIONS.md), [`../relay/README.md`](../relay/README.md).

## Do first

1. **Enroll in the Apple Developer Program.** It unblocks APNs delivery and the Notification Service Extension — the only things gating the rest.

## Build order

1. **Bring in `registerWebPush` + the Debug `-probe "PUSH …"` harness.** ⚠️ They live on branch **`matteo/dm-notification-support-a88776`**, *not* on this branch (`matteo/browser-notification-relay-190821`). Merge or cherry-pick them — the iOS pairing step needs `registerWebPush`.
2. **iOS app side (no Apple needed):**
   - On opt-in: generate a P-256 keypair + 16-byte `auth`; keep the private key in the Keychain.
   - Opt-in + **risk-disclosure** screen (see `NOTIFICATIONS.md` → *Legitimate use & scope* and *Opt-in & risk disclosure*).
   - Pair: `POST <relay>/pair {apnsToken}` → `{deviceId, endpoint}`; then `registerWebPush(endpoint, p256dh, auth)` (from the user's own login).
   - Persist `deviceId`; retire on logout via `POST <relay>/unpair`.
3. **Notification Service Extension (needs Apple):** new extension target; read `wp:{data,headers}` from the APNs payload; decrypt with `WebPushCrypto.swift`; show the notification. Add the push entitlement + request authorization.
4. **Relay live on Oracle:** deploy per `relay/README.md` (systemd + TLS reverse proxy); drop in the `.p8` and set the `APNS_*` env vars; set `PAIRING_TOKEN`.
5. **End-to-end test** on the iPhone: a real DM → notification appears, decrypted on-device.
6. **Harden:** staleness watch (Instagram can silently stop delivering — mautrix/meta#454), retire-on-logout, minimal metrics; update `PRIVACY.md` (the relay handles a device token + ciphertext, never plaintext).

## State & gotchas to know

- **Account writes to his Instagram need his explicit, same-turn OK.**
- **Stale test registrations** sit on his account from the gate tests: 2 Mozilla endpoints (registered 09:00 and 09:24 UTC) + 1 earlier FCM one. There is no unregister API, so they just go stale — harmless.
- **Docker** is still running on his Mac from the earlier FCM experiments (ask before stopping). The Mozilla path needs **no** Docker.
- The **prototypes** (`mozilla-selftest.mjs`, `mozilla-receive.mjs`, `aesgcm-selftest.mjs`) are in the session scratchpad (ephemeral). The productized versions are in `relay/`.
- Mozilla notification **headers** arrive as `crypto_key` (underscore), `encryption`, `encoding`. The receiver needs only outbound **443**; the socket drops ~every 20 min and auto-reconnects.
- **Everything on this branch is currently uncommitted** (`relay/`, `docs/NOTIFICATIONS.md`, `docs/NEXT-SESSION.md`, `Unreeled/Notifications/WebPushCrypto.swift`).
