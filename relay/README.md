# Push relay: the test

Unreeled has no push notifications yet. This folder tests one way to get them. Instagram's website can send a browser's push service an encrypted copy of each notification ("web push"). If Instagram accepts an address of ours instead, a relay there could pass each one to Apple, and the app could decrypt it on the phone.

The Worker here is a stand-in for that relay. It records what arrives at one secret push address and answers as a push service would. It can't read the notifications: they're encrypted for a key that stays on the Mac running the test.

## What the test answers

- Does Instagram send pushes to an address that isn't a browser's push service?
- What's in one: which kinds of notification, and which fields?
- Do they keep coming? The Matrix bridge for Instagram reports that web push sometimes stops ([mautrix/meta#454](https://github.com/mautrix/meta/pull/454)).

## What it has shown

- **A relay address doesn't work** (2026-11-12). Instagram accepted two registrations of the relay's address and then sent it nothing in four hours, at any path. Over the same messages, a Chromium browser that had turned on Instagram's notifications itself got each one within a minute or two.
- **An address at Google's push service works** (2026-11-12). Made by a Chromium browser on the browser test page below and registered from the app's login, it got each direct message about a second after it was sent: type `direct_v2_text`, with the text, the conversation and some thirty other fields.
- **An address at Apple's push service doesn't.** Safari's, registered the same way, got none of the same messages, and the Mac's push service logged nothing arriving. Either Instagram doesn't send there or Apple refuses what it sends.
- **Still open:** Mozilla's push service, and how long pushes keep coming to an address registered this way.

## Running it

Node 22.18 or later, and `npm install` in this folder once.

1. **Keys.** `node tools/pushtest.mjs keys` makes the key pair, the secret end of the push address and the token that reads the log, in `~/.config/unreeled/push-test/`. Nothing secret is in this repository.
2. **Deploy.** Set the relay's address in `cloudflare.config.ts`, sign in once with `npx cf auth login`, then:

   ```bash
   npx cf deploy --secrets-file ~/.config/unreeled/push-test/relay-secrets.json
   ```

   The first deploy creates the D1 database. Then tell the tools where the relay is: `node tools/pushtest.mjs relay <address>`.
3. **Check it.** `node tools/pushtest.mjs selftest` sends the relay a push made on the Mac, and `node tools/pushtest.mjs read` should list it, decrypted.
4. **Register.** Launch a Debug build that's logged in, in the simulator, with the registration as a probe:

   ```bash
   xcrun simctl launch booted <bundle ID> -probe "PUSH $(node tools/pushtest.mjs registration)"
   ```

   This writes to the account: Instagram starts sending its notifications to the relay. `Library/Caches/network-log.jsonl` in the app's data folder says whether Instagram took the address.

   On a phone, where there are no launch arguments, give the build the values instead:

   ```bash
   node tools/pushtest.mjs registration phone --json > ../Unreeled/PushTest.json
   ```

   A build with that file asks, before its first screen, whether to turn the push test on. Saying yes brings up iOS's own question about notifications, then registers. Afterwards the test is in Settings (the gear on your profile), under Notifications. `phone` is a label: it goes at the end of the push address, and the log says which registration each push was for. Git ignores the file; delete it after building, so later builds don't carry it.

   Nothing shows on the phone yet: the relay only records. To try these screens without registering anything, launch a Debug build with `-pushTestDryRun YES`.
5. **Read.** `node tools/pushtest.mjs read` lists what arrived: when, from which network, the push's headers, and each notification's fields by kind and length. Add `--show` to print what they say.

   The relay also records requests to any other address, without who sent them, in case Instagram calls somewhere unexpected. Most are the internet's scanners: `read` lists those from Meta's networks and counts the rest, and `--all` lists them too.

## The browser test

`/browser-test` on the relay is a page where a real browser makes a push address with Instagram's public key, so only Instagram can send to it, and reports it to the relay. Open it in each browser to try, choose **Subscribe this browser** and allow notifications. Then register that address from a Debug build:

```bash
xcrun simctl launch booted <bundle ID> -probe "PUSH $(node tools/pushtest.mjs registration --reported safari)"
```

(`chromium`, `firefox` or `edge` for the others.) When a push arrives, the page's service worker shows it and tells the relay, with the names and kinds of its fields only. `read` lists both the addresses and the arrivals.

## Taking it down

Delete the `unreeled-push-test` Worker and its D1 database of the same name, then `~/.config/unreeled/push-test/`. The website has no call that removes a push address; once the relay is gone, pushes to it are refused.
