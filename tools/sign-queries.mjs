// Signs the query list, so that installed apps take it (docs/MAINTAINING.md).
//
//   node tools/sign-queries.mjs           checks Unreeled/API/Queries.json as the app would, then
//                                         writes its signature, Queries.json.sig
//   node tools/sign-queries.mjs check     says whether Queries.json.sig matches the list
//   node tools/sign-queries.mjs new-key   makes a key pair, for a new maintainer or a lost key, and
//                                         prints the public key, for QueryUpdates.swift
//
// The private key is ~/.config/unreeled/query-signing/private-key.pem, or the file named by
// UNREELED_QUERY_KEY. Whoever has it chooses which of Instagram's queries every installed app
// sends, so it never goes in the repository, a build or a CI service.

import { createPrivateKey, createPublicKey, generateKeyPairSync, sign } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  checkSignature,
  listFile,
  listProblems,
  publicKeys,
  signatureFile,
  signedMessage,
  signingTime,
} from "./query-signature.mjs";

const keyFile =
  process.env.UNREELED_QUERY_KEY || join(homedir(), ".config", "unreeled", "query-signing", "private-key.pem");

try {
  switch (process.argv[2] ?? "sign") {
    case "sign":
      await signList();
      break;
    case "check": {
      const signed = await checkSignature(await readFile(listFile), await readFile(signatureFile));
      console.log(`Queries.json.sig matches Queries.json, signed ${signed}.`);
      break;
    }
    case "new-key":
      await newKey();
      break;
    default:
      throw new Error("Use: node tools/sign-queries.mjs [sign | check | new-key]");
  }
} catch (error) {
  console.error(error.message);
  process.exit(1);
}

async function signList() {
  const list = await readFile(listFile);
  const problems = listProblems(list);
  if (problems.length) {
    throw new Error(`Queries.json isn't ready to sign. The app would turn down:\n- ${problems.join("\n- ")}`);
  }
  const pem = await readFile(keyFile).catch(() => {
    throw new Error(`No signing key at ${keyFile} (see docs/MAINTAINING.md)`);
  });
  const key = createPrivateKey(pem);
  if (!(await publicKeys()).includes(rawPublicKey(createPublicKey(key)))) {
    throw new Error(`${keyFile} isn't one of the keys in QueryUpdates.swift's publicKeys`);
  }
  // Later than the last signing, even if this computer's clock is behind it.
  const previous = await readFile(signatureFile, "utf8").then(
    (text) => JSON.parse(text).signed,
    () => undefined,
  );
  let time = Math.floor(Date.now() / 1000) * 1000;
  if (typeof previous === "string" && signingTime.test(previous)) time = Math.max(time, Date.parse(previous) + 1000);
  const signed = new Date(time).toISOString().replace(/\.\d{3}Z$/, "Z");
  const signature = sign(null, signedMessage(signed, list), key).toString("base64");
  await writeFile(signatureFile, `${JSON.stringify({ signed, signature }, null, 2)}\n`);
  await checkSignature(list, await readFile(signatureFile));
  console.log(`Signed Queries.json at ${signed}. Push Queries.json.sig with it.`);
}

async function newKey() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  await mkdir(dirname(keyFile), { recursive: true, mode: 0o700 });
  try {
    await writeFile(keyFile, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600, flag: "wx" });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    throw new Error(
      `${keyFile} already exists. A list signed with a new key reaches only builds that have its public key: move the old file away first if that's what you want.`,
    );
  }
  console.log(`Private key: ${keyFile}. Keep a copy in your password manager.`);
  console.log(`Public key, for publicKeys in Unreeled/API/QueryUpdates.swift: ${rawPublicKey(publicKey)}`);
}

/** A public key as QueryUpdates.swift lists it: raw Ed25519, base64. */
function rawPublicKey(key) {
  return Buffer.from(key.export({ format: "jwk" }).x, "base64url").toString("base64");
}
