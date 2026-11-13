import { DurableObject } from "cloudflare:workers";
import { Apns, ApnsError, type Device, payload } from "./apns.ts";
import { MozillaClient, type PushMessage } from "./mozilla.ts";

/** How often the object checks its connection to Mozilla, unless the tests say otherwise. */
const CHECK_SECONDS = 60;
/** How long that connection may be quiet before a ping is sent on it: at each check, in effect. */
const QUIET_SECONDS = 50;
/** How many pushes a dry run keeps for GET /outbox. */
const OUTBOX_SIZE = 20;

export interface Health {
	ok: true;
	devices: number;
	/** Whether the connection to Mozilla is up. */
	mozilla: boolean;
	apns: "live" | "dry-run";
	forwarded: number;
	failed: number;
	lastPushAt: string | null;
	/** How many times Cloudflare has started the object: once, plus once per restart. */
	starts: number;
	/** How many times the connection to Mozilla has been made. */
	connections: number;
	/** Since when the current connection has been up. */
	connectedSince: string | null;
}

export interface Pairing {
	apnsToken: string;
	sandbox: boolean;
	topic: string;
	/** A phone that paired before says who it is, to keep its endpoint. */
	deviceId?: string;
}

type Row = Record<string, SqlStorageValue>;

/**
 * The relay itself. There is one of these, and it is always running: it keeps the connection to
 * Mozilla's push service open, holds one record per phone, and forwards each push it receives,
 * unread, to that phone through Apple.
 *
 * Cloudflare restarts an object when it deploys new code or updates its own, which closes the
 * connection. An alarm, set again every time it fires, is what brings the object back: Mozilla
 * keeps what arrived meanwhile and delivers it once the connection resumes.
 *
 * What it stores is all it needs to reach a phone: a random ID, a channel at Mozilla with its
 * endpoint, and the phone's token at Apple. No keys, and nothing it could read.
 */
export class Relay extends DurableObject<Env> {
	private readonly sql: SqlStorage;
	private readonly mozilla: MozillaClient;
	private readonly apns: Apns;
	private readonly checkMs: number;
	/** A dry run's last pushes, as files `xcrun simctl push` takes. Only kept when OUTBOX is set. */
	private outbox: string[] = [];

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		this.sql = ctx.storage.sql;
		this.checkMs = (Number(env.CHECK_SECONDS) || CHECK_SECONDS) * 1000;
		this.apns = new Apns({ key: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, host: env.APNS_HOST });
		this.mozilla = new MozillaClient(env.AUTOPUSH_URL, env.INSTAGRAM_VAPID_KEY, (Number(env.QUIET_SECONDS) || QUIET_SECONDS) * 1000, {
			identity: () => ({ uaid: this.state("uaid"), channelIDs: this.rows("SELECT channel_id FROM devices").map((row) => String(row.channel_id)) }),
			saveIdentity: (uaid) => this.setState("uaid", uaid),
			// No logs are kept, so the object keeps count of how its connection fares.
			onHello: () => {
				this.count("connections");
				this.setState("connectedSince", new Date().toISOString());
			},
			onNotification: (channelID, message) => this.forward(channelID, message),
			onReset: (lost) => this.replaceChannels(lost),
		});

