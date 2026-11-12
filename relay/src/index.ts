import { env } from "cloudflare:workers";

// A stand-in for the push relay, for testing what Instagram sends to a web push address (see
// README.md). It records each request to the push address and answers as a push service does.
// It can't read the notifications: they're encrypted for a key that stays on the Mac running the
// test.

/** A web push message is at most about 4 KB. Anything much larger is cut. */
const maxBody = 16 * 1024;

export default {
	async fetch(request): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname.startsWith("/push/") && (await same(url.pathname.slice(6), env.PUSH_ID))) {
			return record(request, url);
		}
		if (url.pathname === "/log" && request.method === "GET") {
			const token = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
			if (await same(token, env.READ_TOKEN)) return log(url);
		}
		return new Response("Not found\n", { status: 404 });
	},
} satisfies ExportedHandler;

/** Keeps a request to the push address: when, from where, its headers and its body as sent. */
async function record(request: Request, url: URL): Promise<Response> {
	const body = new Uint8Array(await request.arrayBuffer());
	const headers = Object.fromEntries(request.headers);
	const sender = {
		ip: request.headers.get("CF-Connecting-IP"),
		asn: request.cf?.asn,
		network: request.cf?.asOrganization,
		country: request.cf?.country,
	};
	await table();
	await env.DB.prepare("INSERT INTO pushes (received, method, headers, sender, bytes, body) VALUES (?, ?, ?, ?, ?, ?)")
		.bind(
			new Date().toISOString(),
			request.method,
			JSON.stringify(headers),
			JSON.stringify(sender),
			body.length,
			base64(body.subarray(0, maxBody)),
		)
		.run();
	if (request.method !== "POST") {
		return new Response(null, { status: 405, headers: { Allow: "POST" } });
	}
	// What a push service answers once it has the message (RFC 8030, section 5).
	return new Response(null, {
		status: 201,
		headers: {
			Location: `${url.origin}/message/${crypto.randomUUID()}`,
			TTL: request.headers.get("TTL") ?? "0",
		},
	});
}

/** What was recorded after the entry numbered `after`, oldest first. */
async function log(url: URL): Promise<Response> {
	await table();
	const after = Number(url.searchParams.get("after")) || 0;
	const { results } = await env.DB.prepare("SELECT * FROM pushes WHERE id > ? ORDER BY id LIMIT 200").bind(after).all();
	return Response.json(
		results.map((row) => ({
			...row,
			headers: JSON.parse(String(row.headers)),
			sender: JSON.parse(String(row.sender)),
		})),
	);
}

let tableReady: Promise<unknown> | undefined;

/** Creates the table the first time, so the test needs no setup step besides deploying. */
async function table() {
	tableReady ??= env.DB.exec(
		"CREATE TABLE IF NOT EXISTS pushes (id INTEGER PRIMARY KEY AUTOINCREMENT, received TEXT NOT NULL, method TEXT NOT NULL, headers TEXT NOT NULL, sender TEXT NOT NULL, bytes INTEGER NOT NULL, body TEXT NOT NULL)",
	).catch((error: unknown) => {
		tableReady = undefined;
		throw error;
	});
	await tableReady;
}

/** Whether two secrets match, compared in constant time. */
async function same(a: string, b: string): Promise<boolean> {
	const encoder = new TextEncoder();
	const [x, y] = await Promise.all([a, b].map((text) => crypto.subtle.digest("SHA-256", encoder.encode(text))));
	return crypto.subtle.timingSafeEqual(x!, y!);
}

function base64(bytes: Uint8Array): string {
	let text = "";
	for (const byte of bytes) text += String.fromCharCode(byte);
	return btoa(text);
}
