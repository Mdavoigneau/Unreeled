# Features

What each screen does, and how.

| Native | Instagram's website in a web view (Reels and Explore filtered out) |
| --- | --- |
| Home: stories on top, then your Following feed, newest first. No ads, no suggestions, no reels. | Logging in |
| Stories: posting a photo or video to yours, the tray with Watch All, rings on avatars, a full-screen viewer, likes and replies | Message kinds the app can't show yet, through a link to the conversation on the website |
| Messages: the inbox with search and conversations; sending text, photos, videos and voice messages; hearts on messages; photos, videos, voice messages, GIFs, story replies, shared posts and reels (the paper plane on Home, with the unread count) | Editing your profile |
| Activity (the heart tab): what people did with your posts and stories, and follow requests | Anything else, through "Open Website" |
| A post with its comments. Profiles and their posts, account search, likes | |

Reels from accounts you follow can be switched on in Settings (the gear on your profile). They then show as single videos, with no swipe feed.

## Look

Retro but sober, after Instagram around 2016:

- **Bars:** flat white with hairline borders. The app draws its own top bar and tab bar instead of the iOS 26 Liquid Glass ones. Navigation is still native, including swiping back from the left edge.
- **Type and colour:** Helvetica Neue, outline icons, and steel blue as the only accent (links, buttons, story rings).
- **Details:** uppercase timestamps, carousel dots under the photo, and a "Stories · Watch All" tray.
- **Tabs:** tapping the open tab again goes back to its first screen. Direct hides the tab bar, as the old app did, and so does the keyboard.
- **Instant:** what you do shows at once (a message, a story reply, a like) and goes to Instagram in the background. A small "✓ Delivered" confirms it once Instagram has it; if it fails, it says so and offers to retry, or puts things back.

Colours and fonts live in [Theme.swift](../Unreeled/App/Theme.swift), the bars in [Chrome.swift](../Unreeled/Views/Chrome.swift). The app icon is [AppIcon.png](../Unreeled/Assets.xcassets/AppIcon.appiconset/AppIcon.png): the U of the wordmark in white on steel blue. It's a copy of [Design/AppIcon.png](../Design/AppIcon.png), the flat export of [Design/AppIcon.icon](../Design/AppIcon.icon), which opens in Icon Composer (in Xcode › Open Developer Tool). [Design/glyph.swift](../Design/glyph.swift) draws the U.

## First launch

Before anything else, a short notice says what Unreeled is and what using it means for your account. "I Understand" leads to Instagram's own login page. The notice is also in Settings, under About at the top right, with the version and the project's links.

## Speed

Screens open on what the app saved last time, then update when Instagram answers:

- **Saved copies.** Home's feed, the stories tray, the inbox, conversations, Activity and the profiles you visit are kept as Instagram sent them. Each screen shows its copy at once. A conversation opens complete, pictures and all, on its newest message. One you've never opened shows the inbox's last few messages, with grey shapes for photos until the rest arrives.
- **Conversations ahead of time.** Two seconds after launch, and whenever the app comes back to the front, the inbox loads. That gives the paper plane its unread count. Then the app loads the 4 most recent conversations and the 3 you open most, one a second, but only those with something newer than the saved copy. Loading one this way doesn't mark it read; only opening it does. The latest pictures of the first three load too.
- **Stories ahead of time.** The first three accounts with something new load with the picture each starts on, so they open at once.
- **Pictures ahead of time.** On Home, the next three posts' pictures load before they scroll into view.
- **Session values.** The values the website's page provides (`fb_dtsg`, `lsd` and others) are kept in the Keychain, on this device only, and reused for a day. A launch doesn't load instagram.com's page before the first request. They're refreshed in the background after an hour, and at once if a query fails. Requests that need them at the same moment share one read of the page.
- **Cleaning up.** Saved copies unused for two weeks are deleted at launch. Past 150 files or 50 MB, the least recently used go first. Pictures are in iOS's URL cache (up to 512 MB). Logging out deletes all of it, the Keychain values and the counts of which conversations you open.

