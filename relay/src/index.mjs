// Unreeled notification relay — entry point. All config is via env vars (see README.md). Runs
// fine with no Apple account (APNs goes DRY-RUN).
import { fileURLToPath } from "node:url";
import { createRelay } from "./relay.mjs";

const env = process.env;
const list = (value) => (value || "").split(",").map((s) => s.trim()).filter(Boolean);

const relay = createRelay({
  dataFile: env.DATA_FILE || fileURLToPath(new URL("../data/relay.json", import.meta.url)),
  // Instagram's public web-push (VAPID) key. Override via env if Instagram ever rotates it.
  vapidKey: env.INSTAGRAM_VAPID_KEY || "BIBn3E_rWTci8Xn6P9Xj3btShT85Wdtne0LtwNUyRQ5XjFNkuTq9j4MPAVLvAFhXrUU1A9UxyxBA7YIOjqDIDHI",
  autopushUrl: env.AUTOPUSH_URL || "wss://push.services.mozilla.com",
  pairingToken: env.PAIRING_TOKEN || "",
  maxDevices: Number(env.MAX_DEVICES || 1000),
  apns: {
    keyFile: env.APNS_KEY_FILE || "",
    keyId: env.APNS_KEY_ID || "",
    teamId: env.APNS_TEAM_ID || "",
    topics: list(env.APNS_TOPIC), // the app's bundle id; several, separated by commas
    sandbox: env.APNS_ENV === "sandbox", // for a phone that doesn't say which service it's on
    outbox: env.APNS_OUTBOX || "",
  },
});

await relay.start(Number(env.PORT || 8787));

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => { console.log(`[relay] ${sig}; shutting down`); relay.close(); process.exit(0); });
}
