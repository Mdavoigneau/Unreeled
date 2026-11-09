import { defineConfig } from "cf/config";

// The website at unreeled.app: static files from dist/ (see wrangler.config.ts), with no Worker
// code. Requests for files cost nothing and run no code.
export default defineConfig({
  worker: {
    name: "unreeled",
    compatibilityDate: "2026-11-04",
    domains: ["unreeled.app"],
    assets: {
      // /privacy serves privacy.html; /privacy.html and /privacy/ redirect to /privacy.
      htmlHandling: "auto-trailing-slash",
      notFoundHandling: "404-page",
    },
    // Only unreeled.app: no copies of the site on workers.dev addresses.
    workersDev: false,
    previewUrls: false,
    // No request logs. PRIVACY.md promises the site doesn't log requests.
    observability: { enabled: false },
  },
});
