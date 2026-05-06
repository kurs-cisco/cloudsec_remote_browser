import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

async function loadViewerInputHelpers() {
  const source = await readFile(
    fileURLToPath(new URL("../viewer/viewer.js", import.meta.url)),
    "utf8",
  );
  const match = source.match(
    /\/\/ Viewer input helpers BEGIN\n(?<helpers>[\s\S]*?)\/\/ Viewer input helpers END/,
  );
  assert.ok(match?.groups?.helpers, "viewer input helper block must be present");

	  return vm.runInNewContext(`
	    const INPUT_POINTER_CHANNEL_LABEL = "input-pointer";
	    const INPUT_CONTROL_CHANNEL_LABEL = "input-control";
	    const LEGACY_INPUT_CHANNEL_LABEL = "input";
	    const POINTER_CHANNEL_BUFFER_HIGH_WATERMARK_BYTES = 16 * 1024;
	    const TEXT_INSERT_BATCH_INTERVAL_MS = 30;
	    const TEXT_INSERT_BATCH_MAX_CHARS = 256;
	    ${match.groups.helpers}
	    ({
	      buildViewerInputSloReport,
	      buildViewerInputEnvelope,
	      classifyViewerInputSloClass,
	      chooseViewerInputChannel,
	      createViewerInputSloWindow,
	      createViewerTextInsertBatcher,
	      evaluateViewerInputSloViolations,
	      extractViewerInputAck,
	      shouldDropViewerPointerMove,
	      summarizeViewerInputChannelBacklog,
	    });
	  `);
}

function channel(label, extra = {}) {
  return {
    label,
    readyState: "open",
    send() {},
    ...extra,
  };
}

test("viewer input helpers route split pointer and control channels", async () => {
  const { chooseViewerInputChannel } = await loadViewerInputHelpers();
  const channels = {
    pointer: channel("input-pointer"),
    control: channel("input-control"),
    legacy: channel("input"),
  };

  assert.equal(
    chooseViewerInputChannel({ type: "pointer.move" }, channels).label,
    "input-pointer",
  );
  assert.equal(
    chooseViewerInputChannel({ type: "pointer.button" }, channels).label,
    "input-control",
  );
  assert.equal(
    chooseViewerInputChannel({ type: "key" }, channels, { preferControl: true }).label,
    "input-control",
  );
});

test("viewer input helpers fall back to legacy input channel", async () => {
  const { chooseViewerInputChannel } = await loadViewerInputHelpers();
  const channels = {
    legacy: channel("input"),
  };

  assert.equal(
    chooseViewerInputChannel({ type: "pointer.move" }, channels).label,
    "input",
  );
  assert.equal(
    chooseViewerInputChannel({ type: "stream.configure" }, channels, {
      preferControl: true,
    }).label,
    "input",
  );
});

test("viewer input envelope adds sequencing and selected channel metadata", async () => {
  const { buildViewerInputEnvelope } = await loadViewerInputHelpers();

  assert.deepEqual(
    plain(
      buildViewerInputEnvelope(
        { type: "pointer.move", x: 10, y: 20 },
        { seq: 7, now: 12345, channelLabel: "input-pointer" },
      ),
    ),
    {
      type: "pointer.move",
      x: 10,
      y: 20,
      seq: 7,
      viewerTs: 12345,
      ts: 12345,
      channel: "input-pointer",
    },
  );
});

test("viewer input helpers drop pointer moves above bufferedAmount watermark", async () => {
  const { shouldDropViewerPointerMove } = await loadViewerInputHelpers();

  assert.equal(
    shouldDropViewerPointerMove(
      channel("input-pointer", { bufferedAmount: 16 * 1024 + 1 }),
      16 * 1024,
    ),
    true,
  );
  assert.equal(
    shouldDropViewerPointerMove(
      channel("input-pointer", { bufferedAmount: 16 * 1024 }),
      16 * 1024,
    ),
    false,
  );
});

test("viewer text.insert batcher flushes on timer and max chars", async () => {
  const { createViewerTextInsertBatcher } = await loadViewerInputHelpers();
  const sent = [];
  let scheduled = null;
  const batcher = createViewerTextInsertBatcher({
    send: (message) => {
      sent.push(message);
      return true;
    },
    setTimer: (callback, delayMs) => {
      assert.equal(delayMs, 30);
      scheduled = callback;
      return 1;
    },
    clearTimer: () => {},
  });

  assert.equal(batcher.enqueue("abc"), true);
  assert.equal(sent.length, 0);
  scheduled();
  assert.deepEqual(plain(sent[0]), {
    type: "text.insert",
    text: "abc",
    reason: "timer",
  });

  const longBatch = "x".repeat(260);
  assert.equal(batcher.enqueue(longBatch), true);
  assert.equal(sent[1].type, "text.insert");
  assert.equal(sent[1].text.length, 256);
  assert.equal(sent[1].reason, "max-chars");
  assert.equal(batcher.pendingText, "xxxx");
});

