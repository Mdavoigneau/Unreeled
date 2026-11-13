# Next session: notifications

**Where it stands (13 November 2026).** The relay, the app's side and the notification extension are built, and tested up to Apple's push service: [NOTIFICATIONS.md](NOTIFICATIONS.md) has the design, what's proven and how to test. The relay is also written as a Cloudflare Worker, deployed at `relay.unreeled.app` as a dry run (no Apple key yet). Left: everything that needs the Apple Developer Program.

## Done

- **The two branches are one.** `matteo/dm-notification-support-a88776` is merged into `matteo/browser-notification-relay-190821`: `registerWebPush`, the `PUSH` probe, the Settings screen. The push test (its Cloudflare Worker, `PushTest.swift`) is gone from this branch; it's in the other branch's history.
- **The app's side.** Keys in the Keychain, the page that asks, the switch in Settings, pairing with the relay, registering with Instagram, a daily check with the relay and a weekly one with Instagram, turning off on logout, taps opening the right screen.
- **The notification extension,** a second target (`UnreeledNotifications`), sharing the `Shared/` folder with the app.
- **The relay** pairs again without changing the address, serves Apple's sandbox and production per phone, forgets phones Apple reports gone, recovers when Mozilla forgets its identity, and has tests (`npm test` in `relay/`).
- **The relay as a Cloudflare Worker** ([relay/worker/](../relay/worker/README.md)): a Durable Object holds the connection to Mozilla, an alarm every minute brings it back after a restart. Fourteen tests pass in Cloudflare's runtime on a Mac, and a push sent through Mozilla's real service came out of it readable by the app's decryptor. Deployed as a dry run on 13 November: from Cloudflare it holds its connection to Mozilla, pairs and unpairs, and reaches Apple (`GET /apple` answered `MissingProviderToken`). The host name moved to it from the old push test's Worker, which was then deleted with its database. A first version reconnected every two minutes, because a connection that carries nothing gets closed; it now pings Mozilla once a minute and holds one connection.
- **Tested in the simulator** with a stand-in sender and Mozilla's real service: pairing, a push through Mozilla and the relay, decryption in both encodings, taps, switching off. No write was made to any Instagram account.
- **The privacy policy** has a section on notifications, and the website's home page and `llms.txt` say the same in a sentence. They go live when this branch reaches `main`, which rebuilds the site.

## To do, in order

1. **Watch the deployed relay** for a day or two: `curl https://relay.unreeled.app/health` should keep answering `"mozilla": true`. That's the one thing about Cloudflare still unknown: how the connection to Mozilla holds over days. If it doesn't, the Node relay on an always-on machine is the fallback ([relay/README.md](../relay/README.md)).
2. **Enrol in the Apple Developer Program.** Then, in the developer account: Keys › a new key with Apple Push Notifications service. Add the `.p8` file's text, the key ID, the team ID and the bundle ID to the relay's secrets file (it's outside the repository, with the pairing token already in it) and deploy again from `relay/worker`, without `RELAY_DRY_RUN`: [relay/worker/README.md](../relay/worker/README.md). `GET /apple` should then answer `BadDeviceToken`.
3. **Build for the iPhone with push.** In `Config/Local.xcconfig`, set `UNREELED_ENTITLEMENTS = Config/Push.entitlements`, `UNREELED_RELAY_HOST = relay.unreeled.app` and `UNREELED_RELAY_TOKEN` to the pairing token. Xcode makes the provisioning profiles for the app and for the extension (`<bundle ID>.NotificationService`). This signed build hasn't been tried: only the unsigned Release build and the simulator's.
4. **The first real notification.** Turn notifications on in the app on the iPhone (this registers with Instagram: a write to the account), have someone send a message, and see it arrive decrypted with the sender's picture. This is the first time the extension itself runs. If the banner says "New notification on Instagram", the extension didn't decrypt: look at the phone's log for `UnreeledNotifications`.
5. **Watch it for some days.** Do notifications keep coming? Instagram has been seen to stop without saying so ([mautrix/meta#454](https://github.com/mautrix/meta/issues/454)). The relay's `/health` shows when it last forwarded one.
6. **Before a public build has it:** decide who runs the shared relay and under which name, deploy the website so the privacy policy's new section is live, and consider App Attest or rate limits on `/pair` in place of the shared pairing token.

## Worth knowing

- **Writes to the account need an explicit yes.** Turning notifications on in a build that isn't a dry run is one.
- **`xcrun simctl push` doesn't run the extension.** Debug builds do its work in the app instead when the app is open, which is how the simulator test shows decrypted banners.
- **The iOS 27 simulator's switches** don't flip on a quick synthetic tap; slide them.
- **Old test registrations** are still on the account from 12 November: two Mozilla addresses and one of Google's. Instagram has no call to remove them; they go stale.
- **The old push test** is gone from the Cloudflare account: its Worker and its database were deleted on 13 November. Its code is in this repository's history (the commits titled "Push test: …").
- **Apple can't be tried from a Mac** with the Worker: Cloudflare's local runtime only speaks HTTP/1.1 to other servers, and Apple only HTTP/2. From Cloudflare itself it works.
- **The simulator is shared.** Another session installed its own build over this one's on 13 November; check which build is installed before testing there.
- **The app icon** on this branch is the U (`Unreeled/Assets.xcassets/AppIcon.appiconset/AppIcon.png`). The same change is committed on another branch with the icon's sources in `Design/`; the two say the same thing and should merge without a conflict.
