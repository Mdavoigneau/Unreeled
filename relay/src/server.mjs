// Pairing API. A phone pairs by POSTing its APNs device token; the relay registers a Mozilla
// channel and returns its endpoint. The phone then registers that endpoint with Instagram, using
// the phone's OWN p256dh/auth — so the relay never sees the decryption keys. See docs/NOTIFICATIONS.md.
import http from "node:http";
import { randomUUID } from "node:crypto";

export function createServer({ store, mozilla, authToken = "", logger = console }) {
  const json = (res, code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  const readBody = (req) =>
    new Promise((resolve) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => { try { resolve(JSON.parse(b || "{}")); } catch { resolve(null); } }); });

  return http.createServer(async (req, res) => {
    try {
      // Health is open; everything else needs the shared pairing token (if one is set).
      if (req.method === "GET" && req.url === "/health") {
        return json(res, 200, { ok: true, devices: store.channelIDs().length, mozilla: Boolean(store.getUaid()) });
      }
      if (authToken && req.headers.authorization !== `Bearer ${authToken}`) {
        return json(res, 401, { error: "unauthorized" });
      }

      if (req.method === "POST" && req.url === "/pair") {
        const body = await readBody(req);
        if (!body?.apnsToken) return json(res, 400, { error: "apnsToken required" });
        const { channelID, endpoint } = await mozilla.registerChannel();
        const deviceId = randomUUID();
        store.addDevice({ deviceId, channelID, endpoint, apnsToken: body.apnsToken, createdAt: new Date().toISOString() });
        logger.info?.(`[pair] device ${deviceId.slice(0, 8)}… -> channel ${channelID.slice(0, 8)}…`);
        // The phone takes `endpoint` and calls Instagram's registerWebPush(endpoint, its p256dh, its auth).
        return json(res, 200, { deviceId, endpoint });
      }

      if (req.method === "POST" && req.url === "/unpair") {
        const body = await readBody(req);
        const device = body?.deviceId && store.getByDeviceId(body.deviceId);
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
