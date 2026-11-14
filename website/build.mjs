// Builds the website at unreeled.app into dist/, for Cloudflare to serve as static files:
//
//   - the pages in src/, inside src/layout.html, with src/style.css inlined;
//   - /privacy, from the repository's PRIVACY.md (and /privacy.md, the Markdown itself);
//   - /queries.json, the repository's Unreeled/API/Queries.json byte for byte, which installed
//     apps download to stay current (see Unreeled/API/QueryUpdates.swift), and /queries.json.sig,
//     its signature, which they check;
//   - sitemap.xml, and everything in public/ as it is: the images, and the video on /security,
//     which video/build.py makes (see README.md).
//
//     npm run build
//
// Cloudflare runs this on every push to main that touches the site, PRIVACY.md, Queries.json or
// its signature (see README.md), so the live copies never lag behind the repository.

import { createHash } from "node:crypto";
import { cp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { marked } from "marked";
import { checkSignature } from "../tools/query-signature.mjs";

const site = "https://unreeled.app";
const repository = "https://github.com/Mdavoigneau/Unreeled";
const email = "hello@unreeled.app";
const website = new URL("./", import.meta.url);
const root = new URL("../", website);
const dist = new URL("dist/", website);

const description =
  "Unreeled is a free, open-source iPhone app for Instagram that shows only the people you follow. No Reels, no Explore, no suggested posts, no ads.";

// MARK: Files from the repository

/** The query list exactly as it is in the repository, with its signature. A file that isn't a JSON
 * object of queries, or a signature that doesn't match it, fails the build, so the site keeps
 * serving the last good pair. (Apps check the signature too, and each entry, and skip any that
 * look wrong.) */
async function queries() {
  const bytes = await readFile(new URL("Unreeled/API/Queries.json", root));
  const list = JSON.parse(bytes.toString("utf8"));
  const count = list && typeof list === "object" && !Array.isArray(list) ? Object.keys(list).length : 0;
  if (!count) throw new Error("Unreeled/API/Queries.json isn't a list of queries");
  const signature = await readFile(new URL("Unreeled/API/Queries.json.sig", root)).catch(() => {
    throw new Error("Unreeled/API/Queries.json.sig is missing: sign the list (node tools/sign-queries.mjs)");
  });
  const signed = await checkSignature(bytes, signature);
  await writeFile(new URL("queries.json", dist), bytes);
  await writeFile(new URL("queries.json.sig", dist), signature);
  return { count, signed };
}

/** The privacy policy, rendered, with the date it took effect for the sitemap. */
async function privacy() {
  const markdown = await readFile(new URL("PRIVACY.md", root), "utf8");
  await writeFile(new URL("privacy.md", dist), markdown);
  const effective = markdown.match(/^\*Effective (\d{1,2} \w+ \d{4})\*$/m)?.[1];
  const date = effective ? new Date(`${effective} UTC`) : null;
  return {
    html: marked.parse(markdown),
    lastModified: date && !isNaN(date) ? date.toISOString().slice(0, 10) : null,
  };
}

/** How long an MP4 lasts, in seconds, read from its movie header (the mvhd box). */
function mp4Seconds(bytes) {
  const header = bytes.indexOf("mvhd", 0, "latin1");
  if (header < 0) throw new Error("public/video/security.mp4 has no movie header");
  const [scale, length] =
    bytes[header + 4] === 1
      ? [bytes.readUInt32BE(header + 24), Number(bytes.readBigUInt64BE(header + 28))]
      : [bytes.readUInt32BE(header + 16), bytes.readUInt32BE(header + 20)];
  return length / scale;
}

/** The video on /security, which video/build.py makes: how long it is, and what it says, for the
 * page's structured data. */
async function securityVideo() {
  const seconds = Math.round(mp4Seconds(await readFile(new URL("public/video/security.mp4", website))));
  const narration = JSON.parse(await readFile(new URL("video/narration.json", website), "utf8"));
  return {
    file: "security",
    duration: `PT${Math.floor(seconds / 60)}M${seconds % 60}S`,
    transcript: narration.scenes.map((scene) => scene.text).join(" "),
  };
}

/** The video's player, wherever a page says {{security-video}}: the browser's own controls, no
 * JavaScript. Until someone presses play it loads only its first picture. */
const securityPlayer = `<video controls playsinline preload="none" poster="/video/security.png" width="1920" height="1080" aria-label="How Unreeled keeps your account private">
    <source src="/video/security.mp4" type="video/mp4">
    <track kind="captions" srclang="en" label="English" src="/video/security.vtt">
    <a href="/video/security.mp4">Watch the video</a>
  </video>`;

// MARK: Pages

const escape = (text) =>
  text.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/** Plain text from a piece of the site's own HTML, for structured data. */
const plainText = (html) =>
  html
    .replace(/<[^>]+>/g, "")
    .replaceAll("&nbsp;", " ")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&amp;", "&")
    .replace(/\s+/g, " ")
    .trim();

/** A date the way the site writes it, such as "9 November 2026", for an ISO date. */
const longDate = (date) =>
  new Date(`${date}T00:00:00Z`).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });

