import { bindings, defineConfig } from "cf/config";

// The website at unreeled.app: static files from dist/ (see wrangler.config.ts). Requests for
// files cost nothing and run no code, with one exception: the video's files go through worker.js,
// which sends the part of a file a browser asks for. Static files alone can't, and Safari plays
// no video without it.
export default defineConfig({
  worker: {
    name: "unreeled",
    compatibilityDate: "2026-11-04",
    entrypoint: "./worker.js",
    domains: ["unreeled.app"],
    assets: {
      // /privacy serves privacy.html; /privacy.html and /privacy/ redirect to /privacy.
      htmlHandling: "auto-trailing-slash",
      notFoundHandling: "404-page",
      // Only the video's files run worker.js before the static files answer.
      runWorkerFirst: ["/video/*"],
    },
    env: {
      // The static files, for worker.js to take the video from.
      ASSETS: bindings.assets(),
    },
    // Only unreeled.app: no copies of the site on workers.dev addresses.
    workersDev: false,
    previewUrls: false,
    // No request logs. PRIVACY.md promises the site doesn't log requests.
    observability: { enabled: false },
  },
});
