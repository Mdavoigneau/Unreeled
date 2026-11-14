# Privacy Policy

*Effective 14 November 2026*

Unreeled is a free, open-source app for using Instagram without Reels, suggestions or ads. It isn't made or endorsed by Instagram or Meta. This policy explains what happens to your information when you use it. The short version: **Unreeled collects nothing about you.** Your account goes only between your phone and Instagram. One thing is different if you turn it on: notifications pass through a relay, encrypted so that only your phone can read them.

## What stays between your phone and Instagram

- **Logging in.** You log in on Instagram's own login page, shown inside the app. Unreeled never reads or stores your password.
- **Your session.** Instagram's cookies stay on your phone, in the app's own web data store, which is left out of your phone's backups. The session values the website provides (such as `fb_dtsg` and `lsd`) are kept in your phone's Keychain, on this device only. If the app's data reaches another phone anyway, restored from a backup or copied, the app there starts logged out, with nothing of your account.
- **What you see and send.** Feeds, stories, messages, profiles and activity come straight from Instagram's servers to your phone. Pictures and videos load only from Instagram's own servers for them, never from an address someone put in a message. Messages, photos, videos, voice messages, likes and replies you send go straight from your phone to Instagram. None of it passes through any server of ours.
- **Saved copies.** So screens open instantly, the app keeps recent responses from Instagram (your feed, conversations, your profile and the profiles you visit, your last 100 notifications), pictures, and the stories it loads ahead in its cache on your phone, which is never in its backups. Each account's are kept apart. Stories are deleted after a day, conversations you haven't opened for a month, anything Instagram hasn't sent again for a month, and everything else unused for two weeks, automatically, except your own profile and notifications, which stay until you log out.
- **Logging out** asks Instagram to end the session, as the website's Log Out does, then deletes from your phone Instagram's cookies, the session values, all the saved copies and the voice messages you recorded. The same happens when the login ends any other way: Instagram ends it (from another device, or after a password change), or it runs out. If another account logs in on one of the website's pages in the app, everything kept for the first account is deleted the same way.
- **Camera, microphone and photos.** The camera and microphone are used only while you take a photo or video for your story or record a voice message. Photos you pick from your library are only the ones you choose to send or post.

What you do on Instagram through Unreeled is subject to [Instagram's own privacy policy](https://privacycenter.instagram.com/policy), as it would be on the website.

## Notifications, if you turn them on

Notifications are off unless you turn them on, and only some builds of Unreeled offer them. The app says what follows before you do.

- **Keys.** Your phone makes a pair of keys and a secret, and keeps them in its Keychain, on this device only.
- **Instagram.** Your phone gives Instagram a push address and the public key, from your own login, as a browser does when you allow notifications on instagram.com. Instagram then encrypts each notification for your phone and sends it to that address.
- **On the way.** The address belongs to Mozilla's push service, which hands the encrypted notification to Unreeled's relay, which passes it to Apple's push service, which delivers it to your phone. None of the three can read it. Your phone decrypts it and shows it, and downloads the sender's picture from Instagram. The relay runs on Cloudflare. When you turn notifications on, and at most once a day after that, the relay may ask Apple whether it knows your phone's address, with a silent notification your phone doesn't show.
- **What the relay keeps.** A random ID for your phone, your phone's address at Apple's push service, the push address, and when your phone was last seen: when it paired, or Apple last accepted a notification for it. It sees when a notification passes and how large it is, and only whoever runs the relay can see those counts and times. It never has the keys, your login, or anything that says which Instagram account the notifications are for, and it logs nothing from a notification.
- **When the app contacts the relay.** When you turn notifications on or off, and at most once a day when you open the app, to keep the address current. Like any web request, this reaches the relay with your IP address; we don't log these requests or use them to identify anyone.
- **Turning them off,** or logging out, deletes the keys from your phone and the relay's record of it. If you delete the app instead, the relay drops the record the first time Apple reports the app gone, or after 30 days without a sign of your phone.

Mozilla, Apple and Cloudflare handle the encrypted notifications under their own privacy policies. If you built Unreeled yourself, the relay is the one your build was made with, run by whoever runs it.

## What we collect

Nothing, unless you turn notifications on; then only what the relay keeps, listed above. Unreeled has no accounts of its own, no analytics, no crash reporting, no advertising and no tracking, and the app contains no third-party code.

## The query list

Instagram changes the IDs of the requests its website makes from time to time. To keep working, Unreeled downloads the project's current list of those IDs, with its signature, from unreeled.app, or from GitHub if that fails: at launch at most every 6 hours, and when a request to Instagram fails. The app uses a list only if the project signed it. The downloads carry nothing about you or your account. Like any web request, they reach the server with your IP address and the app's version. Those servers are run by Cloudflare (unreeled.app) and GitHub; we don't log these requests or use them to identify anyone.

## Children

Unreeled is for people who can use Instagram, which requires being at least 13.

## Changes

Changes to this policy are published in the project's repository, with their date, and on unreeled.app.

## Contact

Questions or problems: write to [hello@unreeled.app](mailto:hello@unreeled.app), or open an issue at [github.com/Mdavoigneau/Unreeled](https://github.com/Mdavoigneau/Unreeled/issues).
