// The Worker relay, run locally in Cloudflare's runtime (`vite --mode test`), against stand-ins
// for Mozilla's push service and Apple's on this machine. The same cases as ../../test, plus
// what's particular to a Durable Object: coming back after a restart, keeping requests without a
// token away from it, and the storage it had before a change.
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
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";

const here = path.dirname(fileURLToPath(import.meta.url));
const TOKEN = "a".repeat(64);
const OPERATOR = "operator-token";
const operator = { authorization: `Bearer ${OPERATOR}` };
const REFUSED = { status: 400, body: { error: "Apple doesn't know this phone" } };
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
    /** How a hello is answered: 200 takes it, another status refuses it. */
    helloStatus: 200,
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
        socket.send(JSON.stringify({ messageType: "hello", status: m.helloStatus, uaid: m.uaid, use_webpush: true }));
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
  const server = http.createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (d) => (body += d));
    request.on("end", () => {
      const { headers } = request;
      const seen = {
        path: request.url, topic: headers["apns-topic"], type: headers["apns-push-type"], priority: headers["apns-priority"],
        expiration: headers["apns-expiration"], authorization: headers.authorization, body: JSON.parse(body),
      };
      (seen.type === "background" ? a.checks : a.requests).push(seen);
      if (a.silent) return;
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

/**
 * A relay wired to the stand-ins, with a throwaway signing key unless `dryRun`, and the operator
 * token. A `pairingToken` of "" sets an empty one. Unless `connect` is false, it's started with
 * a request that has the operator token, as a deploy is.
 */
async function setup(t, {
  dryRun = false, pairingToken, maxDevices = "", quietSeconds = 3600, topics = "app.unreeled, app.unreeled.dev",
  ttlDays = "", sweepSeconds = "", appleSeconds = "", pairingLimit = false, connect = true,
} = {}) {
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
    RELAY_OPERATOR_TOKEN: OPERATOR,
    ...(dryRun ? {} : {
      RELAY_APNS_KEY: privateKey.export({ type: "pkcs8", format: "pem" }),
      RELAY_APNS_KEY_ID: "KEYID12345",
      RELAY_APNS_TEAM_ID: "TEAMID1234",
      RELAY_APNS_TOPIC: topics,
    }),
    ...(pairingToken === undefined ? {} : { RELAY_PAIRING_TOKEN: pairingToken }),
    ...(maxDevices ? { RELAY_MAX_DEVICES: maxDevices } : {}),
    ...(ttlDays ? { RELAY_DEVICE_TTL_DAYS: ttlDays } : {}),
    ...(sweepSeconds ? { RELAY_SWEEP_SECONDS: sweepSeconds } : {}),
    ...(appleSeconds ? { RELAY_APPLE_SECONDS: appleSeconds } : {}),
    ...(pairingLimit ? { RELAY_PAIRING_LIMIT: "1" } : {}),
  };
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  let relay = await run(port, settings);
  const call = async (method, route, body, headers = {}) => {
    const response = await fetch(`${base}/${route}`, { method, headers: { "content-type": "application/json", ...headers }, body: body && JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const post = (route, body, headers) => call("POST", route, body, headers);
  /** Everything /health tells whoever runs the relay. */
  const health = async () => (await call("GET", "health", undefined, operator)).body;
  /** Stops the relay and starts it again on the same storage, as a deploy or an update does. */
  const restart = async (meanwhile = async () => {}) => { await relay.stop(); await meanwhile(); relay = await run(port, settings); };
  t.after(async () => {
    await relay.stop();
    await mozilla.close();
    await apple.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  // The first request with a token creates the object, which connects.
  if (connect) await until(async () => (await health()).mozilla, "the connection to Mozilla");
  return { mozilla, apple, post, call, health, restart, publicKey, base, state: settings.RELAY_STATE };
}

/** The relay object's SQLite database, in a stopped relay's storage. */
function database(state) {
  for (const name of fs.readdirSync(state, { recursive: true })) {
    if (!String(name).endsWith(".sqlite")) continue;
    const db = new DatabaseSync(path.join(state, String(name)));
    if (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'devices'").get()) return db;
    db.close();
  }
  assert.fail("no database with a devices table");
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
  const { post, call, base } = await setup(t, { pairingToken: "secret", maxDevices: "1" });
  const auth = { authorization: "Bearer secret" };
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 401);
  assert.equal((await post("pair", { apnsToken: TOKEN }, { authorization: "Bearer wrong" })).status, 401);
  assert.equal((await post("pair", { apnsToken: TOKEN }, operator)).status, 401); // the operator's token is no pairing token
  assert.equal((await call("GET", "outbox")).status, 401);
  assert.equal((await post("pair", { apnsToken: "not hex" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, topic: "com.someone.else" }, auth)).status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN, padding: "x".repeat(5000) }, auth)).status, 400);
  // The same, without saying how long it is: read only as far as the limit.
  const long = new TextEncoder().encode(JSON.stringify({ apnsToken: TOKEN, padding: "x".repeat(8000) }));
  const stream = new ReadableStream({ start(controller) { controller.enqueue(long); controller.close(); } });
  const unmeasured = await fetch(`${base}/pair`, { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: stream, duplex: "half" });
  assert.equal(unmeasured.status, 400);
  assert.equal((await post("pair", { apnsToken: TOKEN }, auth)).status, 200);
  assert.equal((await post("pair", { apnsToken: "c".repeat(64) }, auth)).status, 503); // full
  assert.equal((await call("GET", "nowhere", undefined, auth)).status, 404);
});

test("an empty pairing token lets no one pair", async (t) => {
  const { post } = await setup(t, { pairingToken: "" });
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 401);
  assert.equal((await post("pair", { apnsToken: TOKEN }, { authorization: "Bearer " })).status, 401);
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
  assert.equal(apple.checks.length, 0); // nor is Apple asked about the phone
  assert.equal((await health()).apns, "dry-run");
  const { body: outbox } = await call("GET", "outbox");
  assert.equal(outbox.length, 1);
  const written = JSON.parse(outbox[0]);
  assert.equal(written["Simulator Target Bundle"], "com.example.unreeled");
  assert.equal(written.wp.headers.encoding, "aesgcm");
});

test("the relay can tell whoever runs it whether it reaches Apple", async (t) => {
  const { apple, call } = await setup(t, { pairingToken: "secret" });
  apple.respond = () => ({ status: 400, reason: "BadDeviceToken" });
  assert.equal((await call("GET", "apple")).status, 401);
  assert.equal((await call("GET", "apple", undefined, { authorization: "Bearer secret" })).status, 401);
  assert.equal(apple.requests.length, 0);
  assert.deepEqual((await call("GET", "apple", undefined, operator)).body, { reachable: true, status: 400, reason: "BadDeviceToken" });
  assert.equal(apple.requests[0].topic, "app.unreeled");
  assert.match(apple.requests[0].authorization, /^bearer /);
  await apple.close();
  apple.close = async () => {};
  assert.equal((await call("GET", "apple", undefined, operator)).body.reachable, false);
});

test("with Apple's key but no bundle ID, nothing goes to Apple", async (t) => {
  const { mozilla, apple, post, health } = await setup(t, { topics: " , " });
  assert.equal((await health()).apns, "dry-run");
  assert.equal((await post("pair", { apnsToken: TOKEN, topic: "com.other.team.app" })).status, 200);
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  assert.equal(apple.requests.length + apple.checks.length, 0);
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

test("health says that the relay answers to anyone, whether it's up to the app, and the counts to whoever runs it", async (t) => {
  const { call } = await setup(t, { pairingToken: "secret" });
  assert.deepEqual((await call("GET", "health")).body, { ok: true });
  assert.deepEqual((await call("GET", "health", undefined, { authorization: "Bearer wrong" })).body, { ok: true });
  assert.deepEqual((await call("GET", "health", undefined, { authorization: "Bearer secret" })).body, { ok: true, mozilla: true, apns: "live" });
  const full = (await call("GET", "health", undefined, operator)).body;
  assert.deepEqual(Object.keys(full).sort(), ["apns", "connectedSince", "connections", "devices", "failed", "forwarded", "lastPushAt", "mozilla", "ok", "starts"]);
});

test("requests without a token never reach the relay's object", async (t) => {
  const { mozilla, call } = await setup(t, { pairingToken: "secret", connect: false });
  const routes = [["GET", "health"], ["GET", "health?full=1"], ["POST", "health"], ["POST", "pair"], ["POST", "unpair"], ["GET", "apple"], ["GET", "outbox"], ["GET", "nowhere"]];
  const statuses = [];
  for (const [method, route] of routes) statuses.push((await call(method, route, method === "POST" ? { apnsToken: TOKEN } : undefined)).status);
  assert.deepEqual(statuses, [200, 200, 401, 401, 401, 401, 401, 401]);
  // Had any of them created the object, it would have connected by now.
  await wait(2500);
  assert.equal(mozilla.hellos.length, 0);
  // One with the token does, as at the start of a deploy.
  await until(async () => (await call("GET", "health", undefined, { authorization: "Bearer secret" })).body.mozilla, "the connection");
  assert.equal(mozilla.hellos.length, 1);
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

test("pairing again asks Apple about a new token, and forgets a phone Apple doesn't know", async (t) => {
  const { mozilla, apple, post, health } = await setup(t);
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  assert.equal(apple.checks.length, 1);
  // The same token again, within a day of the last check: nothing to ask.
  assert.deepEqual((await post("pair", { apnsToken: TOKEN, deviceId: first.deviceId })).body, first);
  assert.equal(apple.checks.length, 1);
  // A new token is asked about before the record changes.
  apple.respond = () => ({ status: 400, reason: "BadDeviceToken" });
  assert.deepEqual(await post("pair", { apnsToken: "b".repeat(64), deviceId: first.deviceId }), REFUSED);
  assert.equal(apple.checks.length, 2);
  assert.equal(apple.checks[1].path, `/3/device/${"b".repeat(64)}`);
  await until(() => mozilla.unregistered.length === 1, "the unregister");
  assert.equal(mozilla.unregistered[0], mozilla.registered[0].channelID);
  assert.equal((await health()).devices, 0);
});

test("a token has one record: pairing afresh replaces it, even when pairings overlap", async (t) => {
  const { mozilla, post, health } = await setup(t, { maxDevices: "2" });
  const first = (await post("pair", { apnsToken: TOKEN })).body;
  const second = (await post("pair", { apnsToken: TOKEN })).body;
  assert.notEqual(second.deviceId, first.deviceId);
  assert.notEqual(second.endpoint, first.endpoint);
  await until(() => mozilla.unregistered.length === 1, "the old record's unregister");
  assert.equal(mozilla.unregistered[0], mozilla.registered[0].channelID);
  assert.equal((await health()).devices, 1);

  // Two pairings of one token at once end with one record, whichever comes last. Mozilla's slow
  // answer has both waiting for their channels together.
  mozilla.registerDelay = 300;
  const both = await Promise.all([post("pair", { apnsToken: "b".repeat(64) }), post("pair", { apnsToken: "b".repeat(64) })]);
  assert.deepEqual(both.map((answer) => answer.status), [200, 200]);
  assert.equal((await health()).devices, 2);
  await until(() => mozilla.unregistered.length === 2, "the overlapping pairing's unregister");

  // The relay is full: another phone is refused, but a phone with a record still pairs afresh.
  assert.equal((await post("pair", { apnsToken: "c".repeat(64) })).status, 503);
  assert.equal((await post("pair", { apnsToken: TOKEN })).status, 200);
  assert.equal((await health()).devices, 2);
});

test("a phone nothing shows to be real is forgotten after DEVICE_TTL_DAYS", async (t) => {
  // Three seconds' lifetime, looked at every second.
  const { mozilla, post, health } = await setup(t, { ttlDays: String(3 / 86400), sweepSeconds: "1" });
  const quiet = (await post("pair", { apnsToken: TOKEN })).body;
  await post("pair", { apnsToken: "b".repeat(64) });
  const [{ channelID: quietChannel }, { channelID: busyChannel }] = mozilla.registered;
  // Pushes Apple takes keep the busy phone; the quiet one only pairs again with the same token,
  // which proves nothing.
  const pushes = setInterval(() => mozilla.push(busyChannel), 500);
  t.after(() => clearInterval(pushes));
  let lastPairing = 0;
  for (let i = 0; i < 4; i += 1) {
    await wait(500);
    assert.equal((await post("pair", { apnsToken: TOKEN, deviceId: quiet.deviceId })).status, 200);
    lastPairing = Date.now();
  }
  await until(() => mozilla.unregistered.includes(quietChannel), "the quiet phone to be forgotten");
  assert.ok(Date.now() - lastPairing < 3000, "pairing again didn't keep it");
  assert.ok(!mozilla.unregistered.includes(busyChannel));
  clearInterval(pushes);
  await until(() => mozilla.unregistered.includes(busyChannel), "the busy phone, once quiet, to be forgotten");
  assert.equal((await health()).devices, 0);
});

test("in a dry run, pairing again keeps a phone", async (t) => {
  const { mozilla, post } = await setup(t, { dryRun: true, ttlDays: String(3 / 86400), sweepSeconds: "1" });
  const { deviceId } = (await post("pair", { apnsToken: TOKEN })).body;
  const started = Date.now();
  while (Date.now() - started < 5000) {
    assert.equal((await post("pair", { apnsToken: TOKEN, deviceId })).body.deviceId, deviceId);
    await wait(500);
  }
  assert.equal(mozilla.unregistered.length, 0);
  await until(() => mozilla.unregistered.length === 1, "the phone, once it stops pairing, to be forgotten");
});

test("records from before there was a last-seen time are kept, from the time of the change", async (t) => {
  const { mozilla, post, health, restart, state } = await setup(t);
  await post("pair", { apnsToken: TOKEN });
  // The storage as the relay before this change left it.
  let changedAt;
  await restart(async () => {
    const db = database(state);
    db.exec("ALTER TABLE devices DROP COLUMN last_seen");
    db.close();
    changedAt = new Date().toISOString();
  });
  await until(() => mozilla.hellos.length === 2, "the hello after the restart", 400);
  assert.equal((await health()).devices, 1);
  await restart(async () => {
    const db = database(state);
    const { last_seen: lastSeen, created_at: createdAt } = db.prepare("SELECT last_seen, created_at FROM devices").get();
    db.close();
    assert.ok(lastSeen >= changedAt && lastSeen > createdAt, `last_seen ${lastSeen}`);
  });
});

test("Apple not answering in time fails a push, which is still acknowledged", async (t) => {
  const { mozilla, apple, post, call, health } = await setup(t, { appleSeconds: "1" });
  await post("pair", { apnsToken: TOKEN });
  apple.silent = true;
  // No answer about a token isn't held against the phone.
  const started = Date.now();
  assert.equal((await post("pair", { apnsToken: "b".repeat(64) })).status, 200);
  assert.ok(Date.now() - started < 5000);
  mozilla.push(mozilla.registered[0].channelID);
  await until(() => mozilla.acks.length === 1, "the ack");
  const state = await health();
  assert.equal(state.forwarded, 0);
  assert.equal(state.failed, 1);
  assert.equal(state.devices, 2);
  assert.equal((await call("GET", "apple", undefined, operator)).body.reachable, false);
});

test("a refused hello is tried again after a wait that neither the alarm nor a pairing cuts short", async (t) => {
  // The alarm runs every second, more often than the wait.
  const { mozilla, post, health } = await setup(t);
  mozilla.helloStatus = 503;
  mozilla.socket.terminate();
  await until(() => mozilla.hellos.length === 2, "the first refused hello");
  // A pairing meanwhile waits for a connection rather than opening one, and gives up in time.
  const started = Date.now();
  const pairing = post("pair", { apnsToken: TOKEN });
  await until(() => mozilla.hellos.length === 3, "the second refused hello", 300);
  const [, first, second] = mozilla.helloTimes;
  assert.ok(second - first >= 2000, `refused hellos ${second - first}ms apart`);
  assert.equal((await pairing).status, 500);
  assert.ok(Date.now() - started < 15_000);
  assert.equal((await health()).devices, 0);
});

test("pairing calls are limited per address, an IPv6 address by its /56", async (t) => {
  const { post, call } = await setup(t, { pairingLimit: true });
  const from = (address) => ({ "CF-Connecting-IP": address });
  for (let i = 0; i < 10; i += 1) assert.equal((await post("pair", {}, from("2001:db8:1:2::1"))).status, 400);
  assert.equal((await post("pair", {}, from("2001:db8:1:3::9"))).status, 429); // the same /56
  assert.equal((await post("unpair", {}, from("2001:db8:1:2::1"))).status, 429);
  assert.equal((await call("GET", "apple", undefined, { ...operator, ...from("2001:db8:1:2::1") })).status, 429);
  assert.equal((await post("pair", {}, from("2001:db8:1:100::1"))).status, 400); // another /56
  assert.equal((await post("pair", {}, from("192.0.2.1"))).status, 400);
});

test("when two phones pair at once for the last place, one gets it and the other's channel is closed", async (t) => {
  const { mozilla, post, health } = await setup(t, { maxDevices: "1" });
  mozilla.registerDelay = 300;
  const answers = await Promise.all([post("pair", { apnsToken: TOKEN }), post("pair", { apnsToken: "b".repeat(64) })]);
  assert.deepEqual(answers.map((answer) => answer.status).sort(), [200, 503]);
  await until(() => mozilla.unregistered.length === 1, "the other channel's unregister");
  assert.equal(mozilla.registered.length, 2);
  assert.equal((await health()).devices, 1);
});
