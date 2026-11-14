// The relay against stand-ins for Mozilla's push service and Apple's, on this machine only.
// Run with `npm test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http2 from "node:http2";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";
import { createRelay } from "../src/relay.mjs";

const quiet = { info() {}, warn() {} };
const TOKEN = "a".repeat(64);
const OPERATOR = "operator-token";
const operator = { authorization: `Bearer ${OPERATOR}` };
const REFUSED = { status: 400, body: { error: "Apple doesn't know this phone" } };
const DAY_MS = 24 * 3600 * 1000;
const daysAgo = (days) => new Date(Date.now() - days * DAY_MS).toISOString();
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(check, what, tries = 100) {
  for (let i = 0; i < tries; i += 1) { if (check()) return; await wait(20); }
  assert.fail(`timed out waiting for ${what}`);
}

/** Mozilla's push service, as far as the relay uses it. */
async function fakeMozilla() {
  const wss = new WebSocketServer({ port: 0 });
  await new Promise((r) => wss.on("listening", r));
  const m = {
    url: `ws://127.0.0.1:${wss.address().port}`,
    uaid: "uaid-1",
    /** How a hello is answered: 200 takes it, another status refuses it, null leaves it unanswered. */
    helloStatus: 200,
    /** Hangs up right after taking a hello. */
    closesAfterHello: false,
    answersPings: true,
    /** How long a registration waits for its answer, in ms. */
    registerDelay: 0,
    hellos: [], helloTimes: [], registered: [], unregistered: [], acks: [], pings: 0,
    socket: null,
    /** Delivers a push on a channel, as Mozilla does when a sender posts to its endpoint. */
    push(channelID, data = "Y2lwaGVydGV4dA", headers = { encoding: "aesgcm", encryption: "salt=abc", crypto_key: "dh=def" }) {
      m.socket.send(JSON.stringify({ messageType: "notification", channelID, version: `v${Date.now()}`, data, headers }));
    },
    close: () => new Promise((r) => { for (const c of wss.clients) c.terminate(); wss.close(r); }),
  };
  wss.on("connection", (socket) => {
    m.socket = socket;
    socket.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.messageType === "hello") {
        m.hellos.push(msg);
        m.helloTimes.push(Date.now());
        if (m.helloStatus === null) return;
        socket.send(JSON.stringify({ messageType: "hello", status: m.helloStatus, uaid: m.uaid, use_webpush: true }));
        if (m.closesAfterHello) socket.close();
      } else if (msg.messageType === "register") {
        m.registered.push(msg);
        const answer = JSON.stringify({ messageType: "register", status: 200, channelID: msg.channelID, pushEndpoint: `https://push.test/wpush/${msg.channelID}` });
        setTimeout(() => socket.send(answer), m.registerDelay);
      } else if (msg.messageType === "unregister") {
        m.unregistered.push(msg.channelID);
      } else if (msg.messageType === "ack") {
        m.acks.push(...msg.updates);
      } else if (msg.messageType === undefined) {
        // `{}`: the relay asking whether the connection is still there.
        m.pings += 1;
        if (m.answersPings) socket.send("{}");
      }
    });
  });
  return m;
}

/**
 * Apple's push service: records what it's sent, and answers as `respond` says, or not at all
 * while `silent`. The relay's questions about a token (background pushes) are kept apart, in
 * `checks`, from the pushes that show.
 */
