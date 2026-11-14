# unreeled.app

The project's website: the home page, the privacy policy, and the list of queries installed apps download. It's static files on Cloudflare ([Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)), built from this folder and the rest of the repository on every push to `main`. No JavaScript in its pages, no web fonts, no analytics.

| Address | From |
| --- | --- |
| `/` | `src/index.html` |
| `/research` | `src/research.html`: what the research says about Instagram, TikTok and your brain |
| `/social-media-break` | `src/social-media-break.html`: how to take a break from social media without losing your friends |
| `/security` | `src/security.html`: how Unreeled keeps an account private, with [a video](#the-video) |
| `/video/security.mp4`, `/video/security.vtt` | [Unreeled/Video/](../Unreeled/Video), byte for byte: the video and its captions, which the app carries and plays itself |
| `/video/security.png`, `/video/security-path.png` | `public/video/`: two pictures from the video |
| `/privacy` | [PRIVACY.md](../PRIVACY.md), rendered; `/privacy.md` is the Markdown itself |
| `/queries.json` | [Unreeled/API/Queries.json](../Unreeled/API/Queries.json), byte for byte, cached for 5 minutes |
| `/queries.json.sig` | [Unreeled/API/Queries.json.sig](../Unreeled/API/Queries.json.sig), the list's signature ([MAINTAINING.md](../docs/MAINTAINING.md)), cached for 5 minutes |
| `/sitemap.xml` | written by `build.mjs` |
| `/robots.txt`, `/llms.txt`, `/icon.png`, favicons | `public/`, as they are |

The app's About screen links to `/privacy`; under the video, which the app plays from its own copy, it links to `/security` and `/security#notifications`; App Store Connect has `/privacy` as the privacy policy; and the app downloads `/queries.json` and `/queries.json.sig` ([QueryUpdates.swift](../Unreeled/API/QueryUpdates.swift)). Those addresses must never change.

## Working on it

With Node.js 22.18 or later:

```bash
cd website
npm install
npm run dev
```

That builds the site into `dist/` and serves it at http://localhost:8787. `npm run build` only builds. Pages are `src/*.html` inside `src/layout.html`, with `src/style.css` inlined; titles, descriptions and the JSON-LD are in `build.mjs`. Response headers are in `public/_headers`.

`llms.txt` sums up the project for AI assistants. Keep it in step with the README when something big changes, such as AltStore PAL becoming available.

### Articles

The research and the guide are articles. In `build.mjs`, each one has a headline (its `<h1>`), the date it was first published, the date it last changed, and what it's about, as Wikipedia articles. Those go into the page's structured data (schema.org `Article`), its Open Graph tags and the sitemap, and the page shows the last change where it says `{{modified}}`. Set `modified` to the day whenever an article's content changes.

Every claim in an article links to an entry in its Sources list, and those entries link to the papers, court records and reporting themselves. When you update an article, check that each source still says what the article says it does.

A `<section class="faq">` on any page also goes into its structured data (schema.org `FAQPage`): each `<h3>` is a question, and what follows it, up to the next `<h3>`, is the answer.

## The video

`/security` and the home page show a two-minute video: how the app keeps an account private, and how notifications pass through a relay that can't read them. All of it is made from the files in `video/`, with free software and no recordings:

| File | What it is |
| --- | --- |
| `video/narration.json` | What the voice says, scene by scene, and which voice says it |
| `video/scenes.html` | The pictures: a page that draws the frame for any moment, in two shapes: wide for this site, and tall for a phone held upright, which the app shows |
| `video/build.py` | Says the narration with [Kokoro](https://github.com/hexgrad/kokoro), an open text-to-speech model, photographs the page 30 times a second in a headless Chromium, computes the sound effects, and has ffmpeg put it together |

With [uv](https://docs.astral.sh/uv/) and ffmpeg installed:

```bash
uv run website/video/build.py
```

That takes a minute or two and writes two places. Both shapes of the video (`security.mp4`, wide, and `security-tall.mp4`), its captions and the list of where its parts begin go to [Unreeled/Video/](../Unreeled/Video): the app carries them, so the video plays there at once without asking any server, and this site's build takes the wide video and the captions from there, as it takes the query list. Two pictures from the video go to `public/video/`. Commit all of it: Cloudflare only copies. The first run downloads Kokoro's model (about 310 MB), and needs Playwright's Chromium (`uv run --with playwright==1.59.0 playwright install chromium`).

- **The timeline follows the voice.** Each scene lasts as long as its sentences take to say, and `scenes.html` starts its animations at the words they belong to: `at("path", "encrypts")` is the moment that word is said. So after changing `narration.json`, build everything again, and if a word an animation waits for is gone, the build says which.
- **Another voice:** `--voice am_fenrir`, `--voice bm_george` (British), or any other of [Kokoro's](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md). `--effects 0.7` makes the sound effects quieter, `--effects 0` leaves them out.
- **Looking at it while changing it:** `uv run website/video/build.py still 42.5 69.9` writes single frames to `video/.build/stills/` (`--tall` for the tall shape), and `scenes.html` opened in a browser plays with a slider, once the voice and sound steps have run.
- **Two shapes.** In `scenes.html` an element says where it goes in the tall shape in `data-tall`, and the script picks between two numbers where it places things itself (`pick(wide, tall)`). Both shapes have the same sound and length, so the app can go from one to the other when the phone is turned. A change to a scene has to be looked at in both.
- **Parts.** A scene with a `chapter` in `narration.json` begins a part. The app starts at "Notifications" when the video is opened from its page about notifications ([SecurityVideo.swift](../Unreeled/Views/SecurityVideo.swift)), so keep that name, or change it in both.
- **What it says must stay true.** The narration follows [PRIVACY.md](../PRIVACY.md), as `src/security.html` does. When the policy changes, change all three, and set the page's `modified` in `build.mjs`. A new video reaches the website with the push and the app with its next version.

One thing about serving it: a browser asks for a video in parts, and Safari plays one only from a server that answers with the part it asked for. Cloudflare's static files answer with the whole file instead ([workers-sdk#8967](https://github.com/cloudflare/workers-sdk/issues/8967)). So `worker.js`, the site's only code on the server, answers requests under `/video/` with the bytes asked for; `cloudflare.config.ts` sends it those requests and no others.

## Images

The icon, favicons, wordmark and the card shown for shared links are made from the app's icon, `Design/AppIcon.icon`, and the system fonts the app uses. After the icon changes, run this on a Mac with Xcode 26 or later and commit what it writes:

```bash
swift website/tools/images.swift
```

Screenshots come from the iOS simulator, with nobody's posts, stories or messages on screen:

```bash
xcrun simctl status_bar booted override --time 9:41 --batteryState discharging --batteryLevel 100
xcrun simctl io booted screenshot shot.png
xcrun simctl status_bar booted clear
swift website/tools/images.swift --screenshot shot.png welcome
```

The home page's screenshot is the first screen, shown with the launch argument `-acceptedNotice 0`.

## Deploying

Cloudflare builds and deploys the site whenever a push to `main` changes `website/`, `PRIVACY.md`, the video in `Unreeled/Video/`, `Unreeled/API/Queries.json` or its signature ([Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/)). The Worker is `unreeled`, under Settings › Build:

| Setting | Value |
| --- | --- |
| Git repository | `Mdavoigneau/Unreeled`, branch `main` |
| Root directory | `website` |
| Build command | `npm run build` |
| Deploy command | `npx cf deploy` |
| Build watch paths | include `website/*`, `PRIVACY.md`, `Unreeled/API/Queries.json`, `Unreeled/API/Queries.json.sig`, `Unreeled/Video/*`, `tools/query-signature.mjs` |
| Builds for non-production branches | off |

A build that fails, for example because Queries.json isn't valid JSON or its signature doesn't match it, leaves the last good site in place. To deploy from a Mac instead: `npx cf auth login`, then `npm run deploy`.

`cloudflare.config.ts` serves the site on unreeled.app only, with no workers.dev copy, turns logs off, and sends requests under `/video/` through `worker.js` ([The video](#the-video)). [PRIVACY.md](../PRIVACY.md) says the site doesn't log requests or use them to identify anyone: keep observability and Web Analytics off, or change the policy first.

## Later: AltStore PAL

[RELEASING.md](../docs/RELEASING.md) describes an AltStore source at `/altstore.json` and a folder per version for the packages, such as `/altstore/1.0/manifest.json`. Files in `public/` are served as they are, so both can go there. Cloudflare serves files of up to 25 MiB this way; a larger package file would need R2.
