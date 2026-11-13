# The relay on Cloudflare

The same relay as [../](../README.md), written for Cloudflare Workers: no machine to look after, HTTPS and the host name included. It answers the same calls and forwards the same push, so the app can't tell the two apart.

```
Instagram ──► Mozilla's push service ──► Durable Object `Relay` ──► Apple's push service ──► iPhone (decrypts)
                                              ▲
                              the app's pairing calls, through the Worker
```

- **The Worker** ([src/index.ts](src/index.ts)) takes `/pair`, `/unpair` and `/health`, checks the pairing token, and hands the work to the object.
- **One Durable Object, `Relay`** ([src/relay.ts](src/relay.ts)), is the relay itself. It keeps the WebSocket to Mozilla open ([src/mozilla.ts](src/mozilla.ts)), stores one record per phone in its own SQLite storage, and sends each push on to Apple ([src/apns.ts](src/apns.ts)).

**Deployed as a dry run** since 13 November 2026, at `relay.unreeled.app`: everything but Apple's key. From there it holds its connection to Mozilla's service, pairs and unpairs phones, and reaches Apple (see [Apple, and why it can't be tried locally](#apple-and-why-it-cant-be-tried-locally)). Still to see: how the connection to Mozilla holds up over days, and a real push to a real phone, which needs the key.

## How it stays connected

A Worker only runs while it has something to do. A Durable Object with an open outgoing WebSocket stays in memory, and Cloudflare restarts it when it deploys new code or updates its runtime, which closes the connection. So the object sets an alarm for a minute ahead, every minute. The alarm:

- **wakes the object after a restart**, and it reconnects with the identity and channels in its storage, so every phone's endpoint stays the same. Mozilla keeps what arrived meanwhile and delivers it then;
- **keeps the connection open and checks it**: a connection that carries nothing for about two minutes is closed somewhere on the way (seen on the first deployment), so each minute a quiet one is sent Mozilla's `{}` ping, which Mozilla answers. One that hasn't answered by the next minute is dead, and is replaced.

When the connection closes on its own (Mozilla does that every twenty minutes or so), the object reconnects after two seconds without waiting for the alarm.

One object in memory all month is about 332,000 GB-seconds: inside the 400,000 the Workers Paid plan includes, and just under the free plan's 13,000 a day.

## Run it on your machine

Node 22.18 or later.

```bash
cd relay/worker
npm install
npx vite --host 127.0.0.1 --port 8788
```

It connects to Mozilla from your machine and serves the pairing API on port 8788, as a dry run: without Apple's key it does everything but send to Apple. Local storage is in `.cloudflare/state`; delete the folder to start over.

On your machine, settings come from the environment as `RELAY_<NAME>`:

| Variable | Meaning |
|----------|---------|
| `RELAY_INSTAGRAM_VAPID_KEY` | The key whose pushes the relay's channels accept. `$(node ../tools/sample-push.mjs key)` to test with the stand-in sender |
| `RELAY_OUTBOX=1` | Keep the last pushes a dry run would have sent, and serve them at `GET /outbox` as files `xcrun simctl push` takes |
| `RELAY_PAIRING_TOKEN` | Require `Authorization: Bearer <token>` |
| `RELAY_APNS_KEY`, `RELAY_APNS_KEY_ID`, `RELAY_APNS_TEAM_ID`, `RELAY_APNS_TOPIC` | Apple's key and what goes with it. Sending still can't work locally: see below |

The test with the app in the simulator is the one under Testing in [docs/NOTIFICATIONS.md](../../docs/NOTIFICATIONS.md), with this relay in place of the Node one: run the app with `-relay http://127.0.0.1:8788`, and take the push to deliver from `curl -s http://127.0.0.1:8788/outbox`.

`npm test` runs fourteen tests, each starting its own relay with its own storage, against stand-ins for Mozilla and Apple: the Node relay's cases, plus coming back after a restart with nothing but the alarm to wake it, and replacing a connection that stopped answering. `npm run typecheck` checks the types.

### Apple, and why it can't be tried locally

Apple's push service only speaks HTTP/2, and the copy of Cloudflare's runtime that runs on your machine only speaks HTTP/1.1 to other servers: a push sent from there fails with "Network connection lost". Cloudflare's network does speak HTTP/2 for a deployed Worker: the deployed relay got Apple's answer on 13 November 2026. A deployed relay says so itself:

```bash
curl -s -H "Authorization: Bearer $TOKEN" https://<the relay>/apple
```

It sends Apple one push for a token no phone has, and reports the answer:

| Answer | Meaning |
|--------|---------|
| `reachable: true`, `BadDeviceToken` | Apple was reached and accepted the key: all is well |
| `reachable: true`, `MissingProviderToken` | Apple was reached; this relay is a dry run |
| `reachable: true`, `InvalidProviderToken` | Apple was reached and refused the key: check the key, its ID and the team ID |
| `reachable: false` | Apple couldn't be reached from Cloudflare. The Node relay can do what this one can't |

## Deploy

With the `cf` CLI signed in (`npx cf auth whoami`).

1. **Secrets**, in a JSON file outside the repository:

   ```json
   {
     "PAIRING_TOKEN": "a long random string",
     "APNS_KEY": "-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----\n",
     "APNS_KEY_ID": "XXXXXXXXXX",
     "APNS_TEAM_ID": "YYYYYYYYYY",
     "APNS_TOPIC": "app.unreeled"
   }
   ```

   `APNS_KEY` is the whole text of the `.p8` file. `APNS_TOPIC` is the app's bundle ID, or several separated by commas. `PAIRING_TOKEN` is the value the app's build carries as `UNREELED_RELAY_TOKEN`.

2. **Deploy:**

   ```bash
   npx cf deploy --secrets-file <path to that file>
   ```

   The deploy fails if a secret is missing, so a relay can't go out without Apple's key by accident. To deploy one on purpose before there is a key, as a dry run, leave the four `APNS_` entries out of the file and run `RELAY_DRY_RUN=1 npx cf deploy --secrets-file <path>`.

3. **Start it:** `curl https://<the relay>/health`. The first request creates the object, which connects to Mozilla and sets its alarm; from then on it keeps itself running. `mozilla` is `true` a second or two later.

4. **Check Apple:** the `/apple` call above.

The host name is in [cloudflare.config.ts](cloudflare.config.ts), with the Worker's name. A Worker's custom domain can only belong to one Worker: detach it from another that has it before deploying.

## Looking after it

- **`/health`** says how many phones, whether the connection to Mozilla is up and since when, `live` or `dry-run`, how many pushes were forwarded and failed, and when the last one was. Since no logs are kept, it also counts how the relay itself fares: `starts`, the times Cloudflare has started the object, and `connections`, the times it has connected to Mozilla. Both grow slowly on a healthy relay: a start per deploy or runtime update, a connection every twenty minutes or so. The counts are kept in storage, so they survive restarts.
- **Logs** aren't kept: `observability` is off, because the privacy policy says pairing calls aren't logged. To watch the relay live, `npx wrangler tail unreeled-relay` shows what it prints while you look: pairings by the first characters of an ID, pushes by size, never a push's content.
- **A deploy** reaches the running object after a few minutes (about five, the one time it was measured): until then it answers with the old code. Then Cloudflare restarts it, and it reconnects with the same identity; nothing else to do.
- **Pairing is limited** to ten calls a minute from one address, and to `MAX_DEVICES` phones (1000) in all.
- **The storage** is the object's own SQLite database: per phone an ID, a Mozilla channel and its endpoint, the phone's token at Apple, which of Apple's services it's on and the app's bundle ID; and the relay's identity at Mozilla. No keys, no content. Deleting the Worker deletes it, and every phone then gets a new endpoint the next time its app pairs.
- **Instagram changes its push key:** change `INSTAGRAM_VAPID_KEY` in the config, deploy, and have the phones turn notifications off and on.
