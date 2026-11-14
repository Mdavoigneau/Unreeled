# Maintaining Unreeled

## When Instagram changes a query

Instagram gives a query a new ID whenever it changes it, and the old ID stops working. The screen that uses it shows an error, and a Debug build's log shows the query failing.

1. **Find the new ID** in a Debug build, as below.
2. **Update its entry** in [Queries.json](../Unreeled/API/Queries.json): the `doc_id`, and the `providers` if the website now sends different flags. If the variables changed too, Endpoints.swift needs a new version of the app.
3. **Sign the list:** `node tools/sign-queries.mjs`. It checks every entry as the app would, then writes [Queries.json.sig](../Unreeled/API/Queries.json.sig). Push both files to `main`.

Installed apps then pick it up without a new version. They download `https://unreeled.app/queries.json` and its signature, or the two files on GitHub if the site doesn't answer, at launch at most every 6 hours and right after a query fails at most every 10 minutes. They take a list only when it's signed with one of the keys in [QueryUpdates.swift](../Unreeled/API/QueryUpdates.swift), and not signed before the list they have. The site rebuilds from `main` on every push that changes the list, within a few minutes, and refuses a list whose signature doesn't match ([website/README.md](../website/README.md)).

Rules for the list, since every installed version reads it:

- Never remove or rename an entry: older versions still use it. Add new ones freely; versions that don't know a name ignore it.
- Change only what Instagram changed. Apps take an entry only when its `doc_id` is all digits, its `path` is `/api/graphql` or `/graphql/query`, and its flags start with `__relay_internal__pv__`.
- Sign only a list you'd publish: every installed app takes a signed list, wherever it comes from. A `doc_id` from someone else's pull request needs checking before you sign it, by recording the query yourself as below.

To try a list before signing it, serve it locally and point a Debug build at it:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory Unreeled/API
```

Then launch with `-queriesURL http://127.0.0.1:8765/Queries.json -queriesUnsigned YES` (Product › Scheme › Edit Scheme › Run › Arguments). The Debug build looks there at every launch, and the log shows what it took. Without `-queriesUnsigned`, it checks the signature next to the list, as installed apps do.

### The signing key

The private key is `~/.config/unreeled/query-signing/private-key.pem` on the maintainer's computer, or the file named by `UNREELED_QUERY_KEY`. Whoever has it chooses which of Instagram's queries every installed app sends, so it goes nowhere else: not in the repository, a build, or a CI service, where anyone who can push could have it sign. Keep a copy in a password manager.

- **Lost:** installed apps keep the list they have and take no new one until they update. Make a new key with `node tools/sign-queries.mjs new-key`, add the public key it prints to `publicKeys` in QueryUpdates.swift, and release a new version.
- **Leaked:** the same, and take the old key out of `publicKeys` in that version. Versions already installed trust the old key until they update.
- **Changing keys on purpose:** add the new key to `publicKeys` in a release, and keep signing with the old one until most installs have that release.

## Finding a query's new ID

In a Debug build (the **Unreeled** scheme):

1. Open the matching page of the website in the app: "Open Website" on an error, or the launch argument `-web /some/path/`.
2. Read the network log, `Library/Caches/network-log.jsonl` in the app's data folder. In the simulator:

   ```bash
   open "$(xcrun simctl get_app_container booted com.example.unreeled data)/Library/Caches"
   ```

   (Use your own bundle ID if you set one in `Config/Local.xcconfig`.) Each line is one API call the website made: the query name (`fb_api_req_friendly_name`), its `doc_id`, its variables, and the shape of the response (field names and value types, never the values). Session tokens and anything from the login form are masked.
3. Update the query's entry as above.

Some calls never show up as requests: a page the website preloads, or an action you'd rather not perform just to record it. Then search the website's own scripts instead, with `-findScripts '"<regex>"'` together with `-web /some/path/` (keep the double quotes inside the single quotes, or a pattern starting with `(` or `[` is read as a list and the search never runs). About 12 seconds after the page loads, the log gets each match with the code around it, and the `doc_id` of every query or mutation whose name matches. The scripts are also saved to `Library/Caches/scripts/` to search further from the Mac; delete that folder afterwards (about 40 MB).

## Debug tools

Debug builds also log, to the same file:

- **Feed diagnostics.** For each page of the feed: how many items were posts, reels or ads, and any decoding errors.
- **Session values.** Which values were found in the website's page, by length only.
- **Query updates.** Each check: where from, how many entries were valid, which changed.
- **Likes.** Every like the app sends.
- **Messages.** That a message was sent (its length and the conversation's ID, never its text), and each mark-as-read.
- **Stories and activity.** Story likes and replies (a reply's length, never its text), whether Instagram took them, kinds of notification, and follow requests answered.

Launch arguments that help when testing:

- `-web /path/` shows that instagram.com page instead of the app, to record the calls it makes.
- `-post <code>` opens a post natively by the code in its link (`instagram.com/p/<code>/`).
- `-probe 'GQL QueryName {"variable": …}'` runs a query at launch and logs the shape of its response.
- `-directShapes YES` logs the shape of every conversation you open: field names and the kinds of message in it, never what they say. Use it to see a new kind of message the app doesn't show yet.
- `-noStorySeen YES` opens stories without telling Instagram you saw them, to test the story viewer without showing up in anyone's viewers.
- `-standInConversations YES` opens a blank stand-in instead of a conversation, to test the inbox without opening anyone's messages or marking them read.
- `-testVoiceClip YES` records a test tone instead of the microphone.
- `-queriesURL <url>` takes query updates from that address, looked at every launch; with `-queriesUnsigned YES`, without checking the signature.
- `-relay <address>` uses that notification relay, such as `http://localhost:8787`, and `-pushDryRun YES` turns notifications on without registering anything with Instagram. Together they try notifications in the simulator: see Testing in [NOTIFICATIONS.md](NOTIFICATIONS.md).

## Testing on a real account

Anything that writes (a like, a message, a story) acts on a real account and other people see it. Test on your own posts, or with a friend who agreed, and undo what you can. Opening someone's conversation marks it read for them; use `-standInConversations YES` to work on the inbox.

## Building for your own iPhone

See "Build it yourself" in the [README](../README.md). Signing comes from `Config/Signing.xcconfig`, which includes your `Config/Local.xcconfig` (ignored by git). The **Unreeled for iPhone** scheme builds the Release version, which is faster and has none of the debug tools.

With a free Apple ID, the app stops opening after 7 days: build and run again, which reinstalls over the old copy and keeps your login. Deleting the app logs you out. A free Apple ID also allows only 3 of your own apps on the phone at a time.
