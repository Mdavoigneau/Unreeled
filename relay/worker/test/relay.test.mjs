// The Worker relay, run locally in Cloudflare's runtime (`vite --mode test`), against stand-ins
// for Mozilla's push service and Apple's on this machine. The same cases as ../../test, plus
// what's particular to a Durable Object: coming back after a restart.
//
// Run with `npm test`. Each test starts its own relay with its own storage, which takes a few
// seconds.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";

const here = path.dirname(fileURLToPath(import.meta.url));
const TOKEN = "a".repeat(64);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(check, what, tries = 150) {
  for (let i = 0; i < tries; i += 1) { if (await check()) return; await wait(50); }
  assert.fail(`timed out waiting for ${what}`);
}

/** Mozilla's push service, as far as the relay uses it. */
async function fakeMozilla() {
  const wss = new WebSocketServer({ port: 0 });
  await new Promise((r) => wss.on("listening", r));
  const m = {
    url: `ws://127.0.0.1:${wss.address().port}`,
    uaid: "uaid-1",
    answersPings: true,
    hellos: [], registered: [], unregistered: [], acks: [], pings: 0,
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
      } else if (msg.messageType === undefined) {
        // `{}`: the relay asking whether the connection is still there.
        m.pings += 1;
        if (m.answersPings) socket.send("{}");
      }
    });
  });
  return m;
}

/** Apple's push service: records what it's sent, and answers as `respond` says. */
async function fakeApple() {
  const a = { requests: [], respond: () => ({ status: 200 }) };
  const server = http.createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (d) => (body += d));
    request.on("end", () => {
      const seen = { path: request.url, topic: request.headers["apns-topic"], type: request.headers["apns-push-type"], authorization: request.headers.authorization, body: JSON.parse(body) };
      a.requests.push(seen);
      const { status, reason } = a.respond(seen);
      response.writeHead(status, { "content-type": "application/json" });
      response.end(reason ? JSON.stringify({ reason }) : "");
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  a.host = `http://127.0.0.1:${server.address().port}`;
  a.close = () => new Promise((r) => { server.closeAllConnections(); server.close(r); });
  return a;
}

function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => { const { port } = server.address(); server.close(() => resolve(port)); });
  });
}

