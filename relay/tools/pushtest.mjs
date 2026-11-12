#!/usr/bin/env node
// Tools for the push test (see ../README.md). Everything secret stays in
// ~/.config/unreeled/push-test/, outside the repository.
//
//   node tools/pushtest.mjs keys                  make the keys and the relay's secrets, once
//   node tools/pushtest.mjs relay <address>       remember where the relay is deployed
//   node tools/pushtest.mjs registration [label] [--json]
//                                                 what to register: the push address, p256dh, auth
//   node tools/pushtest.mjs selftest [label]      send the relay a push made here, as Instagram would
//   node tools/pushtest.mjs read [--after <n>] [--show] [--all]
//                                                 what the relay recorded, decrypted here
//
// A label (phone, simulator…) goes at the end of the push address, so the log says which
// registration each push was for.

import { createCipheriv, createDecipheriv, createECDH, createHmac, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const folder = join(homedir(), ".config", "unreeled", "push-test");
const keysFile = join(folder, "keys.json");
const secretsFile = join(folder, "relay-secrets.json");
/** Facebook's and Instagram's own networks, by number. */
const metaNetworks = new Set([32934, 54115, 63293, 149642]);

const [command, ...args] = process.argv.slice(2);
const commands = { keys: makeKeys, relay: setRelay, registration, selftest: selfTest, read };
if (!commands[command]) {
	console.error("Usage: node tools/pushtest.mjs keys | relay <address> | registration [label] [--json] | selftest [label] | read [--after <n>] [--show] [--all]");
	process.exit(2);
}
await commands[command]();

// MARK: Keys

/** The key pair notifications are encrypted for, and the relay's two secrets. Never overwritten. */
function makeKeys() {
	if (existsSync(keysFile)) {
		console.log(`Keys already exist in ${folder}`);
		return;
	}
	mkdirSync(folder, { recursive: true, mode: 0o700 });
	const pair = createECDH("prime256v1");
	pair.generateKeys();
	const keys = {
		created: new Date().toISOString(),
		privateKey: base64url(pair.getPrivateKey()),
		publicKey: base64url(pair.getPublicKey()),
		auth: base64url(randomBytes(16)),
		pushID: randomBytes(16).toString("hex"),
		readToken: randomBytes(32).toString("hex"),
		relay: "",
	};
	save(keys);
	// For `cf deploy --secrets-file`: only what the relay needs, never the private key.
	const secrets = { PUSH_ID: keys.pushID, READ_TOKEN: keys.readToken };
	writeFileSync(secretsFile, JSON.stringify(secrets, null, "\t") + "\n", { mode: 0o600 });
	console.log(`Made the keys and the relay's secrets in ${folder}`);
}

function setRelay() {
	const keys = load();
	keys.relay = new URL(args[0]).origin;
	save(keys);
	console.log(`The relay is at ${keys.relay}`);
}

/**
 * The three values a registration takes: on one line for the Debug probe, or with `--json` as the
 * PushTest.json a phone build carries. The address is a secret: don't post it.
 */
function registration() {
	const keys = load();
	const values = { endpoint: pushAddress(keys, label()), p256dh: keys.publicKey, auth: keys.auth };
	console.log(args.includes("--json") ? JSON.stringify(values) : `${values.endpoint} ${values.p256dh} ${values.auth}`);
}

/** The first argument that isn't an option. */
function label() {
	const name = args.find((arg) => !arg.startsWith("--"));
	if (name !== undefined && !/^[a-z0-9-]{1,24}$/.test(name)) throw new Error("A label is up to 24 lowercase letters, digits or hyphens.");
	return name;
}

function load() {
	if (!existsSync(keysFile)) throw new Error("No keys yet: run `node tools/pushtest.mjs keys` first.");
	return JSON.parse(readFileSync(keysFile, "utf8"));
}

function save(keys) {
	writeFileSync(keysFile, JSON.stringify(keys, null, "\t") + "\n", { mode: 0o600 });
}

function pushAddress(keys, label) {
	if (!keys.relay) throw new Error("No relay yet: run `node tools/pushtest.mjs relay <address>` after deploying.");
	return `${keys.relay}/push/${keys.pushID}${label ? `/${label}` : ""}`;
}

// MARK: Self-test

/** Sends the relay a push encrypted the way Instagram's are, to check the relay and `read`. */
async function selfTest() {
	const keys = load();
	const receiver = bytes(keys.publicKey);
	const payload = {
		type: "selftest",
		time: Math.floor(Date.now() / 1000),
		message: "A push made by the test itself",
		t: "Unreeled",
		n: `selftest.${randomBytes(4).toString("hex")}`,
		params: {},
	};
	const sender = createECDH("prime256v1");
	sender.generateKeys();
	const salt = randomBytes(16);
	const { key, nonce } = legacyKeys(sender.computeSecret(receiver), bytes(keys.auth), salt, receiver, sender.getPublicKey());
	const cipher = createCipheriv("aes-128-gcm", key, nonce);
	// Two bytes of padding length (none here), then the message.
	const plain = Buffer.concat([Buffer.alloc(2), Buffer.from(JSON.stringify(payload))]);
	const body = Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
	const response = await fetch(pushAddress(keys, label()), {
		method: "POST",
		headers: {
			"Content-Type": "application/octet-stream",
			"Content-Encoding": "aesgcm",
			Encryption: `salt=${base64url(salt)}`,
			"Crypto-Key": `dh=${base64url(sender.getPublicKey())}`,
			TTL: "60",
		},
		body,
	});
	console.log(`The relay answered ${response.status}${response.headers.get("Location") ? " with a message address" : ""}`);
	if (response.status !== 201) process.exitCode = 1;
}

// MARK: Reading

/**
 * Lists what the relay recorded. A notification's text stays out of the output unless `--show`
 * is given: by default each field shows as its kind and length, apart from the notification's
 * type, its time and the shape of its link.
 *
 * The relay also records requests to other addresses, mostly the internet's scanners. Those from
 * Meta's networks are listed, the rest are counted, and `--all` lists them too.
 */
async function read() {
	const keys = load();
	const after = option("--after") ?? "0";
	const show = args.includes("--show");
	if (!keys.relay) throw new Error("No relay yet: run `node tools/pushtest.mjs relay <address>` after deploying.");
	const response = await fetch(`${keys.relay}/log?after=${encodeURIComponent(after)}`, {
		headers: { Authorization: `Bearer ${keys.readToken}` },
	});
	if (!response.ok) throw new Error(`The relay answered ${response.status}`);
	const rows = await response.json();
	let others = 0;
	for (const row of rows) {
		const { headers, sender } = row;
		if (row.path) {
			// Not the push address.
			if (!args.includes("--all") && !metaNetworks.has(sender.asn)) {
				others += 1;
				continue;
			}
			console.log(`#${row.id}  ${row.received}  ${row.method} ${row.path}  ${row.bytes} bytes  from AS${sender.asn ?? "?"} ${sender.network ?? "?"} (${sender.country ?? "?"})  [not the push address]`);
			if (headers["user-agent"]) console.log(`     user-agent: ${headers["user-agent"]}`);
			continue;
		}
		const to = row.label ? `  to "${row.label}"` : "";
		console.log(`#${row.id}  ${row.received}  ${row.method}${to}  ${row.bytes} bytes  from AS${sender.asn ?? "?"} ${sender.network ?? "?"} (${sender.country ?? "?"})`);
		const notable = ["content-encoding", "content-type", "ttl", "urgency", "topic", "user-agent"]
			.filter((name) => headers[name] != null)
			.map((name) => `${name}: ${headers[name]}`);
		if (notable.length) console.log(`     ${notable.join(" · ")}`);
		const claims = vapidClaims(headers.authorization);
		if (claims) console.log(`     signed by: ${claims}`);
		if (row.method !== "POST" || row.bytes === 0) continue;
		try {
			const plain = decrypt(Buffer.from(row.body, "base64"), headers, keys);
			let content;
			try {
				content = JSON.parse(plain.toString("utf8"));
			} catch {
				content = `not JSON, ${plain.length} bytes`;
			}
			console.log(`     decrypted: ${JSON.stringify(show ? content : shape(content))}`);
		} catch (error) {
			console.log(`     couldn't decrypt: ${error.message}`);
		}
	}
	const listed = rows.length - others;
	const hidden = others ? ` (and ${others} to other addresses from elsewhere: --all lists them)` : "";
	console.log(listed ? `${listed} recorded after #${after}${hidden}` : `Nothing recorded after #${after}${hidden}`);
}

function option(name) {
	const index = args.indexOf(name);
	return index >= 0 ? args[index + 1] : undefined;
}

/** Who signed the push (RFC 8292): the audience, contact and expiry in its token. */
function vapidClaims(authorization) {
	const token = authorization?.match(/(?:^|[\s=])([\w-]+\.[\w-]+\.[\w-]+)/)?.[1];
	if (!token) return authorization ? authorization.split(/\s+/)[0] : null;
	try {
		const claims = JSON.parse(bytes(token.split(".")[1]).toString("utf8"));
		const expiry = claims.exp ? new Date(claims.exp * 1000).toISOString() : "?";
		return `aud ${claims.aud ?? "?"} · sub ${claims.sub ?? "?"} · exp ${expiry}`;
	} catch {
		return "an unreadable token";
	}
}

/** A value's field names and kinds, without what they say. */
function shape(value, key = "") {
	if (Array.isArray(value)) return value.map((item) => shape(item));
	if (value && typeof value === "object") {
		return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, shape(item, name)]));
	}
	if (typeof value === "string") {
		if (key === "type") return value;
		// A link's kind of page, like /direct/t/#/: what it points to, not where.
		if (key === "href") return value.replace(/^https?:\/\/[^/]+/, "").replace(/[?#].*$/, "?…").replace(/\d+/g, "#");
		return `string(${value.length})`;
	}
	if (typeof value === "number") return key === "time" ? value : "number";
	return value === null ? null : typeof value;
}

// MARK: Decryption

function decrypt(body, headers, keys) {
	const encoding = headers["content-encoding"];
	if (encoding === "aesgcm") return decryptLegacy(body, headers, keys);
	if (encoding === "aes128gcm") return decryptStandard(body, keys);
	throw new Error(`unknown encoding ${encoding}`);
}

/** The older "aesgcm" encoding (draft-ietf-webpush-encryption-04): the salt and key are in headers. */
function decryptLegacy(body, headers, keys) {
	const sender = field(headers["crypto-key"], "dh");
	const salt = field(headers.encryption, "salt");
	if (!sender || !salt) throw new Error("no dh or salt in the headers");
	const receiver = bytes(keys.publicKey);
	const { key, nonce } = legacyKeys(sharedSecret(keys, sender), bytes(keys.auth), salt, receiver, sender);
	const plain = open(key, nonce, body);
	return plain.subarray(2 + plain.readUInt16BE(0));
}

function legacyKeys(shared, auth, salt, receiver, sender) {
	const one = Buffer.from([1]);
	const ikm = hmac(hmac(auth, shared), Buffer.concat([Buffer.from("Content-Encoding: auth\0"), one]));
	const prk = hmac(salt, ikm);
	const context = Buffer.concat([Buffer.from("P-256\0"), length(receiver), receiver, length(sender), sender]);
	const derive = (label, size) =>
		hmac(prk, Buffer.concat([Buffer.from(`Content-Encoding: ${label}\0`), context, one])).subarray(0, size);
	return { key: derive("aesgcm", 16), nonce: derive("nonce", 12) };
}

/** The standard "aes128gcm" encoding (RFC 8291): the salt and key lead the body. One record. */
function decryptStandard(body, keys) {
	const salt = body.subarray(0, 16);
	const sender = body.subarray(21, 21 + body[20]);
	const one = Buffer.from([1]);
	const info = Buffer.concat([Buffer.from("WebPush: info\0"), bytes(keys.publicKey), sender, one]);
	const prk = hmac(salt, hmac(hmac(bytes(keys.auth), sharedSecret(keys, sender)), info));
	const derive = (label, size) => hmac(prk, Buffer.concat([Buffer.from(`Content-Encoding: ${label}\0`), one])).subarray(0, size);
	const plain = open(derive("aes128gcm", 16), derive("nonce", 12), body.subarray(21 + body[20]));
	// The message, a 0x02 delimiter, then padding zeros.
	let end = plain.length;
	while (end > 0 && plain[end - 1] === 0) end -= 1;
	return plain.subarray(0, end - 1);
}

function sharedSecret(keys, sender) {
	const pair = createECDH("prime256v1");
	pair.setPrivateKey(bytes(keys.privateKey));
	return pair.computeSecret(sender);
}

function open(key, nonce, sealed) {
	const decipher = createDecipheriv("aes-128-gcm", key, nonce);
	decipher.setAuthTag(sealed.subarray(-16));
	return Buffer.concat([decipher.update(sealed.subarray(0, -16)), decipher.final()]);
}

/** `name=value` in a header like `dh=…;p256ecdsa=…`, decoded. */
function field(header, name) {
	for (const part of (header ?? "").split(/[;,]/)) {
		const [key, value] = part.trim().split(/=(.*)/s);
		if (key === name && value) return bytes(value);
	}
	return null;
}

function hmac(key, data) {
	return createHmac("sha256", key).update(data).digest();
}

function length(buffer) {
	const size = Buffer.alloc(2);
	size.writeUInt16BE(buffer.length);
	return size;
}

function base64url(buffer) {
	return Buffer.from(buffer).toString("base64url");
}

/** Decodes base64 in either alphabet, padded or not. */
function bytes(text) {
	return Buffer.from(text, "base64");
}
