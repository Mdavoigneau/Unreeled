# Push relay: the test

Unreeled has no push notifications yet. This folder tests one way to get them. Instagram's website can send a browser's push service an encrypted copy of each notification ("web push"). If Instagram accepts an address of ours instead, a relay there could pass each one to Apple, and the app could decrypt it on the phone.

The Worker here is a stand-in for that relay. It records what arrives at one secret push address and answers as a push service would. It can't read the notifications: they're encrypted for a key that stays on the Mac running the test.

## What the test answers

- Does Instagram send pushes to an address that isn't a browser's push service?
- What's in one: which kinds of notification, and which fields?
- Do they keep coming? The Matrix bridge for Instagram reports that web push sometimes stops ([mautrix/meta#454](https://github.com/mautrix/meta/pull/454)).

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

## Taking it down

Delete the `unreeled-push-test` Worker and its D1 database of the same name, then `~/.config/unreeled/push-test/`. The website has no call that removes a push address; once the relay is gone, pushes to it are refused.
