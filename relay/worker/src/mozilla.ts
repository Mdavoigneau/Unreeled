// The connection to Mozilla's push service: one WebSocket carrying a channel per phone. The same
// protocol as ../../src/mozilla-client.mjs speaks, on the WebSocket a Worker has.
//
// It registers channels that only accept pushes signed by one key (Instagram's), resumes the
// same identity and channels when the connection comes back, and hands each push, still
// encrypted, to `onNotification`. It never decrypts: only the phone has the keys.

/** A push as Mozilla delivers it: the body in base64url, and the header fields it came with. */
export interface PushMessage {
	data: string;
	headers: Record<string, string>;
	version: string;
}

export interface Callbacks {
	/** What to resume with: the identity Mozilla gave last time, and the channels under it. */
	identity(): { uaid: string | null; channelIDs: string[] };
	/** Mozilla gave a new identity. */
	saveIdentity(uaid: string): void;
	/** Mozilla said hello: the connection is up. */
	onHello(): void;
	onNotification(channelID: string, message: PushMessage): Promise<void>;
	/** Mozilla no longer knows the old identity: these channels, and their endpoints, are gone. */
	onReset(lostChannelIDs: string[]): Promise<void>;
}

const OPEN = 1;
const CONNECT_TIMEOUT_MS = 30_000;
const ANSWER_MS = 10_000; // how long Mozilla gets to answer a ping, as in Firefox
// How long registering a channel may take, waiting for a connection included: a phone gives up
// on pairing after 15 seconds, and should hear why before then.
const REGISTER_TIMEOUT_MS = 10_000;
const RECONNECT_MS = 2_000; // first wait before reconnecting; doubles while it keeps failing
const RECONNECT_MAX_MS = 60_000;
const STABLE_MS = 60_000; // a connection that lasted this long was a good one: the waits start over

export class MozillaClient {
	/** True between Mozilla's hello and the connection closing. */
	connected = false;

	private socket: WebSocket | null = null;
	private openedAt = 0;
	private helloAt = 0;
	private lastHeard = 0;
	private pingSentAt = 0;
	private reconnectMs = RECONNECT_MS;
	/** Set while waiting to reconnect: nothing else opens a connection meanwhile. */
	private reconnectTimer: number | null = null;
	private helloWaiters = new Set<() => void>();
	private registrations = new Map<string, { resolve(endpoint: string): void; reject(error: Error): void; timer: number }>();

	constructor(
		private readonly url: string,
		private readonly vapidKey: string,
		/** How long the connection may be quiet before a ping is sent on it. */
		private readonly quietMs: number,
		private readonly callbacks: Callbacks,
	) {}

	/** Opens the connection, unless it's open or opening. */
	connect(): void {
		if (this.socket) return;
		clearTimeout(this.reconnectTimer);
		this.reconnectTimer = null;
		let socket: WebSocket;
		try {
			socket = new WebSocket(this.url);
		} catch (error) {
			console.warn("[mozilla] couldn't connect:", String(error));
			return this.reconnectLater();
		}
		this.socket = socket;
		this.openedAt = Date.now();
		socket.addEventListener("open", () => {
			const { uaid, channelIDs } = this.callbacks.identity();
			console.log(`[mozilla] connected; hello ${uaid ? "(resume)" : "(new)"} with ${channelIDs.length} channel(s)`);
			socket.send(JSON.stringify({ messageType: "hello", use_webpush: true, uaid, channelIDs }));
		});
		socket.addEventListener("message", (event) => {
			if (this.socket === socket && typeof event.data === "string") void this.receive(socket, event.data);
		});
		const gone = () => this.closed(socket);
		socket.addEventListener("close", gone);
		socket.addEventListener("error", gone);
	}

	/**
	 * Run every minute. Reopens a connection that's gone, gives up on one that never finished
	 * opening, and sends a ping on one that has been quiet: Mozilla answers a `{}` with a `{}`.
	 *
	 * The ping does two jobs. A connection that carries nothing for about two minutes is closed
	 * somewhere along the way, so one a minute keeps it open; and a connection that doesn't
	 * answer by the next check is dead without having said so, and is replaced. Mozilla drops a
	 * client that pings more than once in 45 seconds, hence never sooner than `quietMs`.
	 */
	check(): void {
		const now = Date.now();
		if (!this.socket) {
			// Unless a reconnect is already due: the wait between attempts isn't cut short.
			if (this.reconnectTimer === null) this.connect();
			return;
		}
		if (!this.connected) {
			if (now - this.openedAt > CONNECT_TIMEOUT_MS) this.drop("never said hello");
			return;
		}
		if (this.pingSentAt && this.lastHeard < this.pingSentAt) {
			if (now - this.pingSentAt >= Math.min(ANSWER_MS, this.quietMs)) this.drop("no answer to a ping");
			return;
		}
		if (now - this.lastHeard >= this.quietMs) {
			this.pingSentAt = now;
			this.send({});
		}
	}

	/** Registers a new channel, for one phone. Resolves to its ID and its push endpoint. */
	async registerChannel(): Promise<{ channelID: string; endpoint: string }> {
		const deadline = Date.now() + REGISTER_TIMEOUT_MS;
		await this.hello(REGISTER_TIMEOUT_MS);
		const channelID = crypto.randomUUID();
		const endpoint = await new Promise<string>((resolve, reject) => {
			const timer = setTimeout(
				() => {
					this.registrations.delete(channelID);
					reject(new Error("register timeout"));
				},
				Math.max(0, deadline - Date.now()),
			);
			this.registrations.set(channelID, { resolve, reject, timer });
			this.send({ messageType: "register", channelID, key: this.vapidKey });
		});
		return { channelID, endpoint };
	}

