import { env } from "cloudflare:workers";
import browserTestPage from "./browser-test.html?raw";
import browserTestWorker from "./browser-test-sw.js?raw";

// A stand-in for the push relay, for testing what Instagram sends to a web push address (see
// README.md). It records each request to the push address and answers as a push service does.
// It can't read the notifications: they're encrypted for a key that stays on the Mac running the
// test.
//
// Requests to any other address are recorded too, without who sent them: if Instagram calls
// somewhere unexpected, the log should show it.
//
// /browser-test is a page where a real browser makes a push address with Instagram's key, to
// see which push services Instagram sends to. The page and its service worker report to
// /report/…: the address, and later that a push arrived.

/** A web push message is at most about 4 KB. Anything much larger is cut. */
const maxBody = 16 * 1024;

export default {
	async fetch(request): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/log" && request.method === "GET") {
			const token = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
			if (await same(token, env.READ_TOKEN)) return log(url);
		}
		// The push address, with an optional label after it that says which registration it's for:
		// /push/<secret> or /push/<secret>/phone.
		const push = url.pathname.match(/^\/push\/([^/]+)(?:\/([a-z0-9-]{1,24}))?$/);
		if (push && (await same(push[1]!, env.PUSH_ID))) {
			await record(request, { label: push[2] ?? "" });
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
		if (request.method === "GET" && url.pathname === "/browser-test") {
			return new Response(browserTestPage, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
		}
		if (request.method === "GET" && url.pathname === "/sw.js") {
			return new Response(browserTestWorker, { headers: { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-store" } });
		}
		await record(request, { path: url.pathname.slice(0, 200) + (url.search ? "?…" : "") });
		if (request.method === "POST" && url.pathname.startsWith("/report/")) {
			return new Response(null, { status: 204 });
		}
		return new Response("Not found\n", { status: 404 });
	},
} satisfies ExportedHandler;

/**
 * Keeps a request: when, from which network, its headers and its body as sent. One to the push
 * address is kept with its label and the sender's address. Any other is kept with its path, and
 * without the sender's address or the headers that carry it.
 */
async function record(request: Request, to: { label: string } | { path: string }): Promise<void> {
	const body = new Uint8Array(await request.arrayBuffer());
	const isPush = "label" in to;
	const headers = Object.fromEntries(request.headers);
	if (!isPush) {
		for (const name of ["cf-connecting-ip", "x-real-ip", "x-forwarded-for", "true-client-ip"]) delete headers[name];
	}
	const sender = {
		ip: isPush ? request.headers.get("CF-Connecting-IP") : null,
		asn: request.cf?.asn,
		network: request.cf?.asOrganization,
		country: request.cf?.country,
	};
	await table();
	await env.DB.prepare(
		"INSERT INTO pushes (received, method, headers, sender, bytes, body, label, path) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
	)
		.bind(
			new Date().toISOString(),
			request.method,
			JSON.stringify(headers),
			JSON.stringify(sender),
			body.length,
			base64(body.subarray(0, maxBody)),
			isPush ? to.label : "",
			isPush ? "" : to.path,
		)
		.run();
}

/** What was recorded after the entry numbered `after`, oldest first. */
async function log(url: URL): Promise<Response> {
	await table();
	const after = Number(url.searchParams.get("after")) || 0;
	const { results } = await env.DB.prepare("SELECT * FROM pushes WHERE id > ? ORDER BY id LIMIT 500").bind(after).all();
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
	tableReady ??= (async () => {
		await env.DB.exec(
			"CREATE TABLE IF NOT EXISTS pushes (id INTEGER PRIMARY KEY AUTOINCREMENT, received TEXT NOT NULL, method TEXT NOT NULL, headers TEXT NOT NULL, sender TEXT NOT NULL, bytes INTEGER NOT NULL, body TEXT NOT NULL, label TEXT NOT NULL DEFAULT '', path TEXT NOT NULL DEFAULT '')",
		);
		// A table made before these columns existed gets them. On any other, this fails and is ignored.
		for (const column of ["label", "path"]) {
			await env.DB.exec(`ALTER TABLE pushes ADD COLUMN ${column} TEXT NOT NULL DEFAULT ''`).catch(() => {});
		}
	})().catch((error: unknown) => {
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