// MARK: Structured data
//
// What search engines and assistants read about each page, as schema.org JSON-LD.

const ids = {
  website: `${site}/#website`,
  organization: `${site}/#organization`,
  app: `${site}/#app`,
};

const websiteData = {
  "@type": "WebSite",
  "@id": ids.website,
  url: `${site}/`,
  name: "Unreeled",
  description: "Your friends on Instagram, without the rabbit hole.",
  inLanguage: "en",
  publisher: { "@id": ids.organization },
};

/** The project, which publishes the site and writes its articles. */
const organizationData = {
  "@type": "Organization",
  "@id": ids.organization,
  name: "Unreeled",
  url: `${site}/`,
  logo: `${site}/icon.png`,
  email,
  sameAs: [repository],
};

/** The questions in a page's <section class="faq">: each <h3>, and what follows it as the answer. */
function questionsData(main) {
  const section = main.match(/<section\b[^>]*\bclass="[^"]*\bfaq\b[^"]*"[^>]*>([\s\S]*?)<\/section>/)?.[1];
  if (!section) return [];
  const mainEntity = section
    .split(/<h3\b[^>]*>/)
    .slice(1)
    .map((part) => {
      const [question, answer] = part.split("</h3>");
      return {
        "@type": "Question",
        name: plainText(question),
        acceptedAnswer: { "@type": "Answer", text: plainText(answer) },
      };
    });
  return [{ "@type": "FAQPage", mainEntity }];
}

/** An article: the research and the guide. */
function articleData(page) {
  const url = `${site}${page.path}`;
  return {
    "@type": "Article",
    "@id": `${url}#article`,
    headline: page.headline,
    description: page.description,
    url,
    mainEntityOfPage: url,
    image: [`${site}/images/og.png`, `${site}/icon.png`],
    datePublished: page.published,
    dateModified: page.modified,
    inLanguage: "en",
    author: { "@id": ids.organization },
    publisher: { "@id": ids.organization },
    isPartOf: { "@id": ids.website },
    about: page.about.map(([name, sameAs]) => ({ "@type": "Thing", name, sameAs })),
    ...(page.video && { video: { "@id": `${url}#video` } }),
  };
}

/** An article's video: what search engines need to show it, and what it says. */
function videoData(page) {
  const url = `${site}${page.path}`;
  return {
    "@type": "VideoObject",
    "@id": `${url}#video`,
    name: page.headline,
    description: page.description,
    thumbnailUrl: `${site}/video/${page.video.file}.png`,
    contentUrl: `${site}/video/${page.video.file}.mp4`,
    uploadDate: page.published,
    duration: page.video.duration,
    transcript: page.video.transcript,
    inLanguage: "en",
    publisher: { "@id": ids.organization },
  };
}

/** The app, and its source code. */
const appData = [
  {
    "@type": "SoftwareApplication",
    "@id": ids.app,
    name: "Unreeled",
    description:
      "A free, open-source iPhone app for Instagram that shows the people you follow and nothing else: their posts newest first, their stories, your messages and your activity. No Reels feed, no Explore, no suggested posts, no ads. Unofficial: not made or endorsed by Instagram or Meta.",
    url: `${site}/`,
    image: `${site}/icon.png`,
    screenshot: `${site}/images/welcome.png`,
    applicationCategory: "SocialNetworkingApplication",
    operatingSystem: "iOS 18.0 or later",
    availableOnDevice: "iPhone",
    isAccessibleForFree: true,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    license: "https://www.gnu.org/licenses/gpl-3.0.html",
    featureList: [
      "Home: stories on top, then posts from the accounts you follow, newest first",
      "Stories: watch, like and reply; post a photo or video to yours",
      "Messages: inbox with search; text, photos, videos and voice messages; hearts",
      "Activity: likes, new followers and follow requests",
      "Profiles and posts, with comments, and account search",
      "No Reels feed, no Explore, no suggested posts, no ads",
      "Collects nothing: no analytics, no tracking, no third-party code",
    ],
    publisher: { "@id": ids.organization },
    sameAs: [repository],
  },
  {
    "@type": "SoftwareSourceCode",
    "@id": `${repository}#source`,
    name: "Unreeled",
    codeRepository: repository,
    programmingLanguage: "Swift",
    license: "https://www.gnu.org/licenses/gpl-3.0.html",
    targetProduct: { "@id": ids.app },
  },
];