/** Starts the relay on `port` with `settings`. Resolves once it listens; `stop()` ends it. */
async function run(port, settings) {
  const child = spawn("npx", ["vite", "--mode", "test", "--host", "127.0.0.1", "--port", String(port), "--strictPort"], {
    cwd: path.join(here, ".."),
    env: { ...process.env, ...settings },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (d) => (output += d));
  child.stderr.on("data", (d) => (output += d));
  // Ended, or never started.
  const exited = new Promise((r) => { child.on("exit", r); child.on("error", (error) => { output += String(error); r(); }); });
  const stop = async () => { child.kill("SIGTERM"); await exited; };
  try {
    // Listening, without asking the relay anything: a request would wake the object.
    await until(() => new Promise((r) => {
      const probe = net.connect(port, "127.0.0.1", () => { probe.destroy(); r(true); });
      probe.on("error", () => r(false));
    }), "the relay to listen", 600);
  } catch (error) {
    await stop();
    throw new Error(`${error.message}\n${output}`);
  }
  return { stop, output: () => output };
}

/** A relay wired to the stand-ins, with a throwaway signing key unless `dryRun`. */
async function setup(t, { dryRun = false, pairingToken = "", maxDevices = "", quietSeconds = 3600 } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-worker-test-"));
  const mozilla = await fakeMozilla();
  const apple = await fakeApple();
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
  const settings = {
    RELAY_STATE: path.join(dir, "state"),
    RELAY_AUTOPUSH_URL: mozilla.url,
    RELAY_INSTAGRAM_VAPID_KEY: "test-vapid-key",
    RELAY_APNS_HOST: apple.host,
    RELAY_OUTBOX: "1",
    RELAY_CHECK_SECONDS: "1",
    RELAY_QUIET_SECONDS: String(quietSeconds),
    ...(dryRun ? {} : {
      RELAY_APNS_KEY: privateKey.export({ type: "pkcs8", format: "pem" }),
      RELAY_APNS_KEY_ID: "KEYID12345",
      RELAY_APNS_TEAM_ID: "TEAMID1234",
      RELAY_APNS_TOPIC: "app.unreeled, app.unreeled.dev",
    }),
    ...(pairingToken ? { RELAY_PAIRING_TOKEN: pairingToken } : {}),
    ...(maxDevices ? { RELAY_MAX_DEVICES: maxDevices } : {}),
  };
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  let relay = await run(port, settings);
  const call = async (method, route, body, headers = {}) => {
    const response = await fetch(`${base}/${route}`, { method, headers: { "content-type": "application/json", ...headers }, body: body && JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const post = (route, body, headers) => call("POST", route, body, headers);
  const health = async () => (await call("GET", "health")).body;
  /** Stops the relay and starts it again on the same storage, as a deploy or an update does. */
  const restart = async () => { await relay.stop(); relay = await run(port, settings); };
  t.after(async () => {
    await relay.stop();
    await mozilla.close();
    await apple.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  // The first request creates the object, which connects.
  await until(async () => (await health()).mozilla, "the connection to Mozilla");
  return { mozilla, apple, post, call, health, restart, publicKey };
}

test("pairing registers a channel for Instagram's key", async (t) => {
  const { mozilla, post, health } = await setup(t);
  const { status, body } = await post("pair", { apnsToken: TOKEN, sandbox: true, topic: "app.unreeled.dev" });
  assert.equal(status, 200);
  assert.match(body.deviceId, /^[0-9a-f-]{36}$/);
  assert.equal(mozilla.registered.length, 1);
  assert.equal(mozilla.registered[0].key, "test-vapid-key");
  assert.equal(body.endpoint, `https://push.test/wpush/${mozilla.registered[0].channelID}`);
  assert.deepEqual(Object.keys(body).sort(), ["deviceId", "endpoint"]);

  const state = await health();
  assert.equal(state.devices, 1);
  assert.equal(state.mozilla, true);
  assert.equal(state.apns, "live");
});

test("a push is forwarded to Apple still encrypted, then acknowledged", async (t) => {
  const { mozilla, apple, post, health, publicKey } = await setup(t);
  await post("pair", { apnsToken: TOKEN, sandbox: true });
  const { channelID } = mozilla.registered[0];
  mozilla.push(channelID, "ZW5jcnlwdGVk", { encoding: "aesgcm", encryption: "salt=s", crypto_key: "dh=k;p256ecdsa=v" });
  await until(() => mozilla.acks.length === 1, "the ack");

  assert.equal(apple.requests.length, 1);
  const [request] = apple.requests;
  assert.equal(request.path, `/3/device/${TOKEN}`);
  assert.equal(request.topic, "app.unreeled"); // the first topic, when the phone names none
  assert.equal(request.type, "alert");
  assert.equal(request.body.aps["mutable-content"], 1);
  assert.deepEqual(request.body.wp, { data: "ZW5jcnlwdGVk", headers: { encoding: "aesgcm", encryption: "salt=s", crypto_key: "dh=k;p256ecdsa=v" } });
  assert.equal(mozilla.acks[0].channelID, channelID);

  // The token Apple gets is signed by the push key, as Apple will check it.
  const [, header, claims, signature] = request.authorization.match(/^bearer ([\w-]+)\.([\w-]+)\.([\w-]+)$/);
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), { alg: "ES256", kid: "KEYID12345" });
  assert.equal(JSON.parse(Buffer.from(claims, "base64url")).iss, "TEAMID1234");
  assert.ok(crypto.verify("SHA256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")));

  const state = await health();
  assert.equal(state.forwarded, 1);
  assert.equal(state.failed, 0);
  assert.ok(state.lastPushAt);
});

test("pairing again keeps the endpoint and refreshes the phone's address", async (t) => {
  const { mozilla, apple, post } = await setup(t);
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  const again = (await post("pair", { apnsToken: "b".repeat(64), topic: "app.unreeled.dev", deviceId: first.deviceId })).body;
  assert.deepEqual(again, first);
  assert.equal(mozilla.registered.length, 1);
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => apple.requests.length === 1, "the push");
  assert.equal(apple.requests[0].path, `/3/device/${"b".repeat(64)}`);
  assert.equal(apple.requests[0].topic, "app.unreeled.dev");

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
  const { post, call } = await setup(t, { pairingToken: "secret", maxDevices: "1" });
  const auth = { authorization: "Bearer secret" };
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 401);
  assert.equal((await post("pair", { apnsToken: TOKEN }, { authorization: "Bearer wrong" })).status, 401);
  assert.equal((await call("GET", "outbox")).status, 401);
  assert.equal((await post("pair", { apnsToken: "not hex" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, topic: "com.someone.else" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, padding: "x".repeat(5000) }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN }, auth)).status, 200);
  assert.equal((await post("pair", { apnsToken: TOKEN }, auth)).status, 503); // full
  assert.equal((await call("GET", "nowhere", undefined, auth)).status, 404);
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
  const { mozilla, apple, post, health } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  const { channelID } = mozilla.registered[0];
  mozilla.socket.terminate();
  await until(() => mozilla.hellos.length === 2, "the second hello");
  assert.equal(mozilla.hellos[1].uaid, "uaid-1");
  assert.deepEqual(mozilla.hellos[1].channelIDs, [channelID]);
  assert.equal(mozilla.registered.length, 1);
  mozilla.push(channelID);
  await until(() => apple.requests.length === 1, "the push after reconnecting");
  const state = await health();
  assert.equal(state.starts, 1);
  assert.equal(state.connections, 2);
  assert.ok(state.connectedSince);
});

