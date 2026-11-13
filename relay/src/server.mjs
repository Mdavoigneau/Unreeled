// Pairing API. A phone pairs by POSTing its APNs device token; the relay registers a Mozilla
// channel and returns its endpoint. The phone then registers that endpoint with Instagram, using
// the phone's OWN p256dh/auth — so the relay never sees the decryption keys. See docs/NOTIFICATIONS.md.
import http from "node:http";
import { randomUUID } from "node:crypto";

const MAX_BODY = 4096; // bytes; a pairing request is a few hundred

/**
 * @param {object}   o
 * @param {object}   o.store
 * @param {object}   o.mozilla
 * @param {string}  [o.authToken]   If set, /pair and /unpair need `Authorization: Bearer <token>`.
 * @param {string[]} [o.topics]     Bundle IDs this relay serves; empty accepts any (dry-run).
 * @param {boolean} [o.sandbox]     Which of Apple's services a phone is on when it doesn't say.
 * @param {number}  [o.maxDevices]  Pairing is refused beyond this many devices.
 * @param {Function} [o.health]     () => extra fields for GET /health.
 */
export function createServer({ store, mozilla, authToken = "", topics = [], sandbox = false, maxDevices = 1000, health = () => ({}), logger = console }) {
  const json = (res, code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  const readBody = (req) =>
    new Promise((resolve) => {
      let b = "";
      let tooLong = false;
      // Past the limit the rest is read and dropped, so the answer can still be sent.
      req.on("data", (d) => { if (tooLong) return; b += d; if (b.length > MAX_BODY) { tooLong = true; b = ""; } });
      req.on("end", () => { try { resolve(tooLong ? null : JSON.parse(b || "{}")); } catch { resolve(null); } });
      req.on("error", () => resolve(null));
    });

  return http.createServer(async (req, res) => {
    try {
      // Health is open; everything else needs the shared pairing token (if one is set).
      if (req.method === "GET" && req.url === "/health") {
        return json(res, 200, { ok: true, devices: store.channelIDs().length, mozilla: mozilla.connected, ...health() });
      }
      if (authToken && req.headers.authorization !== `Bearer ${authToken}`) {
        return json(res, 401, { error: "unauthorized" });
      }

      if (req.method === "POST" && req.url === "/pair") {
        const body = await readBody(req);
        const apnsToken = typeof body?.apnsToken === "string" ? body.apnsToken.toLowerCase() : "";
        if (!/^[0-9a-f]{64,200}$/.test(apnsToken)) return json(res, 400, { error: "apnsToken must be the device token in hex" });
        const topic = typeof body.topic === "string" && body.topic ? body.topic : topics[0] || "";
        if (topics.length && !topics.includes(topic)) return json(res, 400, { error: "this relay doesn't serve that app" });
        const fields = { apnsToken, topic, sandbox: typeof body.sandbox === "boolean" ? body.sandbox : sandbox };

        // A phone that pairs again keeps its channel, so the endpoint Instagram has stays good;
        // only what the relay needs to reach the phone is refreshed.
        const known = typeof body.deviceId === "string" && store.getByDeviceId(body.deviceId);
        if (known) {
          store.updateDevice(known.channelID, fields);
          return json(res, 200, { deviceId: known.deviceId, endpoint: known.endpoint });
        }

        if (store.channelIDs().length >= maxDevices) return json(res, 503, { error: "relay is full" });
        const { channelID, endpoint } = await mozilla.registerChannel();
        const deviceId = randomUUID();
        store.addDevice({ deviceId, channelID, endpoint, ...fields, createdAt: new Date().toISOString() });
        logger.info?.(`[pair] device ${deviceId.slice(0, 8)}… -> channel ${channelID.slice(0, 8)}…`);
        // The phone takes `endpoint` and calls Instagram's registerWebPush(endpoint, its p256dh, its auth).
        return json(res, 200, { deviceId, endpoint });
      }

      if (req.method === "POST" && req.url === "/unpair") {
        const body = await readBody(req);
        const device = typeof body?.deviceId === "string" && store.getByDeviceId(body.deviceId);
        if (!device) return json(res, 404, { error: "unknown device" });
        mozilla.unregisterChannel(device.channelID);
        store.removeByChannel(device.channelID);
        logger.info?.(`[unpair] device ${device.deviceId.slice(0, 8)}…`);
        return json(res, 200, { ok: true });
      }

      return json(res, 404, { error: "not found" });
    } catch (e) {
      logger.warn?.("[server] error:", e?.message || e);
      return json(res, 500, { error: "internal" });
    }
  });
}