async function fakeApple() {
  const a = { requests: [], checks: [], silent: false, respond: () => ({ status: 200 }) };
  const server = http2.createServer();
  const sessions = new Set();
  server.on("session", (session) => { sessions.add(session); session.on("close", () => sessions.delete(session)); });
  server.on("stream", (stream, headers) => {
    let body = "";
    stream.setEncoding("utf8");
    stream.on("data", (d) => (body += d));
    stream.on("end", () => {
      const request = {
        path: headers[":path"], topic: headers["apns-topic"], type: headers["apns-push-type"], priority: headers["apns-priority"],
        expiration: headers["apns-expiration"], authorization: headers.authorization, body: JSON.parse(body),
      };
      (request.type === "background" ? a.checks : a.requests).push(request);
      if (a.silent) return;
      const { status, reason } = a.respond(request);
      stream.respond({ ":status": status });
      stream.end(reason ? JSON.stringify({ reason }) : "");
    });
  });
  await new Promise((r) => server.listen(0, r));
  a.host = `http://127.0.0.1:${server.address().port}`;
  a.close = () => new Promise((r) => { for (const s of sessions) s.destroy(); server.close(r); });
  return a;
}

/**
 * A relay wired to the stand-ins, with a real (throwaway) signing key unless `dryRun`, and the
 * operator token. `data` is what the data file holds before it starts; `mozilla` and `answerMs`
 * set the clocks.
 */
