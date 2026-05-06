import test from "node:test";
import assert from "node:assert/strict";

import {
  computeViewportForFrame,
  computeViewportForWindow,
  viewportNeedsRefresh,
} from "../shared/viewport.js";

test("computeViewportForFrame preserves the full width when the viewer is wider than 16:9", () => {
  const viewport = computeViewportForFrame({
    frameWidth: 1500,
    frameHeight: 760,
    maxWidth: 1920,
    maxHeight: 1080,
  });

  assert.deepEqual(viewport, {
    width: 1920,
    height: 972,
    deviceScaleFactor: 1,
  });
});

test("computeViewportForFrame shrinks width when the viewer is narrower than 16:9", () => {
  const viewport = computeViewportForFrame({
    frameWidth: 900,
    frameHeight: 900,
    maxWidth: 1920,
    maxHeight: 1080,
  });

  assert.deepEqual(viewport, {
    width: 1080,
    height: 1080,
    deviceScaleFactor: 1,
  });
});

test("computeViewportForWindow reserves space for the viewer topbar", () => {
  const viewport = computeViewportForWindow({
    innerWidth: 1440,
    innerHeight: 960,
    topbarHeight: 80,
    maxWidth: 1920,
    maxHeight: 1080,
    deviceScaleFactor: 2,
  });

  assert.deepEqual(viewport, {
    width: 1766,
    height: 1080,
    deviceScaleFactor: 2,
  });
});

test("viewportNeedsRefresh ignores small deltas but catches large aspect mismatches", () => {
  assert.equal(
    viewportNeedsRefresh(
      { width: 1920, height: 972 },
      { width: 1920, height: 960 },
      { aspectTolerance: 0.03 },
    ),
    false,
  );

  assert.equal(
    viewportNeedsRefresh(
      { width: 1512, height: 1080 },
      { width: 1480, height: 1080 },
      { aspectTolerance: 0.03 },
    ),
    false,
  );

  assert.equal(
    viewportNeedsRefresh(
      { width: 1920, height: 1080 },
      { width: 1920, height: 972 },
      { aspectTolerance: 0.03 },
    ),
    true,
  );
});
