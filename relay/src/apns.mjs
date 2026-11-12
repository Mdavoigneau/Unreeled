// Sends APNs pushes over HTTP/2 with token (.p8) auth, forwarding the web-push ciphertext + headers
// for the phone's Notification Service Extension to decrypt. The relay never decrypts.
//
// If it isn't configured (no .p8 key), it runs in DRY-RUN: it logs what it would send, so the whole
// service can be developed and tested before the Apple Developer Program account exists.
import http2 from "node:http2";
import crypto from "node:crypto";
import fs from "node:fs";

const JWT_TTL_MS = 50 * 60 * 1000; // Apple requires refresh between 20 and 60 minutes

export class ApnsForwarder {
  constructor({ keyFile, keyId, teamId, topic, production = true, logger = console }) {
    this.keyId = keyId;
    this.teamId = teamId;
    this.topic = topic; // the app's bundle id
    this.log = logger;
    this.host = production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
    this.enabled = Boolean(keyFile && keyId && teamId && topic);
    this.key = this.enabled ? fs.readFileSync(keyFile, "utf8") : null;
    this._jwt = null;
    this._jwtAt = 0;
    this._client = null;
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

  _conn() {
    if (this._client && !this._client.closed && !this._client.destroyed) return this._client;
    this._client = http2.connect(this.host);
    this._client.on("error", (e) => this.log.warn?.("[apns] connection error:", e?.message || e));
    return this._client;
  }

  /** Forwards one web-push message { data, headers } to a device's APNs token. */
  async send(apnsToken, message) {
    const payload = JSON.stringify({
      aps: { "mutable-content": 1, alert: { body: "New notification" }, sound: "default" },
      // The Notification Service Extension reads `wp` and decrypts it with the phone's key:
      wp: { data: message.data, headers: message.headers },
    });

    if (!this.enabled) {
      this.log.info?.(`[apns:dry-run] -> ${apnsToken.slice(0, 10)}… (${payload.length} bytes; encoding ${message.headers?.encoding})`);
      return { dryRun: true };
    }

    const client = this._conn();
    return await new Promise((resolve, reject) => {
      const req = client.request({
        ":method": "POST",
        ":path": `/3/device/${apnsToken}`,
        authorization: `bearer ${this._token()}`,
        "apns-topic": this.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
      });
      let status = 0;
      let body = "";
      req.on("response", (h) => (status = h[":status"]));
      req.setEncoding("utf8");
      req.on("data", (d) => (body += d));
      req.on("end", () => (status === 200 ? resolve({ status }) : reject(new Error(`APNs ${status}: ${body}`))));
      req.on("error", reject);
      req.end(payload);
    });
  }

  close() { try { this._client?.close(); } catch {} }
}

function b64url(s) { return Buffer.from(s).toString("base64url"); }
