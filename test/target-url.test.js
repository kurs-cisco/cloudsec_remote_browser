import test from "node:test";
import assert from "node:assert/strict";

import { normalizeTargetUrl } from "../shared/target-url.js";

test("normalizeTargetUrl accepts bare hostnames", () => {
  assert.equal(
    normalizeTargetUrl("www.youtube.com"),
    "https://www.youtube.com/",
  );
});

test("normalizeTargetUrl rejects non-http schemes", () => {
  assert.throws(() => normalizeTargetUrl("ftp://example.com"), /Only http and https/);
});
