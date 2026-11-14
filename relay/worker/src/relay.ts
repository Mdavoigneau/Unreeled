import { DurableObject } from "cloudflare:workers";
import { Apns, ApnsError, type Device, payload } from "./apns.ts";
import { MozillaClient, type PushMessage } from "./mozilla.ts";

/** How often the object checks its connection to Mozilla, unless the tests say otherwise. */
const CHECK_SECONDS = 60;
/** How long that connection may be quiet before a ping is sent on it: at each check, in effect. */
const QUIET_SECONDS = 50;
/** How many pushes a dry run keeps for GET /outbox. */
const OUTBOX_SIZE = 20;
/** How long a phone's record lasts with nothing to show the phone is real, unless DEVICE_TTL_DAYS says. */
const DEVICE_TTL_DAYS = 30;
/** How often the alarm forgets the phones that have run out, unless the tests say otherwise. */
const SWEEP_SECONDS = 3600;
const DAY_MS = 24 * 3600 * 1000;

const FULL = { status: 503, body: { error: "relay is full" } };
const UNKNOWN_TO_APPLE = { status: 400, body: { error: "Apple doesn't know this phone" } };

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

/** What GET /health says to whoever has the pairing token: whether the relay is up, no more. */
export type Liveness = Pick<Health, "ok" | "mozilla" | "apns">;

export interface Pairing {
	apnsToken: string;
	sandbox: boolean;
	topic: string;
	/** A phone that paired before says who it is, to keep its endpoint. */
	deviceId?: string;
}

type Row = Record<string, SqlStorageValue>;

/** A phone's record. */
type Phone = Device & {
	/**
	 * When the phone was last shown to be real: paired, Apple took a push for it, or it paired
	 * again and Apple didn't refuse its token (in a dry run, it paired again). A record not renewed
	 * for DEVICE_TTL_DAYS is forgotten.
	 */
	lastSeen: string;
};

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
 * endpoint, the phone's token at Apple, and when the phone was last shown to be real. No keys,
 * and nothing it could read.
 */
