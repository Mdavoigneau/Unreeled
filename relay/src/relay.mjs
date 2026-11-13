// The relay, put together: one Mozilla connection (many channels) -> on each push, look up the
// device and forward the ciphertext to its iPhone via APNs. Plus the pairing API. index.mjs runs
// it from the environment; the tests run it against stand-ins for Mozilla and Apple.
import { MozillaClient } from "./mozilla-client.mjs";
import { Store } from "./store.mjs";
import { ApnsForwarder } from "./apns.mjs";
import { createServer } from "./server.mjs";

/**
 * @param {object}   cfg
 * @param {string}   cfg.dataFile      Where device records and the Mozilla uaid are kept.
 * @param {string}   cfg.vapidKey      Instagram's web-push (VAPID) public key.
 * @param {string}  [cfg.autopushUrl]  Mozilla's push service.
 * @param {string}  [cfg.pairingToken] Shared token for /pair and /unpair.
 * @param {number}  [cfg.maxDevices]
 * @param {object}   cfg.apns          { keyFile, keyId, teamId, topics, sandbox, outbox, hosts }
 */
export function createRelay(cfg, logger = console) {
  const store = new Store(cfg.dataFile);
  const apns = new ApnsForwarder({ ...cfg.apns, logger });
  // Counts since start, for /health. Nothing about any one device or push.
  const stats = { forwarded: 0, failed: 0, lastPushAt: null };

  const forget = (device, why) => {
    mozilla.unregisterChannel(device.channelID);
    store.removeByChannel(device.channelID);
    logger.info?.(`[forget] device ${device.deviceId.slice(0, 8)}…: ${why}`);
  };

  const mozilla = new MozillaClient({
    vapidKey: cfg.vapidKey,
    url: cfg.autopushUrl,
    logger,
    getIdentity: () => ({ uaid: store.getUaid(), channelIDs: store.channelIDs() }),
    saveIdentity: (uaid) => store.setUaid(uaid),
    onNotification: async (channelID, message) => {
      const device = store.getByChannel(channelID);
      if (!device) return;
      try {
        await apns.send(device, message);
        stats.forwarded += 1;
        stats.lastPushAt = new Date().toISOString();
        logger.info?.(`[forward] channel ${channelID.slice(0, 8)}… -> APNs`);
      } catch (e) {
        stats.failed += 1;
        logger.warn?.(`[forward] APNs failed for ${channelID.slice(0, 8)}…:`, e?.message || e);
        // The app was deleted, or the token was never good: nothing can reach this phone again.
        if (e?.gone) forget(device, e.reason || "gone");
      }
    },
    // Mozilla forgot our identity, and with it every endpoint. Each device gets a new channel
    // right away; its phone learns the new endpoint the next time it pairs again, and gives it
    // to Instagram.
    onReset: async (lost) => {
      for (const oldChannelID of lost) {
        try {
          const { channelID, endpoint } = await mozilla.registerChannel();
          store.moveDevice(oldChannelID, channelID, endpoint);
        } catch (e) {
          logger.warn?.(`[reset] couldn't re-register ${oldChannelID.slice(0, 8)}…:`, e?.message || e);
        }
      }
    },
  });

  const server = createServer({
    store,
    mozilla,
    authToken: cfg.pairingToken,
    topics: cfg.apns.topics,
    sandbox: cfg.apns.sandbox,
    maxDevices: cfg.maxDevices,
    health: () => ({ apns: apns.enabled ? "live" : "dry-run", ...stats }),
    logger,
  });

  return {
    store,
    mozilla,
    apns,
    server,
    /** Connects to Mozilla, then serves the pairing API on `port`. */
    async start(port) {
      await mozilla.start();
      logger.info?.(`[relay] Mozilla connected; ${store.channelIDs().length} device(s) resumed; APNs ${apns.enabled ? "LIVE" : "DRY-RUN"}`);
      await new Promise((resolve) => server.listen(port, resolve));
      logger.info?.(`[relay] pairing API listening on :${server.address().port}`);
    },
    close() {
      mozilla.close();
      apns.close();
      server.close();
    },
  };
}
