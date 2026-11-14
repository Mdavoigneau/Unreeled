# Next session: notifications

**Where it stands (13 November 2026).** It works: Instagram's real notifications reach an iPhone, decrypted, through the relay deployed at `relay.unreeled.app`. [NOTIFICATIONS.md](NOTIFICATIONS.md) has the design, what's proven and how to test. Left: seeing how it holds over days, and everything a release needs.

## Done

- **The two branches are one.** `matteo/dm-notification-support-a88776` is merged into `matteo/browser-notification-relay-190821`: `registerWebPush`, the `PUSH` probe, the Settings screen. The push test (its Cloudflare Worker, `PushTest.swift`) is gone from this branch; it's in the other branch's history.
- **The app's side.** Keys in the Keychain, the page that asks, the switch in Settings, pairing with the relay, registering with Instagram, a daily check with the relay and a weekly one with Instagram, turning off on logout, taps opening the right screen.
- **The notification extension,** a second target (`UnreeledNotifications`), sharing the `Shared/` folder with the app.
- **The relay** pairs again without changing the address, serves Apple's sandbox and production per phone, forgets phones Apple reports gone, recovers when Mozilla forgets its identity, and has tests (`npm test` in `relay/`).
- **The relay as a Cloudflare Worker** ([relay/worker/](../relay/worker/README.md)): a Durable Object holds the connection to Mozilla, an alarm every minute brings it back after a restart. Fourteen tests pass in Cloudflare's runtime on a Mac, and a push sent through Mozilla's real service came out of it readable by the app's decryptor. Deployed as a dry run on 13 November: from Cloudflare it holds its connection to Mozilla, pairs and unpairs, and reaches Apple (`GET /apple` answered `MissingProviderToken`). The host name moved to it from the old push test's Worker, which was then deleted with its database. A first version reconnected every two minutes, because a connection that carries nothing gets closed; it now pings Mozilla once a minute and holds one connection.
- **Tested in the simulator** with a stand-in sender and Mozilla's real service: pairing, a push through Mozilla and the relay, decryption in both encodings, taps, switching off. No write was made to any Instagram account.
- **The privacy policy** has a section on notifications, and the website's home page and `llms.txt` say the same in a sentence. They go live when this branch reaches `main`, which rebuilds the site.
- **The relay is live.** With the team in the Apple Developer Program came a push key (Sandbox & Production, team scoped). The relay's secrets file has it, and the Worker was deployed again without `RELAY_DRY_RUN`: `GET /apple` answers `BadDeviceToken`, which means Apple accepts the key.
- **The first real notifications, on an iPhone.** A Release build signed for push, with `UNREELED_ENTITLEMENTS`, `UNREELED_RELAY_HOST` and `UNREELED_RELAY_TOKEN` set in `Config/Local.xcconfig`, went onto the phone over the installed app. Xcode made the profiles for the app and for the extension by itself. Notifications were turned on in the app, the phone paired with the relay, and Instagram's notifications arrived with the sender and the message: the first run of the extension itself. Apple accepted all four pushes of the first ten minutes.

## To do, in order

1. **Watch it for some days.** `curl -s -H "Authorization: Bearer $OPERATOR_TOKEN" https://relay.unreeled.app/health` should keep answering `"mozilla": true`, and `forwarded` should grow with the notifications (without the operator token, which goes in the relay's secrets file, `/health` only answers `{"ok":true}`): how the connection to Mozilla holds over days on Cloudflare is still unknown, and Instagram has been seen to stop sending without saying so ([mautrix/meta#454](https://github.com/mautrix/meta/issues/454)). If the connection doesn't hold, the Node relay on an always-on machine is the fallback ([relay/README.md](../relay/README.md)).
2. **Look closer at what arrives:** one notification for each message or two (the relay's count went up by two at a time), how long after the message, and whether the sender's picture shows.
3. **Pick the release bundle ID.** Apple refuses `app.unreeled`, the one [RELEASING.md](RELEASING.md) names: another developer holds it. Whichever is chosen goes into `APNS_TOPIC` in the relay's secrets, next to the one in use.
4. **A distributed build** gets its notifications from Apple's production push service, which hasn't carried a push yet.
5. **Before a public build has it:** decide who runs the shared relay and under which name, deploy the website so the privacy policy's new section is live, and consider App Attest in place of the shared pairing token (`/pair` now has rate limits and checks each phone's token with Apple).

## Worth knowing

- **Writes to the account need an explicit yes.** Turning notifications on in a build that isn't a dry run is one.
- **Signing from the command line** uses the Apple account that Xcode has saved. If `xcodebuild -allowProvisioningUpdates` answers "No Accounts" while Xcode › Settings › Apple Accounts shows you signed in, sign out and in again there: the app can hold a session its saved list has lost.
- **If a banner says "New notification on Instagram",** the push arrived but the extension didn't decrypt it: look at the phone's log for `UnreeledNotifications`.
- **`xcrun simctl push` doesn't run the extension.** Debug builds do its work in the app instead when the app is open, which is how the simulator test shows decrypted banners.
- **The iOS 27 simulator's switches** don't flip on a quick synthetic tap; slide them.
- **Old test registrations** are still on the account from 12 November: two Mozilla addresses and one of Google's. Instagram has no call to remove them; they go stale.
- **The old push test** is gone from the Cloudflare account: its Worker and its database were deleted on 13 November. Its code is in this repository's history (the commits titled "Push test: …").
- **Apple can't be tried from a Mac** with the Worker: Cloudflare's local runtime only speaks HTTP/1.1 to other servers, and Apple only HTTP/2. From Cloudflare itself it works.
- **The simulator is shared.** Another session installed its own build over this one's on 13 November; check which build is installed before testing there.
- **The app icon** on this branch is the U (`Unreeled/Assets.xcassets/AppIcon.appiconset/AppIcon.png`). The same change is committed on another branch with the icon's sources in `Design/`; the two say the same thing and should merge without a conflict.
