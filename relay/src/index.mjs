// Unreeled notification relay — entry point.
//
// Wires together: one Mozilla connection (many channels) -> on each push, look up the device and
// forward the ciphertext to its iPhone via APNs. Plus a small pairing API. All config is via env
// vars (see README.md). Runs fine with no Apple account (APNs goes DRY-RUN).
import { MozillaClient } from "./mozilla-client.mjs";
import { Store } from "./store.mjs";
import { ApnsForwarder } from "./apns.mjs";
import { createServer } from "./server.mjs";

const cfg = {
  port: Number(process.env.PORT || 8787),
  dataFile: process.env.DATA_FILE || new URL("../data/relay.json", import.meta.url).pathname,
  // Instagram's public web-push (VAPID) key. Override via env if Instagram ever rotates it.
  vapidKey: process.env.INSTAGRAM_VAPID_KEY || "BIBn3E_rWTci8Xn6P9Xj3btShT85Wdtne0LtwNUyRQ5XjFNkuTq9j4MPAVLvAFhXrUU1A9UxyxBA7YIOjqDIDHI",
  autopushUrl: process.env.AUTOPUSH_URL || "wss://push.services.mozilla.com",
  pairingToken: process.env.PAIRING_TOKEN || "",
  apns: {
    keyFile: process.env.APNS_KEY_FILE || "",
    keyId: process.env.APNS_KEY_ID || "",
    teamId: process.env.APNS_TEAM_ID || "",
    topic: process.env.APNS_TOPIC || "", // the app's bundle id
    production: process.env.APNS_ENV !== "sandbox",
  },
};

const store = new Store(cfg.dataFile);
const apns = new ApnsForwarder({ ...cfg.apns });

const mozilla = new MozillaClient({
  vapidKey: cfg.vapidKey,
  url: cfg.autopushUrl,
  getIdentity: () => ({ uaid: store.getUaid(), channelIDs: store.channelIDs() }),
  saveIdentity: (uaid) => store.setUaid(uaid),
  onNotification: async (channelID, message) => {
    const device = store.getByChannel(channelID);
    if (!device) return;
    try {
      await apns.send(device.apnsToken, message);
      console.log(`[forward] channel ${channelID.slice(0, 8)}… -> APNs`);
    } catch (e) {
      console.warn(`[forward] APNs failed for ${channelID.slice(0, 8)}…:`, e?.message || e);
    }
  },
});

await mozilla.start();
console.log(`[relay] Mozilla connected; ${store.channelIDs().length} device(s) resumed; APNs ${apns.enabled ? "LIVE" : "DRY-RUN"}`);

const server = createServer({ store, mozilla, authToken: cfg.pairingToken });
server.listen(cfg.port, () => console.log(`[relay] pairing API listening on :${cfg.port}`));

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => { console.log(`[relay] ${sig}; shutting down`); mozilla.close(); apns.close(); server.close(); process.exit(0); });
}
