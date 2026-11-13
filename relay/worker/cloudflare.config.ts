import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// This file runs in Node, when the project is served, built or deployed.
declare const process: { env: Record<string, string | undefined> };

// The notification relay as a Cloudflare Worker (see README.md). A Worker answers the phones'
// pairing calls; one Durable Object, `Relay`, keeps the connection to Mozilla's push service
// open, holds the phones' records, and forwards each push to Apple.
export default defineConfig(({ mode }) => {
	// Deploying builds in "production" mode. Any other mode is this machine: `cf dev`, and the
	// tests, which run `cf dev --mode test` against stand-ins for Mozilla and Apple.
	const local = mode !== undefined && mode !== "production";
	// On this machine a setting comes from the environment, as RELAY_<NAME>, in plain text.
	const given = (name: string) => (local ? process.env[`RELAY_${name}`] : undefined);
	const text = (name: string, value: string) => bindings.text(given(name) ?? value);
	const optional = (name: string) => {
		const value = given(name);
		return value === undefined ? undefined : bindings.text(value);
	};
	// A deployment's secrets are uploaded with `cf deploy --secrets-file` (see README.md). One
	// declared here has to be set, or the deploy fails.
	const secret = (name: string, required = true) => (local ? optional(name) : required ? bindings.secret() : undefined);
	// Without Apple's key the relay can only be deployed on purpose, as a dry run that does
	// everything but send to Apple: `RELAY_DRY_RUN=1 cf deploy`.
	const live = process.env.RELAY_DRY_RUN !== "1";

	return {
		worker: {
			name: "unreeled-relay",
			compatibilityDate: "2026-11-04",
			entrypoint,
			// Phones reach the relay here. A workers.dev address would carry the name of the
			// Cloudflare account.
			domains: local ? [] : ["relay.unreeled.app"],
			workersDev: false,
			previewUrls: false,
			// No request logs: the privacy policy says pairing calls aren't logged.
			observability: { enabled: false },
			exports: {
				Relay: exports.durableObject({ storage: "sqlite" }),
			},
			env: {
				// Mozilla's push service, and Instagram's web push public key: the relay's channels
				// only accept pushes signed by it. Change it if Instagram does.
				AUTOPUSH_URL: text("AUTOPUSH_URL", "wss://push.services.mozilla.com"),
				INSTAGRAM_VAPID_KEY: text(
					"INSTAGRAM_VAPID_KEY",
					"BIBn3E_rWTci8Xn6P9Xj3btShT85Wdtne0LtwNUyRQ5XjFNkuTq9j4MPAVLvAFhXrUU1A9UxyxBA7YIOjqDIDHI",
				),
				// Pairing is refused beyond this many phones.
				MAX_DEVICES: text("MAX_DEVICES", "1000"),
				// Pairing calls from one address, per minute. Not in the tests, which make many.
				PAIRING_LIMIT: mode === "test" ? undefined : bindings.rateLimit({ namespace: "1001", simple: { limit: 10, period: 60 } }),

				// /pair and /unpair need `Authorization: Bearer <token>`. The app's build carries the
				// same value, as UNREELED_RELAY_TOKEN.
				PAIRING_TOKEN: secret("PAIRING_TOKEN"),
				// Apple's push key (the .p8 file's text), its ID, the team's ID, and the app's bundle
				// ID: several, separated by commas, if the team signs more than one build.
				APNS_KEY: secret("APNS_KEY", live),
				APNS_KEY_ID: secret("APNS_KEY_ID", live),
				APNS_TEAM_ID: secret("APNS_TEAM_ID", live),
				APNS_TOPIC: secret("APNS_TOPIC", live),

				// Only on this machine. Where Apple's two services are, for the tests' stand-in.
				APNS_HOST: optional("APNS_HOST"),
				// A dry run keeps the last pushes it would have sent, for GET /outbox to hand to
				// `xcrun simctl push`.
				OUTBOX: optional("OUTBOX"),
				// The tests' clock: how often the object checks its connection, and how long the
				// connection may be quiet before it's asked whether it's still there.
				CHECK_SECONDS: optional("CHECK_SECONDS"),
				QUIET_SECONDS: optional("QUIET_SECONDS"),
			},
		},
	};
});
