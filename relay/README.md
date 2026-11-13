# Unreeled notification relay

The service that passes Instagram's notifications on to iPhones running Unreeled. It receives each phone's web push from Mozilla's push service and forwards it, still encrypted, through Apple's. It never has a decryption key, so it can't read anyone's notifications.

```
Instagram ──► Mozilla's push service ──► relay (this) ──► Apple's push service ──► iPhone (decrypts)
```

The design, and why it's built this way: [docs/NOTIFICATIONS.md](../docs/NOTIFICATIONS.md).

It exists twice, answering the same calls and forwarding the same push:

- **Here**, as a Node program for any machine that's always on. This is the one that has run longest against Mozilla's service.
- **In [worker/](worker/README.md)**, as a Cloudflare Worker with a Durable Object: nothing to host. The project's own relay is this one, at `relay.unreeled.app`, for now as a dry run without Apple's key.

The rest of this page is about the Node one. What the two share (the pairing calls, what's stored, the privacy) is the same in both.

## Why it's small

- The receiving side is Mozilla's open, documented WebSocket protocol.
- One WebSocket serves every phone, with a channel each, so one small machine goes a long way.
- The only dependency is `ws`. HTTP/2 to Apple, the signing for it and the JSON store are Node built-ins.
- It needs outbound port 443 and nothing else.

## Requirements

- Node 20 or later.
- To deliver: a team in the Apple Developer Program and a push key from it (a `.p8` file). Without one the relay runs as a **dry run**: it does everything else and logs what it would send.

## Run it

```bash
cd relay
npm install
npm start
```

It connects to Mozilla, resumes the phones it knows, and serves the pairing API on port 8787. The log says whether Apple delivery is `LIVE` or `DRY-RUN`.

## Settings

All through environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `PORT` | `8787` | The pairing API's port |
| `DATA_FILE` | `./data/relay.json` | Where the phones' records and the Mozilla identity are kept |
| `PAIRING_TOKEN` | none | If set, `/pair` and `/unpair` need `Authorization: Bearer <token>` |
| `MAX_DEVICES` | `1000` | Pairing is refused beyond this many phones |
| `APNS_KEY_FILE` | | Path to the `.p8` push key |
| `APNS_KEY_ID` | | The key's ID, from Apple |
| `APNS_TEAM_ID` | | The Apple team's ID |
| `APNS_TOPIC` | | The app's bundle ID. Several, separated by commas, if the same team signs more than one build of the app; the first is used for a phone that names none |
| `APNS_ENV` | `production` | `sandbox` to use Apple's sandbox service for a phone that doesn't say which it's on. The app does say |
| `APNS_OUTBOX` | none | Dry run only: a folder to write each push to, as a file `xcrun simctl push` takes |
| `INSTAGRAM_VAPID_KEY` | built in | Instagram's web push public key. Change it if Instagram does |
| `AUTOPUSH_URL` | `wss://push.services.mozilla.com` | Mozilla's push service |

Apple only accepts a push for an app from a key of the team that signed the app. So the relay's key and the builds it serves have to come from one team.

## The pairing API

`POST /pair` with `{ "apnsToken": "<the device token in hex>", "sandbox": true, "topic": "<bundle ID>" }`. Only `apnsToken` is required. The relay registers a channel at Mozilla and answers `{ "deviceId": "…", "endpoint": "https://updates.push.services.mozilla.com/…" }`. The phone then registers that `endpoint` with Instagram, with its own public key and `auth`. The relay never sees those.

Pairing **again**, with the `deviceId` added, keeps the channel and its endpoint and only refreshes the token, the service and the topic. A `deviceId` the relay doesn't know is paired afresh, with a new endpoint, which is how a phone finds out that its old one is gone.

`POST /unpair` with `{ "deviceId": "…" }` closes the channel and forgets the phone. Instagram has no call to take an endpoint back; it stops sending once the endpoint stops answering.

`GET /health` answers `{ ok, devices, mozilla, apns, forwarded, failed, lastPushAt }`: how many phones, whether the Mozilla connection is up, `live` or `dry-run`, and counts since the relay started. Nothing about any one phone.

## Try it without an Apple key

```bash
npm start &
curl -s localhost:8787/health
curl -s -XPOST localhost:8787/pair -H 'content-type: application/json' \
  -d '{"apnsToken":"0000000000000000000000000000000000000000000000000000000000000000"}'
```

The answer has a real `updates.push.services.mozilla.com` endpoint, and `/health` counts one phone.

`npm test` runs the relay against stand-ins for Mozilla and Apple on this machine: pairing, forwarding, reconnecting, a lost identity, phones that are gone.

[tools/sample-push.mjs](tools/sample-push.mjs) stands in for Instagram: it encrypts a notification shaped like Instagram's with the `web-push` library and sends it through Mozilla's real service to a relay started with its key. With the app in the simulator that tests everything but Apple's leg; the steps are under Testing in [docs/NOTIFICATIONS.md](../docs/NOTIFICATIONS.md). `web-push` is a development dependency: a deployed relay doesn't install it.

## On a server (systemd)

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
Environment=PAIRING_TOKEN=a-long-random-string

[Install]
WantedBy=multi-user.target
```

```bash
sudo cp -r relay /opt/unreeled-relay && cd /opt/unreeled-relay && npm install --omit=dev
sudo systemctl enable --now unreeled-relay
journalctl -u unreeled-relay -f
```

Put HTTPS in front of port 8787 (Caddy, nginx, or a tunnel), so phones pair over HTTPS: the app reaches the relay at `https://<UNREELED_RELAY_HOST>`. Set `PAIRING_TOKEN` and give the same value to the app's build as `UNREELED_RELAY_TOKEN`, so that only your builds can pair. It ships inside the app, so it keeps strangers' scripts out rather than a determined person; `MAX_DEVICES` bounds what they could do.

Run it as a user of its own. `data/relay.json` and the `.p8` key should be readable by that user only; the relay writes the data file that way.

> **Oracle Always Free:** a machine whose CPU and network both stay under about 20% for 7 days is reclaimed. This relay is light, so keep a small job running beside it.

## Looking after it

- **The connection drops** about every twenty minutes. That's expected: the relay reconnects with the same identity and channels, endpoints survive, and Mozilla delivers what arrived meanwhile.
- **Mozilla answers with a new identity.** Rare, and the log says `new uaid`. Every endpoint is gone; the relay registers a new channel for each phone at once, and each phone picks up its new endpoint the next time its app pairs again (it does once a day, when it's opened) and gives it to Instagram.
- **A phone gets no notifications.** Check that it's in `data/relay.json`, that `/health` shows the Mozilla connection, and that the app did register with Instagram (turn notifications off and on in its Settings). Instagram can also stop delivering without saying so.
- **A phone is gone.** When Apple answers that a token no longer exists, the relay forgets the phone. The log says `[forget]`.
- **Instagram changes its push key.** Set `INSTAGRAM_VAPID_KEY` and have the phones turn notifications off and on.
- **A new push key from Apple.** Put the new `.p8` in place, update `APNS_KEY_ID`, restart.
- **Backups.** `data/relay.json` is the only state: the Mozilla identity, and per phone an ID, a channel, an endpoint and an Apple token. No keys, no content. Losing it means every phone gets a new endpoint the next time its app pairs, and no notifications until then.

## Privacy and scope

The relay forwards ciphertext; the keys never leave the phone. It handles each person's own notifications, which they turned on from their own Instagram login, and logs nothing from a push but its size. It isn't a tool for reading other people's data or acting on accounts without consent. See "Legitimate use and scope" in [docs/NOTIFICATIONS.md](../docs/NOTIFICATIONS.md).