async function setup(t, {
  dryRun = false, pairingToken = "", operatorToken = OPERATOR, maxDevices = 1000, newDevicesPerWeek, trustedProxies, host,
  data, mozilla: timings = {}, answerMs,
} = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-test-"));
  const mozilla = await fakeMozilla();
  const apple = await fakeApple();
  const keyFile = path.join(dir, "key.p8");
  const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
  fs.writeFileSync(keyFile, privateKey.export({ type: "pkcs8", format: "pem" }));
  const config = {
    dataFile: path.join(dir, "relay.json"),
    vapidKey: "test-vapid-key",
    autopushUrl: mozilla.url,
    pairingToken,
    operatorToken,
    trustedProxies,
    maxDevices,
    newDevicesPerWeek,
    mozilla: timings,
    apns: {
      keyFile: dryRun ? "" : keyFile, keyId: "KEYID12345", teamId: "TEAMID1234",
      topics: ["app.unreeled", "app.unreeled.dev"], sandbox: false, answerMs,
      outbox: path.join(dir, "outbox"), hosts: { production: apple.host, sandbox: apple.host },
    },
  };
  if (data) fs.writeFileSync(config.dataFile, JSON.stringify(data));
  const relay = createRelay(config, quiet);
  await relay.start(0, host);
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const call = async (method, route, body, headers = {}) => {
    const response = await fetch(`${base}/${route}`, { method, headers: { "content-type": "application/json", ...headers }, body: body && JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const post = (route, body, headers) => call("POST", route, body, headers);
  /** Everything /health tells whoever runs the relay. */
  const health = async () => (await call("GET", "health", undefined, operator)).body;
  t.after(async () => {
    relay.close();
    await mozilla.close();
    await apple.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return { relay, mozilla, apple, post, call, health, base, dir, config };
}

test("pairing registers a channel for Instagram's key and stores no keys", async (t) => {
  const { mozilla, post, health, config } = await setup(t);
  const { status, body } = await post("pair", { apnsToken: TOKEN, sandbox: true, topic: "app.unreeled.dev" });
  assert.equal(status, 200);
  assert.match(body.deviceId, /^[0-9a-f-]{36}$/);
  assert.equal(mozilla.registered.length, 1);
  assert.equal(mozilla.registered[0].key, "test-vapid-key");
  assert.equal(body.endpoint, `https://push.test/wpush/${mozilla.registered[0].channelID}`);

  const saved = JSON.parse(fs.readFileSync(config.dataFile, "utf8"));
  assert.equal(saved.uaid, "uaid-1");
  const [device] = Object.values(saved.devices);
  assert.deepEqual(Object.keys(device).sort(), ["apnsToken", "channelID", "createdAt", "deviceId", "endpoint", "lastSeen", "sandbox", "topic"]);
  assert.equal(device.sandbox, true);
  assert.equal(device.topic, "app.unreeled.dev");

  const state = await health();
  assert.equal(state.devices, 1);
  assert.equal(state.mozilla, true);
  assert.equal(state.apns, "live");
});

test("a push is forwarded to Apple still encrypted, then acknowledged", async (t) => {
  const { mozilla, apple, post, health } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  const { channelID } = mozilla.registered[0];
  mozilla.push(channelID, "ZW5jcnlwdGVk", { encoding: "aesgcm", encryption: "salt=s", crypto_key: "dh=k;p256ecdsa=v" });
  await until(() => mozilla.acks.length === 1, "the ack");

  assert.equal(apple.requests.length, 1);
  const [request] = apple.requests;
  assert.equal(request.path, `/3/device/${TOKEN}`);
  assert.equal(request.topic, "app.unreeled"); // the first topic, when the phone names none
  assert.equal(request.type, "alert");
  assert.match(request.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.equal(request.body.aps["mutable-content"], 1);
  assert.deepEqual(request.body.wp, { data: "ZW5jcnlwdGVk", headers: { encoding: "aesgcm", encryption: "salt=s", crypto_key: "dh=k;p256ecdsa=v" } });
  assert.equal(mozilla.acks[0].channelID, channelID);

  const state = await health();
  assert.equal(state.forwarded, 1);
  assert.equal(state.failed, 0);
});

test("pairing again keeps the endpoint and refreshes the phone's address", async (t) => {
  const { relay, mozilla, post } = await setup(t);
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  const again = (await post("pair", { apnsToken: "b".repeat(64), sandbox: true, deviceId: first.deviceId })).body;
  assert.deepEqual(again, first);
  assert.equal(mozilla.registered.length, 1);
  const device = relay.store.getByDeviceId(first.deviceId);
  assert.equal(device.apnsToken, "b".repeat(64));
  assert.equal(device.sandbox, true);

  // A device the relay doesn't know is paired afresh.
  const unknown = (await post("pair", { apnsToken: TOKEN, deviceId: "not-a-device" })).body;
  assert.notEqual(unknown.deviceId, first.deviceId);
  assert.notEqual(unknown.endpoint, first.endpoint);
  assert.equal(mozilla.registered.length, 2);
});

test("unpairing drops the channel", async (t) => {
  const { mozilla, post, health } = await setup(t);
  const { deviceId } = (await post("pair", { apnsToken: TOKEN })).body;
  assert.equal((await post("unpair", { deviceId })).status, 200);
  await until(() => mozilla.unregistered.length === 1, "the unregister");
  assert.equal(mozilla.unregistered[0], mozilla.registered[0].channelID);
  assert.equal((await health()).devices, 0);
  assert.equal((await post("unpair", { deviceId })).status, 404);
});

test("a phone Apple no longer knows is forgotten", async (t) => {
  const { mozilla, apple, post, health } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  apple.respond = () => ({ status: 410, reason: "Unregistered" });
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.unregistered.length === 1, "the unregister");
  const state = await health();
  assert.equal(state.devices, 0);
  assert.equal(state.failed, 1);
});

test("a passing failure at Apple keeps the phone", async (t) => {
  const { mozilla, apple, post, health } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  apple.respond = () => ({ status: 503, reason: "ServiceUnavailable" });
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  assert.equal((await health()).devices, 1);
});

test("bad pairing requests are refused", async (t) => {
  const { post, base, health } = await setup(t, { pairingToken: "secret", maxDevices: 1 });
  const auth = { authorization: "Bearer secret" };
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 401);
  assert.equal((await post("pair", { apnsToken: TOKEN }, { authorization: "Bearer wrong" })).status, 401);
  assert.equal((await post("pair", { apnsToken: TOKEN }, operator)).status, 401); // the operator's token is no pairing token
  assert.equal((await post("pair", { apnsToken: "not hex" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, topic: "com.someone.else" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, padding: "x".repeat(5000) }, auth)).status, 400);
  // Far too long, and the request is cut off rather than read to the end.
  const huge = fetch(`${base}/pair`, { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ padding: "x".repeat(1 << 20) }) });
  await assert.rejects(huge);
  assert.equal((await post("pair", { apnsToken: TOKEN }, auth)).status, 200);
  assert.equal((await post("pair", { apnsToken: "c".repeat(64) }, auth)).status, 503); // full
  assert.equal((await health()).devices, 1);
});

test("a push too large for Apple goes without its content", async (t) => {
  const { mozilla, apple, post } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  mozilla.push(mozilla.registered[0].channelID, "A".repeat(5000));
  await until(() => apple.requests.length === 1, "the push");
  assert.equal(apple.requests[0].body.wp, undefined);
  assert.equal(apple.requests[0].body.aps.alert.body, "New notification on Instagram");
});

test("a dropped connection resumes the same identity and channels", async (t) => {
  const { mozilla, apple, post } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  const { channelID } = mozilla.registered[0];
  mozilla.socket.terminate();
  await until(() => mozilla.hellos.length === 2, "the second hello", 200);
  assert.equal(mozilla.hellos[1].uaid, "uaid-1");
  assert.deepEqual(mozilla.hellos[1].channelIDs, [channelID]);
  assert.equal(mozilla.registered.length, 1);
  mozilla.push(channelID);
  await until(() => apple.requests.length === 1, "the push after reconnecting");
});

test("when Mozilla forgets the identity, each device gets a new endpoint", async (t) => {
  const { relay, mozilla, apple, post } = await setup(t);
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  mozilla.uaid = "uaid-2";
  mozilla.socket.terminate();
  await until(() => mozilla.registered.length === 2, "the new channel", 200);
  await until(() => relay.store.getByDeviceId(first.deviceId)?.channelID === mozilla.registered[1].channelID, "the device's move");
  assert.equal(relay.store.getUaid(), "uaid-2");

  // The phone learns the new endpoint when it pairs again, and pushes on it reach the phone.
  const again = (await post("pair", { apnsToken: TOKEN, deviceId: first.deviceId })).body;
  assert.equal(again.deviceId, first.deviceId);
  assert.equal(again.endpoint, `https://push.test/wpush/${mozilla.registered[1].channelID}`);
  mozilla.push(mozilla.registered[1].channelID);
  await until(() => apple.requests.length === 1, "the push on the new channel");
});

test("without an Apple key, a dry run writes each push to the outbox", async (t) => {
  const { mozilla, apple, post, health, config } = await setup(t, { dryRun: true });
  await post("pair", { apnsToken: TOKEN, topic: "app.unreeled.dev" });
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  assert.equal(apple.requests.length, 0);
  assert.equal(apple.checks.length, 0); // nor is Apple asked about the phone
  assert.equal((await health()).apns, "dry-run");
  const files = fs.readdirSync(config.apns.outbox);
  assert.equal(files.length, 1);
  const written = JSON.parse(fs.readFileSync(path.join(config.apns.outbox, files[0]), "utf8"));
  assert.equal(written["Simulator Target Bundle"], "app.unreeled.dev");
  assert.equal(written.wp.headers.encoding, "aesgcm");
});

test("health says that the relay answers to anyone, whether it's up to the app, and the counts to whoever runs it", async (t) => {
  const { call } = await setup(t, { pairingToken: "secret" });
  assert.deepEqual((await call("GET", "health")).body, { ok: true });
  assert.deepEqual((await call("GET", "health", undefined, { authorization: "Bearer wrong" })).body, { ok: true });
  assert.deepEqual((await call("GET", "health", undefined, { authorization: "Bearer secret" })).body, { ok: true, mozilla: true, apns: "live" });
  const full = (await call("GET", "health", undefined, operator)).body;
  assert.deepEqual(Object.keys(full).sort(), ["apns", "devices", "failed", "forwarded", "lastPushAt", "mozilla", "ok"]);
});

test("an operator token that is the pairing token shows no counts", async (t) => {
  const { call } = await setup(t, { pairingToken: "same", operatorToken: "same" });
  assert.deepEqual((await call("GET", "health", undefined, { authorization: "Bearer same" })).body, { ok: true, mozilla: true, apns: "live" });
});

test("a phone's token is checked with Apple before it takes a place", async (t) => {
  const { mozilla, apple, post, health } = await setup(t);
  assert.equal((await post("pair", { apnsToken: TOKEN, sandbox: true, topic: "app.unreeled.dev" })).status, 200);
  assert.equal(apple.checks.length, 1);
  const [check] = apple.checks;
  assert.equal(check.path, `/3/device/${TOKEN}`);
  assert.equal(check.topic, "app.unreeled.dev");
  assert.equal(check.priority, "5");
  assert.equal(check.expiration, "0");
  assert.deepEqual(check.body, { aps: { "content-available": 1 } });
  assert.match(check.authorization, /^bearer /);
  assert.equal(apple.requests.length, 0); // nothing that shows

  // A token Apple says it will never deliver to takes no place, and no channel.
  for (const [status, reason] of [[400, "BadDeviceToken"], [410, "Unregistered"], [400, "DeviceTokenNotForTopic"]]) {
    apple.respond = () => ({ status, reason });
    assert.deepEqual(await post("pair", { apnsToken: "c".repeat(64) }), REFUSED);
  }
  assert.equal(mozilla.registered.length, 1);
  assert.equal((await health()).devices, 1);

  // Any other answer isn't held against the phone.
  apple.respond = () => ({ status: 503, reason: "ServiceUnavailable" });
  assert.equal((await post("pair", { apnsToken: "d".repeat(64) })).status, 200);
  assert.equal((await health()).devices, 2);
});

test("pairing again asks Apple once a day or about a new token, and forgets a phone Apple doesn't know", async (t) => {
  const { relay, mozilla, apple, post, health } = await setup(t);
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  const seen = () => relay.store.getByDeviceId(first.deviceId).lastSeen;
  const paired = seen();
  assert.equal(apple.checks.length, 1);
  // The same token again within a day: nothing to ask, and nothing renewed.
  assert.deepEqual((await post("pair", { apnsToken: TOKEN, deviceId: first.deviceId })).body, first);
  assert.equal(apple.checks.length, 1);
  assert.equal(seen(), paired);
  // A day on, Apple is asked again, and its yes renews the record.
  relay.store.updateDevice(relay.store.getByDeviceId(first.deviceId).channelID, { lastSeen: daysAgo(2) });
  assert.deepEqual((await post("pair", { apnsToken: TOKEN, deviceId: first.deviceId })).body, first);
  assert.equal(apple.checks.length, 2);
  assert.ok(Date.now() - Date.parse(seen()) < 60_000);
  // A new token is asked about before the record changes.
  apple.respond = () => ({ status: 400, reason: "BadDeviceToken" });
  assert.deepEqual(await post("pair", { apnsToken: "b".repeat(64), deviceId: first.deviceId }), REFUSED);
  assert.equal(apple.checks[2].path, `/3/device/${"b".repeat(64)}`);
  await until(() => mozilla.unregistered.length === 1, "the unregister");
  assert.equal((await health()).devices, 0);
});

test("in a dry run, pairing again renews a phone's record, and pushes don't", async (t) => {
  const { relay, mozilla, post } = await setup(t, { dryRun: true });
  const { deviceId } = (await post("pair", { apnsToken: TOKEN })).body;
  const { channelID } = mozilla.registered[0];
  relay.store.updateDevice(channelID, { lastSeen: daysAgo(2) });
  mozilla.push(channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  assert.ok(Date.now() - Date.parse(relay.store.getByChannel(channelID).lastSeen) > DAY_MS);
  await post("pair", { apnsToken: TOKEN, deviceId });
  assert.ok(Date.now() - Date.parse(relay.store.getByChannel(channelID).lastSeen) < 60_000);
});

test("a push Apple takes renews the phone's record", async (t) => {
  const { relay, mozilla, post } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  const { channelID } = mozilla.registered[0];
  relay.store.updateDevice(channelID, { lastSeen: daysAgo(2) });
  mozilla.push(channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  assert.ok(Date.now() - Date.parse(relay.store.getByChannel(channelID).lastSeen) < 60_000);
});

test("a phone nothing has shown to be real for DEVICE_TTL_DAYS is forgotten", async (t) => {
  const { relay, mozilla, post } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  await post("pair", { apnsToken: "b".repeat(64) });
  const [{ channelID: old }, { channelID: recent }] = mozilla.registered;
  relay.store.updateDevice(old, { lastSeen: daysAgo(31) });
  relay.store.updateDevice(recent, { lastSeen: daysAgo(29) });
  relay.sweep();
  await until(() => mozilla.unregistered.length === 1, "the unregister");
  assert.equal(mozilla.unregistered[0], old);
  assert.deepEqual(relay.store.channelIDs(), [recent]);
});

test("records from before there was a last-seen time are kept, from the time of the change", async (t) => {
  const record = { deviceId: "d".repeat(8), channelID: "old-channel", endpoint: "https://push.test/wpush/old-channel", apnsToken: TOKEN, sandbox: false, topic: "app.unreeled", createdAt: daysAgo(400) };
  const started = new Date().toISOString();
  const { relay, mozilla, config } = await setup(t, { data: { uaid: "uaid-1", devices: { "old-channel": record } } });
  assert.deepEqual(mozilla.hellos[0].channelIDs, ["old-channel"]);
  const { lastSeen } = JSON.parse(fs.readFileSync(config.dataFile, "utf8")).devices["old-channel"];
  assert.ok(lastSeen >= started, `lastSeen ${lastSeen}`);
  relay.sweep();
  assert.deepEqual(relay.store.channelIDs(), ["old-channel"]);
});

test("a token has one record: pairing afresh replaces it, even when pairings overlap", async (t) => {
  const { mozilla, post, health } = await setup(t, { maxDevices: 2 });
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  const second = (await post("pair", { apnsToken: TOKEN })).body;
  assert.notEqual(second.deviceId, first.deviceId);
  assert.notEqual(second.endpoint, first.endpoint);
  await until(() => mozilla.unregistered.length === 1, "the old record's unregister");
  assert.equal(mozilla.unregistered[0], mozilla.registered[0].channelID);
  assert.equal((await health()).devices, 1);

  // Two pairings of one token at once end with one record, whichever comes last. Mozilla's slow
  // answer has both waiting for their channels together.
  mozilla.registerDelay = 200;
  const both = await Promise.all([post("pair", { apnsToken: "b".repeat(64) }), post("pair", { apnsToken: "b".repeat(64) })]);
  assert.deepEqual(both.map((answer) => answer.status), [200, 200]);
  assert.equal((await health()).devices, 2);
  await until(() => mozilla.unregistered.length === 2, "the overlapping pairing's unregister");

  // The relay is full: another phone is refused, but a phone with a record still pairs afresh.
  assert.equal((await post("pair", { apnsToken: "c".repeat(64) })).status, 503);
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 200);
  assert.equal((await health()).devices, 2);
});

test("a pairing the phone gave up on leaves nothing behind", async (t) => {
  const { mozilla, base, health } = await setup(t);
  mozilla.registerDelay = 300;
  const giveUp = new AbortController();
  const pairing = fetch(`${base}/pair`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ apnsToken: TOKEN }), signal: giveUp.signal });
  await until(() => mozilla.registered.length === 1, "the registration");
  giveUp.abort();
  await assert.rejects(pairing);
  await until(() => mozilla.unregistered.length === 1, "the unregister");
  assert.equal(mozilla.unregistered[0], mozilla.registered[0].channelID);
  assert.equal((await health()).devices, 0);
});

