import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// The push test's relay (see README.md): a Worker that records what arrives at one secret push
// address.
export default defineConfig({
	worker: {
		name: "unreeled-push-test",
		compatibilityDate: "2026-11-04",
		entrypoint,
		// The push address is given to Instagram, so it's on the project's domain: a workers.dev
		// address carries the name of the Cloudflare account.
		domains: ["relay.unreeled.app"],
		workersDev: false,
		previewUrls: false,
		// No request logs: what the test keeps is in its own database, and nothing else.
		observability: { enabled: false },
		env: {
			// Created by the first deploy.
			DB: bindings.d1({ name: "unreeled-push-test" }),
			// The last part of the push address, and the token that reads the log. Both are made by
			// `node tools/pushtest.mjs keys` and uploaded with `--secrets-file` (see README.md).
			PUSH_ID: bindings.secret(),
			READ_TOKEN: bindings.secret(),
		},
	},
});
