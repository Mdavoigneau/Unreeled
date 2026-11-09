// Debug builds only (see NetworkRecorder.swift). Wraps the page's fetch and XMLHttpRequest
// to log instagram.com's API calls. Responses are reduced to their shape (field names and
// value types, no values) and tokens in request bodies are masked.
(() => {
  const send = (entry) => window.webkit?.messageHandlers?.recorder?.postMessage(entry);

  // API calls only, not the site's own logging.
  const isAPI = (path) =>
    (path.startsWith('/api/') || path.startsWith('/graphql')) && !/logging|\/bz\b|falco/.test(path);

  const shape = (value, depth = 0) => {
    if (depth > 9) return '…';
    if (Array.isArray(value)) {
      if (!value.length) return [];
      let merged = null;
      let other = '?';
      for (const item of value.slice(0, 20)) {
        const s = shape(item, depth + 1);
        if (s && typeof s === 'object' && !Array.isArray(s)) merged = { ...s, ...merged };
        else other = s;
      }
      return [merged ?? other, value.length];
    }
    if (value && typeof value === 'object') {
      const out = {};
      for (const key of Object.keys(value)) out[key] = shape(value[key], depth + 1);
      return out;
    }
    return value === null ? 'null' : typeof value;
  };

  // GraphQL responses can stream several JSON objects, one per line.
  const parse = (text) => {
    const clean = text.replace(/^for \(;;\);/, '');
    try {
      return JSON.parse(clean);
    } catch {}
    try {
      return JSON.parse(clean.split('\n')[0]);
    } catch {}
    return null;
  };

  // Session tokens and anything from the login form are masked. Variables are kept whole: they
  // hold cursors, IDs and flags.
  const MASKED = /^(fb_dtsg|fb_dtsg_ag|lsd|jazoest)$|pass|username|email|phone/i;
  const describeBody = (body) => {
    if (typeof body !== 'string' || !body.includes('=')) return undefined;
    const out = {};
    for (const [key, value] of new URLSearchParams(body)) {
      out[key] = MASKED.test(key) ? '·' : value.slice(0, key === 'variables' ? 20000 : 800);
    }
    return out;
  };

  // Streamed GraphQL responses: what the later parts carry (their label and path, no data).
  const describeParts = (text) =>
    text.replace(/^for \(;;\);/, '').split('\n').filter(Boolean).slice(1, 6).map((line) => {
      try {
        const part = JSON.parse(line);
        return { label: part.label, path: part.path, keys: Object.keys(part) };
      } catch {
        return '(not JSON)';
      }
    });

  const describeHeaders = (headers) => {
    const out = {};
    for (const [key, value] of Object.entries(headers ?? {})) {
      if (/^x-/i.test(key)) out[key.toLowerCase()] = /csrf|lsd|dtsg/i.test(key) ? '·' : String(value);
    }
    return out;
  };

  // A URL's query, with the same session tokens masked as in bodies.
  const describeQuery = (search) => {
    if (!search) return '';
    const params = new URLSearchParams(search);
    for (const key of [...params.keys()]) {
      if (MASKED.test(key)) params.set(key, '·');
    }
    return '?' + params.toString();
  };

  const record = (method, url, headers, body, status, text) => {
    const u = new URL(url, location.href);
    if (u.origin !== location.origin || !isAPI(u.pathname)) return;
    const json = parse(text ?? '');
    send({
      time: new Date().toISOString(),
      page: location.pathname,
      method,
      path: u.pathname,
      query: describeQuery(u.search),
      headers: describeHeaders(headers),
      body: describeBody(body),
      status,
      bytes: (text ?? '').length,
      shape: json ? shape(json) : '(not JSON)',
      parts: describeParts(text ?? ''),
    });
  };

  const originalFetch = window.fetch;
  window.fetch = async function (input, init = {}) {
    const response = await originalFetch.apply(this, arguments);
    try {
      const url = typeof input === 'string' ? input : input.url;
      const method = (init.method ?? input?.method ?? 'GET').toUpperCase();
      const headers = init.headers instanceof Headers ? Object.fromEntries(init.headers) : init.headers;
      response.clone().text().then((text) => record(method, url, headers, init.body, response.status, text));
    } catch {}
    return response;
  };

  // Live connections (chat): where they go and how many frames, never what's in them.
  const NativeWebSocket = window.WebSocket;
  window.WebSocket = function (url, protocols) {
    const socket = protocols === undefined ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
    const u = new URL(url, location.href);
    const where = u.origin + u.pathname;
    const sizeOf = (data) => data?.byteLength ?? data?.size ?? data?.length ?? 0;
    let received = 0;
    send({ time: new Date().toISOString(), page: location.pathname, websocket: where, event: 'open' });
    const nativeSend = socket.send;
    socket.send = function (data) {
      send({ time: new Date().toISOString(), page: location.pathname, websocket: where, event: 'send', bytes: sizeOf(data), received });
      return nativeSend.apply(this, arguments);
    };
    socket.addEventListener('message', () => { received += 1; });
    socket.addEventListener('close', () => {
      send({ time: new Date().toISOString(), page: location.pathname, websocket: where, event: 'close', received });
    });
    return socket;
  };
  window.WebSocket.prototype = NativeWebSocket.prototype;
  Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });

  const { open, send: xhrSend, setRequestHeader } = XMLHttpRequest.prototype;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__recorded = { method: String(method).toUpperCase(), url: String(url), headers: {} };
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (key, value) {
    if (this.__recorded) this.__recorded.headers[key] = value;
    return setRequestHeader.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    const call = this.__recorded;
    if (call) {
      this.addEventListener('loadend', () => {
        try {
          const text =
            this.responseType === 'json' ? JSON.stringify(this.response) :
            this.responseType === '' || this.responseType === 'text' ? this.responseText : '';
          record(call.method, call.url, call.headers, body, this.status, text);
        } catch {}
      });
    }
    return xhrSend.apply(this, arguments);
  };
})();