/** The home page describes the app; articles describe themselves. Other pages have none. */
function structuredData(page, main) {
  let graph;
  if (page.path === "/") graph = [websiteData, organizationData, ...appData, ...questionsData(main)];
  else if (page.published) {
    const video = page.video ? [videoData(page)] : [];
    graph = [websiteData, organizationData, articleData(page), ...video, ...questionsData(main)];
  }
  else return null;
  return { "@context": "https://schema.org", "@graph": graph };
}

function head(page, main) {
  const url = page.path && `${site}${page.path}`;
  const article = Boolean(page.published);
  const tags = [
    `<title>${escape(page.title)}</title>`,
    `<meta name="description" content="${escape(page.description)}">`,
    url ? `<link rel="canonical" href="${url}">` : `<meta name="robots" content="noindex">`,
    `<meta name="color-scheme" content="light">`,
    `<meta name="theme-color" content="#ffffff">`,
    `<link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48">`,
    `<link rel="icon" href="/images/icon-192.png" type="image/png" sizes="192x192">`,
    `<link rel="apple-touch-icon" href="/apple-touch-icon.png">`,
  ];
  if (url) {
    tags.push(
      // Lets search results and Discover show the share card large.
      `<meta name="robots" content="max-image-preview:large">`,
      `<meta property="og:type" content="${article ? "article" : "website"}">`,
      `<meta property="og:site_name" content="Unreeled">`,
      `<meta property="og:title" content="${escape(page.socialTitle ?? page.headline ?? page.title)}">`,
      `<meta property="og:description" content="${escape(page.description)}">`,
      `<meta property="og:url" content="${url}">`,
      `<meta property="og:image" content="${site}/images/og.png">`,
      `<meta property="og:image:width" content="1200">`,
      `<meta property="og:image:height" content="630">`,
      `<meta property="og:image:alt" content="The Unreeled icon, a white U on steel blue, beside the words: Unreeled. Your friends on Instagram, without the rabbit hole.">`,
      `<meta name="twitter:card" content="summary_large_image">`,
    );
    if (article) {
      tags.push(
        `<meta property="article:published_time" content="${page.published}">`,
        `<meta property="article:modified_time" content="${page.modified}">`,
      );
    }
  }
  const data = url && structuredData(page, main);
  if (data) {
    const json = JSON.stringify(data, null, 2).replaceAll("<", "\\u003c");
    tags.push(`<!--email_off--><script type="application/ld+json">\n${json}\n</script><!--/email_off-->`);
  }
  return tags.join("\n");
}

/** Cloudflare's Email Address Obfuscation, on by default, replaces email addresses in pages with a
 * link that needs its JavaScript, which this site doesn't run (see the Content-Security-Policy in
 * public/_headers). It leaves alone anything between <!--email_off--> and <!--/email_off-->, so
 * every mailto: link goes inside those, and so does the structured data (in head above). */
const keepEmailAddresses = (html) =>
  html.replace(/<a href="mailto:[^"]*">[\s\S]*?<\/a>/g, (link) => `<!--email_off-->${link}<!--/email_off-->`);

/** On phones, a table shows each row as a short list (src/style.css), with every cell labelled by
 * its column's heading, so each <td> gets that heading as data-label. */
const labelTableCells = (html) =>
  html.replace(/<table>([\s\S]*?)<\/table>/g, (table, inner) => {
    const headings = [...inner.matchAll(/<th>([\s\S]*?)<\/th>/g)].map((match) => escape(plainText(match[1])));
    const rows = inner.replace(/<tr>([\s\S]*?)<\/tr>/g, (row, cells) => {
      let column = 0;
      return `<tr>${cells.replace(/<td>/g, () => `<td data-label="${headings[column++] ?? ""}">`)}</tr>`;
    });
    return `<table>${rows}</table>`;
  });

/** A short hash of each image and of the video's files, by address. */
async function fileHashes() {
  const hashes = new Map();
  for (const folder of ["images", "video"]) {
    for (const name of await readdir(new URL(`${folder}/`, dist))) {
      const bytes = await readFile(new URL(`${folder}/${name}`, dist));
      hashes.set(`${folder}/${name}`, createHash("sha256").update(bytes).digest("hex").slice(0, 10));
    }
  }
  return hashes;
}

/** Adds each file's hash to its address, so browsers can keep images and the video for a year
 * (see public/_headers) and still get a new one the moment it changes. */
