import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

test("viewer navigation uses remote browser controls instead of session churn", async () => {
  const source = await readFile(
    fileURLToPath(new URL("../viewer/viewer.js", import.meta.url)),
    "utf8",
  );

  assert.match(source, /type:\s*"browser\.history"/);
  assert.match(source, /type:\s*"browser\.reload"/);
  assert.match(source, /type:\s*"viewport\.resize"/);
  assert.match(source, /reason:\s*"in-place-worker-resize"/);
  assert.match(source, /deviceScaleFactor:\s*1/);
  assert.match(source, /const urlRevealButton = document\.getElementById\("urlReveal"\)/);
  assert.match(source, /setText\(originEl,\s*url\)/);
  assert.doesNotMatch(source, /function formatWatermarkUrl/);
  assert.doesNotMatch(source, /Protected by Cisco Secure Browser ·/);
});
