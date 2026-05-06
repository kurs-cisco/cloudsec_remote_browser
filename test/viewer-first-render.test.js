import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

async function loadViewerFirstRenderHelpers() {
  const source = await readFile(
    fileURLToPath(new URL("../viewer/viewer.js", import.meta.url)),
    "utf8",
  );
  const match = source.match(
    /\/\/ Viewer first render helpers BEGIN\n(?<helpers>[\s\S]*?)\/\/ Viewer first render helpers END/,
  );
  assert.ok(match?.groups?.helpers, "viewer first render helper block must be present");

  return vm.runInNewContext(
    `
      const HTMLMediaElement = { HAVE_CURRENT_DATA: 2 };
      const VIEWER_FIRST_RENDERED_MILESTONE = "video.first_rendered";
      ${match.groups.helpers}
      ({
        VIEWER_FIRST_RENDERED_MILESTONE,
        buildFirstRenderedTelemetryFields,
        getPresentedVideoFrameCount,
        hasFirstRenderedVideoFrameEvidence,
      });
    `,
  );
}

test("first rendered helper ignores decoded-only frame counters", async () => {
  const { getPresentedVideoFrameCount, hasFirstRenderedVideoFrameEvidence } =
    await loadViewerFirstRenderHelpers();
  const video = {
    videoWidth: 1280,
    videoHeight: 720,
    readyState: 2,
    paused: false,
    webkitDecodedFrameCount: 7,
    getVideoPlaybackQuality: () => ({ totalVideoFrames: 0 }),
  };

  assert.equal(getPresentedVideoFrameCount(video), 0);
  assert.equal(hasFirstRenderedVideoFrameEvidence(video, {}, "loadeddata"), false);
});

test("first rendered helper accepts compositor-presented frame evidence", async () => {
  const {
    VIEWER_FIRST_RENDERED_MILESTONE,
    buildFirstRenderedTelemetryFields,
    hasFirstRenderedVideoFrameEvidence,
  } = await loadViewerFirstRenderHelpers();
  const video = {
    videoWidth: 1280,
    videoHeight: 720,
    readyState: 2,
    paused: false,
    requestVideoFrameCallback() {},
    getVideoPlaybackQuality: () => ({ totalVideoFrames: 3 }),
  };

  assert.equal(VIEWER_FIRST_RENDERED_MILESTONE, "video.first_rendered");
  assert.equal(
    hasFirstRenderedVideoFrameEvidence(video, { presentedFrames: 1 }, "video-frame-callback"),
    true,
  );
  assert.deepEqual(
    plain(buildFirstRenderedTelemetryFields(video, { presentedFrames: 1 }, "video-frame-callback")),
    {
      reason: "video-frame-callback",
      videoWidth: 1280,
      videoHeight: 720,
      readyState: 2,
      presentedFrames: 1,
    },
  );
});
