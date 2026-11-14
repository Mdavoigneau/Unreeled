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
- **Tabs:** tapping the open tab again goes back to its first screen, and on the first screen, back to the top. On Home, already at the top, it loads the feed again while the wordmark fills. On Search, it opens the search field with the keyboard. Tapping the status bar also goes back to the top. Direct hides the tab bar, as the old app did, and so does the keyboard.
- **Instant:** what you do shows at once (a message, a story reply, a like) and goes to Instagram in the background. A small "✓ Delivered" confirms it once Instagram has it; if it fails, it says so and offers to retry, or puts things back.

Colours and fonts live in [Theme.swift](../Unreeled/App/Theme.swift), the bars in [Chrome.swift](../Unreeled/Views/Chrome.swift). The app icon is [AppIcon.png](../Unreeled/Assets.xcassets/AppIcon.appiconset/AppIcon.png): the U of the wordmark in white on steel blue. It's a copy of [Design/AppIcon.png](../Design/AppIcon.png), the flat export of [Design/AppIcon.icon](../Design/AppIcon.icon), which opens in Icon Composer (in Xcode › Open Developer Tool). [Design/glyph.swift](../Design/glyph.swift) draws the U.

## First launch

Before anything else, a short notice says what Unreeled is and what using it means for your account. "I Understand" leads to Instagram's own login page. The notice is also in Settings, under About at the top right, with the version and the project's links.

## Speed

Screens open on what the app saved last time, then update when Instagram answers:

- **Launch.** The app opens straight on Home's saved feed for the account logged in last time, while WebKit checks the cookies in the background (about a third of a second). If they're gone, the login page follows, and what the app kept for that login is deleted (see Logging out). The cookies are checked again whenever the app comes back to the front, and when you leave one of the website's pages.
- **Home stays current.** At launch, Instagram's latest posts and stories load right away over the saved feed. While they load, the wordmark in the top bar fills with ink from left to right: quickly at first, then slower, and the rest at once when they're in. Coming back to the app after a minute or more loads them again if Home is at the top; after ten minutes or more, Home goes back to the top first, as at launch.
- **Saved copies.** Home's feed, the stories tray, the inbox, conversations and the profiles you visit are kept as Instagram sent them. Each screen shows its copy at once. A conversation opens complete, pictures and all, on its newest message. One you've never opened shows the inbox's last few messages, with grey shapes for photos until the rest arrives. Each account's copies are files of their own, named by a hash of the account and what they are, and an answer is kept only for the login that asked for it. A profile's first posts are kept under its ID, and only when they're its own: a username can pass to another account.
- **Your profile** is kept apart from the profiles you visit, so they never push it out. It's read at launch, with the pictures of its first posts, so the Profile tab opens complete. Instagram's copy replaces it when you open the tab, at most every five minutes.
- **Activity** keeps your last 100 notifications and your follow requests, with only what the rows show: 60 KB for 17 notifications and 28 requests, a quarter of a megabyte at most. It opens on them at once, and keeps the older ones Instagram stops sending (it sends the latest 25 or so).
- **Pictures.** Every picture is kept on the phone once it has loaded, so profile pictures, posts and photos in messages show at once, across launches too. Instagram signs a picture's link anew in every response, so the app keeps pictures by what doesn't change: the file's path on Instagram's servers and its size (and, for a picture Instagram passes on from another site, that picture's address). (Keyed by the full link, the same profile picture was being downloaded and stored again with every refresh: once, 263 times.) Of the sizes Instagram offers, the app takes one in the picture's own shape: it also lists square crops, which made 9:16 stories show zoomed in.
- **Only from Instagram's servers.** Pictures and videos load only over https from Instagram's and Facebook's servers for them (`cdninstagram.com`, `fbcdn.net`, `fbsbx.com`; [MediaHosts.swift](../Unreeled/App/MediaHosts.swift)), redirects included, never from another address a message might carry. A picture stops at 16 MB and a story file at 50 MB, as they come; a story video too large for that streams instead.
- **Inbox at launch.** The saved inbox loads as the app opens, which gives the paper plane its count. From the phone only, the app then gets everyone's picture in the list ready, along with the saved copies of the 8 most recent conversations and the 3 you open most, and the newest pictures of the first three.
- **Conversations ahead of time.** Two seconds after launch, and whenever the app comes back to the front, Instagram's inbox loads. Then the app loads the 4 most recent conversations and the 3 you open most, one a second, but only those with something newer than the saved copy. Loading one this way doesn't mark it read; only opening it does. The latest pictures of the first three load too.
- **Stories ahead of time.** After the tray loads, the first nine accounts with something new load, three at a time as the website's viewer asks for them, a second apart; the others load while you watch, a batch ahead of where you are. Their photos and videos then go onto the phone one at a time, in the order you'd watch them, until 30 MB of stories are there; what the viewer shows next always goes first. Each account's stories are kept for the day, so a relaunch asks only for accounts that posted since. Items more than a day old are left out of a kept reel, and one with none left isn't used. A reel opened from what the phone kept shows at once, and Instagram is asked for it as it opens, as the website does: its answer takes the kept one's place, so an item the owner took down goes, and the account is skipped if nothing is up any more.
- **Home ahead of time.** The next page of posts loads once you're eight posts from the end, and the one after it too if that page was mostly reels. The next four posts' pictures are decoded before they scroll into view, and the four after go onto the phone.
- **Smooth scrolling.** Instagram's responses are read and decoded off the main thread, so a page arriving while you scroll doesn't make the list stutter. In a conversation, typing and recording only redraw the field at the bottom, not the messages.
- **Session values.** The values the website's page provides (`fb_dtsg`, `lsd` and others) are kept in the Keychain, on this device only, and reused for a day; only a logged-in page's are kept. A launch doesn't load instagram.com's page before the first request. They're refreshed in the background after an hour, and at once if a query fails. Requests that need them at the same moment share one read of the page. A launch without a login deletes any left from before, since the Keychain outlives the app.
- **Cleaning up.** At every launch and whenever the app leaves the screen, so it stays light: story photos and videos go a day after they were saved, and past 60 MB the least recently watched go first; pictures unused for two weeks go, and past 100 MB the least recently used; saved copies unused for two weeks go, and so do those Instagram hasn't sent again for a month, however often they're read, then past 100 files or 40 MB the least recently used. Conversations are kept apart so visiting profiles never pushes them out: the 60 opened last, for a month. Your profile and Activity's notifications stay until you log out. Closing the stories viewer trims the stories too.

## Logging out

**Log Out** (Settings, the gear on your profile) first asks Instagram to end the session, with the website's own request (`/api/v1/web/accounts/logout/ajax/`), so a copy of the session cookie stops working too. It gets five seconds at most, while a spinner shows; then, whatever Instagram answered, the phone deletes all of the login: the website's data and cookies, the saved copies, conversations, pictures and stories on the phone and in memory, the voice messages you recorded, the counts of which conversations you open, the session values in the Keychain, and the ID Direct knows this phone by, so the next login gets a new one. Notifications are turned off with it ([NOTIFICATIONS.md](NOTIFICATIONS.md)).

The same deletion follows a login that ends any other way:

- **Its cookie is gone,** run out or taken back by Instagram, or you logged out on one of the website's pages in the app: found at launch, when the app comes back to the front, and when you leave a website page.
- **Instagram says it has ended,** from another device or after a password change. An answer like that can also be an error page on the way, so it deletes nothing on its own: the login counts as ended when its cookie has gone, or when one more small request (Direct search's suggestions) gets Instagram's own answer that it has. No connection, or Instagram failing, changes nothing. This is checked once a minute at most.
- **Another account** logs in on one of the website's pages: everything of the first account goes, but the cookies, which are the new login's.

Backups don't carry the login: iOS leaves the caches folder out of them, and the website's data (its cookies, in `Library/WebKit`) is marked to be left out too. The app's settings do go into backups, among them which conversations you open most and the ID Direct knows the phone by. If the app's data reaches another phone, from an older backup or a copy of its files, the app there starts logged out and deletes all of that: a random mark kept in the Keychain on this device only, and a note in the app's settings that it was made, tell the two apart, since a backup carries the note but never the mark. An install updated from a version without the mark makes both at its first launch and stays logged in.

## Weak connections

On a plane's Wi-Fi, in the underground, with one bar:

- **Reading** is tried three times, a moment apart, before a screen says anything. Without any connection, it isn't tried at all: a grey "No Internet Connection" strip shows under the top bar, screens show what they saved, and each screen that couldn't load loads again by itself once the phone is back online.
- **Saved copies stay.** A screen whose new copy didn't come keeps the saved one, with one quiet line under it: "Couldn't refresh. Try Again". A screen with nothing saved says what happened ("You're offline.", "Couldn't reach Instagram.") with Try Again, and "Open Website" only when it's Instagram's answer, not the connection.
- **Stories** that couldn't load say so with Try Again, under the account's picture and name, and load by themselves when the phone is back online. Moving on to the next account never shows the previous one's stories late.
- **Sending** (messages, hearts, likes, replies) waits up to a minute for a connection, and is tried again only when it certainly didn't reach Instagram, so nothing goes twice. A message whose answer was lost shows as failed until Instagram's copy of the conversation turns up with it, found by the ID it was sent with; it then shows as sent. Retry sends it with that same ID.
- **The Direct list follows your conversations.** Opening one shows it read at once, and a message you send shows on its row and moves it to the top once Instagram has it, even if the inbox can't load afterwards. If marking a conversation read didn't reach Instagram, the next look tries again.

[Caches.swift](../Unreeled/App/Caches.swift) has the saved copies, the pictures and story files on the phone (`ImageFiles`, `StoryFiles`), the Keychain and the open counts; [RemoteImage.swift](../Unreeled/Views/RemoteImage.swift) the pictures in memory.

## Stories

**Your story** comes first in the tray. Tap the blue + (or your avatar, when you have nothing up) to pick a photo or video. It opens on a preview, so nothing is posted until you tap "Share to Your Story". It then goes up in the background: a note says "Posting to your story", then "Added to your story". Videos are cut to 1280×720 H.264; photos to 1920 pixels on their longer side. In your own story, the trash button deletes the item on screen after you confirm.

The rest of the tray lists accounts you follow with stories, in the website's order. A coloured ring means something new; a grey ring means seen. Tapping an avatar anywhere (tray, post, profile) opens that account's stories. In the viewer:

- The story is a 9:16 card under the status bar, with the reply field below it, as in Instagram's app; on a screen too short for that, it fills the screen. Stories in another shape fit inside the card on black instead of being cropped.
- Tap the right side for the next item, the left side for the previous one.
- Hold to pause; swipe down to close. A swipe starts once your finger has clearly moved down, so taps never nudge the story; it then follows your finger, shrinks a little and slides away over the app.
- A video plays from the phone when it was loaded ahead, which starts at once, and streams otherwise. Its cover shows until the first frame is ready, never a black flash.
- While an item loads, a spinner shows and its bar waits: it starts once the photo is on screen or the video plays. The bars move smoothly, redrawn on their own every frame.
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

Opening Activity marks nothing as seen, as on the website. It reloads when you switch to it or come back to its first screen, at most every 30 seconds, when you tap a notification that isn't a message, and when you pull down. The last 100 notifications stay on the phone (see Speed), so older ones remain after Instagram stops sending them.

## Notifications

Only in a build made with a relay, and off until you turn them on: [NOTIFICATIONS.md](NOTIFICATIONS.md) has the whole design. They have worked on an iPhone since 13 November 2026; how they hold over weeks isn't known yet.

- **Asking.** Once, after logging in, a page says what notifications are and what turning them on means, with "Turn On" and "Not Now". "Turn On" brings up iOS's own question. The same page comes up when you switch them on in Settings.
- **In Settings:** a switch, since when they've been on, a way into iOS Settings when notifications are off for Unreeled there, and "Choose What Instagram Sends", which opens Instagram's own page for the kinds of notification, with its "Messages only".
- **What shows:** the conversation's name and the message for a message, with the sender's picture; the notification's text for likes, follows and the rest. Messages stack by conversation. No badge on the app's icon.
- **A tap** opens the conversation, or Activity.
- **Reply.** Press and hold a message's notification, tap Reply and type: the reply goes to the conversation without opening the app, from the lock screen too, and from a Mac that shows the iPhone's notifications. iOS wakes the app in the background to send it. If it doesn't go within 20 seconds, or Instagram refuses it, a notification says so, quoting it, with Reply again; a tap opens the conversation. Works on an iPhone and from a Mac (tried on 13 November 2026; see [NOTIFICATIONS.md](NOTIFICATIONS.md#replying)).
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
