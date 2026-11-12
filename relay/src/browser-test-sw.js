// The browser test's service worker (see README.md). When a push arrives, it shows it and tells
// the relay that one arrived and what fields it had: their names and kinds, never what they say.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
	const report = { browser: browserName(), hasContent: Boolean(event.data) };
	let body = "A push arrived, without content the browser could read.";
	try {
		const content = event.data.json();
		report.shape = shape(content);
		if (typeof content.message === "string") body = content.message;
	} catch {
		try {
			report.textLength = event.data.text().length;
		} catch {}
	}
	event.waitUntil(
		Promise.all([
			self.registration.showNotification("Unreeled push test", { body }),
			fetch(`/report/arrival/${report.browser}`, {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(report),
			}).catch(() => {}),
		]),
	);
});

function browserName() {
	const agent = self.navigator.userAgent;
	if (/Firefox\//.test(agent)) return "firefox";
	if (/Edg\//.test(agent)) return "edge";
	if (/Chrome\//.test(agent)) return "chromium";
	if (/Safari\//.test(agent)) return "safari";
	return "other";
}

/** A value's field names and kinds, without what they say. */
function shape(value, key = "") {
	if (Array.isArray(value)) return value.map((item) => shape(item));
	if (value && typeof value === "object") {
		return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, shape(item, name)]));
	}
	if (typeof value === "string") return key === "type" ? value : `string(${value.length})`;
	if (typeof value === "number") return key === "time" ? value : "number";
	return value === null ? null : typeof value;
}
