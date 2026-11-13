// Sends APNs pushes over HTTP/2 with token (.p8) auth, forwarding the web-push ciphertext + headers
// for the phone's Notification Service Extension to decrypt. The relay never decrypts.
//
// If it isn't configured (no .p8 key), it runs in DRY-RUN: it logs what it would send, so the whole
// service can be developed and tested before the Apple Developer Program account exists. With an
// outbox folder set, a dry run also writes each push there as a file `xcrun simctl push` takes.
import http2 from "node:http2";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const JWT_TTL_MS = 50 * 60 * 1000;   // Apple requires refresh between 20 and 60 minutes
const MAX_PAYLOAD = 4096;            // Apple's limit for a push, in bytes
const EXPIRES_S = 3 * 24 * 3600;     // how long Apple keeps a push for a phone that's off
// What the notification says when the phone can't decrypt it (its keys are gone), or when the
// encrypted copy doesn't fit in a push.
const FALLBACK = { body: "New notification on Instagram" };

const HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

/** Apple answered a push with an error. `gone` when the device token will never work again. */
export class ApnsError extends Error {
  constructor(status, reason) {
    super(`APNs ${status}: ${reason}`);
    this.status = status;
    this.reason = reason;
    this.gone = status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic";
  }
}

export class ApnsForwarder {
  /**
   * @param {object}   o
   * @param {string}   o.keyFile   Path to the .p8 key. Empty: dry-run.
   * @param {string}   o.keyId     The key's ID.
   * @param {string}   o.teamId    The Apple team's ID.
   * @param {string[]} o.topics    Bundle IDs this relay serves; the first is the default.
   * @param {boolean} [o.sandbox]  Which of Apple's services a device is on when it didn't say.
   * @param {string}  [o.outbox]   Dry-run only: a folder to write each push to.
   * @param {object}  [o.hosts]    { production, sandbox } addresses, for tests.
   */
  constructor({ keyFile, keyId, teamId, topics = [], sandbox = false, outbox = "", hosts = HOSTS, logger = console }) {
    this.keyId = keyId;
    this.teamId = teamId;
    this.topics = topics;
    this.sandbox = sandbox;
    this.outbox = outbox;
    this.hosts = hosts;
    this.log = logger;
    this.enabled = Boolean(keyFile && keyId && teamId && topics.length);
    this.key = this.enabled ? fs.readFileSync(keyFile, "utf8") : null;
    this._jwt = null;
    this._jwtAt = 0;
    this._clients = new Map(); // host -> http2 session
  }

  _token() {
    const now = Date.now();
    if (this._jwt && now - this._jwtAt < JWT_TTL_MS) return this._jwt;
    const header = b64url(JSON.stringify({ alg: "ES256", kid: this.keyId }));
    const claims = b64url(JSON.stringify({ iss: this.teamId, iat: Math.floor(now / 1000) }));
    const sig = crypto.sign("SHA256", Buffer.from(`${header}.${claims}`), { key: this.key, dsaEncoding: "ieee-p1363" });
    this._jwt = `${header}.${claims}.${sig.toString("base64url")}`;
    this._jwtAt = now;
    return this._jwt;
  }

  _conn(host) {
    const open = this._clients.get(host);
    if (open && !open.closed && !open.destroyed) return open;
    const client = http2.connect(host);
    client.on("error", (e) => this.log.warn?.("[apns] connection error:", e?.message || e));
    client.on("goaway", () => client.close());
    this._clients.set(host, client);
    return client;
  }

  /** The push for one web-push message: the ciphertext for the phone's extension, if it fits. */
  payload(message) {
    const aps = { "mutable-content": 1, alert: FALLBACK, sound: "default" };
    // The Notification Service Extension reads `wp` and decrypts it with the phone's key.
    const full = JSON.stringify({ aps, wp: { data: message.data, headers: message.headers } });
    if (Buffer.byteLength(full) <= MAX_PAYLOAD) return full;
    this.log.warn?.(`[apns] push of ${Buffer.byteLength(full)} bytes doesn't fit; sending without its content`);
    return JSON.stringify({ aps });
  }

  /**
   * Forwards one web-push message { data, headers } to a device { apnsToken, sandbox, topic }.
   * Throws an ApnsError when Apple refuses it.
   */
  async send(device, message) {
    const payload = this.payload(message);
    const topic = device.topic || this.topics[0] || "";

    if (!this.enabled) {
      this.log.info?.(`[apns:dry-run] -> ${device.apnsToken.slice(0, 10)}… (${Buffer.byteLength(payload)} bytes; encoding ${message.headers?.encoding})`);
      if (this.outbox) {
        fs.mkdirSync(this.outbox, { recursive: true });
        const name = `${new Date().toISOString().replace(/[:.]/g, "-")}-${device.apnsToken.slice(0, 8)}.apns`;
        // "Simulator Target Bundle" tells `xcrun simctl push <device> <file>` which app it's for.
        fs.writeFileSync(path.join(this.outbox, name), JSON.stringify({ "Simulator Target Bundle": topic, ...JSON.parse(payload) }, null, 2));
      }
      return { dryRun: true };
    }

    const sandbox = typeof device.sandbox === "boolean" ? device.sandbox : this.sandbox;
    const host = sandbox ? this.hosts.sandbox : this.hosts.production;
    try {
      return await this._post(host, device.apnsToken, topic, payload);
    } catch (e) {
      if (e instanceof ApnsError) throw e;
      // The connection had gone stale: once more on a fresh one.
      this._clients.get(host)?.destroy();
      return await this._post(host, device.apnsToken, topic, payload);
    }
  }

  _post(host, apnsToken, topic, payload) {
    const client = this._conn(host);
    return new Promise((resolve, reject) => {
      const req = client.request({
        ":method": "POST",
        ":path": `/3/device/${apnsToken}`,
        authorization: `bearer ${this._token()}`,
        "apns-topic": topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + EXPIRES_S),
      });
      let status = 0;
      let body = "";
      req.on("response", (h) => (status = h[":status"]));
      req.setEncoding("utf8");
      req.on("data", (d) => (body += d));
      req.on("end", () => {
        if (status === 200) return resolve({ status });
        let reason = "";
        try { reason = JSON.parse(body).reason || ""; } catch {}
        reject(new ApnsError(status, reason));
      });
      req.on("error", reject);
      req.end(payload);
    });
  }

  close() { for (const client of this._clients.values()) { try { client.close(); } catch {} } }
}

function b64url(s) { return Buffer.from(s).toString("base64url"); }
