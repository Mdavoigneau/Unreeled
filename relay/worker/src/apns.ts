// Sends pushes to Apple's push service, carrying the web push's ciphertext and header fields for
// the phone's notification extension to decrypt. The same push as ../../src/apns.mjs sends, with
// `fetch` and Web Crypto in place of Node's HTTP/2 and crypto.

import type { PushMessage } from "./mozilla.ts";

const JWT_TTL_MS = 50 * 60 * 1000; // Apple wants a token renewed between 20 and 60 minutes
const MAX_PAYLOAD = 4096; // Apple's limit for a push, in bytes
const EXPIRES_S = 3 * 24 * 3600; // how long Apple keeps a push for a phone that's off
// What the notification says when the phone can't decrypt it (its keys are gone), or when the
// encrypted copy doesn't fit in a push.
const FALLBACK = { body: "New notification on Instagram" };

const HOSTS = {
	production: "https://api.push.apple.com",
	sandbox: "https://api.sandbox.push.apple.com",
};

export interface Device {
	deviceId: string;
	channelID: string;
	endpoint: string;
	apnsToken: string;
	/** Which of Apple's two services the token belongs to. */
	sandbox: boolean;
	/** The app's bundle ID. */
	topic: string;
}

/** Apple answered a push with an error. `gone` when the device token will never work again. */
export class ApnsError extends Error {
	readonly gone: boolean;

	constructor(
		readonly status: number,
		readonly reason: string,
	) {
		super(`APNs ${status}: ${reason}`);
		this.gone = status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic";
	}
}

/** The push for one web push message: the ciphertext for the phone's extension, if it fits. */
export function payload(message: PushMessage): string {
	const aps = { "mutable-content": 1, alert: FALLBACK, sound: "default" };
	// The notification extension reads `wp` and decrypts it with the phone's key.
	const full = JSON.stringify({ aps, wp: { data: message.data, headers: message.headers } });
	const bytes = new TextEncoder().encode(full).length;
	if (bytes <= MAX_PAYLOAD) return full;
	console.warn(`[apns] push of ${bytes} bytes doesn't fit; sending without its content`);
	return JSON.stringify({ aps });
}

export class Apns {
	/** False without Apple's key: a dry run. */
	readonly enabled: boolean;
	private jwt: { token: string; at: number } | undefined;
	private key: Promise<CryptoKey> | undefined;

	constructor(
		private readonly settings: {
			/** The .p8 file's text. */
			key?: string;
			keyId?: string;
			teamId?: string;
			/** Where both of Apple's services are, for the tests. */
			host?: string;
		},
	) {
		this.enabled = Boolean(settings.key && settings.keyId && settings.teamId);
	}

	/** Sends one push to a phone. Throws an ApnsError when Apple refuses it. */
	async send(device: Device, body: string): Promise<void> {
		const host = this.settings.host ?? (device.sandbox ? HOSTS.sandbox : HOSTS.production);
		const response = await fetch(`${host}/3/device/${device.apnsToken}`, {
			method: "POST",
			headers: {
				authorization: `bearer ${await this.token()}`,
				"apns-topic": device.topic,
				"apns-push-type": "alert",
				"apns-priority": "10",
				"apns-expiration": String(Math.floor(Date.now() / 1000) + EXPIRES_S),
			},
			body,
		});
		if (response.status === 200) return void (await response.arrayBuffer());
		let reason = "";
		try {
			reason = ((await response.json()) as { reason?: string }).reason ?? "";
		} catch {}
		throw new ApnsError(response.status, reason);
	}

	/**
	 * Sends Apple a push for a token no phone has, to see whether Apple can be reached from here
	 * and what it makes of the key. Apple's answer says which: BadDeviceToken when it accepted
	 * the key, InvalidProviderToken when it didn't, MissingProviderToken in a dry run.
	 */
	async check(topic: string): Promise<{ reachable: boolean; status?: number; reason?: string; error?: string }> {
		try {
			const headers: Record<string, string> = { "apns-push-type": "alert", "apns-topic": topic };
			if (this.enabled) headers.authorization = `bearer ${await this.token()}`;
			const response = await fetch(`${this.settings.host ?? HOSTS.production}/3/device/${"0".repeat(64)}`, {
				method: "POST",
				headers,
				body: JSON.stringify({ aps: { alert: FALLBACK } }),
			});
			const reason = ((await response.json().catch(() => ({}))) as { reason?: string }).reason;
			return { reachable: true, status: response.status, reason };
		} catch (error) {
			return { reachable: false, error: String(error) };
		}
	}

	/** The token Apple wants with each push: signed with the push key, good for an hour. */
	private async token(): Promise<string> {
		const now = Date.now();
		if (this.jwt && now - this.jwt.at < JWT_TTL_MS) return this.jwt.token;
		const header = base64url(JSON.stringify({ alg: "ES256", kid: this.settings.keyId }));
		const claims = base64url(JSON.stringify({ iss: this.settings.teamId, iat: Math.floor(now / 1000) }));
		this.key ??= importKey(this.settings.key ?? "");
		const signature = await crypto.subtle.sign(
			{ name: "ECDSA", hash: "SHA-256" },
			await this.key,
			new TextEncoder().encode(`${header}.${claims}`),
		);
		this.jwt = { token: `${header}.${claims}.${base64url(new Uint8Array(signature))}`, at: now };
		return this.jwt.token;
	}
}

/** A .p8 file is a PKCS#8 key in PEM: base64 between two marker lines. */
function importKey(pem: string): Promise<CryptoKey> {
	const base64 = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
	const der = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
	return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

function base64url(value: string | Uint8Array): string {
	const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
	let text = "";
	for (const byte of bytes) text += String.fromCharCode(byte);
	return btoa(text).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