[Caches.swift](../Unreeled/App/Caches.swift) has the saved copies, the Keychain and the open counts.

## Stories

**Your story** comes first in the tray. Tap the blue + (or your avatar, when you have nothing up) to pick a photo or video. It opens on a preview, so nothing is posted until you tap "Share to Your Story". It then goes up in the background: a note says "Posting to your story", then "Added to your story". Videos are cut to 1280×720 H.264; photos to 1920 pixels on their longer side. In your own story, the trash button deletes the item on screen after you confirm.

The rest of the tray lists accounts you follow with stories, in the website's order. A coloured ring means something new; a grey ring means seen. Tapping an avatar anywhere (tray, post, profile) opens that account's stories. In the viewer:

- Tap the right side for the next item, the left side for the previous one.
- Hold to pause; swipe down to close. The story shrinks and slides away over the app.
- While an item loads, a spinner shows and its bar waits: it starts once the photo is on screen or the video plays.
- When one account's stories end, the next account's start.

At the bottom, as on the website:

- **Send message:** type a reply and send. The story pauses while you type; the reply goes to the owner's Direct with the story attached. A note at the bottom says "Sending to …", then "✓ Delivered to …", and stays on screen if you close the story first.
- **Heart:** likes or unlikes that story item. It turns red at once; if Instagram refuses, it goes back.

There's no field on your own stories, or when the owner has turned replies off.

Watching a story marks it seen the way the website does, so its owner sees you in their viewers.

## Messages

The paper plane on Home opens Direct: your conversations, newest first, with a blue dot on unread ones and story rings on avatars.

**Search** sits at the top of Direct. As you type, your conversations whose name or people match show at once under "Conversations". Half a second after you stop typing, Instagram's own search adds anyone else under "More accounts", as the website does (`/api/v1/direct_v2/ranked_recipients/`, one request per pause). Someone found that way opens your conversation with them by their Direct ID, as on the website, including older conversations further down the inbox. Clearing the search puts you back where you were in the inbox. Opening someone you've never written to shows an empty conversation; sending a first message to a new person hasn't been tried.

In a conversation:

- **Text** in bubbles: yours light grey on the right, theirs white with a hairline on the left. Times appear between messages more than half an hour apart.
- **Photos and videos** show in the conversation, including several sent at once. Tap one to see it full screen: photos zoom with a pinch, videos play with sound. Swipe down to close.
- **Voice messages** play in place, with their waveform filling in as they play, and the time left.
- **Recording a voice message:** when the field is empty, a microphone sits where Send goes. Tap it to start recording; a bar shows the time and the sound as it comes in, with a trash button to throw it away and an arrow to send it. Recordings stop at a minute, Instagram's limit. The first time, iOS asks for the microphone.
- **GIFs and stickers** loop silently.
- **View-once photos and videos** only open in Instagram's own app: the website never gets them, only a "use the mobile app" placeholder. They show as a "View-once photo" bubble. Tapping it opens a note: open it in Instagram, look, come straight back without scrolling, and ask the friend to send photos normally next time. Its "Open Instagram" button opens that conversation in Instagram's app; tap ‹ Unreeled at the top left to come back.
- **Sending photos and videos:** the photo button left of the field picks up to ten from your library. Each shows in the conversation at once, uploads in the background, and gets the same "Sending…" then "✓ Delivered". A failed one keeps its "Tap to retry".
- **Shared posts and reels** show as a card with the author and a preview. Tapping one opens that post or reel on its own page, where a video starts by itself. There's no feed after it to scroll into.
- **Story replies and reactions** say so above the story: "Replied to your story" or "Reacted to your story" (or "You replied to their story"). The story shows small, then the words; a reaction's emoji sits on the story. After a day the story has expired and shows as "Story unavailable". The inbox says "Replied to your story: …" too.
- **Shared stories** open their preview full screen. Expired stories can't be opened.
- **Hearts:** double-tap a message to put a heart on it, and again to take it off. The heart shows under the message at once, with a light tap, and goes to Instagram in the background. If Instagram refuses, it comes off again and an error shows. Other people's hearts and reactions show the same way. Instagram's "… reacted to your message" lines are hidden, since the heart is on the message itself.
- **Other notices** from Instagram are small grey lines.
- **Older messages** load one page of 20 each time you scroll up to the top, at most one a second, and the message you were reading stays where it is.
- **Sending** shows your message straight away. Under your latest message: "Sending…", then "✓ Delivered" once Instagram has it, then "Seen" when they've read it. If it fails: "Not sent · Tap to retry".

