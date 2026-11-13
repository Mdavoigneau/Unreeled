// The relay against stand-ins for Mozilla's push service and Apple's, on this machine only.
// Run with `npm test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http2 from "node:http2";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";
import { createRelay } from "../src/relay.mjs";

const quiet = { info() {}, warn() {} };
const TOKEN = "a".repeat(64);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(check, what) {
  for (let i = 0; i < 100; i += 1) { if (check()) return; await wait(20); }
  assert.fail(`timed out waiting for ${what}`);
}

/** Mozilla's push service, as far as the relay uses it. */
async function fakeMozilla() {
  const wss = new WebSocketServer({ port: 0 });
  await new Promise((r) => wss.on("listening", r));
  const m = {
    url: `ws://127.0.0.1:${wss.address().port}`,
    uaid: "uaid-1",
    hellos: [], registered: [], unregistered: [], acks: [],
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
        socket.send(JSON.stringify({ messageType: "hello", status: 200, uaid: m.uaid, use_webpush: true }));
      } else if (msg.messageType === "register") {
        m.registered.push(msg);
        socket.send(JSON.stringify({ messageType: "register", status: 200, channelID: msg.channelID, pushEndpoint: `https://push.test/wpush/${msg.channelID}` }));
      } else if (msg.messageType === "unregister") {
        m.unregistered.push(msg.channelID);
      } else if (msg.messageType === "ack") {
        m.acks.push(...msg.updates);
      }
    });
  });
  return m;
}

/** Apple's push service: records what it's sent, and answers as `respond` says. */
async function fakeApple() {
  const a = { requests: [], respond: () => ({ status: 200 }) };
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    let body = "";
    stream.setEncoding("utf8");
    stream.on("data", (d) => (body += d));
    stream.on("end", () => {
      const request = { path: headers[":path"], topic: headers["apns-topic"], type: headers["apns-push-type"], authorization: headers.authorization, body: JSON.parse(body) };
      a.requests.push(request);
      const { status, reason } = a.respond(request);
      stream.respond({ ":status": status });
      stream.end(reason ? JSON.stringify({ reason }) : "");
    });
  });
  await new Promise((r) => server.listen(0, r));
  a.host = `http://127.0.0.1:${server.address().port}`;
  a.close = () => new Promise((r) => server.close(r));
  return a;
}

/** A relay wired to the stand-ins, with a real (throwaway) signing key unless `dryRun`. */
async function setup(t, { dryRun = false, pairingToken = "", maxDevices = 1000 } = {}) {
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
    maxDevices,
    apns: {
      keyFile: dryRun ? "" : keyFile, keyId: "KEYID12345", teamId: "TEAMID1234",
      topics: ["app.unreeled", "app.unreeled.dev"], sandbox: false,
      outbox: path.join(dir, "outbox"), hosts: { production: apple.host, sandbox: apple.host },
    },
  };
  const relay = createRelay(config, quiet);
  await relay.start(0);
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const post = async (route, body, headers = {}) => {
    const response = await fetch(`${base}/${route}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const health = async () => (await fetch(`${base}/health`)).json();
  t.after(async () => {
    relay.close();
    await mozilla.close();
    await apple.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return { relay, mozilla, apple, post, health, dir, config };
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
  assert.deepEqual(Object.keys(device).sort(), ["apnsToken", "channelID", "createdAt", "deviceId", "endpoint", "sandbox", "topic"]);
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
  const { post } = await setup(t, { pairingToken: "secret", maxDevices: 1 });
  const auth = { authorization: "Bearer secret" };
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 401);
  assert.equal((await post("pair", { apnsToken: TOKEN }, { authorization: "Bearer wrong" })).status, 401);
  assert.equal((await post("pair", { apnsToken: "not hex" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, topic: "com.someone.else" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, padding: "x".repeat(5000) }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN }, auth)).status, 200);
  assert.equal((await post("pair", { apnsToken: TOKEN }, auth)).status, 503); // full
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
  await until(() => mozilla.hellos.length === 2, "the second hello");
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
  await until(() => mozilla.registered.length === 2, "the new channel");
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
  assert.equal((await health()).apns, "dry-run");
  const files = fs.readdirSync(config.apns.outbox);
  assert.equal(files.length, 1);
  const written = JSON.parse(fs.readFileSync(path.join(config.apns.outbox, files[0]), "utf8"));
  assert.equal(written["Simulator Target Bundle"], "app.unreeled.dev");
  assert.equal(written.wp.headers.encoding, "aesgcm");
});
