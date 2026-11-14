// The relay, put together: one Mozilla connection (many channels) -> on each push, look up the
// device and forward the ciphertext to its iPhone via APNs. Plus the pairing API. index.mjs runs
// it from the environment; the tests run it against stand-ins for Mozilla and Apple.
import { MozillaClient } from "./mozilla-client.mjs";
import { Store } from "./store.mjs";
import { ApnsForwarder } from "./apns.mjs";
import { createServer } from "./server.mjs";

const DAY_MS = 24 * 3600 * 1000;
const SWEEP_MS = 3600 * 1000; // how often the records that have run out are forgotten

/**
 * @param {object}   cfg
 * @param {string}   cfg.dataFile      Where device records and the Mozilla uaid are kept.
 * @param {string}   cfg.vapidKey      Instagram's web-push (VAPID) public key.
 * @param {string}  [cfg.autopushUrl]  Mozilla's push service.
 * @param {string}  [cfg.pairingToken] Shared token for /pair and /unpair.
 * @param {string}  [cfg.operatorToken] For whoever runs the relay, never in a build: GET /health's counts.
 * @param {string[]} [cfg.trustedProxies] The HTTPS proxy's addresses: only their X-Forwarded-For is believed.
 * @param {number}  [cfg.maxDevices]
 * @param {number}  [cfg.newDevicesPerWeek] New records one caller (an address, an IPv6 /56) may make in a week.
 * @param {number}  [cfg.deviceTtlDays] How long a record lasts with nothing to show its phone is real.
 * @param {object}   cfg.apns          { keyFile, keyId, teamId, topics, sandbox, outbox, hosts, answerMs }
 * @param {object}  [cfg.mozilla]      The tests' clock for the connection to Mozilla (see MozillaClient).
 */
export function createRelay(cfg, logger = console) {
  const store = new Store(cfg.dataFile);
  const apns = new ApnsForwarder({ ...cfg.apns, logger });
  // Counts since start, for whoever runs the relay. Nothing about any one device or push.
  const stats = { forwarded: 0, failed: 0, lastPushAt: null };
  const ttlDays = cfg.deviceTtlDays > 0 ? cfg.deviceTtlDays : 30;

  const forget = (device, why) => {
    mozilla.unregisterChannel(device.channelID);
    store.removeByChannel(device.channelID);
    logger.info?.(`[forget] device ${device.deviceId.slice(0, 8)}…: ${why}`);
  };

  const mozilla = new MozillaClient({
    ...cfg.mozilla,
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
        // Apple took it, so the phone is real: its record lives on. Written at most once a day,
        // to spare the data file. A dry run proves nothing.
        if (apns.enabled && !(Date.now() - Date.parse(device.lastSeen) < DAY_MS)) store.updateDevice(channelID, { lastSeen: stats.lastPushAt });
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
    apns,
    forget,
    authToken: cfg.pairingToken,
    operatorToken: cfg.operatorToken,
    trustedProxies: cfg.trustedProxies,
    topics: cfg.apns.topics,
    sandbox: cfg.apns.sandbox,
    maxDevices: cfg.maxDevices,
    newDevicesPerWeek: cfg.newDevicesPerWeek,
    health: () => ({ apns: apns.enabled ? "live" : "dry-run", ...stats }),
    logger,
  });

  /**
   * Forgets the phones nothing has shown to be real for `deviceTtlDays`: no push Apple took, and
   * no pairing again that Apple didn't refuse. A real phone that was only quiet pairs afresh the
   * next time its app is opened, and gives Instagram its new endpoint.
   */
  const sweep = () => {
    const before = Date.now() - ttlDays * DAY_MS;
    for (const device of store.devices()) if (Date.parse(device.lastSeen) < before) forget(device, `not seen for ${ttlDays} days`);
  };
  let sweeper = null;

  return {
    store,
    mozilla,
    apns,
    server,
    sweep,
    /** Connects to Mozilla, then serves the pairing API on `port`, on every interface unless `host` says. */
    async start(port, host) {
      await mozilla.start();
      logger.info?.(`[relay] Mozilla connected; ${store.channelIDs().length} device(s) resumed; APNs ${apns.enabled ? "LIVE" : "DRY-RUN"}`);
      sweep();
      sweeper = setInterval(sweep, SWEEP_MS);
      await new Promise((resolve) => server.listen(port, host, resolve));
      logger.info?.(`[relay] pairing API listening on ${host || ""}:${server.address().port}`);
    },
    close() {
      clearInterval(sweeper);
      mozilla.close();
      apns.close();
      server.close();
    },
  };
}
