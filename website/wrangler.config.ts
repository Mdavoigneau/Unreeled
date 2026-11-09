import { defineWranglerConfig } from "wrangler/experimental-config";

// cf builds a site without Worker code through Wrangler, which takes the files from here.
export default defineWranglerConfig({
  assetsDirectory: "dist",
});