		void ctx.blockConcurrencyWhile(async () => {
			this.sql.exec(`CREATE TABLE IF NOT EXISTS devices (
				device_id TEXT PRIMARY KEY,
				channel_id TEXT NOT NULL UNIQUE,
				endpoint TEXT NOT NULL,
				apns_token TEXT NOT NULL,
				sandbox INTEGER NOT NULL,
				topic TEXT NOT NULL,
				created_at TEXT NOT NULL
			)`);
			this.sql.exec("CREATE TABLE IF NOT EXISTS state (name TEXT PRIMARY KEY, value TEXT NOT NULL)");
			this.count("starts");
			// Only if none is pending: the constructor also runs when an alarm wakes the object.
			if ((await ctx.storage.getAlarm()) === null) await ctx.storage.setAlarm(Date.now() + this.checkMs);
		});
		this.mozilla.connect();
	}

	/** Fires every minute, and after every restart. */
	override async alarm(): Promise<void> {
		// Before anything else, so that nothing below can end the chain.
		await this.ctx.storage.setAlarm(Date.now() + this.checkMs);
		this.mozilla.check();
	}

	health(): Health {
		return {
			ok: true,
			devices: Number(this.rows("SELECT COUNT(*) AS n FROM devices")[0]?.n ?? 0),
			mozilla: this.mozilla.connected,
			apns: this.apns.enabled ? "live" : "dry-run",
			forwarded: Number(this.state("forwarded") ?? 0),
			failed: Number(this.state("failed") ?? 0),
			lastPushAt: this.state("lastPushAt"),
			starts: Number(this.state("starts") ?? 0),
			connections: Number(this.state("connections") ?? 0),
			connectedSince: this.mozilla.connected ? this.state("connectedSince") : null,
		};
	}

	/**
	 * Pairs a phone: a new channel at Mozilla, whose endpoint the phone gives to Instagram with
	 * its own keys. A phone that pairs again keeps its channel, so the endpoint Instagram has
	 * stays good; only what the relay needs to reach the phone is refreshed.
	 */
	async pair(request: Pairing): Promise<{ status: number; body: Record<string, string> }> {
		const known = request.deviceId ? this.device("device_id", request.deviceId) : undefined;
		if (known) {
			this.sql.exec(
				"UPDATE devices SET apns_token = ?, sandbox = ?, topic = ? WHERE device_id = ?",
				request.apnsToken,
				request.sandbox ? 1 : 0,
				request.topic,
				known.deviceId,
			);
			return { status: 200, body: { deviceId: known.deviceId, endpoint: known.endpoint } };
		}
		if (this.health().devices >= (Number(this.env.MAX_DEVICES) || 1000)) return { status: 503, body: { error: "relay is full" } };

		const { channelID, endpoint } = await this.mozilla.registerChannel();
		const deviceId = crypto.randomUUID();
		this.sql.exec(
			"INSERT INTO devices (device_id, channel_id, endpoint, apns_token, sandbox, topic, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
			deviceId,
			channelID,
			endpoint,
			request.apnsToken,
			request.sandbox ? 1 : 0,
			request.topic,
			new Date().toISOString(),
		);
		console.log(`[pair] device ${deviceId.slice(0, 8)}… -> channel ${channelID.slice(0, 8)}…`);
		return { status: 200, body: { deviceId, endpoint } };
	}

	/** Forgets a phone and closes its channel. False for a phone the relay doesn't know. */
	unpair(deviceId: string): boolean {
		const device = this.device("device_id", deviceId);
		if (!device) return false;
		this.forget(device, "unpaired");
		return true;
	}

	/** Whether Apple can be reached from here, and what it makes of the key (see Apns.check). */
	checkApple(): Promise<{ reachable: boolean; status?: number; reason?: string; error?: string }> {
		return this.apns.check((this.env.APNS_TOPIC ?? "").split(",")[0]?.trim() ?? "");
	}

	/** A dry run's last pushes, newest last. */
	outboxPushes(): string[] {
		return this.outbox;
	}

	/** One push from Mozilla: on to the phone it's for, as it came. */
	private async forward(channelID: string, message: PushMessage): Promise<void> {
		const device = this.device("channel_id", channelID);
		if (!device) return;
		const body = payload(message);
		try {
			if (this.apns.enabled) {
				await this.send(device, body);
			} else {
				console.log(`[apns:dry-run] -> ${device.apnsToken.slice(0, 10)}… (${body.length} bytes; encoding ${message.headers.encoding})`);
				if (this.env.OUTBOX) {
					// "Simulator Target Bundle" tells `xcrun simctl push <device> <file>` which app it's for.
					this.outbox.push(JSON.stringify({ "Simulator Target Bundle": device.topic, ...JSON.parse(body) }, null, 2));
					this.outbox = this.outbox.slice(-OUTBOX_SIZE);
				}
			}
			this.count("forwarded");
			this.setState("lastPushAt", new Date().toISOString());
			console.log(`[forward] channel ${channelID.slice(0, 8)}… -> APNs`);
		} catch (error) {
			this.count("failed");
			console.warn(`[forward] APNs failed for ${channelID.slice(0, 8)}…: ${String(error)}`);
			// The app was deleted, or the token was never good: nothing can reach this phone again.
			if (error instanceof ApnsError && error.gone) this.forget(device, error.reason || "gone");
		}
	}

	private async send(device: Device, body: string): Promise<void> {
		try {
			await this.apns.send(device, body);
		} catch (error) {
			if (error instanceof ApnsError) throw error;
			// The request never got an answer: once more.
			await this.apns.send(device, body);
		}
	}

	/**
	 * Mozilla forgot the relay's identity, and with it every endpoint. Each phone gets a new
	 * channel right away; it learns the new endpoint the next time it pairs again, and gives it
	 * to Instagram.
	 */
	private async replaceChannels(lost: string[]): Promise<void> {
		for (const old of lost) {
			try {
				const { channelID, endpoint } = await this.mozilla.registerChannel();
				this.sql.exec("UPDATE devices SET channel_id = ?, endpoint = ? WHERE channel_id = ?", channelID, endpoint, old);
			} catch (error) {
				console.warn(`[reset] couldn't re-register ${old.slice(0, 8)}…: ${String(error)}`);
			}
		}
	}

	private forget(device: Device, why: string): void {
		this.mozilla.unregisterChannel(device.channelID);
		this.sql.exec("DELETE FROM devices WHERE device_id = ?", device.deviceId);
		console.log(`[forget] device ${device.deviceId.slice(0, 8)}…: ${why}`);
	}

	// Storage

	private rows(query: string, ...values: SqlStorageValue[]): Row[] {
		return this.sql.exec<Row>(query, ...values).toArray();
	}

	private device(column: "device_id" | "channel_id", value: string): Device | undefined {
		const row = this.rows(`SELECT * FROM devices WHERE ${column} = ?`, value)[0];
		if (!row) return undefined;
		return {
			deviceId: String(row.device_id),
			channelID: String(row.channel_id),
			endpoint: String(row.endpoint),
			apnsToken: String(row.apns_token),
			sandbox: row.sandbox === 1,
			topic: String(row.topic),
		};
	}

	private state(name: string): string | null {
		const row = this.rows("SELECT value FROM state WHERE name = ?", name)[0];
		return row ? String(row.value) : null;
	}

	private count(name: string): void {
		this.setState(name, String(Number(this.state(name) ?? 0) + 1));
	}

	private setState(name: string, value: string): void {
		this.sql.exec("INSERT INTO state (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value", name, value);
	}
}
