// Unreeled's notification relay, as a Cloudflare Worker (see ../README.md).
//
// This is what a phone talks to: it pairs by POSTing its token at Apple's push service, and gets
// the push endpoint to give Instagram. Everything that lasts is in the one `Relay` object.

export { Relay } from "./relay.ts";

const MAX_BODY = 4096; // bytes; a pairing request is a few hundred

export default {
	async fetch(request, env, ctx): Promise<Response> {
		const { pathname } = new URL(request.url);
		const relay = ctx.exports.Relay.getByName("relay");

		// Who is asking. The pairing token is the one the app's build carries. The operator token,
		// if one is set, is for whoever runs the relay, and is never the pairing token, which every
		// build carries. A deployed relay always has a pairing token (the config requires one), and
		// an empty one lets no one in; only on this machine, where it's a setting that can be left
		// out, is pairing open.
		const operator = env.OPERATOR_TOKEN !== env.PAIRING_TOKEN && (await carries(request, env.OPERATOR_TOKEN));
		const admitted = env.PAIRING_TOKEN === undefined || (await carries(request, env.PAIRING_TOKEN));

		// Health is open, but without a token it only says the Worker answers: the object isn't
		// asked, so a stranger's requests never reach the one object every phone depends on. The
		// counts and times are for whoever runs the relay.
		if (request.method === "GET" && pathname === "/health") {
			if (!operator && !admitted) return Response.json({ ok: true });
			try {
				return Response.json(operator ? await relay.health() : await relay.liveness());
			} catch (error) {
				console.warn("[health] failed:", String(error));
				return answer(503, { ok: false, error: "the relay isn't answering" });
			}
		}

		// For whoever runs the relay: can it reach Apple, and does Apple take its key? Each call
		// sends Apple a request, so it counts against the same limit as pairing.
		if (request.method === "GET" && pathname === "/apple") {
			if (!operator) return answer(401, { error: "unauthorized" });
			if (!(await withinLimit(env, request))) return answer(429, { error: "too many calls" });
			return Response.json(await relay.checkApple());
		}

		if (!admitted) return answer(401, { error: "unauthorized" });

		if (request.method === "POST" && pathname === "/pair") {
			// A phone pairs when notifications are turned on, and once a day after that.
			if (!(await withinLimit(env, request))) return answer(429, { error: "too many pairing calls" });
			const body = await read(request);
			const apnsToken = typeof body?.apnsToken === "string" ? body.apnsToken.toLowerCase() : "";
			if (!/^[0-9a-f]{64,200}$/.test(apnsToken)) return answer(400, { error: "apnsToken must be the device token in hex" });
			// The bundle IDs this relay serves; none set (a dry run) accepts any.
			const topics = (env.APNS_TOPIC ?? "").split(",").map((topic) => topic.trim()).filter(Boolean);
			const topic = typeof body?.topic === "string" && body.topic ? body.topic : (topics[0] ?? "");
			if (topics.length && !topics.includes(topic)) return answer(400, { error: "this relay doesn't serve that app" });
			try {
				const paired = await relay.pair({
					apnsToken,
					topic,
					// A phone that doesn't say is on Apple's production service.
					sandbox: body?.sandbox === true,
					deviceId: typeof body?.deviceId === "string" ? body.deviceId : undefined,
				});
				return answer(paired.status, paired.body);
			} catch (error) {
				console.warn("[pair] failed:", String(error));
				return answer(500, { error: "internal" });
			}
		}

		if (request.method === "POST" && pathname === "/unpair") {
			if (!(await withinLimit(env, request))) return answer(429, { error: "too many pairing calls" });
			const body = await read(request);
			const known = typeof body?.deviceId === "string" && (await relay.unpair(body.deviceId));
			return known ? answer(200, { ok: true }) : answer(404, { error: "unknown device" });
		}

		// On a developer's machine: what a dry run would have sent to Apple.
		if (env.OUTBOX && request.method === "GET" && pathname === "/outbox") return Response.json(await relay.outboxPushes());

		return answer(404, { error: "not found" });
	},
} satisfies ExportedHandler<Env>;

function answer(status: number, body: object): Response {
	return Response.json(body, { status });
}

/**
 * Whether a client may make another limited call this minute. A client is its address, or for
 * IPv6 the /56 the address is in: one home, or one phone, is often given a whole block of them.
 */
async function withinLimit(env: Env, request: Request): Promise<boolean> {
	if (!env.PAIRING_LIMIT) return true;
	const { success } = await env.PAIRING_LIMIT.limit({ key: client(request.headers.get("CF-Connecting-IP") ?? "") });
	return success;
}

/** The pairing limit's name for an address: an IPv4 address as it is, an IPv6 one by its /56. */
function client(address: string): string {
	const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address);
	if (mapped) return mapped[1]!;
	if (!address.includes(":")) return address;
	const [head = "", tail = ""] = address.toLowerCase().split("%")[0]!.split("::");
	const left = head ? head.split(":") : [];
	const right = tail ? tail.split(":") : [];
	const groups = [...left, ...Array<string>(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
	// 56 bits: three groups of sixteen, and the first half of the fourth.
	const prefix = groups.slice(0, 4).map((group) => parseInt(group, 16) || 0);
	prefix[3] = prefix[3]! & 0xff00;
	return `${prefix.map((group) => group.toString(16)).join(":")}::/56`;
}

/** A request's JSON body, or null when it's too long or isn't JSON. */
async function read(request: Request): Promise<Record<string, unknown> | null> {
	if (Number(request.headers.get("Content-Length")) > MAX_BODY) return null;
	// Read as it comes, and given up on past the limit: a body sent without a length isn't taken
	// whole first.
	let text = "";
	if (request.body) {
		const reader = request.body.getReader();
		const decoder = new TextDecoder();
		let size = 0;
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			size += value.byteLength;
			if (size > MAX_BODY) {
				await reader.cancel();
				return null;
			}
			text += decoder.decode(value, { stream: true });
		}
		text += decoder.decode();
	}
	try {
		const body: unknown = JSON.parse(text || "{}");
		return typeof body === "object" && body !== null ? (body as Record<string, unknown>) : null;
	} catch {
		return null;
	}
}

/** Whether a request carries `Bearer <token>`, compared in constant time. An empty token matches nothing. */
async function carries(request: Request, token: string | undefined): Promise<boolean> {
	return Boolean(token) && (await same(request.headers.get("Authorization") ?? "", `Bearer ${token}`));
}

/** Whether two secrets match, compared in constant time. */
async function same(a: string, b: string): Promise<boolean> {
	const encoder = new TextEncoder();
	const [x, y] = await Promise.all([a, b].map((text) => crypto.subtle.digest("SHA-256", encoder.encode(text))));
	return crypto.subtle.timingSafeEqual(x!, y!);
}
