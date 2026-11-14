// One WebSocket connection to Mozilla's push service, managing many channels (one per device).
//
// It registers channels restricted to a VAPID key (Instagram's), holds the connection with a
// keepalive ping and auto-reconnect that *resumes the same uaid + channels* (so endpoints survive
// drops and restarts), and routes each incoming push to the right device by channelID.
//
// It NEVER decrypts: it hands the raw ciphertext + headers to onNotification, which forwards them
// to the phone. Only the phone holds the decryption key. See ../../docs/NOTIFICATIONS.md.
//
// A connection can die without closing, so nothing here waits on Mozilla for ever: a connection
// that hasn't said hello in time is dropped, so is one that doesn't answer a ping, and a
// registration gives up before the phone waiting for it does.
import { WebSocket } from "ws";
import { randomUUID } from "node:crypto";

const DEFAULT_URL = "wss://push.services.mozilla.com";
const HELLO_TIMEOUT_MS = 30_000;  // from starting a connection to Mozilla's hello
const CHECK_MS = 60_000;          // how often the connection is checked
// How long the connection may be quiet before Mozilla is asked whether it's still there: a `{}`,
// which it answers with a `{}`. A connection that carries nothing for about two minutes is closed
// somewhere along the way, and Mozilla drops a client that pings more than once in 45 seconds.
const QUIET_MS = 50_000;
const RECONNECT_MS = 2_000;       // first wait before reconnecting; doubles while it keeps failing
const RECONNECT_MAX_MS = 60_000;
const STABLE_MS = 60_000;         // a connection that lasted this long was a good one: the waits start over
// How long registering a channel may take, waiting for a connection included: a phone gives up on
// pairing after 15 seconds, and should hear why before then.
const REGISTER_TIMEOUT_MS = 10_000;

export class MozillaClient {
  /**
   * @param {object}   o
   * @param {string}   o.vapidKey        Instagram's VAPID public key (base64url) — restricts channels to it.
   * @param {string}  [o.url]            autopush WebSocket URL.
   * @param {object}  [o.logger]         console-like logger.
   * @param {Function} o.onNotification  (channelID, { data, headers, version }) => void | Promise
   * @param {Function} o.getIdentity     () => { uaid, channelIDs: string[] } — persisted identity to resume.
   * @param {Function} o.saveIdentity    (uaid) => void — called when Mozilla assigns/changes the uaid.
   * @param {Function} [o.onReset]       (lostChannelIDs) => void | Promise — Mozilla answered with a new
   *                                     uaid, so the channels of the old one (and their endpoints) are gone.
   * @param {number}  [o.helloTimeoutMs] The tests' clock: the waits above, in ms.
   * @param {number}  [o.checkMs]
   * @param {number}  [o.quietMs]
   * @param {number}  [o.reconnectMs]
   * @param {number}  [o.registerTimeoutMs]
   */
  constructor({
    vapidKey, url = DEFAULT_URL, logger = console, onNotification, getIdentity, saveIdentity, onReset,
    helloTimeoutMs = HELLO_TIMEOUT_MS, checkMs = CHECK_MS, quietMs = QUIET_MS, reconnectMs = RECONNECT_MS, registerTimeoutMs = REGISTER_TIMEOUT_MS,
  }) {
    this.vapidKey = vapidKey;
    this.url = url;
    this.log = logger;
    this.onNotification = onNotification;
    this.getIdentity = getIdentity;
    this.saveIdentity = saveIdentity;
    this.onReset = onReset;
    this.helloTimeoutMs = helloTimeoutMs;
    this.checkMs = checkMs;
    this.quietMs = quietMs;
    this.firstReconnectMs = reconnectMs;
    this.registerTimeoutMs = registerTimeoutMs;

    this.ws = null;
    this.connected = false;            // true between Mozilla's hello and the socket closing
    this.ready = null;                 // resolves at the next hello
    this._resolveReady = null;
    this.uaid = null;
    this.channelIDs = new Set();
    this.pendingRegisters = new Map(); // channelID -> { resolve, reject, timer }
    this.checkTimer = null;
    this.reconnectTimer = null;
    this.reconnectMs = reconnectMs;
    this.helloAt = 0;
    this.lastHeard = 0;
    this.pingSentAt = 0;
    this.stopped = false;
  }

  /** Loads the saved identity and connects. Resolves once Mozilla has said hello. */
  async start() {
    const id = (await this.getIdentity?.()) || {};
    this.uaid = id.uaid || null;
    for (const c of id.channelIDs || []) this.channelIDs.add(c);
    this.checkTimer = setInterval(() => this._check(), this.checkMs);
    this._connect();
    await this.ready;
  }

