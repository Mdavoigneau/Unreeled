# The relay on Cloudflare

The same relay as [../](../README.md), written for Cloudflare Workers: no machine to look after, HTTPS and the host name included. It answers the same calls and forwards the same push, so the app can't tell the two apart.

```
Instagram ──► Mozilla's push service ──► Durable Object `Relay` ──► Apple's push service ──► iPhone (decrypts)
                                              ▲
                              the app's pairing calls, through the Worker
```

- **The Worker** ([src/index.ts](src/index.ts)) takes `/pair`, `/unpair`, `/health` and `/apple`, checks the tokens and the pairing limit, and hands the work to the object. A request without a token never reaches the object.
- **One Durable Object, `Relay`** ([src/relay.ts](src/relay.ts)), is the relay itself. It keeps the WebSocket to Mozilla open ([src/mozilla.ts](src/mozilla.ts)), stores one record per phone in its own SQLite storage, and sends each push on to Apple ([src/apns.ts](src/apns.ts)).

**Deployed** since 13 November 2026, at `relay.unreeled.app`, first as a dry run and then live, with Apple's key. From there it holds its connection to Mozilla's service, pairs and unpairs phones, and Apple accepts its key (see [Apple, and why it can't be tried locally](#apple-and-why-it-cant-be-tried-locally)). The same day it carried Instagram's real notifications to an iPhone. Still to see: how the connection to Mozilla holds up over days.

## How it stays connected

A Worker only runs while it has something to do. A Durable Object with an open outgoing WebSocket stays in memory, and Cloudflare restarts it when it deploys new code or updates its runtime, which closes the connection. So the object sets an alarm for a minute ahead, every minute. The alarm:

- **wakes the object after a restart**, and it reconnects with the identity and channels in its storage, so every phone's endpoint stays the same. Mozilla keeps what arrived meanwhile and delivers it then;
- **keeps the connection open and checks it**: a connection that carries nothing for about two minutes is closed somewhere on the way (seen on the first deployment), so each minute a quiet one is sent Mozilla's `{}` ping, which Mozilla answers. One that hasn't answered by the next minute is dead, and is replaced.

When the connection closes on its own (Mozilla does that every twenty minutes or so), the object reconnects after two to two and a half seconds without waiting for the alarm. A hello Mozilla refuses, or a connection that closes less than a minute after its hello, makes the next wait twice as long, up to a minute; neither the alarm nor a pairing call cuts that wait short.

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
| `RELAY_PAIRING_TOKEN` | Require `Authorization: Bearer <token>`. Left out, pairing is open, which only this machine allows |
| `RELAY_OPERATOR_TOKEN` | The operator token: `/health` with it shows the counts, and `/apple` answers |
| `RELAY_APNS_KEY`, `RELAY_APNS_KEY_ID`, `RELAY_APNS_TEAM_ID`, `RELAY_APNS_TOPIC` | Apple's key and what goes with it. Sending still can't work locally: see below |
| `RELAY_DEVICE_TTL_DAYS`, `RELAY_MAX_DEVICES` | As deployed; days can be a fraction, for trying the record lifetime |

The test with the app in the simulator is the one under Testing in [docs/NOTIFICATIONS.md](../../docs/NOTIFICATIONS.md), with this relay in place of the Node one: run the app with `-relay http://127.0.0.1:8788`, and take the push to deliver from `curl -s http://127.0.0.1:8788/outbox`.

`npm test` runs twenty-eight tests, each starting its own relay with its own storage, against stand-ins for Mozilla and Apple: the Node relay's cases, plus coming back after a restart with nothing but the alarm to wake it, replacing a connection that stopped answering, keeping requests without a token away from the object, and records from before the last-seen time. `npm run typecheck` checks the types.

### Apple, and why it can't be tried locally

Apple's push service only speaks HTTP/2, and the copy of Cloudflare's runtime that runs on your machine only speaks HTTP/1.1 to other servers: a push sent from there fails with "Network connection lost". Cloudflare's network does speak HTTP/2 for a deployed Worker: the deployed relay got Apple's answer on 13 November 2026. A deployed relay says so itself, to whoever has the operator token:

```bash
curl -s -H "Authorization: Bearer $OPERATOR_TOKEN" https://<the relay>/apple
```

It sends Apple one push for a token no phone has, and reports the answer (or `reachable: false` when Apple hasn't answered within ten seconds). Each call counts against the pairing limit below:

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
     "OPERATOR_TOKEN": "another long random string",
     "APNS_KEY": "-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----\n",
     "APNS_KEY_ID": "XXXXXXXXXX",
     "APNS_TEAM_ID": "YYYYYYYYYY",
     "APNS_TOPIC": "app.unreeled"
   }
   ```

   `APNS_KEY` is the whole text of the `.p8` file. `APNS_TOPIC` is the app's bundle ID, or several separated by commas; without one nothing is sent to Apple. `PAIRING_TOKEN` is the value the app's build carries as `UNREELED_RELAY_TOKEN`; an empty one lets no one pair. `OPERATOR_TOKEN` is for you alone, never in a build and never the pairing token's value: with it `/health` shows the counts and `/apple` answers. It's optional; without it, neither is served. `cf deploy` uploads every entry of the file, so it's bound when the file has it, and like the other secrets it stays through later deploys (`npx cf workers secrets delete OPERATOR_TOKEN --worker unreeled-relay` removes it).

2. **Deploy:**

   ```bash
   npx cf deploy --secrets-file <path to that file>
   ```

   The deploy fails if a required secret is missing, so a relay can't go out without Apple's key by accident. To deploy one on purpose before there is a key, as a dry run, leave the four `APNS_` entries out of the file and run `RELAY_DRY_RUN=1 npx cf deploy --secrets-file <path>`.

3. **Start it:** `curl -s -H "Authorization: Bearer $OPERATOR_TOKEN" https://<the relay>/health` (the pairing token does too). The first request with a token creates the object, which connects to Mozilla and sets its alarm; from then on it keeps itself running. `mozilla` is `true` a second or two later. Without a token `/health` only answers `{"ok":true}`, from the Worker, and doesn't create the object.

4. **Check Apple:** the `/apple` call above.

The host name is in [cloudflare.config.ts](cloudflare.config.ts), with the Worker's name. A Worker's custom domain can only belong to one Worker: detach it from another that has it before deploying.

## Looking after it

- **`/health`** answers according to who asks. Without a token, `{"ok":true}`: the Worker answers, and the object isn't asked. With the pairing token, `{ ok, mozilla, apns }`: whether the connection to Mozilla is up, and `live` or `dry-run`. With the operator token, also how many phones, since when the connection has been up, how many pushes were forwarded and failed, and when the last one was. Since no logs are kept, it also counts how the relay itself fares: `starts`, the times Cloudflare has started the object, and `connections`, the times it has connected to Mozilla. Both grow slowly on a healthy relay: a start per deploy or runtime update, a connection every twenty minutes or so. The counts are kept in storage, so they survive restarts.
- **Logs** aren't kept: `observability` is off, because the privacy policy says pairing calls aren't logged. To watch the relay live, `npx wrangler tail unreeled-relay` shows what it prints while you look: pairings by the first characters of an ID, pushes by size, never a push's content.
- **A deploy** reaches the running object after a few minutes (about five, the one time it was measured): until then it answers with the old code. Then Cloudflare restarts it, and it reconnects with the same identity; nothing else to do.
- **Pairing is limited** to ten calls a minute from one address, an IPv6 address counted by the /56 it's in, with unpairing and `/apple` counted alongside; and to `MAX_DEVICES` phones (1000) in all. Cloudflare's rate limit can't count over more than a minute, so unlike the Node relay this one has no weekly limit on new phones per address; the check with Apple and the record lifetime below are what keep made-up phones out.
- **Apple is asked about a phone** before it takes a place, with a background push that shows nothing: a token Apple says it will never deliver to (a made-up one, or one for another app) gets `400 {"error":"Apple doesn't know this phone"}` and nothing is kept. Any other answer, or none within ten seconds, lets the pairing go ahead. Pairing again asks the same when the token has changed, or when the phone's last-seen time is more than a day old, and Apple saying no forgets the phone. A token has one record: pairing afresh with one the relay has replaces its record. A dry run asks nothing.
- **How long a phone is kept:** each record has a last-seen time, set when the phone pairs, when Apple takes a push for it, and when it pairs again and Apple doesn't refuse its token (in a dry run, whenever it pairs again). The alarm forgets, once an hour, the records whose time is more than `DEVICE_TTL_DAYS` (30) old: their channels are closed and the rows deleted. Pairing again doesn't renew a record by itself, since whoever made a record can pair it again at will. A real phone that was simply quiet that long pairs afresh the next time its app is opened. Records from before there was a last-seen time got the time of the deploy that added it.
- **Apple not answering** within ten seconds counts as a failed push, tried once more; Mozilla's copy is acknowledged either way.
- **The storage** is the object's own SQLite database: per phone an ID, a Mozilla channel and its endpoint, the phone's token at Apple, which of Apple's services it's on, the app's bundle ID, when it was paired and when it was last seen; and the relay's identity at Mozilla. No keys, no content, no addresses. Deleting the Worker deletes it, and every phone then gets a new endpoint the next time its app pairs.
- **Instagram changes its push key:** change `INSTAGRAM_VAPID_KEY` in the config, deploy, and have the phones turn notifications off and on.
