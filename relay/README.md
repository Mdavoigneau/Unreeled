# Unreeled notification relay

The central, opt-in, **end-to-end-encrypted** service that gives Unreeled instant Instagram
notifications on the iPhone. It receives each opt-in user's Instagram web push from **Mozilla's push
service** and forwards it — **still encrypted** — to their phone via **APNs**. The relay never holds a
decryption key, so it cannot read anyone's notifications.

Design and rationale: [`../docs/NOTIFICATIONS.md`](../docs/NOTIFICATIONS.md).

```
Instagram ──web push──▶ Mozilla push ──▶ relay (this) ──APNs (ciphertext)──▶ iPhone (decrypts)
```

## Why this is small and maintainable

- The receiver is Mozilla's **open, documented** WebSocket protocol — not reverse-engineered FCM.
- **One** WebSocket connection serves **all** devices (one channel per device), so one tiny box
  scales to many users.
- The only dependency is `ws`. Everything else (HTTP/2 for APNs, crypto for the JWT, the JSON store)
  is a Node built-in.
- Outbound **443 only**. No special ports.

## Requirements

- Node ≥ 20.
- For live delivery: an Apple Developer Program account and an **APNs auth key** (`.p8`). Without it
  the relay runs in **dry-run** (it logs what it would send) so you can build and test everything else.

## Install & run

```bash
cd relay
npm install
npm start
```

On start it connects to Mozilla, resumes any known devices, and serves the pairing API on `:8787`.
APNs shows `LIVE` or `DRY-RUN` in the startup log.

## Configuration (environment variables)

| Var | Default | Meaning |
|-----|---------|---------|
| `PORT` | `8787` | Pairing API port |
| `DATA_FILE` | `./data/relay.json` | Where device records + the Mozilla `uaid` are stored |
| `AUTOPUSH_URL` | `wss://push.services.mozilla.com` | Mozilla push endpoint |
| `INSTAGRAM_VAPID_KEY` | *(built in)* | Instagram's web-push public key; override if Instagram rotates it |
| `PAIRING_TOKEN` | *(none)* | If set, `/pair` and `/unpair` require `Authorization: Bearer <token>` |
| `APNS_KEY_FILE` | — | Path to the `.p8` APNs auth key |
| `APNS_KEY_ID` | — | The key's ID (from Apple) |
| `APNS_TEAM_ID` | — | Your Apple team ID |
| `APNS_TOPIC` | — | The app's bundle id (e.g. `app.unreeled`) |
| `APNS_ENV` | `production` | `sandbox` to use Apple's sandbox |

## The pairing flow (how a phone gets connected)

1. The **phone** generates a P-256 keypair + a 16-byte `auth` (private key stays in its Keychain) and
   gets an APNs device token.
2. The phone calls **`POST /pair`** with `{ "apnsToken": "…" }`. The relay registers a new Mozilla
   channel and replies `{ "deviceId": "…", "endpoint": "https://updates.push.services.mozilla.com/…" }`.
3. The phone registers that **endpoint** with Instagram via `registerWebPush(endpoint, p256dh, auth)`
   — using the phone's own `p256dh`/`auth`. **The relay never sees these keys.**
4. From then on, Instagram → Mozilla → relay → (ciphertext over APNs) → phone decrypts in its
   Notification Service Extension.

To disconnect: **`POST /unpair`** with `{ "deviceId": "…" }`. (Instagram has no unregister call, so
the endpoint also just goes stale once the channel is dropped.)

`GET /health` → `{ ok, devices, mozilla }`.

### Quick local test (dry-run, no account needed)

```bash
npm start &
curl -s localhost:8787/health
curl -s -XPOST localhost:8787/pair -H 'content-type: application/json' -d '{"apnsToken":"testtoken"}'
```

You should get back a real `updates.push.services.mozilla.com` endpoint, and `/health` should show one
device. (Registering that endpoint with a real Instagram account, then sending a message, is how the
gate tests confirmed delivery — see `../docs/NOTIFICATIONS.md`.)

## Deploy on the Oracle box (systemd)

```ini
# /etc/systemd/system/unreeled-relay.service
[Unit]
Description=Unreeled notification relay
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/unreeled-relay
ExecStart=/usr/bin/node src/index.mjs
Restart=always
RestartSec=5
Environment=PORT=8787
Environment=DATA_FILE=/opt/unreeled-relay/data/relay.json
Environment=APNS_KEY_FILE=/opt/unreeled-relay/secrets/AuthKey.p8
Environment=APNS_KEY_ID=XXXXXXXXXX
Environment=APNS_TEAM_ID=YYYYYYYYYY
Environment=APNS_TOPIC=app.unreeled
# Environment=PAIRING_TOKEN=... (recommended; see Hardening)

[Install]
WantedBy=multi-user.target
```

```bash
sudo cp -r relay /opt/unreeled-relay && cd /opt/unreeled-relay && npm install --omit=dev
sudo systemctl enable --now unreeled-relay
journalctl -u unreeled-relay -f
```

Put a TLS reverse proxy (Caddy/nginx) in front of `:8787` so the phone pairs over HTTPS. Only
outbound 443 to Mozilla/Apple is required; inbound is just your pairing port.

> **Oracle Always-Free note:** the VM is reclaimed if CPU **and** network stay under ~20% over 7
> days. This relay is light, so keep a token workload (or a small cron) alive to avoid reclamation.

## Maintenance / troubleshooting

- **Connection drops** — expected (~every 20 min). The client reconnects and resumes the same
  `uaid` + channels automatically; endpoints survive, and Mozilla redelivers anything queued while
  offline. Nothing to do.
- **No notifications for a user** — check: the device is in `data/relay.json`; `/health` shows the
  Mozilla connection; the phone actually called `registerWebPush` (the app logs the result). Instagram
  can also silently stop delivering (it's unsanctioned) — have the app re-assert registration on open.
- **Instagram rotates its VAPID key** — set `INSTAGRAM_VAPID_KEY` and re-pair devices.
- **Rotating the APNs key** — drop in a new `.p8`, update `APNS_KEY_ID`, restart.
- **Backups** — `data/relay.json` is the only state. It holds transport identifiers + APNs tokens,
  **no** decryption keys and **no** message content.

## Privacy & scope

This relay forwards ciphertext only; the decryption key never leaves the user's phone. It handles each
user's **own** notifications, which they opt into from their own Instagram login. It is not a tool for
reading others' data or acting on accounts without consent. See the "Legitimate use & scope" section
of [`../docs/NOTIFICATIONS.md`](../docs/NOTIFICATIONS.md).
