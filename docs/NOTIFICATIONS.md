# Notifications

How Unreeled shows Instagram's notifications (messages, likes, follows) on the iPhone while the app is closed, without Instagram's app.

**Where it stands (13 November 2026).** The relay, the app's side and the notification extension are built, and the whole route has run for real: Instagram's notifications reached an iPhone through Mozilla's push service, the relay and Apple's, and showed there decrypted. The relay exists as a Node program and as a Cloudflare Worker; the Worker is deployed at `relay.unreeled.app`, live, with Apple's push key. What's left is to see how it holds over days. See [What's left](#whats-left).

It's off unless you turn it on, and a build only offers it when it was made with a relay (see [Building with notifications](#building-with-notifications)).

## Principles

1. **You turn it on.** The app asks once, says what it means, and does nothing without a yes.
2. **End to end.** Instagram encrypts each notification for keys that never leave the phone. The relay passes on ciphertext it can't read.
3. **Your login stays on your phone.** The phone itself gives Instagram the push address, as a browser would. The relay never talks to Instagram and holds nothing of your account.
4. **Small.** One small machine serves many phones. The receiving side is a documented protocol with one dependency.

## How it works

```
  Instagram ──► Mozilla's push service ──► relay ──► Apple's push service ──► iPhone
  encrypts for    holds a push address      passes on    delivers             decrypts,
  the phone       for each phone            ciphertext                        shows it
```

Instagram's website can notify a browser through web push: the browser gets a push address from its maker's push service, gives it to Instagram with a public key, and Instagram sends each notification there, encrypted for that key. Unreeled does the same with the parts split in two:

| Part | Who has it | What for |
|------|-----------|----------|
| The push address (at Mozilla's push service) | The relay | Receiving the bytes |
| The key pair and the `auth` secret | The phone, in its Keychain | Reading them |

So what the relay receives is ciphertext, and what it sends on through Apple is the same ciphertext. Only the phone can decrypt it.

Turning notifications on, step by step:

1. iOS asks whether Unreeled may show notifications.
2. The phone gets its address at Apple's push service (a device token).
3. It pairs with the relay: `POST /pair` with the token. The relay opens a channel at Mozilla and answers with that channel's push address.
4. The phone makes its keys: a P-256 key pair and a 16-byte `auth` secret, kept in the Keychain.
5. The phone registers the push address, the public key and `auth` with Instagram from your own login: the website's own `/api/v1/web/push/register/` call.

From then on, each notification goes Instagram → Mozilla → relay → Apple → phone, where the notification extension decrypts it and shows what it says.

Turning them off, or logging out, deletes the keys and tells the relay to forget the phone, which closes the push address, and removes the notifications already shown. Instagram has no call to take an address back; it stops sending once the address stops answering.

## What's proven

**12 November 2026**, with a real account:

- Instagram sends web push only to a real push service. A plain address of our own got nothing, Apple's web push got nothing, Google's and Mozilla's work.
- A program that isn't a browser can hold a push address at Mozilla's service and receive on it. Instagram delivered four real notifications to such an address over an hour, all in the `aesgcm` encoding, across two dropped connections.
- A registration made from Unreeled's login is honoured like a browser's.

**13 November 2026**, with no account involved (a stand-in sender, [relay/tools/sample-push.mjs](../relay/tools/sample-push.mjs)):

- The whole path after Instagram: a push encrypted by the `web-push` library went through Mozilla's real service to the relay, which forwarded it unread; delivered to the simulator, it was decrypted with the keys in the Keychain and shown.
- The phone's decryption ([WebPushCrypto.swift](../Shared/WebPushCrypto.swift)) agrees with `web-push` in both encodings, `aesgcm` and `aes128gcm`.
- Tapping a notification opens its conversation, or Activity for a like; one for the conversation on screen doesn't show on top of it; switching off unpairs and deletes the keys.

- The relay as a Cloudflare Worker, in Cloudflare's runtime on a Mac: it holds the connection to Mozilla's real service from a Durable Object, pairs, and forwards a push that the app's decryptor then reads. Its tests cover what the Node relay's do, and coming back after a restart with only its alarm to wake it.

- The Worker deployed on Cloudflare, as a dry run: from there it holds its connection to Mozilla's service, pairs and unpairs a phone, and reaches Apple's push service, which answers it (`MissingProviderToken`, as it should without a key). Deployed again with the key, its `/apple` check answers `BadDeviceToken`: Apple accepts the key.

**13 November 2026**, on an iPhone, with a real account:

- The whole route. A build signed for push (run from a Mac, so on Apple's sandbox push service) paired with the deployed relay and registered with Instagram. Instagram's notifications then came through Mozilla's service and the relay to Apple, which accepted every one: four in the first ten minutes, none refused. The phone showed them with the sender and the message, so the notification extension ran as its own process and read the keys from the app's Keychain group.

**Not yet known:** how the deployed Worker's connection to Mozilla holds over days, and whether Instagram keeps sending over weeks. Apple's production push service, which a distributed build uses, hasn't carried a push yet: the relay sends there for such a build, by the same code. The simulator can't stand in for an iPhone: `xcrun simctl push` puts a notification straight into Notification Centre without running an extension. The extension's work is one shared function, which is what the simulator test runs (see [Testing](#testing)).

**Why Mozilla and not Google:** Google's service would need a client rebuilt from observation and outbound ports 5228 to 5230. Mozilla's is an open, documented WebSocket protocol on port 443, with a maintained reference client ([Bitwarden's autopush-manager](https://github.com/bitwarden/autopush-manager)).

## The parts

### On the phone

| File | What it does |
|------|--------------|
| [Shared/PushKeys.swift](../Shared/PushKeys.swift) | The key pair and `auth`, in the Keychain: this device only, readable once the phone has been unlocked since it started |
| [Shared/WebPushCrypto.swift](../Shared/WebPushCrypto.swift) | Decrypts a web push, `aesgcm` or `aes128gcm` |
| [Shared/InstagramPush.swift](../Shared/InstagramPush.swift) | Reads Instagram's notification and turns an Apple push into the notification to show |
| [NotificationService/](../NotificationService/NotificationService.swift) | The notification extension: runs the above when a push arrives, and adds the sender's picture |
| [Unreeled/Notifications/PushNotifications.swift](../Unreeled/Notifications/PushNotifications.swift) | Turning on and off, keeping it working, taps, Reply and arrivals; what it keeps of the pairing, in the Keychain |
| [Unreeled/Notifications/PushRelay.swift](../Unreeled/Notifications/PushRelay.swift) | The two calls to the relay |
| [Unreeled/Views/Notifications.swift](../Unreeled/Views/Notifications.swift) | The page that asks, and the rows in Settings |

`Shared/` belongs to both the app and the extension. The extension can read the keys because its entitlements name the app's Keychain group ([Config/NotificationService.entitlements](../Config/NotificationService.entitlements)); it never writes them.

**What stays on the phone.** Beside the keys, in the Keychain and like them on this device only (a backup can't take them to another), the app keeps the registration (the relay's name for the phone, `deviceId`, and the relay's address, the push address, the login it was registered from), the pairings still to retire, and a pairing just made until it's saved or retired. The `deviceId` is all a relay asks to forget a phone, or to send its notifications to another token, so it mustn't travel in a backup. Builds before 14 November 2026 kept the registration and the pairings to retire in UserDefaults; the first launch of a later build carries them over (see [Upgrading](#upgrading-from-a-build-before-14-november-2026)). Since the Keychain outlives a deleted app, a reinstalled app finds the old pairing, and retires it when it starts logged out.

What the app does besides turning on and off:

- **Keeps it working.** At launch and when it comes back to the front, it asks iOS for the phone's address at Apple. When that has changed, and otherwise once a day, it pairs again, which keeps the same push address unless the relay has had to replace it. When the relay answers with a new push address, or a week has passed, it registers with Instagram again. Notifications turned off while it waits (for Apple, the relay or Instagram) stay off: nothing more is done, and a pairing it made meanwhile is retired. So is one made when Instagram then refuses the address, and one a launch made but ended before keeping, at the next launch.
- **One relay per pairing.** Each pairing is kept with the address of the relay that made it, and retired there, with the build's token. A build made with another relay, or a Debug launch with `-relay`, pairs with its own relay at its first look and retires the pairing at the other one. A relay's answer counts only when it's final: forgotten (200), its own `{"error":"unknown device"}` (a 404 from anything else, such as a relay that moved, doesn't count), or a token it won't take (401).
- **Follows the login.** Logging out, by any route, turns notifications off and removes the notifications already shown. A relay that can't be reached then is told at each later launch and each return to the app, logged in or not, until it has heard.
- **A tap** opens the conversation for a message, Activity for anything else, for the login that's on. It reads where to go from the push itself, which the extension leaves in the notification: also when the extension didn't get to the push.
- **Opening a conversation** removes its notifications from Notification Centre: the conversation shows their messages. Each notification keeps its message's ID (`n`) too, for the app to take it back should the message be unsent (`withdraw(messageIDs:)`; what Instagram sends on an unsend isn't known yet).
- **While the app is open,** a notification shows as a banner, except one about the conversation on screen, and the inbox and the open conversation look again right away.
- **Says which of Apple's two services** its address belongs to (sandbox for a build run from Xcode, production for a distributed one), read from the build's provisioning profile, since an address from one doesn't work at the other.

#### Upgrading from a build before 14 November 2026

The first launch of a later build reads the registration and the pairings to retire from UserDefaults, writes them to the Keychain, and only then removes them from UserDefaults; if the Keychain refuses, they stay there and the next launch tries again. Notifications stay on as they were: the same pairing and push address, no new pairing and no new registration with Instagram. The pairing is taken to be the build's relay's. Notifications that the earlier build showed carry its routing without the push, which it deleted: a tap or Reply on one still works as before when it was delivered before that first launch and the login that turned notifications on is the one logged in. Anything delivered after that first launch needs the push. A build from before 14 November 2026 run again over a later one finds no registration in UserDefaults and deletes the keys, as it always did; the later build then retires the pairing it kept.

### The relay

One WebSocket to Mozilla carries a channel per phone. On a push the relay looks up the phone and forwards the body and header fields, untouched, to Apple. It stores a random ID per phone, the Mozilla channel and its address, the phone's Apple token, and when the phone was last seen: no keys, nothing readable. Before a phone takes a place, the relay asks Apple about its token with a background push that shows nothing, and refuses a token Apple says it will never deliver to; it asks again when a phone pairs again with a new token, or more than a day after it was last seen. A token has one record. A record that nothing has renewed for 30 days (no push Apple accepted, no pairing again that Apple didn't refuse) is forgotten, and its phone pairs afresh the next time the app is opened.

It's written twice, with the same calls and the same push:

- [relay/](../relay/README.md): a Node program with one dependency (`ws`), for any machine that's always on.
- [relay/worker/](../relay/worker/README.md): a Cloudflare Worker. A Durable Object holds the connection and the phones' records, and an alarm every minute brings it back after Cloudflare restarts it. This is where the project's relay is meant to run: nothing to host, HTTPS and the name included, and one object fits in what the paid plan includes.

How to run each and what each setting does is in its README.

What it handles on its own:

- **Dropped connections.** Mozilla closes the socket every twenty minutes or so. The relay reconnects with the same identity and channels, so the push addresses stay good, and Mozilla delivers what arrived meanwhile.
- **A lost identity.** If Mozilla answers with a new identity, every channel of the old one is gone. The relay registers a new channel for each phone at once; the phone learns the new address the next time it pairs, within a day of use, and gives it to Instagram.
- **Phones that are gone.** When Apple says a token no longer exists (the app was deleted), the relay forgets the phone and closes its channel.
- **A push too large for Apple** (over 4 KB with the ciphertext in base64) goes without its content, as "New notification on Instagram". The sample pushes are about 800 bytes.

### Mozilla's protocol, as the relay speaks it

Connect to `wss://push.services.mozilla.com` and exchange JSON:

| Direction | Message |
|-----------|---------|
| → hello | `{"messageType":"hello","use_webpush":true,"uaid":<saved or null>,"channelIDs":[<saved>]}` |
| ← hello | `{"messageType":"hello","uaid":"…","status":200}`: save the `uaid` |
| → register | `{"messageType":"register","channelID":"<uuid>","key":"<Instagram's public key>"}` |
| ← register | `{"messageType":"register","channelID":"…","status":200,"pushEndpoint":"https://updates.push.services.mozilla.com/wpush/v2/…"}` |
| ← notification | `{"messageType":"notification","channelID":"…","version":"…","data":"<base64url>","headers":{"encoding":"aesgcm","encryption":"salt=…","crypto_key":"dh=…;p256ecdsa=…"}}` |
| → ack | `{"messageType":"ack","updates":[{"channelID":"…","version":"…"}]}` |

A channel registered with a `key` only accepts pushes signed by that key, here Instagram's. The header fields arrive as `crypto_key` (with an underscore), `encryption` and `encoding`. Only outbound port 443 is needed.

### The encryption

Instagram uses the older `aesgcm` encoding. From the push: `data` (ciphertext with a 16-byte tag), the salt from `encryption`, the sender's public key `dh` from `crypto_key`. The phone has its private key, `auth`, and its own public key.

```
shared  = ECDH(private, dh)
ikm     = HMAC(HMAC(auth, shared), "Content-Encoding: auth\0" ‖ 0x01)
prk     = HMAC(salt, ikm)
info(x) = x ‖ "\0P-256\0" ‖ 0x00 0x41 ‖ own public key ‖ 0x00 0x41 ‖ dh
key     = HMAC(prk, info("Content-Encoding: aesgcm") ‖ 0x01)[0..16]
nonce   = HMAC(prk, info("Content-Encoding: nonce")  ‖ 0x01)[0..12]
plain   = AES-128-GCM-open(data, key, nonce)
message = plain[2 + big-endian-u16(plain[0..2]) ...]        # after the padding
```

The standard `aes128gcm` encoding (RFC 8188 with RFC 8291) is read too, in case Instagram moves to it. The message is JSON: `type` (`direct_v2_text`, `direct_v2_media_share`, …), `message` (the notification's text), `t` (the conversation's name), `ppu` (the sender's picture), `n` (the message's ID) and `params`, where `t_id` is the conversation's ID.

## Replying

A message's notification offers Reply, which sends what you type to the conversation without opening the app.

- **The action.** The extension gives a decrypted `direct_v2_*` push with a conversation ID the category `message` ([InstagramPush.swift](../Shared/InstagramPush.swift)), and any other notification none. The app registers that category at every launch, with one `UNTextInputNotificationAction` and no options, as Signal and Telegram do: no unlock is asked for, so it works from the lock screen ("Reply with Message" in iOS's lock screen settings governs that). A Mac that shows the iPhone's notifications offers Reply too: the reply runs on the iPhone, as for a Watch, and the app needs nothing more for it.
- **Where it goes.** Whoever sends the Apple push writes everything in it but the encrypted push: the relay could add a conversation, a category and words of its own. So the extension keeps the push (`wp`) in the notification it shows, and the app reads the conversation from it again, decrypted, never from what sits beside it in the Apple push. Reply is sent only when the notification shows what the push says (a push replayed under other words can't redirect an answer), and only from the login notifications were turned on from: on a notification of another login, or with nobody logged in, nothing is sent and nothing it said is shown again. When the extension can't read a push, it drops any conversation and category that came with it, so no Reply is offered. The app's own notification about a reply that didn't go keeps its conversation and login itself; nothing but the app can add one.
- **Sending.** iOS wakes the app in the background and hands the text to the notification delegate, which the app delegate sets before launch ends ([PushNotifications.swift](../Unreeled/Notifications/PushNotifications.swift)). SwiftUI may not create any view on such a launch, so the reply goes through `Session.shared`, whose API exists from the start, with the same `IGDirectTextSendMutation` as the composer. A background task keeps the app running meanwhile.
- **The time limit.** Apple doesn't document how long an app woken for a notification gets (its engineers have said about 10 seconds, a background task about 30), and a weak connection can take longer. A reply Instagram hasn't confirmed within 20 seconds counts as not sent: the request is stopped, and isn't tried again later, rather than going out hours later, and a notification says the reply may not have been sent. One Instagram refuses gets a notification that it wasn't sent. Both quote the reply, offer Reply again, and open the conversation when tapped.
- **No page in the way.** Since 13 November 2026 requests no longer run in a hidden web view, so there's no page for WebKit to hold back in the background, nor a page process iOS may have ended while the app was suspended. The reply is an ordinary request, with the website's headers and cookies (see [HOW-IT-WORKS.md](HOW-IT-WORKS.md)).
- **Tried.** First in the simulator, without sending anything: iOS has the category (`message: reply`), and a reply sent as the app leaves the screen went through the hidden page in about a second, also with the page's process killed just before. Then on 13 November 2026, on an iPhone and from a Mac: both replies arrived, still through the hidden page. Replies through the native requests haven't been tried on a phone yet, nor how they hold after the app has been suspended for hours.

**Testing in the simulator, without sending anything.** Scripted touches can't press a notification there, so a Debug build has a stand-in. Set two values in the app's own settings, by the path of its container so the app reads them (a plain `defaults write <bundle ID>` lands elsewhere):

```bash
APP=$(xcrun simctl get_app_container booted <bundle ID> data)
xcrun simctl spawn booted defaults write "$APP/Library/Preferences/<bundle ID>" replyDryRun -bool YES
xcrun simctl spawn booted defaults write "$APP/Library/Preferences/<bundle ID>" replyTest -bool YES
```

With both, each time the app leaves the screen it replies to a stand-in conversation the way Reply does, but sends nothing: a read-only request (Activity) goes the same way instead. `Library/Caches/network-log.jsonl` shows `notificationCategories` at launch, then `replyDryRun` and `replyDryRunDone`. Delete both values afterwards. A stand-in message notification, `xcrun simctl push booted <file>` with `"aps": {"alert": {…}, "category": "message"}` and `"unreeled": {"type": "direct_v2_text", "thread": "dry-run-thread"}`, shows how it looks, but a tap or Reply on it does nothing more: it's what a relay could write, without a push to read. For Reply on a real one, deliver a push made by `node tools/sample-push.mjs apns …` (see [Testing](#testing)) with the app open and `replyDryRun` set: the Debug build decrypts it and shows it as the extension would, and Reply on that goes to its conversation.

## Legitimate use and scope

This feature gives people their **own** Instagram notifications on their **own** phone, without Instagram's app. It is built to be defensible and must stay that way:

- **Consent and ownership.** Opt-in only; each person enrols their own account from their own login. The service only handles notifications Instagram already sends that person.
- **End-to-end encryption.** The service forwards ciphertext; only the phone decrypts. The operator can't read messages.
- **No third-party harm.** No scraping, mass-messaging, targeting, or acting on anyone.
- **User control.** Off at any time; logging out retires it. Minimal metadata; nothing from the body is logged.
- **Honest about risk.** It uses Instagram's web push and Mozilla's push service in ways neither formally supports for this. The app says so before you turn it on.
- **Open, documented technique.** Receiving web push outside a browser through Mozilla's service is a documented protocol with a maintained reference client; it isn't the exploit of a security vulnerability.

It is **not** for evading detection to harm anyone, reaching data a person isn't entitled to, or operating on accounts without consent, and must not be repurposed for those.

## Building with notifications

A build offers notifications only when it knows a relay, and can only receive them when it's signed for push. Both are set in `Config/Local.xcconfig` (see [Local.example.xcconfig](../Config/Local.example.xcconfig)):

```
UNREELED_ENTITLEMENTS = Config/Push.entitlements
UNREELED_RELAY_HOST = relay.example.com
UNREELED_RELAY_TOKEN =
```

- `UNREELED_ENTITLEMENTS` needs a team in the Apple Developer Program. A free team can't sign for push; leave the line out and the app builds as before.
- The relay has to hold a push key of the **same team**, and list the app's bundle ID in `APNS_TOPIC`: Apple only accepts a push for an app from that app's team. So whoever signs the app runs the relay, or shares one with people who build with the same team.

Simulator builds always carry the push entitlement, which costs nothing there and lets the simulator get a real address from Apple.

## Testing

Without an Apple key or an Instagram account, everything but Apple's leg can be run on a Mac. The stand-in sender plays Instagram:

```bash
cd relay && npm install
INSTAGRAM_VAPID_KEY=$(node tools/sample-push.mjs key) APNS_OUTBOX=/tmp/outbox npm start
```

That relay accepts pushes from the stand-in sender instead of Instagram, and writes each push it would send to Apple into the outbox. Then:

1. Run a Debug build in the simulator with `-relay http://localhost:8787 -pushDryRun YES`. The dry run does everything but register with Instagram, and writes what it would have registered to the app's `Library/Caches/push-dry-run.json`.
2. Turn notifications on in the app. The relay logs the pairing.
3. Send a push through Mozilla to the relay: `node tools/sample-push.mjs send <path to push-dry-run.json> --title "Someone" --message "Hello"`.
4. Deliver the file that appears in the outbox: `xcrun simctl push booted <file>`.

With the app open, the banner shows the decrypted text: Debug builds do the extension's work themselves for a push that skipped it. With the app closed, the banner shows the relay's words, and a tap still opens the right conversation. `node tools/sample-push.mjs apns … > push.apns` makes such a file directly, with no relay or network; `--encoding aes128gcm`, `--type like` and `--thread <conversation ID>` vary it.

A registration made in a dry run is turned off by the next launch that isn't one, so it can never reach Instagram.

The relay has its own tests, against stand-ins for Mozilla and Apple: `npm test`.

Registering for real writes to an account: Instagram starts sending that account's notifications to the address. Do it on your own account, knowingly. The Debug `-probe "PUSH <address> <p256dh> <auth>"` registers by hand.

## Risks

1. **Instagram or Mozilla stop delivering.** Instagram has been seen to stop sending to a login while still accepting its registration ([mautrix/meta#454](https://github.com/mautrix/meta/issues/454)). The app registers again every week and whenever the address changes; whether that's enough isn't known yet.
2. **The account.** This is as unofficial as the rest of Unreeled, and the app says so before you turn it on.
3. **The relay's operator** sees each phone's Apple token and the time and size of each notification. Not its content, and not whose account it's for. No one else does: `/health` shows the counts and times only with the operator's own token, which no build carries. A relay could send a phone notifications of its own, but not choose where a Reply goes (see [Replying](#replying)).

## What's left

1. **Watch the deployed relay** for a few days: `curl -s -H "Authorization: Bearer $OPERATOR_TOKEN" https://relay.unreeled.app/health` should keep saying `"mozilla": true`. Without a token it only answers `{"ok":true}`. If the connection doesn't hold on Cloudflare, the Node relay on an always-on machine does the same job.
2. **Watch the notifications** over days and weeks: do they keep coming, and how soon after the message? Instagram has been seen to stop sending without saying so. `/health` with the operator token says how many the relay has forwarded and when the last one was.
3. **A distributed build,** which gets its notifications from Apple's production push service. Only the sandbox one has carried a real push so far.
4. **Publish the privacy policy's new section** with the release that has notifications.
5. **Unsent messages.** See what Instagram sends when a message is unsent, and whether a push's `n` is the ID the conversation gives the same message, before the app takes back the notification of a message it finds gone (`PushNotifications.withdraw(messageIDs:)`). Until then, opening the conversation removes it.
