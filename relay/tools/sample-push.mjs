#!/usr/bin/env node
// A stand-in for Instagram, to test the relay and the phone without an Instagram account: it
// encrypts a notification shaped like Instagram's for a phone's keys, with the `web-push`
// library, and either sends it through Mozilla's push service or writes it as the Apple push
// the relay would have forwarded.
//
//   node tools/sample-push.mjs key
//       Prints this sender's public (VAPID) key. Run the relay with INSTAGRAM_VAPID_KEY set to
//       it, and the channels it registers accept pushes from this tool instead of Instagram.
//
//   node tools/sample-push.mjs send <subscription.json> [options]
//       Sends a push to the subscription's endpoint, through Mozilla, to the relay.
//
//   node tools/sample-push.mjs apns <subscription.json> [options] > push.apns
//       No network: the push as the relay forwards it to Apple, for
//       `xcrun simctl push <device> push.apns`.
//
// <subscription.json> is what a browser calls a push subscription: { endpoint, keys: { p256dh,
// auth } }. A Debug build of the app launched with -pushDryRun YES writes the one it would have
// given Instagram to Library/Caches/push-dry-run.json.
//
// Options: --encoding aesgcm|aes128gcm (aesgcm, Instagram's)   --type direct_v2_text
//          --title "Thread name"   --message "Text"   --thread <conversation ID>
//          --picture <https URL>   --bundle <bundle ID, for apns>
import fs from "node:fs";
import webpush from "web-push";

const senderFile = new URL("../data/test-sender.json", import.meta.url);

function sender() {
  try {
    return JSON.parse(fs.readFileSync(senderFile, "utf8"));
  } catch {
    const keys = webpush.generateVAPIDKeys();
    fs.mkdirSync(new URL(".", senderFile), { recursive: true });
    fs.writeFileSync(senderFile, JSON.stringify(keys, null, 2), { mode: 0o600 });
    return keys;
  }
}

function options(args) {
  const found = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!args[i].startsWith("--") || args[i + 1] === undefined) throw new Error(`can't read option ${args[i]}`);
    found[args[i].slice(2)] = args[i + 1];
  }
  return found;
}

/** A notification as Instagram's web push carries it (see Shared/InstagramPush.swift). */
function notification(o) {
  const thread = o.thread || "340282366841710300949128000000000000000";
  return JSON.stringify({
    type: o.type || "direct_v2_text",
    time: String(Math.floor(Date.now() / 1000)),
    message: o.message || "This is a test, sent by relay/tools/sample-push.mjs",
    href: null,
    t: o.title ?? "Unreeled test",
    n: `test-${Date.now()}`,
    ...(o.picture ? { ppu: o.picture } : {}),
    params: { t_id: thread, collapse_key: `direct_v2_${thread}`, badge: "1", ts: String(Date.now()) },
  });
}

function request(subscription, o) {
  const keys = sender();
  return webpush.generateRequestDetails(subscription, notification(o), {
    vapidDetails: { subject: "https://example.com", publicKey: keys.publicKey, privateKey: keys.privateKey },
    contentEncoding: o.encoding || "aesgcm",
    TTL: 300,
  });
}

const [command, file, ...rest] = process.argv.slice(2);

if (command === "key") {
  console.log(sender().publicKey);
} else if ((command === "send" || command === "apns") && file) {
  const subscription = JSON.parse(fs.readFileSync(file, "utf8"));
  const o = options(rest);
  const details = request(subscription, o);
  if (command === "send") {
    const response = await fetch(details.endpoint, { method: details.method, headers: details.headers, body: details.body });
    console.log(`${new URL(details.endpoint).host} answered ${response.status}${response.ok ? "" : `: ${await response.text()}`}`);
    process.exit(response.ok ? 0 : 1);
  }
  // As Mozilla hands a push to the relay: the body in base64url, the header fields under its names.
  const headers = { encoding: details.headers["Content-Encoding"] };
  if (details.headers.Encryption) headers.encryption = details.headers.Encryption;
  if (details.headers["Crypto-Key"]) headers.crypto_key = details.headers["Crypto-Key"];
  console.log(JSON.stringify({
    "Simulator Target Bundle": o.bundle || "com.example.unreeled",
    aps: { "mutable-content": 1, alert: { body: "New notification on Instagram" }, sound: "default" },
    wp: { data: Buffer.from(details.body).toString("base64url"), headers },
  }, null, 2));
} else {
  console.error("usage: sample-push.mjs key | send <subscription.json> [options] | apns <subscription.json> [options]");
  process.exit(2);
}
