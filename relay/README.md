# Unreeled notification relay

The service that passes Instagram's notifications on to iPhones running Unreeled. It receives each phone's web push from Mozilla's push service and forwards it, still encrypted, through Apple's. It never has a decryption key, so it can't read anyone's notifications.

```
Instagram ──► Mozilla's push service ──► relay (this) ──► Apple's push service ──► iPhone (decrypts)
```

The design, and why it's built this way: [docs/NOTIFICATIONS.md](../docs/NOTIFICATIONS.md).

It exists twice, answering the same calls and forwarding the same push:

- **Here**, as a Node program for any machine that's always on. This is the one that has run longest against Mozilla's service.
- **In [worker/](worker/README.md)**, as a Cloudflare Worker with a Durable Object: nothing to host. The project's own relay is this one, at `relay.unreeled.app`.

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
| `HOST` | every interface | The address to listen on. `127.0.0.1` behind an HTTPS proxy on the same machine, so that only the proxy reaches the relay |
| `DATA_FILE` | `./data/relay.json` | Where the phones' records and the Mozilla identity are kept |
| `PAIRING_TOKEN` | none | If set, `/pair` and `/unpair` need `Authorization: Bearer <token>`. Required with `APNS_KEY_FILE`: a relay that delivers won't start without one |
| `OPERATOR_TOKEN` | none | For whoever runs the relay, never in an app build: `/health` with `Authorization: Bearer <token>` also shows the counts. Without it they're never shown |
| `TRUSTED_PROXY` | none | The HTTPS proxy's address, as the relay sees it (`127.0.0.1` on the same machine). Only its `X-Forwarded-For` is believed about who's calling; several, separated by commas |
| `MAX_DEVICES` | `1000` | Pairing is refused beyond this many phones |
| `NEW_DEVICES_PER_WEEK` | `5` | New phones one caller may pair in a week (see [Limits](#limits)) |
| `DEVICE_TTL_DAYS` | `30` | How long a phone's record lasts with nothing to show the phone is real (see [How long a phone is kept](#how-long-a-phone-is-kept)) |
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

Before a phone takes a place, a relay with Apple's key asks Apple about its token, with a background push that shows nothing. If Apple says it will never deliver to it (a made-up token, or one for another app), the answer is `400 {"error":"Apple doesn't know this phone"}` and nothing is kept. Any other answer from Apple, or none within ten seconds, lets the pairing go ahead. A dry run doesn't ask.

A token has one record. A phone that pairs afresh with a token the relay already has replaces that record, and gets a new ID and endpoint; the old ID is never handed out again.

Pairing **again**, with the `deviceId` added, keeps the channel and its endpoint and only refreshes the token, the service and the topic. When the token has changed, or the phone's last-seen time (see [How long a phone is kept](#how-long-a-phone-is-kept)) is more than a day old, Apple is asked about it first, as above; if Apple says no, the relay forgets the phone and answers `400`. A `deviceId` the relay doesn't know is paired afresh, with a new endpoint, which is how a phone finds out that its old one is gone.

`POST /unpair` with `{ "deviceId": "…" }` closes the channel and forgets the phone. Instagram has no call to take an endpoint back; it stops sending once the endpoint stops answering.

`GET /health` is open, and answers according to who asks:

- Without a token: `{ ok: true }`, that the relay answers.
- With the pairing token: `{ ok, mozilla, apns }`, whether the Mozilla connection is up, and `live` or `dry-run`.
- With `OPERATOR_TOKEN`: also `devices`, `forwarded`, `failed` and `lastPushAt`, how many phones and the counts since the relay started. Nothing about any one phone.

### Limits

One caller, which is an address, or for IPv6 the /56 the address is in, may make ten pairing calls a minute, pairing again and unpairing included, and pair `NEW_DEVICES_PER_WEEK` new phones a week; beyond either the answer is `429`. Pairing again doesn't count towards the weekly number, nor does pairing afresh with a token that has a record. The counts are kept in memory only, never written anywhere, and start over when the relay restarts.

Behind a proxy every call comes from the proxy's address. Set `TRUSTED_PROXY` to it, and the relay counts by the address the proxy adds last to `X-Forwarded-For`; it believes that header from no one else, so a caller who reaches the port directly can't pass for someone else. Caddy and nginx both add it.

### How long a phone is kept

Each record has a last-seen time, set when the phone pairs, when Apple takes a push for it, and when it pairs again and Apple doesn't refuse its token (in a dry run, whenever it pairs again). A record whose time is more than `DEVICE_TTL_DAYS` old is forgotten: its channel is closed and the record removed, checked every hour. Pairing again doesn't renew a record by itself, since whoever made a record can pair it again at will; only Apple's word does, which a made-up token never gets.

A real phone that was simply quiet for that long pairs afresh the next time its app is opened, and gives Instagram its new endpoint. Records from before there was a last-seen time get the time the relay first loaded them.

## Try it without an Apple key

```bash
OPERATOR_TOKEN=try npm start &
curl -s -XPOST localhost:8787/pair -H 'content-type: application/json' \
  -d '{"apnsToken":"0000000000000000000000000000000000000000000000000000000000000000"}'
curl -s -H 'Authorization: Bearer try' localhost:8787/health
```

The answer has a real `updates.push.services.mozilla.com` endpoint, and `/health` counts one phone.

`npm test` runs the relay against stand-ins for Mozilla and Apple on this machine: pairing, forwarding, reconnecting, a lost identity, phones that are gone, what `/health` tells whom, the check with Apple, the limits, how long a phone is kept, and a Mozilla or an Apple that stops answering.

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
Environment=HOST=127.0.0.1
Environment=TRUSTED_PROXY=127.0.0.1
Environment=DATA_FILE=/opt/unreeled-relay/data/relay.json
Environment=APNS_KEY_FILE=/opt/unreeled-relay/secrets/AuthKey.p8
Environment=APNS_KEY_ID=XXXXXXXXXX
Environment=APNS_TEAM_ID=YYYYYYYYYY
Environment=APNS_TOPIC=app.unreeled
Environment=PAIRING_TOKEN=a-long-random-string
Environment=OPERATOR_TOKEN=another-long-random-string

[Install]
WantedBy=multi-user.target
```

```bash
sudo cp -r relay /opt/unreeled-relay && cd /opt/unreeled-relay && npm install --omit=dev
sudo systemctl enable --now unreeled-relay
journalctl -u unreeled-relay -f
```

Put HTTPS in front of port 8787 (Caddy, nginx, or a tunnel), so phones pair over HTTPS: the app reaches the relay at `https://<UNREELED_RELAY_HOST>`. With the proxy on the same machine, `HOST=127.0.0.1` keeps everyone else off the port, and `TRUSTED_PROXY=127.0.0.1` has the relay count calls by the address the proxy passes on (see [Limits](#limits)). A tunnel such as `cloudflared` also connects from `127.0.0.1`.

Set `PAIRING_TOKEN` and give the same value to the app's build as `UNREELED_RELAY_TOKEN`, so that only your builds can pair; with Apple's key the relay won't start without it. It ships inside the app, so it keeps strangers' scripts out rather than a determined person; the check with Apple, the limits and the record lifetime bound what they could do. `OPERATOR_TOKEN` is a different value, which stays with you.

Run it as a user of its own. `data/relay.json` and the `.p8` key should be readable by that user only; the relay writes the data file that way.

> **Oracle Always Free:** a machine whose CPU and network both stay under about 20% for 7 days is reclaimed. This relay is light, so keep a small job running beside it.

## Looking after it

- **`/health`** with `Authorization: Bearer <OPERATOR_TOKEN>` shows how many phones, whether the Mozilla connection is up, and the counts.
- **The connection drops** about every twenty minutes. That's expected: the relay reconnects with the same identity and channels, endpoints survive, and Mozilla delivers what arrived meanwhile.
- **A connection that stops answering** without closing is replaced: one that hasn't said hello thirty seconds after it was opened, and one that leaves Mozilla's `{}` ping unanswered for a minute (the relay sends one when the connection has been quiet for fifty seconds). A refused hello, or a connection that drops within a minute, makes the next wait longer, up to a minute.
- **Apple not answering** within ten seconds counts as a failed push, which is tried once more on a fresh connection; Mozilla's copy is acknowledged either way.
- **Mozilla answers with a new identity.** Rare, and the log says `new uaid`. Every endpoint is gone; the relay registers a new channel for each phone at once, and each phone picks up its new endpoint the next time its app pairs again (it does once a day, when it's opened) and gives it to Instagram.
- **A phone gets no notifications.** Check that it's in `data/relay.json`, that `/health` shows the Mozilla connection, and that the app did register with Instagram (turn notifications off and on in its Settings). Instagram can also stop delivering without saying so.
- **A phone is gone.** When Apple answers that a token no longer exists, the relay forgets the phone. So does a record that has run out (see [How long a phone is kept](#how-long-a-phone-is-kept)). The log says `[forget]`.
- **Instagram changes its push key.** Set `INSTAGRAM_VAPID_KEY` and have the phones turn notifications off and on.
- **A new push key from Apple.** Put the new `.p8` in place, update `APNS_KEY_ID`, restart.
- **Backups.** `data/relay.json` is the only state: the Mozilla identity, and per phone an ID, a channel, an endpoint, an Apple token and when the phone was last seen. No keys, no content, and no addresses. Losing it means every phone gets a new endpoint the next time its app pairs, and no notifications until then.

## Privacy and scope

The relay forwards ciphertext; the keys never leave the phone. It handles each person's own notifications, which they turned on from their own Instagram login, and logs nothing from a push but its size. It isn't a tool for reading other people's data or acting on accounts without consent. See "Legitimate use and scope" in [docs/NOTIFICATIONS.md](../docs/NOTIFICATIONS.md).
