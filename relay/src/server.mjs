// Pairing API. A phone pairs by POSTing its APNs device token; the relay registers a Mozilla
// channel and returns its endpoint. The phone then registers that endpoint with Instagram, using
// the phone's OWN p256dh/auth — so the relay never sees the decryption keys. See docs/NOTIFICATIONS.md.
import http from "node:http";
import { randomUUID, createHash, timingSafeEqual } from "node:crypto";

const MAX_BODY = 4096; // bytes; a pairing request is a few hundred
const PER_MINUTE = 10; // pairing calls from one caller, pairing again and unpairing included
const DAY_MS = 24 * 3600 * 1000;
const UNKNOWN_TO_APPLE = { error: "Apple doesn't know this phone" };

/**
 * @param {object}   o
 * @param {object}   o.store
 * @param {object}   o.mozilla
 * @param {object}   o.apns          Whether the relay sends to Apple, and asking Apple about a token.
 * @param {Function} o.forget        (device, why) => void: closes a device's channel and drops its record.
 * @param {string}  [o.authToken]   If set, /pair and /unpair need `Authorization: Bearer <token>`.
 * @param {string}  [o.operatorToken] If set, GET /health with `Authorization: Bearer <token>` has the counts too.
 * @param {string[]} [o.trustedProxies] The HTTPS proxy's addresses: only their X-Forwarded-For is believed.
 * @param {string[]} [o.topics]     Bundle IDs this relay serves; empty accepts any (dry-run).
 * @param {boolean} [o.sandbox]     Which of Apple's services a phone is on when it doesn't say.
 * @param {number}  [o.maxDevices]  Pairing is refused beyond this many devices.
 * @param {number}  [o.newDevicesPerWeek] New records one caller may make in a week.
 * @param {Function} [o.health]     () => extra fields for GET /health, for whoever runs the relay.
 */