test("pairing calls are limited per caller, and new records per caller and week", async (t) => {
  const { post } = await setup(t, { newDevicesPerWeek: 2 });
  const a = (await post("pair", { apnsToken: TOKEN })).body;
  assert.equal((await post("pair", { apnsToken: "b".repeat(64) })).status, 200);
  assert.deepEqual(await post("pair", { apnsToken: "c".repeat(64) }), { status: 429, body: { error: "too many new pairings" } });
  // Pairing again, or afresh with a token that has a record, adds none.
  assert.equal((await post("pair", { apnsToken: TOKEN, deviceId: a.deviceId })).status, 200);
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 200);
  // Ten calls a minute in all, pairing or not.
  for (let i = 0; i < 5; i += 1) assert.equal((await post("pair", {})).status, 400);
  assert.equal((await post("pair", {})).status, 429);
  assert.equal((await post("unpair", { deviceId: a.deviceId })).status, 429);
});

test("only the named proxy is believed about who's calling, and IPv6 callers are counted by /56", async (t) => {
  const { relay, post } = await setup(t, { host: "127.0.0.1", trustedProxies: ["127.0.0.1"] });
  assert.equal(relay.server.address().address, "127.0.0.1");
  // The proxy's own entry is the last; one the caller wrote before it changes nothing.
  const from = (address) => ({ "x-forwarded-for": `2001:db8:1:100::1, ${address}` });
  for (let i = 0; i < 10; i += 1) assert.equal((await post("pair", {}, from("2001:db8:1:2::1"))).status, 400);
  assert.equal((await post("pair", {}, from("2001:db8:1:3::9"))).status, 429); // the same /56
  assert.equal((await post("pair", {}, from("2001:db8:1:100::1"))).status, 400); // another /56
  assert.equal((await post("pair", {}, from("192.0.2.1"))).status, 400);
});