  _connect() {
    // One promise per wait for a hello: a connection that fails before it keeps the same one, so
    // whoever is waiting (start, registerChannel) is still answered by the attempt that succeeds.
    if (!this._resolveReady) this.ready = new Promise((res) => (this._resolveReady = res));
    this.reconnectTimer = null;
    const ws = new WebSocket(this.url, { handshakeTimeout: this.helloTimeoutMs });
    this.ws = ws;
    // A connection Mozilla hasn't said hello on in time is given up on, whatever stage it stalled
    // at: terminate() ends in "close", which reconnects after the usual wait.
    const helloTimer = setTimeout(() => {
      if (this.ws !== ws || this.connected) return;
      this.log.warn?.("[mozilla] no hello in time; reconnecting");
      ws.terminate();
    }, this.helloTimeoutMs);
    ws.on("open", () => {
      this.log.info?.(`[mozilla] connected; hello ${this.uaid ? "(resume)" : "(new)"} with ${this.channelIDs.size} channel(s)`);
      this._send({ messageType: "hello", use_webpush: true, uaid: this.uaid, channelIDs: [...this.channelIDs] });
    });
    ws.on("message", (raw) => {
      // Anything Mozilla says shows the connection is alive.
      this.lastHeard = Date.now();
      this.pingSentAt = 0;
      // Whatever goes wrong with one message is that message's problem, not the process's.
      this._onMessage(raw).catch((e) => this.log.warn?.("[mozilla] handling a message failed:", e?.message || e));
    });
    ws.on("error", (e) => this.log.warn?.("[mozilla] ws error:", e?.message || e));
    ws.on("close", (code) => {
      clearTimeout(helloTimer);
      // A connection that held for a minute was a good one, and the waits start over. Not at
      // every hello: a service that answered and then hung up would be tried every two seconds.
      if (this.connected && Date.now() - this.helloAt >= STABLE_MS) this.reconnectMs = this.firstReconnectMs;
      this.connected = false;
      this.pingSentAt = 0;
      // Reject any in-flight registrations so callers don't hang across a reconnect.
      for (const [ch, p] of this.pendingRegisters) { clearTimeout(p.timer); p.reject(new Error("connection closed")); this.pendingRegisters.delete(ch); }
      if (this.stopped) return;
      // Up to a quarter longer, by chance, so that attempts don't keep in step with anything.
      const wait = Math.round(this.reconnectMs * (1 + Math.random() / 4));
      this.log.info?.(`[mozilla] closed (code ${code}); reconnecting in ${wait}ms`);
      this.reconnectTimer = setTimeout(() => this._connect(), wait);
      this.reconnectMs = Math.min(this.reconnectMs * 2, RECONNECT_MAX_MS);
    });
  }

  /**
   * Run every `checkMs`. Sends a quiet connection a `{}`, and drops one that hasn't answered the
   * last: it's dead without having said so. The same check as the Worker relay's, which is known
   * to work against Mozilla's service.
   */
  _check() {
    const ws = this.ws;
    if (!ws || !this.connected) return;
    if (this.pingSentAt && this.lastHeard < this.pingSentAt) {
      this.log.warn?.("[mozilla] no answer to a ping; reconnecting");
      ws.terminate();
      return;
    }
    if (Date.now() - this.lastHeard >= this.quietMs) {
      this.pingSentAt = Date.now();
      this._send({});
    }
  }

  _send(obj) { if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(obj)); }

  async _onMessage(raw) {
    let m;
    try { m = JSON.parse(raw.toString()); } catch { return; }
    switch (m.messageType) {
      case "hello": {
        // Closing it reconnects after the usual wait, which grows while this keeps happening.
        if (m.status !== 200 || typeof m.uaid !== "string" || !m.uaid) {
          this.log.warn?.(`[mozilla] hello refused (status ${m.status})`);
          try { this.ws.close(); } catch {}
          break;
        }
        // A different uaid than the one we resumed with: Mozilla no longer knows the old one,
        // and every channel registered under it, with its endpoint, is gone.
        const lost = this.uaid && m.uaid !== this.uaid ? [...this.channelIDs] : [];
        if (m.uaid !== this.uaid) {
          this.uaid = m.uaid;
          this.channelIDs.clear();
          await this.saveIdentity?.(this.uaid);
        }
        this.connected = true;
        this.helloAt = Date.now();
        this.log.info?.(`[mozilla] hello ok (uaid ${this.uaid.slice(0, 8)}…); ${this.channelIDs.size} channel(s) resumed`);
        this._resolveReady?.();
        this._resolveReady = null;
        if (lost.length) {
          this.log.warn?.(`[mozilla] new uaid: ${lost.length} channel(s) lost`);
          try { await this.onReset?.(lost); } catch (e) { this.log.warn?.("[mozilla] onReset threw:", e?.message || e); }
        }
        break;
      }
      case "register": {
        const p = this.pendingRegisters.get(m.channelID);
        if (!p) break;
        this.pendingRegisters.delete(m.channelID);
        clearTimeout(p.timer);
        if (m.status === 200 && m.pushEndpoint) { this.channelIDs.add(m.channelID); p.resolve(m.pushEndpoint); }
        else p.reject(new Error(`register failed (status ${m.status})`));
        break;
      }
      case "notification":
        if (m.channelID && this.channelIDs.has(m.channelID)) {
          try { await this.onNotification?.(m.channelID, { data: m.data, headers: m.headers, version: m.version }); }
          catch (e) { this.log.warn?.("[mozilla] onNotification threw:", e?.message || e); }
        }
        // Always ack, even unknown channels, so Mozilla stops redelivering.
        this._send({ messageType: "ack", updates: [{ channelID: m.channelID, version: m.version }] });
        break;
    }
  }

  /** Registers a new channel (one device). Resolves to { channelID, endpoint }. */
  async registerChannel() {
    const deadline = Date.now() + this.registerTimeoutMs;
    if (!this.connected) {
      let timer;
      try {
        await Promise.race([
          this.ready,
          new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("not connected to Mozilla")), this.registerTimeoutMs); }),
        ]);
      } finally {
        clearTimeout(timer);
      }
    }
    const channelID = randomUUID();
    const endpoint = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pendingRegisters.delete(channelID); reject(new Error("register timeout")); }, Math.max(0, deadline - Date.now()));
      this.pendingRegisters.set(channelID, { resolve, reject, timer });
      this._send({ messageType: "register", channelID, key: this.vapidKey });
    });
    return { channelID, endpoint };
  }

  /** Drops a channel (one device). */
  unregisterChannel(channelID) {
    this.channelIDs.delete(channelID);
    this._send({ messageType: "unregister", channelID });
  }

  close() {
    this.stopped = true;
    clearInterval(this.checkTimer);
    clearTimeout(this.reconnectTimer);
    try { this.ws?.close(); } catch {}
  }
}
