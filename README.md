# Unreeled

**Your friends on Instagram, without the rabbit hole.**

Unreeled is a free, open-source iPhone app for Instagram that shows the people you follow and nothing else: their posts newest first, their stories, your messages and your activity. No Reels feed, no Explore, no suggested posts, no ads.

> [!WARNING]
> **Unofficial.** Unreeled isn't made or endorsed by Instagram or Meta. It talks to Instagram the way instagram.com does, from your phone. Instagram doesn't approve apps like this one, and it could restrict or disable an account that uses it. Use it at your own risk.

## What's in it

- **Home:** stories on top, then posts from the accounts you follow, newest first.
- **Stories:** watch, like and reply; post a photo or video to yours.
- **Messages:** your inbox with search; text, photos, videos and voice messages; hearts. Posts and reels sent to you open on their own, with no feed after them.
- **Activity:** likes, new followers and follow requests.
- **Profiles and posts,** with comments, and account search.
- **Instant:** what you do shows at once and goes to Instagram in the background, with a "✓ Delivered" once it's there. Screens open on what the app saved last time.
- **A 2016 look:** flat white bars, Helvetica Neue and one steel-blue accent.

Reels from accounts you follow can be switched on in Profile › gear. They then show one at a time, with no feed to swipe.

The details, screen by screen: [docs/FEATURES.md](docs/FEATURES.md).

## Install

- **In the EU, Japan and Brazil:** from [AltStore PAL](https://altstore.io). Coming soon.
- **Anywhere else:** build it yourself with Xcode, below. With a free Apple ID, the app has to be reinstalled every 7 days.

### Build it yourself

1. Install Xcode 27 or later and clone this repository.
2. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`, and set your team ID and a bundle ID of your own in it.
3. Open `Unreeled.xcodeproj`, pick the **Unreeled for iPhone** scheme and your iPhone, and press ⌘R.
4. The first time: turn on Developer Mode on the iPhone (Settings › Privacy & Security, then restart), and trust your Apple ID under Settings › General › VPN & Device Management.

The **Unreeled** scheme builds the Debug version, with the tools for finding Instagram's requests described in [docs/MAINTAINING.md](docs/MAINTAINING.md). It runs in the simulator without any setup.

## Privacy

Unreeled collects nothing. You log in on Instagram's own page, and your account goes only between your phone and Instagram. There are no analytics, no tracking and no third-party code. The only other request the app makes downloads the project's list of Instagram query IDs. The full policy is in [PRIVACY.md](PRIVACY.md).

## How it works

Instagram's website loads nearly everything through GraphQL queries that it sends by ID. Unreeled sends the same queries, with the same parameters and headers, from a hidden web view on www.instagram.com. That way each request carries the website's cookies and the browser's own headers, and the session never leaves your phone. The screens on top are native SwiftUI. More in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

When Instagram changes a query, its ID changes and the screen that uses it stops loading. The fix is one edit to [Queries.json](Unreeled/API/Queries.json). Installed apps pick up the new list from the project within 6 hours, or right away when a query fails, with no new version needed. See [docs/MAINTAINING.md](docs/MAINTAINING.md).

## Not in this version

Push notifications, starting a new conversation, searching inside messages, reactions other than the heart, replying to a particular message, group settings, story text, stickers and music, Close Friends, posting to the feed, writing comments, following and unfollowing, and saved posts.

## Contributing

Issues and pull requests are welcome. Two rules keep everyone's accounts safer:

- Send only requests the website itself sends, with its parameters and headers.
- Nothing automated: no background likes, follows or scraping. Everything should happen at a human pace, because a person tapped something.

Releasing a version is described in [docs/RELEASING.md](docs/RELEASING.md).

## License

Unreeled is free software: you can share and change it under the terms of the [GNU General Public License, version 3](LICENSE). Contributions are accepted under the same license.