test("without a named proxy, X-Forwarded-For is ignored", async (t) => {
  const { post } = await setup(t);
  for (let i = 0; i < 10; i += 1) assert.equal((await post("pair", {}, { "x-forwarded-for": `192.0.2.${i}` })).status, 400);
  assert.equal((await post("pair", {}, { "x-forwarded-for": "198.51.100.1" })).status, 429);
});

test("a quiet connection is asked whether it's still there, and replaced when it isn't", async (t) => {
  const { mozilla } = await setup(t, { mozilla: { checkMs: 100, quietMs: 50, reconnectMs: 100 } });
  await until(() => mozilla.pings >= 2, "two pings");
  assert.equal(mozilla.hellos.length, 1); // answered, so the connection stays
  mozilla.answersPings = false;
  await until(() => mozilla.hellos.length === 2, "a new connection");
});

test("a connection that doesn't say hello in time is replaced", async (t) => {
  const { relay, mozilla } = await setup(t, { mozilla: { helloTimeoutMs: 300, reconnectMs: 100 } });
  mozilla.helloStatus = null;
  mozilla.socket.terminate();
  await until(() => mozilla.hellos.length === 3, "a connection after the one that got no hello", 150);
  assert.equal(relay.mozilla.connected, false);
  mozilla.helloStatus = 200;
  await until(() => relay.mozilla.connected, "the connection", 150);
});