test("viewer input ack helper accepts input ack variants", async () => {
  const { extractViewerInputAck } = await loadViewerInputHelpers();

  assert.deepEqual(
    plain(
      extractViewerInputAck('{"type":"input.ack","ackSeq":42,"channel":"input-control"}'),
    ),
    {
      seq: 42,
      channel: "input-control",
      received: 0,
      workerTs: 0,
      acks: [],
    },
  );
  assert.equal(extractViewerInputAck('{"type":"heartbeat-ack"}'), null);
});

test("viewer input ack helper preserves batch timing data", async () => {
  const { extractViewerInputAck } = await loadViewerInputHelpers();

  assert.deepEqual(
    plain(
      extractViewerInputAck(
        '{"type":"input.ack","lastReceivedSeq":9,"channel":"input-control","count":1,"workerTs":300,"acks":[{"seq":9,"type":"key","viewerTs":100,"workerApplyTs":180,"workerApplyDelayMs":12}]}',
      ),
    ),
    {
      seq: 9,
      channel: "input-control",
      received: 1,
      workerTs: 300,
      acks: [
        {
          seq: 9,
          type: "key",
          viewerTs: 100,
          workerApplyTs: 180,
          workerApplyDelayMs: 12,
        },
      ],
    },
  );
});

test("viewer input SLO window summarizes p50 p95 and max by input class", async () => {
  const { classifyViewerInputSloClass, createViewerInputSloWindow } =
    await loadViewerInputHelpers();
  const window = createViewerInputSloWindow();

  assert.equal(classifyViewerInputSloClass({ type: "pointer.move" }), "pointer_move");
  assert.equal(classifyViewerInputSloClass({ type: "text.insert" }), "text_insert");

  window.recordSent({
    seq: 1,
    inputClass: "pointer_move",
    channel: "input-pointer",
    sentAt: 100,
  });
  window.recordSent({
    seq: 2,
    inputClass: "pointer_move",
    channel: "input-pointer",
    sentAt: 140,
  });
  window.recordDrop("pointer_move", "input-pointer");
  window.recordAckBatch(
    {
      seq: 2,
      acks: [
        {
          seq: 1,
          type: "pointer.move",
          viewerTs: 100,
          workerApplyTs: 150,
          workerApplyDelayMs: 8,
        },
        {
          seq: 2,
          type: "pointer.move",
          viewerTs: 140,
          workerApplyTs: 210,
          workerApplyDelayMs: 10,
        },
      ],
    },
    240,
  );

	  assert.deepEqual(plain(window.snapshot()), {
	    pending: 0,
	    pendingByChannel: {},
	    byClass: {
      pointer_move: {
        sent: 2,
        acked: 2,
        dropped: 1,
        channels: {
          "input-pointer": 3,
        },
        ackMs: {
          count: 2,
          p50: 100,
          p95: 140,
          max: 140,
        },
        workerApplyMs: {
          count: 2,
          p50: 50,
          p95: 70,
          max: 70,
        },
        workerApplyDelayMs: {
          count: 2,
          p50: 8,
          p95: 10,
          max: 10,
        },
      },
    },
  });

  assert.deepEqual(plain(window.snapshot({ reset: true }).pending), 0);
	  assert.deepEqual(plain(window.snapshot()), {
	    pending: 0,
	    pendingByChannel: {},
	    byClass: {},
	  });
	});

test("viewer input SLO report includes control backlog and click-to-apply violations", async () => {
  const { buildViewerInputSloReport, createViewerInputSloWindow, evaluateViewerInputSloViolations } =
    await loadViewerInputHelpers();
  const window = createViewerInputSloWindow();

  window.recordSent({
    seq: 7,
    inputClass: "pointer_button",
    channel: "input-control",
    sentAt: 100,
  });
  window.recordAckBatch(
    {
      seq: 7,
      acks: [
        {
          seq: 7,
          type: "pointer.button",
          viewerTs: 100,
          workerApplyTs: 260,
          workerApplyDelayMs: 21,
        },
      ],
    },
    350,
  );

  const report = buildViewerInputSloReport(window.snapshot(), {
    pointer: channel("input-pointer", { bufferedAmount: 128 }),
    control: channel("input-control", { bufferedAmount: 20 * 1024 }),
  });

  assert.equal(report.channelBacklog.pointer, 128);
  assert.equal(report.controlBacklog.bufferedAmount, 20 * 1024);
  assert.deepEqual(plain(report.clickToApplyMs), {
    count: 1,
    p50: 160,
    p95: 160,
    max: 160,
  });

  assert.deepEqual(
    plain(
      evaluateViewerInputSloViolations(report, {
        ackP95Ms: 220,
        clickApplyP95Ms: 120,
        controlBacklogBytes: 16 * 1024,
      }),
    ),
    [
      {
        metric: "ack.p95",
        inputClass: "pointer_button",
        value: 250,
        threshold: 220,
      },
      {
        metric: "click_to_apply.p95",
        inputClass: "pointer_button",
        value: 160,
        threshold: 120,
      },
      {
        metric: "control_backlog.bytes",
        inputClass: "control",
        value: 20 * 1024,
        threshold: 16 * 1024,
      },
    ],
  );
});
