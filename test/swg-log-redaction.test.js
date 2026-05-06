import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";

test("invalid SWG signature logs use fingerprints instead of raw signatures", async () => {
  const source = await fs.readFile(new URL("../app/server.js", import.meta.url), "utf8");

  assert.equal(source.includes("expectedSignature:"), false);
  assert.equal(source.includes("receivedSignature:"), false);
  assert.match(source, /expectedSignatureFingerprint/);
  assert.match(source, /receivedSignatureFingerprint/);
  assert.match(source, /canonicalFingerprint/);
});