test("a refused hello, or one without an identity, is tried again after a growing wait", async (t) => {
  const { relay, mozilla } = await setup(t, { mozilla: { reconnectMs: 100 } });
  mozilla.helloStatus = 503;
  mozilla.socket.terminate();
  await until(() => mozilla.hellos.length === 4, "three refused hellos", 150);
  const [, first, second, third] = mozilla.helloTimes;
  assert.ok(second - first >= 200 && third - second >= 400, `refused hellos ${second - first}ms, then ${third - second}ms apart`);
  // An answer of 200 whose identity isn't a string is no better, and mustn't end the process.
  mozilla.helloStatus = 200;
  mozilla.uaid = 12345;
  await until(() => mozilla.hellos.length === 5, "the hello without an identity", 150);
  assert.equal(relay.mozilla.connected, false);
  mozilla.uaid = "uaid-1";
  await until(() => relay.mozilla.connected, "the connection", 150);
});

test("a service that takes each hello and hangs up is tried less and less often", async (t) => {
  const { mozilla } = await setup(t, { mozilla: { reconnectMs: 100 } });
  mozilla.closesAfterHello = true;
  mozilla.socket.terminate();
  await until(() => mozilla.hellos.length === 4, "three more hellos", 150);
  const [, first, second, third] = mozilla.helloTimes;
  assert.ok(second - first >= 200 && third - second >= 400, `hellos ${second - first}ms, then ${third - second}ms apart`);
});