	/** Drops a phone's channel: its endpoint stops accepting pushes. */
	unregisterChannel(channelID: string): void {
		this.send({ messageType: "unregister", channelID });
	}

	/**
	 * Resolves once Mozilla has said hello on the current connection, opening one if need be, and
	 * rejects after `ms`. A reconnect that's already due isn't brought forward: pairing calls
	 * mustn't cut the wait between attempts short.
	 */
	private hello(ms: number): Promise<void> {
		if (this.connected) return Promise.resolve();
		if (this.reconnectTimer === null) this.connect();
		return new Promise((resolve, reject) => {
			const waiter = () => {
				clearTimeout(timer);
				resolve();
			};
			// A waiter that has given up is let go, so that waiting through a long outage costs nothing.
			const timer = setTimeout(() => {
				this.helloWaiters.delete(waiter);
				reject(new Error("not connected to Mozilla"));
			}, ms);
			this.helloWaiters.add(waiter);
		});
	}

	private send(message: object): void {
		if (this.socket?.readyState === OPEN) this.socket.send(JSON.stringify(message));
	}

	private async receive(socket: WebSocket, text: string): Promise<void> {
		this.lastHeard = Date.now();
		this.pingSentAt = 0;
		let message: Record<string, unknown>;
		try {
			message = JSON.parse(text);
		} catch {
			return;
		}
		try {
			switch (message.messageType) {
				case "hello": {
					if (message.status !== 200 || typeof message.uaid !== "string") {
						console.warn(`[mozilla] hello refused (status ${String(message.status)})`);
						// Tried again after the usual wait, which grows while it keeps happening: never at once.
						return this.drop("hello refused", false);
					}
					// A different identity than the one resumed with: Mozilla no longer knows the old
					// one, and every channel registered under it, with its endpoint, is gone.
					const { uaid, channelIDs } = this.callbacks.identity();
					if (message.uaid !== uaid) this.callbacks.saveIdentity(message.uaid);
					this.connected = true;
					this.helloAt = Date.now();
					this.callbacks.onHello();
					console.log(`[mozilla] hello ok (uaid ${message.uaid.slice(0, 8)}…)`);
					const waiters = [...this.helloWaiters];
					this.helloWaiters.clear();
					for (const waiter of waiters) waiter();
					if (uaid && message.uaid !== uaid && channelIDs.length) {
						console.warn(`[mozilla] new uaid: ${channelIDs.length} channel(s) lost`);
						await this.callbacks.onReset(channelIDs);
					}
					break;
				}
				case "register": {
					const waiting = this.registrations.get(String(message.channelID));
					if (!waiting) break;
					this.registrations.delete(String(message.channelID));
					clearTimeout(waiting.timer);
					if (message.status === 200 && typeof message.pushEndpoint === "string") waiting.resolve(message.pushEndpoint);
					else waiting.reject(new Error(`register failed (status ${String(message.status)})`));
					break;
				}
				case "notification": {
					const channelID = String(message.channelID);
					try {
						await this.callbacks.onNotification(channelID, {
							data: String(message.data ?? ""),
							headers: (message.headers ?? {}) as Record<string, string>,
							version: String(message.version),
						});
					} finally {
						// Always, even for a channel no phone has, so that Mozilla stops redelivering.
						if (this.socket === socket) this.send({ messageType: "ack", updates: [{ channelID, version: message.version }] });
					}
					break;
				}
			}
		} catch (error) {
			console.warn("[mozilla] handling a message failed:", String(error));
		}
	}

	/**
	 * Closes the connection and opens another: at once when the minute's check found it dead,
	 * otherwise after the usual wait.
	 */
	private drop(why: string, now = true): void {
		const socket = this.socket;
		if (!socket) return;
		console.log(`[mozilla] dropping the connection: ${why}`);
		this.closed(socket, now);
		try {
			socket.close();
		} catch {}
	}

	private closed(socket: WebSocket, now = false): void {
		if (this.socket !== socket) return;
		// A connection that held for a minute was a good one, and the waits start over. Not at
		// every hello: a service that answered and then hung up would be tried every two seconds.
		if (this.connected && Date.now() - this.helloAt >= STABLE_MS) this.reconnectMs = RECONNECT_MS;
		this.socket = null;
		this.connected = false;
		this.pingSentAt = 0;
		// Whoever is waiting for a registration mustn't wait across a reconnect.
		for (const [channelID, waiting] of this.registrations) {
			clearTimeout(waiting.timer);
			waiting.reject(new Error("connection closed"));
			this.registrations.delete(channelID);
		}
		if (now) return this.connect();
		this.reconnectLater();
	}

	private reconnectLater(): void {
		clearTimeout(this.reconnectTimer);
		// Up to a quarter longer, by chance, so that attempts don't keep in step with anything.
		const wait = Math.round(this.reconnectMs * (1 + Math.random() / 4));
		console.log(`[mozilla] reconnecting in ${wait}ms`);
		this.reconnectTimer = setTimeout(() => {
			this.reconnectTimer = null;
			this.connect();
		}, wait);
		this.reconnectMs = Math.min(this.reconnectMs * 2, RECONNECT_MAX_MS);
	}
}
