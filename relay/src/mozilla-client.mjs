// One WebSocket connection to Mozilla's push service, managing many channels (one per device).
//
// It registers channels restricted to a VAPID key (Instagram's), holds the connection with a
// keepalive ping and auto-reconnect that *resumes the same uaid + channels* (so endpoints survive
// drops and restarts), and routes each incoming push to the right device by channelID.
//
// It NEVER decrypts: it hands the raw ciphertext + headers to onNotification, which forwards them
// to the phone. Only the phone holds the decryption key. See ../../docs/NOTIFICATIONS.md.
import { WebSocket } from "ws";
import { randomUUID } from "node:crypto";

const DEFAULT_URL = "wss://push.services.mozilla.com";
const PING_MS = 60_000;          // keepalive; Mozilla drops idle sockets
const RECONNECT_MS = 2_000;      // first wait before reconnecting; doubles while it keeps failing
const RECONNECT_MAX_MS = 60_000;
const REGISTER_TIMEOUT_MS = 15_000;

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
   */
  constructor({ vapidKey, url = DEFAULT_URL, logger = console, onNotification, getIdentity, saveIdentity, onReset }) {
    this.vapidKey = vapidKey;
    this.url = url;
    this.log = logger;
    this.onNotification = onNotification;
    this.getIdentity = getIdentity;
    this.saveIdentity = saveIdentity;
    this.onReset = onReset;

    this.ws = null;
    this.connected = false;            // true between Mozilla's hello and the socket closing
    this.ready = null;                 // resolves at the next hello
    this._resolveReady = null;
    this.uaid = null;
    this.channelIDs = new Set();
    this.pendingRegisters = new Map(); // channelID -> { resolve, reject, timer }
    this.pingTimer = null;
    this.reconnectTimer = null;
    this.reconnectMs = RECONNECT_MS;
    this.stopped = false;
  }

  /** Loads the saved identity and connects. Resolves once Mozilla has said hello. */
  async start() {
    const id = (await this.getIdentity?.()) || {};
    this.uaid = id.uaid || null;
    for (const c of id.channelIDs || []) this.channelIDs.add(c);
    this._connect();
    await this.ready;
  }

  _connect() {
    // One promise per wait for a hello: a connection that fails before it keeps the same one, so
    // whoever is waiting (start, registerChannel) is still answered by the attempt that succeeds.
    if (!this._resolveReady) this.ready = new Promise((res) => (this._resolveReady = res));
    this.ws = new WebSocket(this.url);
    this.ws.on("open", () => {
      this.log.info?.(`[mozilla] connected; hello ${this.uaid ? "(resume)" : "(new)"} with ${this.channelIDs.size} channel(s)`);
      this._send({ messageType: "hello", use_webpush: true, uaid: this.uaid, channelIDs: [...this.channelIDs] });
      clearInterval(this.pingTimer);
      this.pingTimer = setInterval(() => { try { if (this.ws?.readyState === 1) this.ws.ping(); } catch {} }, PING_MS);
    });
    this.ws.on("message", (raw) => this._onMessage(raw));
    this.ws.on("error", (e) => this.log.warn?.("[mozilla] ws error:", e?.message || e));
    this.ws.on("close", (code) => {
      this.connected = false;
      clearInterval(this.pingTimer);
      // Reject any in-flight registrations so callers don't hang across a reconnect.
      for (const [ch, p] of this.pendingRegisters) { clearTimeout(p.timer); p.reject(new Error("connection closed")); this.pendingRegisters.delete(ch); }
      if (this.stopped) return;
      this.log.info?.(`[mozilla] closed (code ${code}); reconnecting in ${this.reconnectMs}ms`);
      this.reconnectTimer = setTimeout(() => this._connect(), this.reconnectMs);
      this.reconnectMs = Math.min(this.reconnectMs * 2, RECONNECT_MAX_MS);
    });
  }

  _send(obj) { if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(obj)); }

  async _onMessage(raw) {
    let m;
    try { m = JSON.parse(raw.toString()); } catch { return; }
    switch (m.messageType) {
      case "hello": {
        if (m.status !== 200 || !m.uaid) {
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
        this.reconnectMs = RECONNECT_MS;
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
    await this.ready;
    const channelID = randomUUID();
    const endpoint = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pendingRegisters.delete(channelID); reject(new Error("register timeout")); }, REGISTER_TIMEOUT_MS);
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
    clearInterval(this.pingTimer);
    clearTimeout(this.reconnectTimer);
    try { this.ws?.close(); } catch {}
  }
}