test("a pairing doesn't wait longer for Mozilla than a phone does", async (t) => {
  const { mozilla, post, health } = await setup(t, { mozilla: { reconnectMs: 100, registerTimeoutMs: 300 } });
  mozilla.helloStatus = null;
  mozilla.socket.terminate();
  await until(() => mozilla.hellos.length === 2, "the connection that gets no hello");
  const started = Date.now();
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 500);
  assert.ok(Date.now() - started < 1000);
  assert.equal(mozilla.registered.length, 0);
  assert.equal((await health()).devices, 0);
});

test("Apple not answering in time fails a push, which is still acknowledged", async (t) => {
  const { mozilla, apple, post, health } = await setup(t, { answerMs: 200 });
  await post("pair", { apnsToken: TOKEN });
  apple.silent = true;
  // No answer about a token isn't held against the phone.
  const started = Date.now();
  assert.equal((await post("pair", { apnsToken: "b".repeat(64) })).status, 200);
  assert.ok(Date.now() - started < 1000);
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  assert.equal(apple.requests.length, 2); // once more, on a fresh connection
  const state = await health();
  assert.equal(state.forwarded, 0);
  assert.equal(state.failed, 1);
  assert.equal(state.devices, 2);
  // Apple answering again is reached on a new connection.
  apple.silent = false;
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.acks.length === 2, "the second ack");
  assert.equal((await health()).forwarded, 1);
});