export class Relay extends DurableObject<Env> {
	private readonly sql: SqlStorage;
	private readonly mozilla: MozillaClient;
	private readonly apns: Apns;
	private readonly checkMs: number;
	private readonly sweepMs: number;
	private readonly topics: string[];
	private sweptAt = 0;
	/** A dry run's last pushes, as files `xcrun simctl push` takes. Only kept when OUTBOX is set. */
	private outbox: string[] = [];

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		this.sql = ctx.storage.sql;
		this.checkMs = (Number(env.CHECK_SECONDS) || CHECK_SECONDS) * 1000;
		this.sweepMs = (Number(env.SWEEP_SECONDS) || SWEEP_SECONDS) * 1000;
		this.topics = (env.APNS_TOPIC ?? "")
			.split(",")
			.map((topic) => topic.trim())
			.filter(Boolean);
		this.apns = new Apns({
			key: env.APNS_KEY,
			keyId: env.APNS_KEY_ID,
			teamId: env.APNS_TEAM_ID,
			topics: this.topics,
			host: env.APNS_HOST,
			answerMs: Number(env.APPLE_SECONDS) * 1000 || undefined,
		});
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
				created_at TEXT NOT NULL,
				last_seen TEXT
			)`);
			// Records from before there was a last_seen start their time now, so that the change
			// drops no phone.
			const columns = this.rows("PRAGMA table_info(devices)").map((row) => String(row.name));
			if (!columns.includes("last_seen")) this.sql.exec("ALTER TABLE devices ADD COLUMN last_seen TEXT");
			this.sql.exec("UPDATE devices SET last_seen = ? WHERE last_seen IS NULL", new Date().toISOString());
			this.sql.exec("CREATE INDEX IF NOT EXISTS devices_by_token ON devices (apns_token, topic)");
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
		if (Date.now() - this.sweptAt >= this.sweepMs) {
			this.sweptAt = Date.now();
			this.sweep();
		}
	}

	/** For whoever has the pairing token: whether the relay is up. */
	liveness(): Liveness {
		return { ok: true, mozilla: this.mozilla.connected, apns: this.apns.enabled ? "live" : "dry-run" };
	}

	/** For whoever runs the relay. */
	health(): Health {
		return {
			ok: true,
			devices: this.deviceCount(),
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
	 *
	 * A place is only for a token Apple knows for the app, and a token has one place: pairing
	 * afresh replaces the token's old record, and never hands out its ID.
	 */
	async pair(request: Pairing): Promise<{ status: number; body: Record<string, string> }> {
		let asked = false;
		const known = request.deviceId ? this.device("device_id", request.deviceId) : undefined;
		if (known) {
			// Whoever made a record can pair it again at will, so pairing again keeps the record
			// going only for a token Apple doesn't refuse: asked when the token changes, and at most
			// once a day otherwise. A dry run can't ask, and takes the phone's word for it.
			const changed = known.apnsToken !== request.apnsToken || known.sandbox !== request.sandbox || known.topic !== request.topic;
			const due = !(Date.now() - Date.parse(known.lastSeen) < DAY_MS);
			if (this.apns.enabled && (changed || due)) {
				asked = true;
				if (await this.apns.refuses(request)) {
					const current = this.device("device_id", known.deviceId);
					if (current) this.forget(current, "Apple doesn't know its token");
					return UNKNOWN_TO_APPLE;
				}
			}
			// Unless it was forgotten meanwhile: then it's paired afresh, below.
			const current = this.device("device_id", known.deviceId);
			if (current) {
				for (const other of this.holders(request)) if (other.deviceId !== current.deviceId) this.forget(other, "its token paired again");
				this.sql.exec(
					"UPDATE devices SET apns_token = ?, sandbox = ?, topic = ?, last_seen = ? WHERE device_id = ?",
					request.apnsToken,
					request.sandbox ? 1 : 0,
					request.topic,
					asked || !this.apns.enabled ? new Date().toISOString() : current.lastSeen,
					current.deviceId,
				);
				return { status: 200, body: { deviceId: current.deviceId, endpoint: current.endpoint } };
			}
		}

		// A phone whose token has a record replaces it, so even a full relay takes it.
		const max = Number(this.env.MAX_DEVICES) || 1000;
		if (this.deviceCount() - this.holders(request).length >= max) return FULL;
		// Apple answers a made-up token with BadDeviceToken. A dry run can't ask.
		if (this.apns.enabled && !asked && (await this.apns.refuses(request))) return UNKNOWN_TO_APPLE;
		const { channelID, endpoint } = await this.mozilla.registerChannel();

		// Other pairings went on during the waits, the same token's among them. So the place is
		// decided only now, in one step: the token's old record goes, and the new one is kept if
		// there's room for it.
		const old = this.holders(request);
		if (this.deviceCount() - old.length >= max) {
			this.mozilla.unregisterChannel(channelID);
			return FULL;
		}
		for (const device of old) this.forget(device, "paired afresh");
		const deviceId = crypto.randomUUID();
		const now = new Date().toISOString();
		this.sql.exec(
			"INSERT INTO devices (device_id, channel_id, endpoint, apns_token, sandbox, topic, created_at, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
			deviceId,
			channelID,
			endpoint,
			request.apnsToken,
			request.sandbox ? 1 : 0,
			request.topic,
			now,
			now,
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
		return this.apns.check(this.topics[0] ?? "");
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
				// Apple took it, so the phone is real: its record lives on.
				this.sql.exec("UPDATE devices SET last_seen = ? WHERE device_id = ?", new Date().toISOString(), device.deviceId);
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

	/**
	 * Forgets the phones nothing has shown to be real for DEVICE_TTL_DAYS: no push Apple took,
	 * and no pairing again that Apple didn't refuse. A real phone that was only quiet pairs afresh
	 * the next time its app is opened, and gives Instagram its new endpoint.
	 */
	private sweep(): void {
		const days = Number(this.env.DEVICE_TTL_DAYS) > 0 ? Number(this.env.DEVICE_TTL_DAYS) : DEVICE_TTL_DAYS;
		const before = new Date(Date.now() - days * DAY_MS).toISOString();
		for (const row of this.rows("SELECT device_id FROM devices WHERE last_seen < ?", before)) {
			const device = this.device("device_id", String(row.device_id));
			if (device) this.forget(device, `not seen for ${days} days`);
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

	private deviceCount(): number {
		return Number(this.rows("SELECT COUNT(*) AS n FROM devices")[0]?.n ?? 0);
	}

	private device(column: "device_id" | "channel_id", value: string): Phone | undefined {
		const row = this.rows(`SELECT * FROM devices WHERE ${column} = ?`, value)[0];
		return row && phone(row);
	}

	/** The records a phone's token has for an app: one, or more left from before a token had only one. */
	private holders(request: Pick<Device, "apnsToken" | "topic">): Phone[] {
		return this.rows("SELECT * FROM devices WHERE apns_token = ? AND topic = ?", request.apnsToken, request.topic).map(phone);
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

function phone(row: Row): Phone {
	return {
		deviceId: String(row.device_id),
		channelID: String(row.channel_id),
		endpoint: String(row.endpoint),
		apnsToken: String(row.apns_token),
		sandbox: row.sandbox === 1,
		topic: String(row.topic),
		lastSeen: String(row.last_seen),
	};
}