The website gets new messages over a live connection the app doesn't have. Instead, an open conversation checks for new messages every 15 seconds, and the inbox reloads when you come back from a conversation (and at most every 10 seconds otherwise). A reload refreshes the top of the list and keeps the conversations loaded below it, so you stay where you were. New messages scroll into view only if you're already at the bottom or the message is yours.

Opening a conversation with something new in it marks it read, which the other person sees, as on the website. So does sending.

A message the app can't show yet shows what it is, with a link to the conversation on the website.

## Activity

The heart tab, native:

- **Follow requests** on top when you have some: who's asking, and a list where Confirm and Delete act at once and go to Instagram in the background. These two buttons haven't been tried on a real request yet.
- **Notifications** by Today, Yesterday, This Week, This Month and Earlier: likes on your stories and posts, new followers, and the like. Names are in bold; a post shows its thumbnail.
- **Taps:** a row opens the post, or the person's profile. One about your story opens your story while it's still up. An avatar with a ring opens that person's story.
- **Left out:** Instagram's own prompts rather than things people did: "… has new followers", suggested Threads posts, and account notices. A notification Instagram repeats shows once.

Opening Activity marks nothing as seen, as on the website. It reloads when you come back to it, at most every 30 seconds, and when you pull down.

## Notifications

Only in a build made with a relay, and off until you turn them on: [NOTIFICATIONS.md](NOTIFICATIONS.md) has the whole design. Not yet tried on an iPhone.

- **Asking.** Once, after logging in, a page says what notifications are and what turning them on means, with "Turn On" and "Not Now". "Turn On" brings up iOS's own question. The same page comes up when you switch them on in Settings.
- **In Settings:** a switch, since when they've been on, a way into iOS Settings when notifications are off for Unreeled there, and "Choose What Instagram Sends", which opens Instagram's own page for the kinds of notification, with its "Messages only".
- **What shows:** the conversation's name and the message for a message, with the sender's picture; the notification's text for likes, follows and the rest. Messages stack by conversation. No badge on the app's icon.
- **A tap** opens the conversation, or Activity.
- **While the app is open,** a notification shows as a banner unless it's about the conversation on screen, and the inbox's count and the open conversation refresh at once instead of waiting.
- **Off** in Settings or by logging out: the keys are deleted and the relay forgets the phone.

The code is in [Unreeled/Notifications](../Unreeled/Notifications), [Shared](../Shared) and [NotificationService](../NotificationService).

## Known limits

- Notifications need a build made with a relay. Without one, they still come from Instagram's own app.
- Messages arrive within 15 seconds while a conversation is open, not instantly. What you send shows at once.
- Hearts are the only reaction you can put on a message, and you can't reply to a particular message yet.
- Stories go up as they are: no text, stickers, music or Close Friends.
- Not tested yet: recording from a real microphone (the voice test used a generated tone), posting a video story, and the hand-off to Instagram's app for view-once photos.
- Instagram's checks for automated behaviour look at more than request format. This client doesn't load the website's pages or send its logging events, so keep likes and follows at a human pace.