test("when Mozilla forgets the identity, each device gets a new endpoint", async (t) => {
  const { mozilla, apple, post } = await setup(t);
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  mozilla.uaid = "uaid-2";
  mozilla.socket.terminate();
  await until(() => mozilla.registered.length === 2, "the new channel");

  // The phone learns the new endpoint when it pairs again, and pushes on it reach the phone.
  const moved = `https://push.test/wpush/${mozilla.registered[1].channelID}`;
  let again;
  await until(async () => (again = (await post("pair", { apnsToken: TOKEN, deviceId: first.deviceId })).body).endpoint === moved, "the device's move");
  assert.equal(again.deviceId, first.deviceId);
  mozilla.push(mozilla.registered[1].channelID);
  await until(() => apple.requests.length === 1, "the push on the new channel");
});

test("without an Apple key, a dry run keeps each push for the outbox", async (t) => {
  const { mozilla, apple, post, call, health } = await setup(t, { dryRun: true });
  // A dry run serves any app.
  await post("pair", { apnsToken: TOKEN, topic: "com.example.unreeled" });
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  assert.equal(apple.requests.length, 0);
  assert.equal((await health()).apns, "dry-run");
  const { body: outbox } = await call("GET", "outbox");
  assert.equal(outbox.length, 1);
  const written = JSON.parse(outbox[0]);
  assert.equal(written["Simulator Target Bundle"], "com.example.unreeled");
  assert.equal(written.wp.headers.encoding, "aesgcm");
});

test("the relay can say whether it reaches Apple", async (t) => {
  const { apple, call } = await setup(t);
  apple.respond = () => ({ status: 400, reason: "BadDeviceToken" });
  assert.deepEqual((await call("GET", "apple")).body, { reachable: true, status: 400, reason: "BadDeviceToken" });
  assert.equal(apple.requests[0].topic, "app.unreeled");
  assert.match(apple.requests[0].authorization, /^bearer /);
  await apple.close();
  apple.close = async () => {};
  assert.equal((await call("GET", "apple")).body.reachable, false);
});

test("a quiet connection is asked whether it's still there, and replaced when it isn't", async (t) => {
  const { mozilla } = await setup(t, { quietSeconds: 1 });
  await until(() => mozilla.pings >= 2, "two pings", 300);
  assert.equal(mozilla.hellos.length, 1); // answered, so the connection stays
  mozilla.answersPings = false;
  await until(() => mozilla.hellos.length === 2, "a new connection", 300);
});

test("after a restart, an alarm brings the relay back with its phones", async (t) => {
  const { mozilla, apple, post, health, restart } = await setup(t);
  const { endpoint } = (await post("pair", { apnsToken: TOKEN })).body;
  const { channelID } = mozilla.registered[0];
  await restart();
  // Nothing asks the relay anything: the alarm alone has to wake it.
  await until(() => mozilla.hellos.length === 2, "the hello after the restart", 400);
  assert.equal(mozilla.hellos[1].uaid, "uaid-1");
  assert.deepEqual(mozilla.hellos[1].channelIDs, [channelID]);
  mozilla.push(channelID);
  await until(() => apple.requests.length === 1, "the push after the restart");
  assert.ok(endpoint.endsWith(channelID));
  assert.equal((await health()).starts, 2);
});
