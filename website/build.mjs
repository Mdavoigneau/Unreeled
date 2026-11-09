// Builds the website at unreeled.app into dist/, for Cloudflare to serve as static files:
//
//   - the pages in src/, inside src/layout.html, with src/style.css inlined;
//   - /privacy, from the repository's PRIVACY.md (and /privacy.md, the Markdown itself);
//   - /queries.json, the repository's Unreeled/API/Queries.json byte for byte, which installed
//     apps download to stay current (see Unreeled/API/QueryUpdates.swift);
//   - sitemap.xml, and everything in public/ as it is.
//
//     npm run build
//
// Cloudflare runs this on every push to main that touches the site, PRIVACY.md or Queries.json
// (see README.md), so the live copies never lag behind the repository.

import { createHash } from "node:crypto";
import { cp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { marked } from "marked";

const site = "https://unreeled.app";
const repository = "https://github.com/Mdavoigneau/Unreeled";
const website = new URL("./", import.meta.url);
const root = new URL("../", website);
const dist = new URL("dist/", website);

const description =
  "Unreeled is a free, open-source iPhone app for Instagram that shows only the people you follow. No Reels, no Explore, no suggested posts, no ads.";

// MARK: Files from the repository

/** The query list exactly as it is in the repository. A file that isn't a JSON object of queries
 * fails the build, so the site keeps serving the last good one. (Apps check each entry
 * themselves and skip any that look wrong.) */
async function queries() {
  const bytes = await readFile(new URL("Unreeled/API/Queries.json", root));
  const list = JSON.parse(bytes.toString("utf8"));
  const count = list && typeof list === "object" && !Array.isArray(list) ? Object.keys(list).length : 0;
  if (!count) throw new Error("Unreeled/API/Queries.json isn't a list of queries");
  await writeFile(new URL("queries.json", dist), bytes);
  return count;
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

// MARK: Pages

const escape = (text) =>
  text.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/** What search engines and assistants read about the app, as schema.org JSON-LD. */
function structuredData() {
  const app = `${site}/#app`;
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebSite",
        "@id": `${site}/#website`,
        url: `${site}/`,
        name: "Unreeled",
        description: "Your friends on Instagram, without the rabbit hole.",
        inLanguage: "en",
      },
      {
        "@type": "SoftwareApplication",
        "@id": app,
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
        sameAs: [repository],
      },
      {
        "@type": "SoftwareSourceCode",
        "@id": `${repository}#source`,
        name: "Unreeled",
        codeRepository: repository,
        programmingLanguage: "Swift",
        license: "https://www.gnu.org/licenses/gpl-3.0.html",
        targetProduct: { "@id": app },
      },
    ],
  };
}

function head(page) {
  const url = page.path && `${site}${page.path}`;
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
      `<meta property="og:type" content="website">`,
      `<meta property="og:site_name" content="Unreeled">`,
      `<meta property="og:title" content="${escape(page.title)}">`,
      `<meta property="og:description" content="${escape(page.description)}">`,
      `<meta property="og:url" content="${url}">`,
      `<meta property="og:image" content="${site}/images/og.png">`,
      `<meta property="og:image:width" content="1200">`,
      `<meta property="og:image:height" content="630">`,
      `<meta property="og:image:alt" content="The Unreeled icon, a white U on steel blue, beside the words: Unreeled. Your friends on Instagram, without the rabbit hole.">`,
      `<meta name="twitter:card" content="summary_large_image">`,
    );
  }
  if (page.structuredData) {
    const json = JSON.stringify(structuredData(), null, 2).replaceAll("<", "\\u003c");
    tags.push(`<script type="application/ld+json">\n${json}\n</script>`);
  }
  return tags.join("\n");
}

/** Adds a short hash of each image to its address, so browsers can keep images for a year (see
 * public/_headers) and still get a new one the moment it changes. */
async function versionImages(html) {
  const hashes = new Map();
  for (const name of await readdir(new URL("images/", dist))) {
    const bytes = await readFile(new URL(`images/${name}`, dist));
    hashes.set(name, createHash("sha256").update(bytes).digest("hex").slice(0, 10));
  }
  return html.replace(/(["'])((?:https:\/\/unreeled\.app)?\/images\/([\w.-]+))\1/g, (match, quote, url, name) => {
    if (!hashes.has(name)) throw new Error(`Missing image: ${url}`);
    return `${quote}${url}?v=${hashes.get(name)}${quote}`;
  });
}

async function render(page, layout, style) {
  const main = page.main ?? (await readFile(new URL(`src/${page.file}`, website), "utf8"));
  let html = layout
    .replace("{{head}}", () => head(page))
    .replace("{{style}}", () => style.trim())
    .replace("{{main}}", () => main.trim());
  // Marks where you are in the header.
  if (page.path) {
    html = html.replace(`<a href="${page.path}">`, `<a href="${page.path}" aria-current="page">`);
  }
  await writeFile(new URL(page.file, dist), await versionImages(html));
}

function sitemap(pages) {
  const urls = pages
    .filter((page) => page.path)
    .map((page) => {
      const lastModified = page.lastModified ? `<lastmod>${page.lastModified}</lastmod>` : "";
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

const queryCount = await queries();
const policy = await privacy();
const layout = await readFile(new URL("src/layout.html", website), "utf8");
const style = await readFile(new URL("src/style.css", website), "utf8");

const pages = [
  {
    file: "index.html",
    path: "/",
    title: "Unreeled: your friends on Instagram, without the rabbit hole",
    description,
    structuredData: true,
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

for (const page of pages) await render(page, layout, style);
await writeFile(new URL("sitemap.xml", dist), sitemap(pages));

console.log(`Built dist/: ${pages.length} pages, queries.json with ${queryCount} queries.`);
