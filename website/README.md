# unreeled.app

The project's website: the home page, the privacy policy, and the list of queries installed apps download. It's static files on Cloudflare ([Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/)), built from this folder and the rest of the repository on every push to `main`. No JavaScript, no web fonts, no analytics.

| Address | From |
| --- | --- |
| `/` | `src/index.html` |
| `/research` | `src/research.html`: what the research says about Instagram, TikTok and your brain |
| `/social-media-break` | `src/social-media-break.html`: how to take a break from social media without losing your friends |
| `/privacy` | [PRIVACY.md](../PRIVACY.md), rendered; `/privacy.md` is the Markdown itself |
| `/queries.json` | [Unreeled/API/Queries.json](../Unreeled/API/Queries.json), byte for byte, cached for 5 minutes |
| `/queries.json.sig` | [Unreeled/API/Queries.json.sig](../Unreeled/API/Queries.json.sig), the list's signature ([MAINTAINING.md](../docs/MAINTAINING.md)), cached for 5 minutes |
| `/sitemap.xml` | written by `build.mjs` |
| `/robots.txt`, `/llms.txt`, `/icon.png`, favicons | `public/`, as they are |

The app's About screen links to `/privacy`, App Store Connect has it as the privacy policy, and the app downloads `/queries.json` and `/queries.json.sig` ([QueryUpdates.swift](../Unreeled/API/QueryUpdates.swift)). Those addresses must never change.

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

Cloudflare builds and deploys the site whenever a push to `main` changes `website/`, `PRIVACY.md`, `Unreeled/API/Queries.json` or its signature ([Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/)). The Worker is `unreeled`, under Settings › Build:

| Setting | Value |
| --- | --- |
| Git repository | `Mdavoigneau/Unreeled`, branch `main` |
| Root directory | `website` |
| Build command | `npm run build` |
| Deploy command | `npx cf deploy` |
| Build watch paths | include `website/*`, `PRIVACY.md`, `Unreeled/API/Queries.json`, `Unreeled/API/Queries.json.sig`, `tools/query-signature.mjs` |
| Builds for non-production branches | off |

A build that fails, for example because Queries.json isn't valid JSON or its signature doesn't match it, leaves the last good site in place. To deploy from a Mac instead: `npx cf auth login`, then `npm run deploy`.

`cloudflare.config.ts` serves the site on unreeled.app only, with no workers.dev copy, and turns logs off. [PRIVACY.md](../PRIVACY.md) says the site doesn't log requests or use them to identify anyone: keep observability and Web Analytics off, or change the policy first.

## Later: AltStore PAL

[RELEASING.md](../docs/RELEASING.md) describes an AltStore source at `/altstore.json` and a folder per version for the packages, such as `/altstore/1.0/manifest.json`. Files in `public/` are served as they are, so both can go there. Cloudflare serves files of up to 25 MiB this way; a larger package file would need R2.