export function createServer({
  store, mozilla, apns, forget, authToken = "", operatorToken = "", trustedProxies = [], topics = [], sandbox = false,
  maxDevices = 1000, newDevicesPerWeek = 5, health = () => ({}), logger = console,
}) {
  const json = (res, code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  const readBody = (req) =>
    new Promise((resolve) => {
      let b = "";
      let size = 0;
      // Past the limit the rest is read and dropped, so the answer can still be sent; far past it,
      // the request is cut off.
      req.on("data", (d) => {
        size += d.length;
        if (size > MAX_BODY * 16) return req.destroy();
        if (size <= MAX_BODY) b += d;
      });
      req.on("end", () => { try { resolve(size > MAX_BODY ? null : JSON.parse(b || "{}")); } catch { resolve(null); } });
      req.on("error", () => resolve(null));
      req.on("close", () => resolve(null));
    });

  // Pairing calls, and new records, per caller. Counted in memory only: no address is written
  // anywhere, and a restart starts the counts over.
  const perMinute = new Budget(PER_MINUTE, 60_000);
  const perWeek = new Budget(newDevicesPerWeek, 7 * DAY_MS);
  const proxies = trustedProxies.map(plain);
  // Who's calling: the address the connection comes from, or for a request from the HTTPS proxy
  // named in TRUSTED_PROXY, the address the proxy says it's passing on. That's the last in
  // X-Forwarded-For, the one the proxy added itself: anyone else could have written anything there.
  const callerOf = (req) => {
    const peer = plain(req.socket.remoteAddress || "");
    const forwarded = proxies.includes(peer) ? String(req.headers["x-forwarded-for"] || "").split(",").pop().trim() : "";
    return caller(plain(forwarded || peer));
  };

  const server = http.createServer(async (req, res) => {
    try {
      // The operator token is for whoever runs the relay and is never in a build, so never the
      // pairing token, which every build carries.
      const operator = operatorToken !== authToken && carries(req, operatorToken);
      const admitted = !authToken || carries(req, authToken);

      // Health is open, but without a token it only says the relay answers. Whether it's up is for
      // the app; the counts and times are for whoever runs the relay.
      if (req.method === "GET" && req.url === "/health") {
        if (operator) return json(res, 200, { ok: true, devices: store.channelIDs().length, mozilla: mozilla.connected, ...health() });
        if (admitted) return json(res, 200, { ok: true, mozilla: mozilla.connected, apns: apns.enabled ? "live" : "dry-run" });
        return json(res, 200, { ok: true });
      }
      // Everything else needs the shared pairing token (if one is set).
      if (!admitted) return json(res, 401, { error: "unauthorized" });

      const from = callerOf(req);
      if (req.method === "POST" && (req.url === "/pair" || req.url === "/unpair") && !perMinute.take(from)) {
        return json(res, 429, { error: "too many pairing calls" });
      }

      if (req.method === "POST" && req.url === "/pair") {
        const body = await readBody(req);
        const apnsToken = typeof body?.apnsToken === "string" ? body.apnsToken.toLowerCase() : "";
        if (!/^[0-9a-f]{64,200}$/.test(apnsToken)) return json(res, 400, { error: "apnsToken must be the device token in hex" });
        const topic = typeof body.topic === "string" && body.topic ? body.topic : topics[0] || "";
        if (topics.length && !topics.includes(topic)) return json(res, 400, { error: "this relay doesn't serve that app" });
        const fields = { apnsToken, topic, sandbox: typeof body.sandbox === "boolean" ? body.sandbox : sandbox };
        const now = () => new Date().toISOString();

        // A phone that pairs again keeps its channel, so the endpoint Instagram has stays good;
        // only what the relay needs to reach the phone is refreshed. Whoever made a record can
        // pair it again at will, so pairing again keeps the record going only for a token Apple
        // doesn't refuse: asked when the token changes, and at most once a day otherwise. A dry
        // run can't ask, and takes the phone's word for it.
        let asked = false;
        const known = typeof body.deviceId === "string" && store.getByDeviceId(body.deviceId);
        if (known) {
          const changed = known.apnsToken !== apnsToken || known.topic !== topic || known.sandbox !== fields.sandbox;
          const due = !(Date.now() - Date.parse(known.lastSeen) < DAY_MS);
          if (apns.enabled && (changed || due)) {
            asked = true;
            if (await apns.refuses(fields)) {
              const current = store.getByDeviceId(known.deviceId);
              if (current) forget(current, "Apple doesn't know its token");
              return json(res, 400, UNKNOWN_TO_APPLE);
            }
          }
          // Unless it was forgotten meanwhile: then it's paired afresh, below.
          const current = store.getByDeviceId(known.deviceId);
          if (current) {
            // One record per token.
            for (const other of store.getByToken(apnsToken, topic)) if (other.channelID !== current.channelID) forget(other, "its token paired again");
            store.updateDevice(current.channelID, asked || !apns.enabled ? { ...fields, lastSeen: now() } : fields);
            return json(res, 200, { deviceId: current.deviceId, endpoint: current.endpoint });
          }
        }

        // A new record, of which a caller makes only so many a week. A pairing that adds none,
        // because it's refused or replaces its token's own record, doesn't count.
        const counted = !store.getByToken(apnsToken, topic).length;
        if (counted && !perWeek.take(from)) return json(res, 429, { error: "too many new pairings" });
        let added = false;
        try {
          // A phone whose token has a record replaces it, so even a full relay takes it.
          if (store.channelIDs().length - store.getByToken(apnsToken, topic).length >= maxDevices) return json(res, 503, { error: "relay is full" });
          // Apple answers a made-up token with BadDeviceToken. A dry run can't ask.
          if (apns.enabled && !asked && (await apns.refuses(fields))) return json(res, 400, UNKNOWN_TO_APPLE);
          const { channelID, endpoint } = await mozilla.registerChannel();

          // Other pairings went on during the waits, the same token's among them, and the phone may
          // have given up. So the place is decided only now, in one step: no record for a phone
          // that has gone; the token's old record goes; and the new one is kept if there's room.
          if (req.socket.destroyed) return mozilla.unregisterChannel(channelID);
          const old = store.getByToken(apnsToken, topic);
          if (store.channelIDs().length - old.length >= maxDevices) {
            mozilla.unregisterChannel(channelID);
            return json(res, 503, { error: "relay is full" });
          }
          for (const device of old) forget(device, "paired afresh");
          const deviceId = randomUUID();
          store.addDevice({ deviceId, channelID, endpoint, ...fields, createdAt: now(), lastSeen: now() });
          added = !old.length;
          logger.info?.(`[pair] device ${deviceId.slice(0, 8)}… -> channel ${channelID.slice(0, 8)}…`);
          // The phone takes `endpoint` and calls Instagram's registerWebPush(endpoint, its p256dh, its auth).
          return json(res, 200, { deviceId, endpoint });
        } finally {
          if (counted && !added) perWeek.giveBack(from);
        }
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
  // One machine answering phones' occasional calls, behind an HTTPS proxy: no more connections,
  // and no longer for a request to arrive, than that needs.
  server.maxConnections = 256;
  server.headersTimeout = 10_000;
  server.requestTimeout = 20_000;
  return server;
}

/**
 * At most `limit` of something per `windowMs` for each caller. Callers whose window has passed
 * are let go as it goes, so the count stays small.
 */
class Budget {
  constructor(limit, windowMs) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.spent = new Map(); // caller -> times, oldest first
    this.sweptAt = Date.now();
  }

  /** Takes one for `caller`: false when its budget is spent. */
  take(caller) {
    const now = Date.now();
    if (now - this.sweptAt >= Math.min(this.windowMs, 60_000)) {
      this.sweptAt = now;
      for (const [key, times] of this.spent) if (!times.length || now - times[times.length - 1] >= this.windowMs) this.spent.delete(key);
    }
    const times = (this.spent.get(caller) || []).filter((at) => now - at < this.windowMs);
    this.spent.set(caller, times);
    if (times.length >= this.limit) return false;
    times.push(now);
    return true;
  }

  /** Gives back the last one `caller` took, for something that didn't happen after all. */
  giveBack(caller) {
    this.spent.get(caller)?.pop();
  }
}

/**
 * The limits' name for an address: an IPv4 address as it is, an IPv6 one by the /56 it's in, since
 * one home, or one phone, is often given a whole block of them.
 */
function caller(address) {
  if (!address.includes(":")) return address;
  const [head = "", tail = ""] = address.toLowerCase().split("%")[0].split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
  // 56 bits: three groups of sixteen, and the first half of the fourth.
  const prefix = groups.slice(0, 4).map((group) => parseInt(group, 16) || 0);
  prefix[3] &= 0xff00;
  return `${prefix.map((group) => group.toString(16)).join(":")}::/56`;
}

/** An address as written: Node gives an IPv4 one in IPv6 form on a socket that takes both. */
function plain(address) {
  return address.replace(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/i, "$1");
}

/** Whether a request carries `Bearer <token>`. An empty token matches nothing. */
function carries(req, token) {
  return Boolean(token) && same(req.headers.authorization || "", `Bearer ${token}`);
}

/** Whether two secrets match, compared in constant time. */
function same(a, b) {
  return timingSafeEqual(createHash("sha256").update(a).digest(), createHash("sha256").update(b).digest());
}
