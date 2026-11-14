// The query list's signature, for tools/sign-queries.mjs and the website's build.
//
// Unreeled/API/Queries.json.sig says when the list was signed, with an Ed25519 signature over that
// time and the list's exact bytes:
//
//   "Unreeled query list\n" + signed + "\n" + the bytes of Queries.json
//
// The app checks it the same way (Unreeled/API/QueryUpdates.swift), with the public keys in its
// `publicKeys`. They're read from there, so the keys are listed in one place.

import { createPublicKey, verify } from "node:crypto";
import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
export const listFile = new URL("Unreeled/API/Queries.json", root);
export const signatureFile = new URL("Unreeled/API/Queries.json.sig", root);
const keysFile = new URL("Unreeled/API/QueryUpdates.swift", root);

/** A signing time, such as 2026-11-14T10:32:05Z: always this form, so that two compare as text. */
export const signingTime = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

/** What is signed: the time, then the list. */
export function signedMessage(signed, list) {
  return Buffer.concat([Buffer.from(`Unreeled query list\n${signed}\n`, "utf8"), list]);
}

/** The keys the app takes a list from, as QueryUpdates.swift lists them: raw Ed25519, base64. */
export async function publicKeys() {
  const swift = await readFile(keysFile, "utf8");
  const array = swift.match(/static let publicKeys(?:: \[String\])? = \[([^\]]*)\]/)?.[1] ?? "";
  const keys = [...array.matchAll(/"([A-Za-z0-9+/]{43}=)"/g)].map((match) => match[1]);
  if (!keys.length) throw new Error("QueryUpdates.swift lists no key in publicKeys");
  return keys;
}

/** A raw Ed25519 public key, base64, as one Node checks signatures with. */
export function publicKey(base64) {
  return createPublicKey({
    key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(base64, "base64").toString("base64url") },
    format: "jwk",
  });
}

/** When `list` was signed, if `signature` (the bytes of a Queries.json.sig) is one of the app's
 * keys' over it. Throws otherwise, saying why. */
export async function checkSignature(list, signature) {
  let parsed;
  try {
    parsed = JSON.parse(signature.toString("utf8"));
  } catch {
    throw new Error("Queries.json.sig isn't JSON");
  }
  const { signed, signature: value } = parsed ?? {};
  const bytes = typeof value === "string" ? Buffer.from(value, "base64") : Buffer.alloc(0);
  if (typeof signed !== "string" || !signingTime.test(signed) || bytes.length !== 64) {
    throw new Error("Queries.json.sig needs a signing time (signed) and a signature");
  }
  const message = signedMessage(signed, list);
  const keys = await publicKeys();
  if (!keys.some((key) => verify(null, message, publicKey(key), bytes))) {
    throw new Error("Queries.json.sig doesn't match Queries.json: sign the list (node tools/sign-queries.mjs)");
  }
  return signed;
}

/** What the app would turn down in the list, entry by entry, as QueryUpdates.validated does. */
export function listProblems(list) {
  let parsed;
  try {
    parsed = JSON.parse(list.toString("utf8"));
  } catch (error) {
    return [`not JSON: ${error.message}`];
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return ["not a JSON object of queries"];
  const names = Object.keys(parsed);
  const problems = names.length ? [] : ["no queries"];
  for (const name of names) {
    const entry = parsed[name];
    const wrong = (what) => problems.push(`${name}: ${what}`);
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      wrong("not an object");
      continue;
    }
    if (typeof entry.doc_id !== "string" || !/^[0-9]+$/.test(entry.doc_id)) wrong("doc_id isn't all digits");
    if (!["/api/graphql", "/graphql/query"].includes(entry.path)) wrong("path isn't /api/graphql or /graphql/query");
    if (entry.root_field != null && (typeof entry.root_field !== "string" || !/^[A-Za-z0-9_]*$/.test(entry.root_field))) {
      wrong("root_field has characters other than letters, digits and _");
    }
    if (!entry.providers || typeof entry.providers !== "object" || Array.isArray(entry.providers)) {
      wrong("providers isn't an object");
      continue;
    }
    for (const [flag, value] of Object.entries(entry.providers)) {
      if (!/^__relay_internal__pv__[A-Za-z0-9_]*$/.test(flag)) wrong(`${flag} doesn't start with __relay_internal__pv__`);
      if (typeof value !== "boolean" && !Number.isInteger(value)) wrong(`${flag} isn't true, false or a whole number`);
    }
  }
  return problems;
}
