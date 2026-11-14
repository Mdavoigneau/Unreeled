// Unreeled notification relay — entry point. All config is via env vars (see README.md). Runs
// fine with no Apple account (APNs goes DRY-RUN).
import { fileURLToPath } from "node:url";
import { createRelay } from "./relay.mjs";

const env = process.env;
const list = (value) => (value || "").split(",").map((s) => s.trim()).filter(Boolean);
// A number setting, or its default when it isn't a positive number: a typo mustn't lift a limit.
const number = (value, fallback) => (Number(value) > 0 ? Number(value) : fallback);

// Without a pairing token anyone can pair. That's for a dry run on one's own machine, never for a
// relay that delivers.
if (env.APNS_KEY_FILE && !env.PAIRING_TOKEN) {
  console.error("[relay] PAIRING_TOKEN isn't set. A relay with Apple's key needs one, so that only your builds can pair: give the app's build the same value as UNREELED_RELAY_TOKEN. Without APNS_KEY_FILE the relay is a dry run, which can go without.");
  process.exit(1);
}

const relay = createRelay({
  dataFile: env.DATA_FILE || fileURLToPath(new URL("../data/relay.json", import.meta.url)),
  // Instagram's public web-push (VAPID) key. Override via env if Instagram ever rotates it.
  vapidKey: env.INSTAGRAM_VAPID_KEY || "BIBn3E_rWTci8Xn6P9Xj3btShT85Wdtne0LtwNUyRQ5XjFNkuTq9j4MPAVLvAFhXrUU1A9UxyxBA7YIOjqDIDHI",
  autopushUrl: env.AUTOPUSH_URL || "wss://push.services.mozilla.com",
  pairingToken: env.PAIRING_TOKEN || "",
  operatorToken: env.OPERATOR_TOKEN || "", // GET /health's counts, for whoever runs the relay; never in a build
  trustedProxies: list(env.TRUSTED_PROXY), // the HTTPS proxy in front: only its X-Forwarded-For is believed
  maxDevices: number(env.MAX_DEVICES, 1000),
  newDevicesPerWeek: number(env.NEW_DEVICES_PER_WEEK, 5),
  deviceTtlDays: number(env.DEVICE_TTL_DAYS, 30),
  apns: {
    keyFile: env.APNS_KEY_FILE || "",
    keyId: env.APNS_KEY_ID || "",
    teamId: env.APNS_TEAM_ID || "",
    topics: list(env.APNS_TOPIC), // the app's bundle id; several, separated by commas
    sandbox: env.APNS_ENV === "sandbox", // for a phone that doesn't say which service it's on
    outbox: env.APNS_OUTBOX || "",
  },
});

// HOST=127.0.0.1 behind a proxy on the same machine, so that only the proxy reaches the relay.
await relay.start(Number(env.PORT || 8787), env.HOST || undefined);

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => { console.log(`[relay] ${sig}; shutting down`); relay.close(); process.exit(0); });
}