test("with Apple's key, the relay won't start without a pairing token", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-test-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const mozilla = await fakeMozilla();
  t.after(() => mozilla.close());
  const entry = fileURLToPath(new URL("../src/index.mjs", import.meta.url));
  const env = { PATH: process.env.PATH, APNS_KEY_FILE: path.join(dir, "key.p8"), AUTOPUSH_URL: mozilla.url, DATA_FILE: path.join(dir, "relay.json"), PORT: "0" };
  const child = spawn(process.execPath, [entry], { env, stdio: ["ignore", "ignore", "pipe"] });
  let errors = "";
  child.stderr.on("data", (d) => (errors += d));
  const code = await new Promise((resolve) => {
    const timer = setTimeout(() => { child.kill(); resolve("still running"); }, 5000);
    child.on("exit", (c) => { clearTimeout(timer); resolve(c); });
  });
  assert.equal(code, 1);
  assert.match(errors, /PAIRING_TOKEN/);
  assert.equal(mozilla.hellos.length, 0);
});

test("when two phones pair at once for the last place, one gets it and the other's channel is closed", async (t) => {
  const { mozilla, post, health } = await setup(t, { maxDevices: 1 });
  mozilla.registerDelay = 200;
  const answers = await Promise.all([post("pair", { apnsToken: TOKEN }), post("pair", { apnsToken: "b".repeat(64) })]);
  assert.deepEqual(answers.map((answer) => answer.status).sort(), [200, 503]);
  await until(() => mozilla.unregistered.length === 1, "the other channel's unregister");
  assert.equal(mozilla.registered.length, 2);
  assert.equal((await health()).devices, 1);
});
