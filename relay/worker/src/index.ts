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

		// Health is open; everything else needs the pairing token, if one is set.
		if (request.method === "GET" && pathname === "/health") return Response.json(await relay.health());
		if (env.PAIRING_TOKEN && !(await same(request.headers.get("Authorization") ?? "", `Bearer ${env.PAIRING_TOKEN}`))) {
			return answer(401, { error: "unauthorized" });
		}

		if (request.method === "POST" && pathname === "/pair") {
			// A phone pairs when notifications are turned on, and once a day after that.
			const address = request.headers.get("CF-Connecting-IP") ?? "";
			if (env.PAIRING_LIMIT && !(await env.PAIRING_LIMIT.limit({ key: address })).success) {
				return answer(429, { error: "too many pairing calls" });
			}
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
			const body = await read(request);
			const known = typeof body?.deviceId === "string" && (await relay.unpair(body.deviceId));
			return known ? answer(200, { ok: true }) : answer(404, { error: "unknown device" });
		}

		// For whoever runs the relay: can it reach Apple, and does Apple take its key?
		if (request.method === "GET" && pathname === "/apple") return Response.json(await relay.checkApple());

		// On a developer's machine: what a dry run would have sent to Apple.
		if (env.OUTBOX && request.method === "GET" && pathname === "/outbox") return Response.json(await relay.outboxPushes());

		return answer(404, { error: "not found" });
	},
} satisfies ExportedHandler<Env>;

function answer(status: number, body: object): Response {
	return Response.json(body, { status });
}

/** A request's JSON body, or null when it's too long or isn't JSON. */
async function read(request: Request): Promise<Record<string, unknown> | null> {
	if (Number(request.headers.get("Content-Length")) > MAX_BODY) return null;
	const text = await request.text();
	if (text.length > MAX_BODY) return null;
	try {
		const body: unknown = JSON.parse(text || "{}");
		return typeof body === "object" && body !== null ? (body as Record<string, unknown>) : null;
	} catch {
		return null;
	}
}

/** Whether two secrets match, compared in constant time. */
async function same(a: string, b: string): Promise<boolean> {
	const encoder = new TextEncoder();
	const [x, y] = await Promise.all([a, b].map((text) => crypto.subtle.digest("SHA-256", encoder.encode(text))));
	return crypto.subtle.timingSafeEqual(x!, y!);
}
