// Parts of a file, for the video.
//
// A browser playing a video asks for it in parts ("Range: bytes=0-1", then more), and Safari, on
// the iPhone too, plays one only from a server that answers with the part it asked for. Cloudflare's
// static files don't: they answer with the whole file
// (https://github.com/cloudflare/workers-sdk/issues/8967). So requests under /video/ come here
// first (cloudflare.config.ts), and this takes the file from the static files and sends the bytes
// asked for.
//
// Every other file on the site is still served as it is, without running any code. An address
// with no file comes here too, as it does for any site with a Worker, and gets the static files'
// own answer: the 404 page.

export default {
  async fetch(request, env) {
    const range = request.headers.get("Range");
    if (!range || (request.method !== "GET" && request.method !== "HEAD")) {
      return acceptingRanges(await env.ASSETS.fetch(request));
    }

    // The whole file, whatever the browser has of it already: a part is cut from the file as it
    // is now, so nothing about an earlier copy (If-None-Match, If-Range) is passed on.
    const whole = await env.ASSETS.fetch(new Request(request.url, { method: "GET" }));
    if (whole.status !== 200) return whole;
    const bytes = await whole.arrayBuffer();
    const part = partOf(range, bytes.byteLength);
    // More than one part at once, or something that isn't a range: the whole file is a right answer.
    if (part === undefined) return acceptingRanges(new Response(request.method === "HEAD" ? null : bytes, whole));

    const headers = new Headers(whole.headers);
    headers.set("Accept-Ranges", "bytes");
    if (part === null) {
      headers.set("Content-Range", `bytes */${bytes.byteLength}`);
      headers.delete("Content-Type");
      return new Response(null, { status: 416, headers });
    }
    const [first, last] = part;
    headers.set("Content-Range", `bytes ${first}-${last}/${bytes.byteLength}`);
    headers.set("Content-Length", String(last - first + 1));
    return new Response(request.method === "HEAD" ? null : bytes.slice(first, last + 1), { status: 206, headers });
  },
};

/** The first and last byte a Range header asks for, of a file `size` bytes long: null when the
 * file has no such bytes, undefined when the header isn't one range of bytes. */
export function partOf(range, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  if (!match || (match[1] === "" && match[2] === "")) return undefined;
  // "-500" is the last 500 bytes; "500-" is from byte 500 to the end.
  if (match[1] === "") {
    const length = Math.min(Number(match[2]), size);
    return length > 0 ? [size - length, size - 1] : null;
  }
  const first = Number(match[1]);
  const last = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
  return first < size && first <= last ? [first, last] : null;
}

/** A whole file, saying that parts of it can be asked for. */
function acceptingRanges(response) {
  if (response.status !== 200) return response;
  const headers = new Headers(response.headers);
  headers.set("Accept-Ranges", "bytes");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