function versionFiles(html, hashes) {
  return html.replace(/(["'])((?:https:\/\/unreeled\.app)?\/((?:images|video)\/[\w.-]+))\1/g, (match, quote, url, file) => {
    if (!hashes.has(file)) throw new Error(`Missing file: ${url}`);
    return `${quote}${url}?v=${hashes.get(file)}${quote}`;
  });
}

async function render(page, layout, style, hashes) {
  let main = page.main ?? (await readFile(new URL(`src/${page.file}`, website), "utf8"));
  main = main.replaceAll("{{security-video}}", securityPlayer);
  // Articles show their dates from the page list below, so the page and its metadata agree.
  if (page.published) {
    const time = (date) => `<time datetime="${date}">${longDate(date)}</time>`;
    main = main.replaceAll("{{published}}", time(page.published)).replaceAll("{{modified}}", time(page.modified));
  }
  let html = layout
    .replace("{{head}}", () => head(page, main))
    .replace("{{style}}", () => style.trim())
    .replace("{{main}}", () => main.trim());
  // Marks where you are in the header.
  if (page.path) {
    html = html.replace(`<a href="${page.path}">`, `<a href="${page.path}" aria-current="page">`);
  }
  await writeFile(new URL(page.file, dist), versionFiles(keepEmailAddresses(labelTableCells(html)), hashes));
}

function sitemap(pages) {
  const urls = pages
    .filter((page) => page.path)
    .map((page) => {
      const date = page.lastModified ?? page.modified;
      const lastModified = date ? `<lastmod>${date}</lastmod>` : "";
      return `  <url><loc>${site}${page.path}</loc>${lastModified}</url>`;
    });
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.join("\n")}
</urlset>
`;
}

// MARK: Build

await rm(dist, { recursive: true, force: true });
await cp(new URL("public/", website), dist, { recursive: true });

const queryList = await queries();
const policy = await privacy();
const layout = await readFile(new URL("src/layout.html", website), "utf8");
const style = await readFile(new URL("src/style.css", website), "utf8");
const hashes = await fileHashes();

// Articles have a headline (their <h1>), the dates they were first published and last changed,
// and what they're about, as Wikipedia articles, for search engines and assistants. One has a video.
const pages = [
  {
    file: "index.html",
    path: "/",
    // What people search for; links shared elsewhere show the tagline.
    title: "Unreeled: Instagram without Reels, just your friends",
    socialTitle: "Unreeled: your friends on Instagram, without the rabbit hole",
    description,
  },
  {
    file: "research.html",
    path: "/research",
    title: "Instagram, TikTok and your brain: what the research says",
    headline: "Built to keep you scrolling: what the research says about Instagram, TikTok and your brain",
    description:
      "Meta's and TikTok's own research, court records and peer-reviewed studies on how feeds hold attention, what they do to wellbeing, and what a break changes.",
    published: "2026-11-09",
    modified: "2026-11-09",
    about: [
      ["Problematic social media use", "https://en.wikipedia.org/wiki/Problematic_social_media_use"],
      ["Attention economy", "https://en.wikipedia.org/wiki/Attention_economy"],
      ["Infinite scrolling", "https://en.wikipedia.org/wiki/Infinite_scrolling"],
    ],
  },
  {
    file: "social-media-break.html",
    path: "/social-media-break",
    title: "Social media detox: take a break without losing your friends",
    headline: "How to take a break from social media without losing your friends",
    description:
      "A practical guide to a social media break, backed by research: how long to go, what to tell friends, how to keep messages and stories, and what to expect.",
    published: "2026-11-09",
    modified: "2026-11-09",
    about: [
      ["Digital detox", "https://en.wikipedia.org/wiki/Digital_detox"],
      ["Doomscrolling", "https://en.wikipedia.org/wiki/Doomscrolling"],
    ],
  },
  {
    file: "security.html",
    path: "/security",
    title: "Is Unreeled safe? How it keeps your Instagram account private",
    headline: "How Unreeled keeps your account private",
    description:
      "What happens to your Instagram login in Unreeled, the one thing the app downloads, and how notifications pass through a relay that can't read them. With a two-minute video.",
    published: "2026-11-14",
    modified: "2026-11-14",
    about: [
      ["End-to-end encryption", "https://en.wikipedia.org/wiki/End-to-end_encryption"],
      ["Push technology", "https://en.wikipedia.org/wiki/Push_technology"],
      ["Open-source software", "https://en.wikipedia.org/wiki/Open-source_software"],
    ],
    video: await securityVideo(),
  },
  {
    file: "privacy.html",
    path: "/privacy",
    title: "Privacy Policy · Unreeled",
    description:
      "Unreeled collects nothing about you. Your Instagram account goes only between your phone and Instagram: no analytics, no tracking, no third-party code.",
    main: `<main id="main" class="document">\n<article>\n${policy.html}</article>\n<p class="history"><a href="${repository}/commits/main/PRIVACY.md">Earlier versions of this policy</a></p>\n</main>`,
    lastModified: policy.lastModified,
  },
  {
    file: "404.html",
    path: null,
    title: "Page not found · Unreeled",
    description,
  },
];

for (const page of pages) await render(page, layout, style, hashes);
await writeFile(new URL("sitemap.xml", dist), sitemap(pages));

console.log(
  `Built dist/: ${pages.length} pages, queries.json with ${queryList.count} queries, signed ${queryList.signed}.`,
);
