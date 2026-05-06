import {
  computeViewportForWindow,
  viewportNeedsRefresh,
} from "/shared/viewport.js";

const params = new URLSearchParams(window.location.search);
const sessionId = params.get("sessionId");
const targetUrlHint = params.get("targetUrl");
const handoffMode = String(params.get("handoff") || "").trim().toLowerCase();
const handoffClickX = Number.parseFloat(params.get("handoffClickX") || "");
const handoffClickY = Number.parseFloat(params.get("handoffClickY") || "");
const handoffClickUrl = String(params.get("handoffClickUrl") || "").trim();

const statusEl = document.getElementById("status");
const originEl = document.getElementById("origin");
const urlRevealButton = document.getElementById("urlReveal");
const protectedMarkEl = document.getElementById("protectedMark");
const navBackButton = document.getElementById("navBack");
const navForwardButton = document.getElementById("navForward");
const navReloadButton = document.getElementById("navReload");
const overlayEl = document.getElementById("overlay");
const overlayTextEl = document.getElementById("overlayText");
const overlayActionButton = document.getElementById("overlayAction");
const remoteVideo = document.getElementById("remoteVideo");
const audioToggleButton = document.getElementById("audioToggle");
const endSessionButton = document.getElementById("endSession");
const restartSessionButton = document.getElementById("restartSession");
const reportProblemButton = document.getElementById("reportProblem");
const bannerTenantEl = document.getElementById("bannerTenant");
const bannerTargetEl = document.getElementById("bannerTarget");
const bannerModeEl = document.getElementById("bannerMode");
const bannerPolicyEl = document.getElementById("bannerPolicy");
const bannerControlsEl = document.getElementById("bannerControls");
const bannerConnectionEl = document.getElementById("bannerConnection");
const bannerRegionEl = document.getElementById("bannerRegion");
const bannerSessionEl = document.getElementById("bannerSession");
const stageTextEl = document.getElementById("stageText");
const stageListEl = document.getElementById("stageList");
const viewerFrameEl = document.querySelector(".viewer-frame");
const topbarEl = document.querySelector(".topbar");
const enterpriseBannerEl = document.querySelector(".enterprise-banner");
const progressStripEl = document.querySelector(".progress-strip");

const SIGNALING_HEARTBEAT_INTERVAL_MS = 20_000;
const SIGNALING_RECONNECT_MAX_DELAY_MS = 5_000;
const ICE_RESTART_DELAY_MS = 1_500;
const WHEEL_BATCH_INTERVAL_MS = 12;
const INPUT_POINTER_CHANNEL_LABEL = "input-pointer";
const INPUT_CONTROL_CHANNEL_LABEL = "input-control";
const LEGACY_INPUT_CHANNEL_LABEL = "input";
const POINTER_CHANNEL_BUFFER_HIGH_WATERMARK_BYTES = 16 * 1024;
const TEXT_INSERT_BATCH_INTERVAL_MS = 30;
const TEXT_INSERT_BATCH_MAX_CHARS = 256;
const INPUT_ACK_STATS_INTERVAL_MS = 5_000;
const INPUT_ACK_P95_WARN_MS = 220;
const INPUT_CLICK_APPLY_P95_WARN_MS = 120;
const INPUT_CONTROL_BACKLOG_WARN_BYTES = 16 * 1024;
const VIEWER_TELEMETRY_FLUSH_INTERVAL_MS = 5_000;
const VIEWER_TELEMETRY_MAX_EVENTS = 20;
const VIEWER_TELEMETRY_MAX_FIELD_LENGTH = 180;
const VIEWER_FIRST_RENDERED_MILESTONE = "video.first_rendered";
const STREAM_PROFILE_SYNC_DELAY_MS = 180;
const STREAM_PROFILE_SCALES = [0.5, 0.67, 0.84, 1];
const INITIAL_STREAM_PROFILE_SCALE = 1;
const MAX_STREAM_DEVICE_SCALE_FACTOR = 2;
const VIDEO_STALL_CHECK_INTERVAL_MS = 3_000;
const VIDEO_STALL_THRESHOLD_MS = 8_000;
const VIDEO_STALL_RESTART_THRESHOLD_MS = 20_000;
const VIDEO_STALL_RECOVERY_COOLDOWN_MS = 15_000;
const AUDIO_ENABLE_RETRY_INTERVAL_MS = 200;
const AUDIO_ENABLE_RETRY_MAX_ATTEMPTS = 150;
const AUDIO_STARTUP_SYNC_MAX_WAIT_MS = 3500;
const AUDIO_STARTUP_SYNC_POLL_INTERVAL_MS = 120;
const AUDIO_STARTUP_SYNC_MIN_ADVANCING_POLLS = 2;
const AUDIO_STARTUP_SYNC_MIN_BYTES_RECEIVED = 1536;
const AUDIO_STARTUP_SYNC_MIN_BYTES_ADVANCE = 320;
const AUDIO_STARTUP_SYNC_MIN_TOTAL_SAMPLES_DURATION_SEC = 0.24;
const AUDIO_STARTUP_SYNC_MIN_SAMPLE_ADVANCE_SEC = 0.08;
const HYBRID_HANDOFF_REMOTE_CLICK_DELAY_MS = 180;
const POST_LIVE_STREAM_PROFILE_SYNC_DELAY_MS = 650;
const VIEWER_HISTORY_TRAP_STATE_KEY = "__rbiViewerHistoryTrap";
const VIEWER_HISTORY_TRAP_HASH_KEY = "__rbiViewerTrap";
const VIEWER_HISTORY_TRAP_BASE = "base";
const VIEWER_HISTORY_TRAP_SENTINEL = "sentinel";
const ACTIVE_VIEWER_SESSION_STORAGE_KEY = "rbiActiveViewerSession";
const VIEWER_MEDIA_RELAY_MODE = "gateway-media-relay";
const VIEWER_GATEWAY_WEBRTC_RELAY_MODE = "gateway-webrtc-relay";
const VIEWER_GATEWAY_WEBRTC_SRTP_PROTOCOL = "webrtc-srtp";
const VIEWER_PROGRESS_STAGES = [
  "loading",
  "allocating",
  "worker-ready",
  "media",
  "first-frame",
  "live",
];
const audioStartupSyncEnabled = false;
const sourceCoupledAvEnabled = true;

let session = null;
let currentPageState = {};
let ws = null;
let mediaRelayWs = null;
let peer = null;
let inputChannel = null;
let inputPointerChannel = null;
let inputControlChannel = null;
let inputLegacyChannel = null;
let remoteDesktopWidth = 1280;
let remoteDesktopHeight = 720;
let streamWidth = 1280;
let streamHeight = 720;
let remoteMediaStream = null;
let pointerMoveFrame = 0;
let pointerMoveFrameUsesAnimationFrame = false;
let pendingPointerMove = null;
let wheelTimer = null;
let pendingWheel = null;
let inputSeq = 0;
let inputAckStatsTimer = null;
let unloadSent = false;
let isLive = false;
let sessionPollTimer = null;
let slowStartTimer = null;
let disconnectTimer = null;
let reconnectAttempts = 0;
let signalingReconnectTimer = null;
let signalingHeartbeatTimer = null;
let restartIceTimer = null;
let streamProfileSyncTimer = null;
let postLiveStreamProfileTimer = null;
let pendingIceRestart = false;
let pendingStreamProfileSync = false;
let sessionEnded = false;
let hasRemoteAudio = false;
let hasRemoteVideo = false;
let workerStreaming = false;
let audioEnabled = false;
let activeStreamProfileKey = "";
let activeViewportResizeKey = "";
let resizeObserver = null;
let canRequestIceRestart = false;
let playbackKickTimer = null;
let playbackKickAttempts = 0;
let audioEnableRetryTimer = null;
let audioEnableRetryAttempts = 0;
let audioStartupGateStartedAt = 0;
let audioStartupGateSatisfied = !audioStartupSyncEnabled;
let audioStartupGateTimer = null;
let audioStartupGateCheckInFlight = false;
let audioStartupAdvancingPolls = 0;
let audioStartupLastProgress = null;
let workerAudioReady = !audioStartupSyncEnabled;
let videoStallTimer = null;
let videoFrameCallbackId = 0;
let lastVideoFrameAt = 0;
let lastVideoFrameCount = 0;
let lastVideoRecoveryAt = 0;
let firstFrameRecorded = false;
let telemetryFlushTimer = null;
let enterpriseBannerTimer = null;
let currentViewerStage = "";
let currentViewerStageDetail = "";
let currentViewerStageStartedAt = 0;
let recoveryAttemptCount = 0;
let hybridHandoffReplayClickTimer = null;
let hybridHandoffReplayClickSent = false;
let viewerHistoryTrapArmed = false;
let viewerHistoryTrapBounceInFlight = false;
let staleViewerHistoryRecoveryAttempted = false;
let mediaRelayConfig = null;
let mediaRelayRegistered = false;
let mediaRelayReceivedFrames = 0;
let viewerGatewayWebrtcConfig = null;
let viewerGatewayNegotiationPromise = null;
const viewerStartedAt = performance.now();
const viewerMilestones = new Set();
const viewerTelemetryQueue = [];
const inputAckStats = {
  sent: 0,
  sentByChannel: {
    [INPUT_POINTER_CHANNEL_LABEL]: 0,
    [INPUT_CONTROL_CHANNEL_LABEL]: 0,
    [LEGACY_INPUT_CHANNEL_LABEL]: 0,
  },
  droppedPointerMoves: 0,
  acks: 0,
  lastAckSeq: 0,
  lastAckAt: 0,
  lastAckChannel: "",
};
const textInsertSuppressedKeyIds = new Set();

// Viewer media relay helpers BEGIN
function normalizeViewerMediaRelayValue(value) {
  return String(value || "").trim();
}

function normalizeViewerMediaRelayMode(candidateSession) {
  const transport = candidateSession?.transport || {};
  const mediaTermination = transport.mediaTermination || {};
  return normalizeViewerMediaRelayValue(
    mediaTermination.mode ||
      transport.relayMode ||
      candidateSession?.workerBridge?.relayMode ||
      candidateSession?.gatewayAssignment?.relayMode ||
      candidateSession?.sessionPlacement?.gatewayAssignment?.relayMode,
  ).toLowerCase();
}

function normalizeViewerMediaRelayUrl(value) {
  const raw = normalizeViewerMediaRelayValue(value);
  if (!raw) {
    return "";
  }
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
      return "";
    }
    return parsed.toString();
  } catch {
    return "";
  }
}

function isViewerMediaRelayCanaryAllowed(searchParams) {
  const configured = normalizeViewerMediaRelayValue(
    searchParams?.get?.("mediaRelay") || searchParams?.get?.("mediaRelayCanary"),
  ).toLowerCase();
  if (!configured) {
    return true;
  }
  return !["0", "false", "off", "disabled", "direct"].includes(configured);
}

function buildViewerMediaRelayConfig(candidateSession, { canaryEnabled = true } = {}) {
  const transport = candidateSession?.transport || {};
  const mediaTermination = transport.mediaTermination || {};
  const mode = normalizeViewerMediaRelayMode(candidateSession);
  const mediaRelayUrl = normalizeViewerMediaRelayUrl(
    transport.mediaRelayUrl || transport.mediaRelayURL,
  );
  const gatewayTerminatesMedia = mediaTermination.gatewayTerminatesMedia === true;
  const base = {
    enabled: false,
    mode,
    mediaRelayUrl,
    gatewayTerminatesMedia,
    canaryOnly: true,
    replaceWebRtc: false,
  };

  if (!canaryEnabled) {
    return { ...base, reason: "viewer-media-relay-canary-disabled" };
  }
  if (!mediaRelayUrl) {
    return { ...base, reason: "missing-media-relay-url" };
  }
  if (mode !== VIEWER_MEDIA_RELAY_MODE) {
    return { ...base, reason: "media-termination-not-gateway-media-relay" };
  }
  if (!gatewayTerminatesMedia) {
    return { ...base, reason: "gateway-does-not-terminate-media" };
  }

  return {
    ...base,
    enabled: true,
    reason: "gateway-media-relay-canary",
  };
}

function buildViewerMediaRelayRegisterMessage(candidateSessionId, token) {
  return {
    type: "register",
    role: "viewer",
    sessionId: candidateSessionId,
    token,
  };
}

function normalizeViewerGatewayMode(candidateSession) {
  const transport = candidateSession?.transport || {};
  const mediaTermination = transport.mediaTermination || {};
  return normalizeViewerMediaRelayValue(
    transport.mediaPlaneMode || mediaTermination.mediaPlaneMode,
  ).toLowerCase();
}

function normalizeViewerGatewayProtocol(candidateSession) {
  const transport = candidateSession?.transport || {};
  const mediaTermination = transport.mediaTermination || {};
  return normalizeViewerMediaRelayValue(
    transport.protocol || mediaTermination.protocol,
  ).toLowerCase();
}

function normalizeViewerGatewayHttpUrl(value) {
  const raw = normalizeViewerMediaRelayValue(value);
  if (!raw) {
    return "";
  }
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return "";
    }
    return parsed.toString();
  } catch {
    return "";
  }
}

function buildViewerGatewayOfferUrl(mediaGatewayUrl) {
  const normalized = normalizeViewerGatewayHttpUrl(mediaGatewayUrl);
  if (!normalized) {
    return "";
  }
  const parsed = new URL(normalized);
  const trimmedPath = parsed.pathname.replace(/\/+$/, "");
  if (trimmedPath.endsWith("/offer")) {
    parsed.pathname = trimmedPath;
    return parsed.toString();
  }
  parsed.pathname = `${trimmedPath || ""}/offer`;
  return parsed.toString();
}

function buildViewerGatewayWebrtcConfig(candidateSession) {
  const transport = candidateSession?.transport || {};
  const mediaPlaneMode = normalizeViewerGatewayMode(candidateSession);
  const protocol = normalizeViewerGatewayProtocol(candidateSession);
  const mediaGatewayUrl = normalizeViewerGatewayHttpUrl(
    transport.mediaGatewayUrl || transport.mediaGatewayURL,
  );
  const offerUrl = buildViewerGatewayOfferUrl(mediaGatewayUrl);
  const base = {
    enabled: false,
    mediaPlaneMode,
    protocol,
    mediaGatewayUrl,
    offerUrl,
    inputPointerName: normalizeViewerMediaRelayValue(
      transport.inputPointerName || INPUT_POINTER_CHANNEL_LABEL,
    ),
    inputControlName: normalizeViewerMediaRelayValue(
      transport.inputControlName || INPUT_CONTROL_CHANNEL_LABEL,
    ),
  };

  if (!mediaGatewayUrl || !offerUrl) {
    return { ...base, reason: "missing-media-gateway-url" };
  }
  if (mediaPlaneMode !== VIEWER_GATEWAY_WEBRTC_RELAY_MODE) {
    return { ...base, reason: "media-plane-not-gateway-webrtc-relay" };
  }
  if (protocol !== VIEWER_GATEWAY_WEBRTC_SRTP_PROTOCOL) {
    return { ...base, reason: "protocol-not-webrtc-srtp" };
  }

  return {
    ...base,
    enabled: true,
    reason: "gateway-webrtc-relay",
  };
}

function buildViewerGatewayOfferRequest(candidateSessionId, token, sdp) {
  return {
    type: "offer",
    role: "viewer",
    sessionId: candidateSessionId,
    token,
    sdp,
  };
}

function extractViewerGatewayAnswerSdp(payload) {
  const candidates = [
    payload?.sdp,
    payload?.answerSdp,
    payload?.answer?.sdp,
    payload?.description?.sdp,
  ];
  for (const candidate of candidates) {
    const text = String(candidate || "");
    if (text.trim()) {
      return text;
    }
  }
  return "";
}
// Viewer media relay helpers END

// Viewer input helpers BEGIN
function normalizeViewerInputChannelLabel(value) {
  return String(value || "").trim();
}

function classifyViewerInputChannel(label) {
  const normalized = normalizeViewerInputChannelLabel(label);
  if (normalized === INPUT_POINTER_CHANNEL_LABEL) {
    return "pointer";
  }
  if (normalized === INPUT_CONTROL_CHANNEL_LABEL) {
    return "control";
  }
  return "legacy";
}

function isViewerInputChannelOpen(channel) {
  return Boolean(channel && channel.readyState === "open" && typeof channel.send === "function");
}

function getViewerInputChannelLabel(channel, fallback = LEGACY_INPUT_CHANNEL_LABEL) {
  return normalizeViewerInputChannelLabel(channel?.label) || fallback;
}

function chooseViewerInputChannel(message, channels = {}, options = {}) {
  const type = normalizeViewerInputChannelLabel(message?.type);
  const legacyChannel = channels.legacy || channels.input || null;
  const preferControl = Boolean(options.reliable || options.preferControl);
  const preferPointer = Boolean(options.preferPointer || type === "pointer.move");

  if (preferControl) {
    if (isViewerInputChannelOpen(channels.control)) {
      return channels.control;
    }
    if (isViewerInputChannelOpen(legacyChannel)) {
      return legacyChannel;
    }
    return null;
  }

  if (preferPointer) {
    if (isViewerInputChannelOpen(channels.pointer)) {
      return channels.pointer;
    }
    if (isViewerInputChannelOpen(legacyChannel)) {
      return legacyChannel;
    }
    return null;
  }

  if (isViewerInputChannelOpen(channels.control)) {
    return channels.control;
  }
  if (isViewerInputChannelOpen(legacyChannel)) {
    return legacyChannel;
  }
  return null;
}

function shouldDropViewerPointerMove(channel, highWatermarkBytes) {
  if (!channel) {
    return false;
  }
  const bufferedAmount = Number(channel.bufferedAmount || 0);
  return Number.isFinite(bufferedAmount) && bufferedAmount > highWatermarkBytes;
}

function readViewerInputChannelBacklog(channel) {
  const bufferedAmount = Number(channel?.bufferedAmount || 0);
  return Number.isFinite(bufferedAmount) && bufferedAmount > 0 ? Math.round(bufferedAmount) : 0;
}

function summarizeViewerInputChannelBacklog(channels = {}) {
  const pointer = readViewerInputChannelBacklog(channels.pointer);
  const control = readViewerInputChannelBacklog(channels.control);
  const legacy = readViewerInputChannelBacklog(channels.legacy || channels.input);
  return {
    pointer,
    control,
    legacy,
    total: pointer + control + legacy,
  };
}

function buildViewerInputEnvelope(message, { seq, now, channelLabel }) {
  return {
    ...message,
    seq,
    viewerTs: now,
    ts: now,
    channel: channelLabel,
  };
}

function extractViewerInputAck(rawMessage) {
  let message = rawMessage;
  if (typeof rawMessage === "string") {
    try {
      message = JSON.parse(rawMessage);
    } catch {
      return null;
    }
  }
  if (!message || typeof message !== "object") {
    return null;
  }
  const type = normalizeViewerInputChannelLabel(message.type);
  if (!["input.ack", "input-ack", "ack"].includes(type)) {
    return null;
  }
  const seq = Number(
    message.ackSeq ??
      message.seq ??
      message.lastSeq ??
      message.lastAckSeq ??
      message.lastReceivedSeq ??
      0,
  );
  return {
    seq: Number.isFinite(seq) ? seq : 0,
    channel: normalizeViewerInputChannelLabel(message.channel),
    received: Number(message.received || message.count || 0) || 0,
    workerTs: Number(message.workerTs || 0) || 0,
    acks: Array.isArray(message.acks) ? message.acks : [],
  };
}

function classifyViewerInputSloClass(messageOrType) {
  const type = normalizeViewerInputChannelLabel(
    typeof messageOrType === "string" ? messageOrType : messageOrType?.type,
  );
  if (type === "pointer.move") {
    return "pointer_move";
  }
  if (type === "pointer.button") {
    return "pointer_button";
  }
  if (type === "wheel") {
    return "wheel";
  }
  if (type === "key") {
    return "key";
  }
  if (type === "text.insert") {
    return "text_insert";
  }
  if (type === "stream.configure") {
    return "stream_configure";
  }
  if (type === "viewport.resize") {
    return "viewport_resize";
  }
  if (type === "browser.history") {
    return "browser_history";
  }
  if (type === "browser.reload") {
    return "browser_reload";
  }
  return type ? "other" : "unknown";
}

function percentile(values, p) {
  if (!values.length) {
    return 0;
  }
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * p) - 1));
  return sorted[index];
}

function summarizeLatencyValues(values) {
  if (!values.length) {
    return {
      count: 0,
      p50: 0,
      p95: 0,
      max: 0,
    };
  }
  return {
    count: values.length,
    p50: Math.round(percentile(values, 0.5)),
    p95: Math.round(percentile(values, 0.95)),
    max: Math.round(Math.max(...values)),
  };
}

function createViewerInputSloWindow({ maxSamples = 500 } = {}) {
  const pendingBySeq = new Map();
  const classes = new Map();

  function getBucket(inputClass) {
    const key = inputClass || "unknown";
    if (!classes.has(key)) {
      classes.set(key, {
        sent: 0,
        acked: 0,
        dropped: 0,
        channels: {},
        ackMs: [],
        workerApplyMs: [],
        workerApplyDelayMs: [],
      });
    }
    return classes.get(key);
  }

  function pushSample(values, value) {
    const sample = Number(value);
    if (!Number.isFinite(sample) || sample < 0) {
      return;
    }
    values.push(sample);
    if (values.length > maxSamples) {
      values.splice(0, values.length - maxSamples);
    }
  }

  function recordSent({ seq, inputClass, channel, sentAt }) {
    const bucket = getBucket(inputClass);
    bucket.sent += 1;
    bucket.channels[channel || "unknown"] = (bucket.channels[channel || "unknown"] || 0) + 1;
    if (seq) {
      pendingBySeq.set(seq, {
        inputClass,
        channel,
        sentAt,
      });
    }
  }

  function recordDrop(inputClass, channel = "") {
    const bucket = getBucket(inputClass);
    bucket.dropped += 1;
    if (channel) {
      bucket.channels[channel] = (bucket.channels[channel] || 0) + 1;
    }
  }

  function recordAckBatch(ack, now) {
    const ackItems = ack?.acks?.length ? ack.acks : [ack];
    for (const item of ackItems) {
      const seq = Number(item.seq || ack.seq || 0);
      const pending = seq ? pendingBySeq.get(seq) : null;
      const itemClass = item.type ? classifyViewerInputSloClass(item.type) : "";
      const inputClass = itemClass || pending?.inputClass || "unknown";
      const bucket = getBucket(inputClass);
      bucket.acked += 1;

      const sentAt = pending?.sentAt || Number(item.viewerTs || 0);
      if (sentAt) {
        pushSample(bucket.ackMs, now - sentAt);
      }
      const workerApplyTs = Number(item.workerApplyTs || 0);
      const viewerTs = Number(item.viewerTs || sentAt || 0);
      if (workerApplyTs && viewerTs) {
        pushSample(bucket.workerApplyMs, workerApplyTs - viewerTs);
      }
      pushSample(bucket.workerApplyDelayMs, Number(item.workerApplyDelayMs || 0));
      if (seq) {
        pendingBySeq.delete(seq);
      }
    }
  }

  function snapshot({ reset = false } = {}) {
    const byClass = {};
    for (const [inputClass, bucket] of classes.entries()) {
      byClass[inputClass] = {
        sent: bucket.sent,
        acked: bucket.acked,
        dropped: bucket.dropped,
        channels: { ...bucket.channels },
        ackMs: summarizeLatencyValues(bucket.ackMs),
        workerApplyMs: summarizeLatencyValues(bucket.workerApplyMs),
        workerApplyDelayMs: summarizeLatencyValues(bucket.workerApplyDelayMs),
      };
    }
    const pendingByChannel = {};
    for (const pending of pendingBySeq.values()) {
      const key = pending.channel || "unknown";
      pendingByChannel[key] = (pendingByChannel[key] || 0) + 1;
    }
    const result = {
      pending: pendingBySeq.size,
      pendingByChannel,
      byClass,
    };
    if (reset) {
      pendingBySeq.clear();
      classes.clear();
    }
    return result;
  }

  return {
    recordSent,
    recordDrop,
    recordAckBatch,
    snapshot,
  };
}

function buildViewerInputSloReport(snapshot, channels = {}) {
  const channelBacklog = summarizeViewerInputChannelBacklog(channels);
  const pointerMove = snapshot.byClass?.pointer_move || null;
  const pointerButton = snapshot.byClass?.pointer_button || null;
  const emptyLatency = summarizeLatencyValues([]);
  return {
    ...snapshot,
    channelBacklog,
    controlBacklog: {
      pending: snapshot.pendingByChannel?.[INPUT_CONTROL_CHANNEL_LABEL] || 0,
      bufferedAmount: channelBacklog.control,
    },
    pointerDropCount: pointerMove?.dropped || 0,
    clickToApplyMs: pointerButton?.workerApplyMs || emptyLatency,
  };
}

function evaluateViewerInputSloViolations(report, thresholds = {}) {
  const violations = [];
  const ackP95Ms = Number(thresholds.ackP95Ms || 0);
  const clickApplyP95Ms = Number(thresholds.clickApplyP95Ms || 0);
  const controlBacklogBytes = Number(thresholds.controlBacklogBytes || 0);

  if (ackP95Ms > 0) {
    for (const [inputClass, bucket] of Object.entries(report.byClass || {})) {
      const p95 = Number(bucket?.ackMs?.p95 || 0);
      if (p95 > ackP95Ms) {
        violations.push({
          metric: "ack.p95",
          inputClass,
          value: Math.round(p95),
          threshold: ackP95Ms,
        });
      }
    }
  }

  const clickP95 = Number(report.clickToApplyMs?.p95 || 0);
  if (clickApplyP95Ms > 0 && clickP95 > clickApplyP95Ms) {
    violations.push({
      metric: "click_to_apply.p95",
      inputClass: "pointer_button",
      value: Math.round(clickP95),
      threshold: clickApplyP95Ms,
    });
  }

  const controlBacklog = Number(report.controlBacklog?.bufferedAmount || 0);
  if (controlBacklogBytes > 0 && controlBacklog > controlBacklogBytes) {
    violations.push({
      metric: "control_backlog.bytes",
      inputClass: "control",
      value: Math.round(controlBacklog),
      threshold: controlBacklogBytes,
    });
  }

  return violations;
}

function createViewerTextInsertBatcher({
  send,
  setTimer,
  clearTimer,
  intervalMs = TEXT_INSERT_BATCH_INTERVAL_MS,
  maxChars = TEXT_INSERT_BATCH_MAX_CHARS,
}) {
  let pendingText = "";
  let timer = null;

  function clearPendingTimer() {
    if (!timer) {
      return;
    }
    clearTimer(timer);
    timer = null;
  }

  function scheduleFlush() {
    if (timer || !pendingText) {
      return;
    }
    timer = setTimer(() => {
      timer = null;
      flush("timer");
    }, intervalMs);
  }

  function flush(reason = "") {
    clearPendingTimer();
    if (!pendingText) {
      return false;
    }
    const text = pendingText;
    pendingText = "";
    return Boolean(
      send({
        type: "text.insert",
        text,
        reason,
      }),
    );
  }

  function enqueue(text) {
    const value = String(text || "");
    if (!value) {
      return false;
    }
    pendingText += value;
    while (pendingText.length >= maxChars) {
      const batch = pendingText.slice(0, maxChars);
      pendingText = pendingText.slice(maxChars);
      send({
        type: "text.insert",
        text: batch,
        reason: "max-chars",
      });
    }
    scheduleFlush();
    return true;
  }

  function cancel() {
    clearPendingTimer();
    pendingText = "";
  }

  return {
    enqueue,
    flush,
    cancel,
    get pendingText() {
      return pendingText;
    },
  };
}
// Viewer input helpers END

const textInsertBatcher = createViewerTextInsertBatcher({
  send: (message) => sendInput(message, { preferControl: true }),
  setTimer: (callback, delayMs) => window.setTimeout(callback, delayMs),
  clearTimer: (timerId) => window.clearTimeout(timerId),
});
const inputSloWindow = createViewerInputSloWindow();
const inputSloSessionWindow = createViewerInputSloWindow({ maxSamples: 2000 });

function getCurrentViewerLocation() {
  return `${window.location.pathname}${window.location.search}${window.location.hash}`;
}

function getCanonicalViewerLocation() {
  return `${window.location.pathname}${window.location.search}`;
}

function buildViewerModeUrl(rawUrl) {
  const next = new URL(rawUrl, window.location.origin);
  next.searchParams.delete("sourceCoupledAv");
  return `${next.pathname}${next.search}${next.hash}`;
}

function truncateTelemetryValue(value, maxLength = VIEWER_TELEMETRY_MAX_FIELD_LENGTH) {
  const text = String(value ?? "");
  if (text.length <= maxLength) {
    return text;
  }
  return `${text.slice(0, Math.max(0, maxLength - 3))}...`;
}

function sanitizeTelemetryFields(fields = {}) {
  const sanitized = {};
  for (const [key, value] of Object.entries(fields || {})) {
    if (value === undefined || typeof value === "function") {
      continue;
    }
    if (typeof value === "string") {
      sanitized[key] = truncateTelemetryValue(value);
      continue;
    }
    if (typeof value === "number" || typeof value === "boolean" || value === null) {
      sanitized[key] = value;
      continue;
    }
    try {
      sanitized[key] = JSON.parse(JSON.stringify(value));
    } catch {
      sanitized[key] = truncateTelemetryValue(value);
    }
  }
  return sanitized;
}

function buildTelemetrySessionContext() {
  return {
    generation: session?.generation || null,
    sessionMode: session?.sessionMode || "",
    viewerEntryMode: session?.viewerEntryMode || "",
    signalingMode: session?.signalingMode || "",
    targetOrigin: session?.targetOrigin || "",
    workerRuntimeKind: session?.workerRuntimeKind || "",
    workerRegion: session?.workerRegion || session?.gatewayAssignment?.region || "",
  };
}

function queueViewerTelemetry(name, fields = {}, { flush = false } = {}) {
  if (!sessionId) {
    return;
  }
  viewerTelemetryQueue.push({
    name,
    ts: Date.now(),
    viewerElapsedMs: Math.round(performance.now() - viewerStartedAt),
    stage: currentViewerStage || "",
    stageDetail: currentViewerStageDetail || "",
    fields: sanitizeTelemetryFields(fields),
  });
  if (viewerTelemetryQueue.length > VIEWER_TELEMETRY_MAX_EVENTS) {
    viewerTelemetryQueue.splice(0, viewerTelemetryQueue.length - VIEWER_TELEMETRY_MAX_EVENTS);
  }
  if (flush) {
    void flushViewerTelemetry({ reason: name });
  }
}

function recordViewerMilestone(name, fields = {}) {
  if (viewerMilestones.has(name)) {
    return false;
  }
  viewerMilestones.add(name);
  queueViewerTelemetry("viewer.milestone", {
    milestone: name,
    ...fields,
  });
  return true;
}

function startViewerTelemetryTimer() {
  if (telemetryFlushTimer || !sessionId) {
    return;
  }
  telemetryFlushTimer = window.setInterval(() => {
    emitInputSloTelemetry("interval");
    void flushViewerTelemetry({ reason: "interval" });
  }, VIEWER_TELEMETRY_FLUSH_INTERVAL_MS);
}

function clearViewerTelemetryTimer() {
  if (!telemetryFlushTimer) {
    return;
  }
  window.clearInterval(telemetryFlushTimer);
  telemetryFlushTimer = null;
}

async function flushViewerTelemetry({ reason = "manual", beacon = false } = {}) {
  if (!sessionId || !viewerTelemetryQueue.length) {
    return false;
  }

  const events = viewerTelemetryQueue.splice(0, VIEWER_TELEMETRY_MAX_EVENTS);
  const payload = {
    reason,
    session: buildTelemetrySessionContext(),
    events,
  };
  let body = JSON.stringify(payload);
  while (body.length > 3600 && payload.events.length > 1) {
    payload.events.shift();
    body = JSON.stringify(payload);
  }
  const endpoint = `/api/sessions/${encodeURIComponent(sessionId)}/viewer-events`;

  if (beacon && navigator.sendBeacon) {
    try {
      const sent = navigator.sendBeacon(
        endpoint,
        new Blob([body], { type: "application/json" }),
      );
      if (sent) {
        return true;
      }
    } catch {
      // Fall through to fetch.
    }
  }

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      credentials: "same-origin",
      keepalive: beacon,
      headers: {
        "Content-Type": "application/json",
      },
      body,
    });
    if (!response.ok) {
      throw new Error(`viewer telemetry rejected: ${response.status}`);
    }
    return true;
  } catch (error) {
    debugLog("viewer-telemetry-send-failed", error?.message || String(error));
    viewerTelemetryQueue.unshift(...events);
    if (viewerTelemetryQueue.length > VIEWER_TELEMETRY_MAX_EVENTS) {
      viewerTelemetryQueue.splice(0, viewerTelemetryQueue.length - VIEWER_TELEMETRY_MAX_EVENTS);
    }
    return false;
  }
}

function setText(el, text) {
  if (el) {
    el.textContent = text;
  }
}

function isDisplayablePageUrl(value) {
  const text = String(value || "").trim();
  if (!text) {
    return false;
  }
  return !/^(about:blank|chrome:\/\/|chrome-error:\/\/|devtools:\/\/)/i.test(text);
}

function normalizeDisplayUrl(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "";
  }
  try {
    return new URL(text, window.location.origin).href;
  } catch {
    return text;
  }
}

function deriveWatermarkUrl() {
  const candidates = [
    currentPageState.href,
    currentPageState.url,
    session?.targetUrl,
    targetUrlHint,
    session?.targetOrigin,
  ];
  for (const candidate of candidates) {
    const normalized = normalizeDisplayUrl(candidate);
    if (isDisplayablePageUrl(normalized)) {
      return normalized;
    }
  }
  return "Connecting";
}

function deriveWatermarkHost(rawUrl = deriveWatermarkUrl()) {
  const value = String(rawUrl || "").trim();
  if (!value || value === "Connecting") {
    return "";
  }
  try {
    return new URL(value).host;
  } catch {
    return value.replace(/^https?:\/\//i, "").split("/")[0];
  }
}

function syncWatermark() {
  const url = deriveWatermarkUrl();
  setText(originEl, url);
  if (originEl) {
    originEl.title = url;
  }
  if (urlRevealButton) {
    urlRevealButton.title = url;
    urlRevealButton.setAttribute("aria-label", "Show isolated page URL");
  }
  if (protectedMarkEl) {
    protectedMarkEl.title = "Protected by Cisco Secure Browser";
    protectedMarkEl.setAttribute("aria-label", "Protected by Cisco Secure Browser");
  }
}

function updateCurrentPageState(page = {}, reason = "") {
  if (!page || typeof page !== "object") {
    return false;
  }
  const href = normalizeDisplayUrl(page.href || page.url || "");
  const next = {
    ...currentPageState,
    href: isDisplayablePageUrl(href) ? href : currentPageState.href || "",
    title: String(page.title || currentPageState.title || "").trim(),
    readyState: String(page.readyState || currentPageState.readyState || "").trim(),
  };
  const changed =
    next.href !== currentPageState.href ||
    next.title !== currentPageState.title ||
    next.readyState !== currentPageState.readyState;
  currentPageState = next;
  syncWatermark();
  syncEnterpriseBanner();
  if (changed) {
    queueViewerTelemetry("viewer.page_state", {
      reason,
      host: deriveWatermarkHost(next.href),
      readyState: next.readyState,
      title: next.title,
    });
  }
  return changed;
}

function formatShortSessionId(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "Pending";
  }
  return text.length > 12 ? text.slice(-12) : text;
}

function formatElapsedDuration(startedAt) {
  const started = Date.parse(String(startedAt || ""));
  if (!Number.isFinite(started)) {
    return "00:00";
  }
  const seconds = Math.max(0, Math.floor((Date.now() - started) / 1000));
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const mm = String(minutes % 60).padStart(2, "0");
  const ss = String(seconds % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
}

// Viewer banner/progress helpers BEGIN
function hashBannerIdentifier(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "";
  }
  let hash = 2166136261;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16).padStart(8, "0").slice(0, 8);
}

function formatPrivateFallbackLabel(value, label, prefix) {
  const hash = hashBannerIdentifier(value);
  return hash ? `${label} ${prefix}-${hash}` : "";
}

function deriveTargetHostForSession(viewerSession, targetHint = "") {
  const swgContext = viewerSession?.swgContext || {};
  const candidate =
    swgContext.upstreamHost ||
    viewerSession?.viewerPolicySummary?.targetHost ||
    viewerSession?.targetOrigin ||
    targetHint ||
    viewerSession?.targetUrl ||
    "";
  try {
    return new URL(candidate).host;
  } catch {
    return String(candidate || "").replace(/^https?:\/\//i, "").split("/")[0];
  }
}

function deriveTenantLabelForSession(viewerSession) {
  const swgContext = viewerSession?.swgContext || {};
  return (
    viewerSession?.viewerPolicySummary?.tenantLabel ||
    viewerSession?.client?.tenantLabel ||
    viewerSession?.client?.organizationName ||
    viewerSession?.client?.orgName ||
    formatPrivateFallbackLabel(swgContext.tenantId, "Tenant", "t") ||
    "Enterprise tenant"
  );
}

function deriveProfileLabelForSession(viewerSession) {
  const swgContext = viewerSession?.swgContext || {};
  return (
    viewerSession?.viewerPolicySummary?.profileLabel ||
    viewerSession?.client?.profileLabel ||
    viewerSession?.client?.profileName ||
    formatPrivateFallbackLabel(swgContext.profileId, "Profile", "p")
  );
}

function deriveDataControlLabelForSession(viewerSession) {
  const summary = viewerSession?.viewerPolicySummary || {};
  const labels = [];
  for (const value of [
    summary.clipboardPolicy,
    summary.filePolicy,
    summary.downloadPolicy,
    summary.uploadPolicy,
  ]) {
    const text = String(value || "").trim();
    if (text) {
      labels.push(text);
    }
  }
  if (Array.isArray(summary.dataControlLabels)) {
    labels.push(...summary.dataControlLabels.map((value) => String(value || "").trim()).filter(Boolean));
  }
  return labels.length ? labels.slice(0, 2).join(" · ") : "Policy governed";
}

function derivePolicyLabelForSession(viewerSession) {
  const swgContext = viewerSession?.swgContext || {};
  const policy =
    viewerSession?.viewerPolicySummary?.policyReason ||
    swgContext.policy ||
    viewerSession?.client?.policyLabel ||
    "Enterprise policy";
  const profile = deriveProfileLabelForSession(viewerSession);
  if (!profile) {
    return policy;
  }
  if (String(policy).toLowerCase().includes(String(profile).toLowerCase())) {
    return policy;
  }
  return `${policy} · ${profile}`;
}

function deriveConnectionLabelForState({
  ended = false,
  sessionState = "",
  currentStage = "",
  currentDetail = "",
} = {}) {
  if (ended || sessionState === "terminated") {
    return "Ended";
  }
  if (currentStage === "live") {
    return "Live";
  }
  if (currentStage === "first-frame") {
    return "First frame rendered";
  }
  if (currentDetail) {
    return currentDetail;
  }
  return "Connecting";
}

function formatBannerValue(value, fallback) {
  const text = String(value || "").trim();
  return truncateTelemetryValue(text || fallback, 48);
}

function buildEnterpriseBannerModel(viewerSession, options = {}) {
  const transport = viewerSession?.transport || {};
  const mediaTermination = transport.mediaTermination || {};
  const gatewayAssignment = viewerSession?.gatewayAssignment || {};
  const sessionMode = String(viewerSession?.sessionMode || "").toLowerCase();
  const mediaMode =
    transport.mediaPlaneMode ||
    mediaTermination.mediaPlaneMode ||
    mediaTermination.mode ||
    viewerSession?.signalingMode ||
    "secure relay";

  return {
    tenant: formatBannerValue(deriveTenantLabelForSession(viewerSession), "Enterprise tenant"),
    target: formatBannerValue(
      deriveTargetHostForSession(viewerSession, options.targetUrlHint),
      "Resolving target",
    ),
    mode: sessionMode === "swg" ? "Cisco Secure Browsers" : "Secure browser",
    policy: formatBannerValue(derivePolicyLabelForSession(viewerSession), "Enterprise policy"),
    controls: formatBannerValue(
      deriveDataControlLabelForSession(viewerSession),
      "Policy governed",
    ),
    connection: formatBannerValue(
      deriveConnectionLabelForState({
        ended: options.sessionEnded,
        sessionState: viewerSession?.state,
        currentStage: options.currentViewerStage,
        currentDetail: options.currentViewerStageDetail,
      }),
      "Connecting",
    ),
    region: formatBannerValue(
      gatewayAssignment.region || viewerSession?.workerRegion || viewerSession?.workerAvailabilityZone,
      "Regional placement",
    ),
    session: `${formatElapsedDuration(viewerSession?.createdAt)} · ${formatBannerValue(mediaMode, "relay")}`,
  };
}

function getProgressStageState(stage, itemStage, stages = VIEWER_PROGRESS_STAGES) {
  const activeIndex = stages.indexOf(stage);
  const itemIndex = stages.indexOf(itemStage);
  return {
    done: activeIndex >= 0 && itemIndex >= 0 && itemIndex < activeIndex,
    active: itemStage === stage,
    error: stage === "ended" && itemStage === "live",
  };
}
// Viewer banner/progress helpers END

function deriveTargetHost() {
  return deriveWatermarkHost() || deriveTargetHostForSession(session, targetUrlHint);
}

function deriveTenantLabel() {
  return deriveTenantLabelForSession(session);
}

function deriveDataControlLabel() {
  return deriveDataControlLabelForSession(session);
}

function deriveConnectionLabel() {
  return deriveConnectionLabelForState({
    ended: sessionEnded,
    sessionState: session?.state,
    currentStage: currentViewerStage,
    currentDetail: currentViewerStageDetail,
  });
}

function startEnterpriseBannerTimer() {
  if (enterpriseBannerTimer) {
    return;
  }
  enterpriseBannerTimer = window.setInterval(syncEnterpriseBanner, 1000);
}

function clearEnterpriseBannerTimer() {
  if (!enterpriseBannerTimer) {
    return;
  }
  window.clearInterval(enterpriseBannerTimer);
  enterpriseBannerTimer = null;
}

function syncEnterpriseBanner() {
  const model = buildEnterpriseBannerModel(session, {
    currentViewerStage,
    currentViewerStageDetail,
    sessionEnded,
    targetUrlHint,
  });
  setText(bannerTenantEl, model.tenant);
  setText(bannerTargetEl, model.target);
  setText(bannerModeEl, model.mode);
  setText(bannerPolicyEl, model.policy);
  setText(bannerControlsEl, model.controls);
  setText(bannerConnectionEl, model.connection);
  setText(bannerRegionEl, model.region);
  setText(bannerSessionEl, model.session);
}

function updateProgressStage(stage, detail = "") {
  setText(stageTextEl, detail || "Connecting");
  if (!stageListEl) {
    return;
  }
  for (const item of stageListEl.querySelectorAll("li[data-stage]")) {
    const itemStage = item.getAttribute("data-stage");
    const state = getProgressStageState(stage, itemStage);
    item.classList.toggle("stage-done", state.done);
    item.classList.toggle("stage-active", state.active);
    item.classList.toggle("stage-error", state.error);
  }
}

function setViewerStage(stage, {
  detail = "",
  statusKind = "connecting",
  statusText = "",
  overlay = "",
  overlayVisible = true,
  actionLabel = "",
  telemetry = {},
} = {}) {
  const nextStage = String(stage || "loading");
  const nextDetail = detail || statusText || overlay || "Connecting";
  const changed = currentViewerStage !== nextStage || currentViewerStageDetail !== nextDetail;
  currentViewerStage = nextStage;
  currentViewerStageDetail = nextDetail;
  if (changed) {
    currentViewerStageStartedAt = performance.now();
    queueViewerTelemetry("viewer.stage", {
      stage: nextStage,
      detail: nextDetail,
      ...telemetry,
    });
  }
  updateProgressStage(nextStage, nextDetail);
  syncEnterpriseBanner();
  if (statusText) {
    setStatus(statusKind, statusText);
  }
  if (overlay) {
    setOverlay(overlay, overlayVisible, actionLabel);
  } else if (!overlayVisible) {
    setOverlay(nextDetail, false);
  }
}

function buildViewerHistoryState(marker) {
  const baseState =
    window.history.state && typeof window.history.state === "object"
      ? { ...window.history.state }
      : {};
  return {
    ...baseState,
    [VIEWER_HISTORY_TRAP_STATE_KEY]: marker,
  };
}

function buildViewerHistoryUrl(marker) {
  const next = new URL(buildViewerModeUrl(window.location.href), window.location.origin);
  next.hash = marker
    ? `${VIEWER_HISTORY_TRAP_HASH_KEY}=${encodeURIComponent(marker)}`
    : "";
  return `${next.pathname}${next.search}${next.hash}`;
}

function getViewerHistoryMarker(state = window.history.state, hash = window.location.hash) {
  const stateMarker = String(state?.[VIEWER_HISTORY_TRAP_STATE_KEY] || "").trim();
  if (stateMarker) {
    return stateMarker;
  }
  const rawHash = String(hash || "").replace(/^#/, "");
  if (!rawHash) {
    return "";
  }
  const params = new URLSearchParams(rawHash);
  return String(params.get(VIEWER_HISTORY_TRAP_HASH_KEY) || "").trim();
}

function isManagedViewerHistoryMarker(marker) {
  return marker === VIEWER_HISTORY_TRAP_BASE || marker === VIEWER_HISTORY_TRAP_SENTINEL;
}

function replaceViewerHistoryEntry(marker) {
  window.history.replaceState(
    buildViewerHistoryState(marker),
    "",
    buildViewerHistoryUrl(marker),
  );
}

function pushViewerHistoryEntry(marker) {
  window.history.pushState(
    buildViewerHistoryState(marker),
    "",
    buildViewerHistoryUrl(marker),
  );
}

function pushViewerHistorySentinelEntry() {
  pushViewerHistoryEntry(VIEWER_HISTORY_TRAP_SENTINEL);
}

function sendBrowserHistoryInput(action, reason = "") {
  if (!hasOpenInputControlChannel()) {
    return false;
  }
  return sendInput({
    type: "browser.history",
    action,
    reason,
  }, { preferControl: true });
}

function sendBrowserNavigationInput(action, reason = "viewer-nav") {
  const normalizedAction = String(action || "").trim().toLowerCase();
  if (normalizedAction === "reload") {
    return sendInput({
      type: "browser.reload",
      reason,
    }, { preferControl: true });
  }
  return sendBrowserHistoryInput(normalizedAction, reason);
}

function installPageNavigationControls() {
  navBackButton?.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    sendBrowserNavigationInput("back", "viewer-button");
  });
  navForwardButton?.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    sendBrowserNavigationInput("forward", "viewer-button");
  });
  navReloadButton?.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    sendBrowserNavigationInput("reload", "viewer-button");
  });
}

function armViewerHistoryTrap() {
  if (!sessionId || viewerHistoryTrapArmed) {
    return;
  }

  const currentMarker = getViewerHistoryMarker();

  if (currentMarker !== VIEWER_HISTORY_TRAP_BASE) {
    replaceViewerHistoryEntry(VIEWER_HISTORY_TRAP_BASE);
  }

  if (getViewerHistoryMarker() !== VIEWER_HISTORY_TRAP_SENTINEL) {
    pushViewerHistorySentinelEntry();
  }
  viewerHistoryTrapArmed = true;
}

function restoreViewerHistorySentinel() {
  if (!viewerHistoryTrapArmed || !sessionId) {
    return;
  }

  if (viewerHistoryTrapBounceInFlight) {
    return;
  }

  viewerHistoryTrapBounceInFlight = true;
  window.setTimeout(() => {
    viewerHistoryTrapBounceInFlight = false;
    const currentMarker = getViewerHistoryMarker();
    if (currentMarker === VIEWER_HISTORY_TRAP_SENTINEL) {
      return;
    }
    if (currentMarker === VIEWER_HISTORY_TRAP_BASE) {
      window.history.forward();
      return;
    }
    replaceViewerHistoryEntry(VIEWER_HISTORY_TRAP_BASE);
    pushViewerHistorySentinelEntry();
  }, 0);
}

function handleViewerPopState(event) {
  if (!viewerHistoryTrapArmed || !sessionId) {
    return;
  }

  const marker = getViewerHistoryMarker(event.state);
  if (!isManagedViewerHistoryMarker(marker)) {
    return;
  }

  if (marker === VIEWER_HISTORY_TRAP_SENTINEL) {
    return;
  }

  const sent = sendBrowserHistoryInput("back", "browser-popstate");
  debugLog("browser-history-back", { sent, marker });
  restoreViewerHistorySentinel();
}

function readStoredActiveViewerSession() {
  try {
    const raw = window.sessionStorage.getItem(ACTIVE_VIEWER_SESSION_STORAGE_KEY);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") {
      return null;
    }
    const storedSessionId = String(parsed.sessionId || "").trim();
    const storedViewerUrl = String(parsed.viewerUrl || "").trim();
    if (!storedSessionId || !storedViewerUrl) {
      return null;
    }
    return {
      sessionId: storedSessionId,
      viewerUrl: storedViewerUrl,
    };
  } catch {
    return null;
  }
}

function persistActiveViewerSession() {
  if (!sessionId) {
    return;
  }
  try {
    window.sessionStorage.setItem(
      ACTIVE_VIEWER_SESSION_STORAGE_KEY,
      JSON.stringify({
        sessionId,
        viewerUrl: getCanonicalViewerLocation(),
      }),
    );
  } catch {
    // Ignore storage failures in private browsing or quota pressure.
  }
}

function clearStoredActiveViewerSession() {
  try {
    const current = readStoredActiveViewerSession();
    if (current?.sessionId === sessionId) {
      window.sessionStorage.removeItem(ACTIVE_VIEWER_SESSION_STORAGE_KEY);
    }
  } catch {
    // Ignore storage failures during teardown.
  }
}

function recoverToStoredActiveViewerSession() {
  if (staleViewerHistoryRecoveryAttempted || !sessionId) {
    return false;
  }
  const current = readStoredActiveViewerSession();
  if (!current || current.sessionId === sessionId) {
    return false;
  }
  staleViewerHistoryRecoveryAttempted = true;
  setViewerStage("loading", {
    detail: "Returning to active session",
    statusText: "Returning",
    overlay: "Returning to the active RBI session",
  });
  window.location.replace(current.viewerUrl);
  return true;
}

function shouldRecoverStaleViewerEntry(error) {
  if (staleViewerHistoryRecoveryAttempted || !sessionId) {
    return false;
  }

  const message = String(error?.message || "");
  if (!/session not found|session is terminated|session has expired|failed to load session: (404|410)/i.test(message)) {
    return false;
  }

  if (readStoredActiveViewerSession()) {
    return true;
  }

  if (window.history.length < 2 || !document.referrer) {
    return false;
  }

  try {
    const referrerUrl = new URL(document.referrer, window.location.origin);
    if (referrerUrl.origin !== window.location.origin) {
      return false;
    }
    if (referrerUrl.pathname !== window.location.pathname) {
      return false;
    }
    const referrerSessionId = referrerUrl.searchParams.get("sessionId");
    return Boolean(referrerSessionId && referrerSessionId !== sessionId);
  } catch {
    return false;
  }
}

function recoverStaleViewerEntry() {
  if (staleViewerHistoryRecoveryAttempted) {
    return true;
  }
  staleViewerHistoryRecoveryAttempted = true;
  setViewerStage("loading", {
    detail: "Returning to active session",
    statusText: "Returning",
    overlay: "Returning to the active RBI session",
  });
  window.setTimeout(() => {
    window.history.forward();
  }, 0);
  return true;
}

function hasRenderableVideo() {
  return (
    hasRemoteVideo &&
    remoteVideo.videoWidth > 0 &&
    remoteVideo.videoHeight > 0 &&
    !remoteVideo.paused &&
    remoteVideo.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
  );
}

function maybeMarkLiveState(reason = "") {
  if (!hasRenderableVideo()) {
    if (reason) {
      debugLog("defer-live", reason);
    }
    return false;
  }
  if (isAudioStartupGatePending()) {
    if (reason) {
      debugLog("defer-live-audio", reason);
    }
    noteAudioStartupGateStarted(reason);
    setViewerStage("media", {
      detail: "Syncing audio",
      statusText: "Syncing audio",
      overlay: "Waiting for audio before entering the live session.",
    });
    scheduleAudioStartupGateCheck(reason, 0);
    return false;
  }
  maybeMarkFirstFrame(reason);
  if (!firstFrameRecorded) {
    if (reason) {
      debugLog("defer-live-first-render", reason);
    }
    return false;
  }
  markLiveState();
  return true;
}

function debugLog(...args) {
  console.debug("[viewer]", ...args);
}

// Viewer first render helpers BEGIN
function getHaveCurrentDataReadyState() {
  return typeof HTMLMediaElement !== "undefined" ? HTMLMediaElement.HAVE_CURRENT_DATA : 2;
}

function getPresentedVideoFrameCount(video) {
  if (typeof video?.getVideoPlaybackQuality !== "function") {
    return 0;
  }
  const quality = video.getVideoPlaybackQuality();
  const totalVideoFrames = Number(quality?.totalVideoFrames || 0);
  return Number.isFinite(totalVideoFrames) && totalVideoFrames > 0
    ? Math.round(totalVideoFrames)
    : 0;
}

function hasFirstRenderedVideoFrameEvidence(video, metadata = {}, source = "") {
  if (!video || video.videoWidth <= 0 || video.videoHeight <= 0) {
    return false;
  }
  const presentedFrames = Number(metadata?.presentedFrames || 0);
  if (Number.isFinite(presentedFrames) && presentedFrames > 0) {
    return true;
  }
  if (source === "video-frame-callback") {
    return true;
  }
  if (getPresentedVideoFrameCount(video) > 0) {
    return true;
  }
  if (
    typeof video.requestVideoFrameCallback === "function" ||
    typeof video.getVideoPlaybackQuality === "function"
  ) {
    return false;
  }
  return !video.paused && video.readyState >= getHaveCurrentDataReadyState();
}

function buildFirstRenderedTelemetryFields(video, metadata = {}, reason = "") {
  const presentedFrames = Number(metadata?.presentedFrames || getPresentedVideoFrameCount(video) || 0);
  return {
    reason,
    videoWidth: video?.videoWidth || 0,
    videoHeight: video?.videoHeight || 0,
    readyState: video?.readyState || 0,
    presentedFrames: Number.isFinite(presentedFrames) ? Math.round(presentedFrames) : 0,
  };
}
// Viewer first render helpers END

function getRenderedVideoFrameCount() {
  if (typeof remoteVideo.getVideoPlaybackQuality === "function") {
    const quality = remoteVideo.getVideoPlaybackQuality();
    if (quality && Number.isFinite(quality.totalVideoFrames)) {
      return quality.totalVideoFrames;
    }
  }

  const webkitCount = Number(remoteVideo.webkitDecodedFrameCount || 0);
  return Number.isFinite(webkitCount) ? webkitCount : 0;
}

function noteVideoFrameProgress(reason = "") {
  lastVideoFrameAt = performance.now();
  lastVideoFrameCount = getRenderedVideoFrameCount();
  if (reason) {
    debugLog("video-progress", reason, lastVideoFrameCount);
  }
}

function markFirstFrame(reason = "", metadata = {}) {
  if (firstFrameRecorded) {
    return false;
  }
  if (!hasFirstRenderedVideoFrameEvidence(remoteVideo, metadata, reason)) {
    return false;
  }
  firstFrameRecorded = true;
  recordViewerMilestone(VIEWER_FIRST_RENDERED_MILESTONE, {
    ...buildFirstRenderedTelemetryFields(remoteVideo, metadata, reason),
    progressFrames: lastVideoFrameCount || getRenderedVideoFrameCount(),
    ...metadata,
  });
  if (!isLive) {
    setViewerStage("first-frame", {
      detail: "First frame rendered",
      statusText: "Connecting",
      overlay: "First frame rendered. Finalizing the secure session.",
    });
  }
  return true;
}

function maybeMarkFirstFrame(reason = "", metadata = {}) {
  if (firstFrameRecorded) {
    return false;
  }
  if (
    remoteVideo.videoWidth > 0 &&
    remoteVideo.videoHeight > 0 &&
    remoteVideo.readyState >= getHaveCurrentDataReadyState()
  ) {
    return markFirstFrame(reason, metadata);
  }
  return false;
}

function stopVideoFrameObserver() {
  if (
    videoFrameCallbackId &&
    typeof remoteVideo.cancelVideoFrameCallback === "function"
  ) {
    remoteVideo.cancelVideoFrameCallback(videoFrameCallbackId);
  }
  videoFrameCallbackId = 0;
}

function startVideoFrameObserver() {
  stopVideoFrameObserver();
  if (typeof remoteVideo.requestVideoFrameCallback !== "function") {
    return;
  }

  const onFrame = (_now, metadata = {}) => {
    lastVideoFrameAt = performance.now();
    if (Number.isFinite(metadata.presentedFrames)) {
      lastVideoFrameCount = metadata.presentedFrames;
    } else {
      lastVideoFrameCount = getRenderedVideoFrameCount();
    }
    markFirstFrame("video-frame-callback", {
      presentedFrames: Number(metadata.presentedFrames || lastVideoFrameCount || 0),
    });
    if (overlayEl.style.display !== "none" && hasRenderableVideo()) {
      maybeMarkLiveState("frame-callback");
    }
    videoFrameCallbackId = remoteVideo.requestVideoFrameCallback(onFrame);
  };

  videoFrameCallbackId = remoteVideo.requestVideoFrameCallback(onFrame);
}

function clearVideoStallTimer() {
  if (!videoStallTimer) {
    return;
  }
  window.clearInterval(videoStallTimer);
  videoStallTimer = null;
}

function clearVideoStallWatch() {
  clearVideoStallTimer();
  stopVideoFrameObserver();
  lastVideoFrameAt = 0;
  lastVideoFrameCount = 0;
  lastVideoRecoveryAt = 0;
}

function shouldWatchForVideoStall() {
  return (
    !sessionEnded &&
    !unloadSent &&
    !isStubWorkerSession() &&
    isLive &&
    hasRemoteVideo &&
    peer?.connectionState === "connected" &&
    session?.state === "streaming" &&
    !remoteVideo.paused &&
    remoteVideo.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
  );
}

async function maybeRecoverFrozenVideo() {
  if (!shouldWatchForVideoStall()) {
    return;
  }

  const now = performance.now();
  const renderedFrames = getRenderedVideoFrameCount();
  if (renderedFrames > lastVideoFrameCount) {
    noteVideoFrameProgress("frame-count-advanced");
    maybeMarkLiveState("frame-count-advanced");
    return;
  }

  if (!lastVideoFrameAt) {
    noteVideoFrameProgress("watch-init");
    return;
  }

  const stalledForMs = now - lastVideoFrameAt;
  if (stalledForMs < VIDEO_STALL_THRESHOLD_MS) {
    return;
  }

  if (now - lastVideoRecoveryAt < VIDEO_STALL_RECOVERY_COOLDOWN_MS) {
    return;
  }

  lastVideoRecoveryAt = now;
  if (stalledForMs >= VIDEO_STALL_RESTART_THRESHOLD_MS) {
    recoveryAttemptCount += 1;
    setViewerStage("media", {
      detail: "Restarting stalled stream",
      statusText: "Recovering",
      overlay: "Video stalled. Starting a fresh secure session.",
      actionLabel: "Start fresh session",
      telemetry: {
        reason: "video-stall-restart",
        attempt: recoveryAttemptCount,
        stalledForMs: Math.round(stalledForMs),
      },
    });
    await replaceWithFreshSession({
      reason: "Video stalled. Starting a fresh session for this viewer.",
      fallbackToLaunch: true,
    });
    return;
  }

  recoveryAttemptCount += 1;
  setViewerStage("media", {
    detail: "Refreshing secure stream",
    statusText: "Recovering",
    overlay: "Video stalled. Refreshing secure stream.",
    actionLabel: "Start fresh session",
    telemetry: {
      reason: "video-stall-ice-restart",
      attempt: recoveryAttemptCount,
      stalledForMs: Math.round(stalledForMs),
    },
  });
  armDisconnectTimer("Video stalled. Trying to recover.");
  void requestIceRestart("Video stalled. Refreshing secure stream.");
}

function ensureVideoStallWatch() {
  if (videoStallTimer || isStubWorkerSession()) {
    return;
  }
  noteVideoFrameProgress("watch-start");
  startVideoFrameObserver();
  videoStallTimer = window.setInterval(() => {
    void maybeRecoverFrozenVideo();
  }, VIDEO_STALL_CHECK_INTERVAL_MS);
}

function getAllowedCandidateTypes() {
  const defaults = ["host", "srflx", "relay"];
  const configured = Array.isArray(session?.allowedCandidateTypes)
    ? session.allowedCandidateTypes
    : defaults;
  const normalized = configured
    .map((value) => String(value).toLowerCase())
    .filter((value) => defaults.includes(value));
  return normalized.length ? normalized : defaults;
}

function extractCandidateType(candidateLine = "") {
  const match = candidateLine.match(/\btyp\s+([a-z]+)/i);
  return match?.[1]?.toLowerCase() || "";
}

function isAllowedCandidate(candidate) {
  const candidateLine = candidate?.candidate || "";
  const candidateType = (candidate?.type || extractCandidateType(candidateLine)).toLowerCase();
  if (!candidateType) {
    return true;
  }
  return getAllowedCandidateTypes().includes(candidateType);
}

function filterSdpCandidates(sdp = "") {
  if (!sdp) {
    return sdp;
  }

  const lines = sdp.split(/\r\n|\n/);
  const filtered = lines.filter((line) => {
    if (!line.startsWith("a=candidate:")) {
      return true;
    }
    return isAllowedCandidate({ candidate: line.slice("a=".length) });
  });
  return filtered.join("\r\n");
}

function isViewerGatewayWebrtcRelaySession() {
  return Boolean(viewerGatewayWebrtcConfig?.enabled);
}

function waitForIceGatheringComplete(pc, timeoutMs = 5000) {
  if (!pc || pc.iceGatheringState === "complete") {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    let settled = false;
    const cleanup = () => {
      pc.removeEventListener("icegatheringstatechange", onStateChange);
      window.clearTimeout(timer);
    };
    const done = () => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolve();
    };
    const onStateChange = () => {
      if (pc.iceGatheringState === "complete") {
        done();
      }
    };
    const timer = window.setTimeout(done, timeoutMs);
    pc.addEventListener("icegatheringstatechange", onStateChange);
    onStateChange();
  });
}

function configureViewerGatewayPeer() {
  if (!isViewerGatewayWebrtcRelaySession() || !peer) {
    return;
  }

  peer.addTransceiver("video", { direction: "recvonly" });
  peer.addTransceiver("audio", { direction: "recvonly" });
  registerInputChannel(
    peer.createDataChannel(
      viewerGatewayWebrtcConfig.inputPointerName || INPUT_POINTER_CHANNEL_LABEL,
      {
        ordered: false,
        maxRetransmits: 0,
      },
    ),
  );
  registerInputChannel(
    peer.createDataChannel(
      viewerGatewayWebrtcConfig.inputControlName || INPUT_CONTROL_CHANNEL_LABEL,
    ),
  );
  debugLog("gateway-webrtc-peer-configured", {
    mediaPlaneMode: viewerGatewayWebrtcConfig.mediaPlaneMode,
    protocol: viewerGatewayWebrtcConfig.protocol,
  });
}

function getViewerGatewayToken() {
  return normalizeViewerMediaRelayValue(
    session?.viewerGatewayToken ||
      session?.viewerMediaRelayToken ||
      session?.viewerSignalingToken ||
      session?.viewerToken,
  );
}

async function postViewerGatewayOffer(sdp) {
  const token = getViewerGatewayToken();
  if (!token) {
    throw new Error("Missing viewer gateway token");
  }
  const response = await fetch(viewerGatewayWebrtcConfig.offerUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(buildViewerGatewayOfferRequest(sessionId, token, sdp)),
  });
  const responseText = await response.text();
  let payload = {};
  if (responseText) {
    try {
      payload = JSON.parse(responseText);
    } catch {
      payload = { message: responseText };
    }
  }
  if (!response.ok) {
    throw new Error(
      payload?.message || `Gateway offer failed with status ${response.status}`,
    );
  }
  const answerSdp = extractViewerGatewayAnswerSdp(payload);
  if (!answerSdp) {
    throw new Error("Gateway offer response did not include an SDP answer");
  }
  return {
    ...payload,
    sdp: answerSdp,
  };
}

async function negotiateViewerGatewayWebrtc(reason = "initial", offerOptions = {}) {
  if (!isViewerGatewayWebrtcRelaySession() || !peer) {
    return false;
  }
  if (viewerGatewayNegotiationPromise) {
    return viewerGatewayNegotiationPromise;
  }

  viewerGatewayNegotiationPromise = (async () => {
    if (peer.signalingState !== "stable") {
      debugLog("defer-gateway-offer", "signalingState=" + peer.signalingState);
      pendingIceRestart = true;
      return false;
    }
    setViewerStage("media", {
      detail: "Establishing secure media path",
      statusText: "Connecting",
      overlay: "Establishing secure media path",
      telemetry: { reason },
    });
    const offer = await peer.createOffer(offerOptions);
    await peer.setLocalDescription(offer);
    await waitForIceGatheringComplete(peer);
    const offerSdp = filterSdpCandidates(peer.localDescription?.sdp || offer.sdp || "");
    const gatewayAnswer = await postViewerGatewayOffer(offerSdp);
    await peer.setRemoteDescription({
      type: "answer",
      sdp: filterSdpCandidates(gatewayAnswer.sdp),
    });
    pendingIceRestart = false;
    debugLog("gateway-webrtc-answer-applied", reason);
    return true;
  })();

  try {
    return await viewerGatewayNegotiationPromise;
  } finally {
    viewerGatewayNegotiationPromise = null;
  }
}

function setStatus(kind, text) {
  if (!statusEl) {
    return;
  }
  statusEl.className = `status status-${kind}`;
  statusEl.textContent = text;
}

function setOverlayAction(label = "") {
  if (!overlayActionButton) {
    return;
  }
  if (!label || !getRestartTargetUrl()) {
    overlayActionButton.classList.add("hidden");
    return;
  }
  overlayActionButton.textContent = label;
  overlayActionButton.classList.remove("hidden");
}

function setOverlay(text, visible = true, actionLabel = "") {
  overlayTextEl.textContent = text;
  overlayEl.style.display = visible ? "grid" : "none";
  setOverlayAction(actionLabel);
}

function syncRestartButton() {
  if (!restartSessionButton) {
    return;
  }
  restartSessionButton.disabled = !getRestartTargetUrl();
}

function markLiveState() {
  isLive = true;
  clearAudioStartupGateTimer();
  canRequestIceRestart = true;
  pendingIceRestart = false;
  clearDisconnectTimer();
  clearSlowStartTimer();
  clearRestartIceTimer();
  stopSessionPolling();
  recordViewerMilestone("viewer.live", {
    firstFrameRecorded,
  });
  setViewerStage("live", {
    detail: "Remote browser live",
    statusKind: "live",
    statusText: "Live",
    overlayVisible: false,
  });
  remoteVideo.classList.add("cursor-live");
  noteVideoFrameProgress("live");
  ensureVideoStallWatch();
  scheduleStreamProfileSync({ force: true });
  schedulePostLiveStreamProfileSync();
}

function syncAudioButton() {
  if (!audioToggleButton) {
    return;
  }
  if (!hasRemoteAudio) {
    audioToggleButton.classList.add("hidden");
    return;
  }
  audioToggleButton.classList.remove("hidden");
  audioToggleButton.textContent = audioEnabled ? "Sound on" : "Enable sound";
}

function ensureRemoteMediaStream() {
  if (!(remoteMediaStream instanceof MediaStream)) {
    remoteMediaStream = new MediaStream();
    remoteVideo.srcObject = remoteMediaStream;
  }
  return remoteMediaStream;
}

async function ensureVideoPlayback(reason = "") {
  if (sessionEnded || unloadSent || !(remoteVideo.srcObject instanceof MediaStream)) {
    return false;
  }

  try {
    const playPromise = remoteVideo.play();
    if (playPromise && typeof playPromise.then === "function") {
      await playPromise;
    }
    debugLog("video-play", reason, {
      paused: remoteVideo.paused,
      readyState: remoteVideo.readyState,
      currentTime: remoteVideo.currentTime,
    });
    return !remoteVideo.paused;
  } catch (error) {
    debugLog("video-play-failed", reason, error?.name || error?.message || String(error));
    return false;
  }
}

function clearPlaybackKickTimer() {
  if (!playbackKickTimer) {
    return;
  }
  window.clearTimeout(playbackKickTimer);
  playbackKickTimer = null;
}

function hasPendingHybridReplayClick() {
  return (
    handoffMode === "hybrid" &&
    !hybridHandoffReplayClickSent &&
    Number.isFinite(handoffClickX) &&
    Number.isFinite(handoffClickY)
  );
}

function clearHybridHandoffReplayClickTimer() {
  if (!hybridHandoffReplayClickTimer) {
    return;
  }
  window.clearTimeout(hybridHandoffReplayClickTimer);
  hybridHandoffReplayClickTimer = null;
}

function clearHybridHandoffReplayClickParams() {
  const next = new URL(window.location.href);
  next.searchParams.delete("handoffClickX");
  next.searchParams.delete("handoffClickY");
  next.searchParams.delete("handoffClickUrl");
  window.history.replaceState({}, "", `${next.pathname}${next.search}`);
}

function scheduleHybridHandoffReplayClick(reason = "", delayMs = HYBRID_HANDOFF_REMOTE_CLICK_DELAY_MS) {
  if (
    !hasPendingHybridReplayClick() ||
    hybridHandoffReplayClickTimer ||
    sessionEnded ||
    unloadSent ||
    !hasOpenInputControlChannel()
  ) {
    return;
  }

  hybridHandoffReplayClickTimer = window.setTimeout(() => {
    hybridHandoffReplayClickTimer = null;
    if (
      !hasPendingHybridReplayClick() ||
      sessionEnded ||
      unloadSent ||
      !hasOpenInputControlChannel()
    ) {
      return;
    }

    hybridHandoffReplayClickSent = true;
    clearHybridHandoffReplayClickParams();
    debugLog("hybrid-handoff-replay-click", reason, {
      x: handoffClickX,
      y: handoffClickY,
      url: handoffClickUrl || targetUrlHint || "",
    });
    sendReliablePointerSync({
      x: Math.max(0, Math.round(handoffClickX)),
      y: Math.max(0, Math.round(handoffClickY)),
    });
    sendInput({
      type: "pointer.button",
      button: 0,
      action: "down",
    }, { preferControl: true });
    window.setTimeout(() => {
      sendInput({
        type: "pointer.button",
        button: 0,
        action: "up",
      }, { preferControl: true });
    }, 40);
  }, delayMs);
}

function clearAudioEnableRetryTimer() {
  if (!audioEnableRetryTimer) {
    return;
  }
  window.clearTimeout(audioEnableRetryTimer);
  audioEnableRetryTimer = null;
}

function clearAudioStartupGateTimer() {
  if (!audioStartupGateTimer) {
    return;
  }
  window.clearTimeout(audioStartupGateTimer);
  audioStartupGateTimer = null;
}

function noteAudioStartupGateStarted(reason = "") {
  if (audioStartupGateStartedAt) {
    return;
  }
  audioStartupGateStartedAt = performance.now();
  debugLog("audio-startup-gate", {
    reason,
    enabled: audioStartupSyncEnabled,
  });
}

function getAudioStartupGateElapsedMs() {
  if (!audioStartupGateStartedAt) {
    return 0;
  }
  return Math.max(0, performance.now() - audioStartupGateStartedAt);
}

function isAudioStartupGatePending() {
  if (!audioStartupSyncEnabled || audioStartupGateSatisfied || isLive || sessionEnded || unloadSent) {
    return false;
  }
  if (!audioStartupGateStartedAt) {
    return true;
  }
  return true;
}

function getAudioInboundProgress(report) {
  if (!report) {
    return null;
  }
  return {
    packetsReceived: Number(report.packetsReceived || 0),
    bytesReceived: Number(report.bytesReceived || 0),
    jitterBufferEmittedCount: Number(report.jitterBufferEmittedCount || 0),
    totalSamplesDuration: Number(report.totalSamplesDuration || 0),
    totalAudioEnergy: Number(report.totalAudioEnergy || 0),
  };
}

function hasMeaningfulAudioStartupProgress(current, previous = null) {
  if (!current) {
    return false;
  }
  const bytesAdvanced = previous ? current.bytesReceived - previous.bytesReceived : current.bytesReceived;
  const samplesAdvanced = previous
    ? current.totalSamplesDuration - previous.totalSamplesDuration
    : current.totalSamplesDuration;
  const jitterAdvanced = previous
    ? current.jitterBufferEmittedCount - previous.jitterBufferEmittedCount
    : current.jitterBufferEmittedCount;
  const energyAdvanced = previous
    ? current.totalAudioEnergy - previous.totalAudioEnergy
    : current.totalAudioEnergy;
  return (
    current.bytesReceived >= AUDIO_STARTUP_SYNC_MIN_BYTES_RECEIVED &&
    current.totalSamplesDuration >= AUDIO_STARTUP_SYNC_MIN_TOTAL_SAMPLES_DURATION_SEC &&
    current.totalAudioEnergy > 0 &&
    (bytesAdvanced >= AUDIO_STARTUP_SYNC_MIN_BYTES_ADVANCE ||
      samplesAdvanced >= AUDIO_STARTUP_SYNC_MIN_SAMPLE_ADVANCE_SEC ||
      jitterAdvanced >= 1 ||
      energyAdvanced > 0)
  );
}

async function sampleInboundAudioProgress() {
  if (!peer || typeof peer.getStats !== "function") {
    return null;
  }
  const report = await peer.getStats();
  for (const value of report.values()) {
    if (value.type === "inbound-rtp" && value.kind === "audio") {
      return getAudioInboundProgress(value);
    }
  }
  return null;
}

function scheduleAudioStartupGateCheck(reason = "", delayMs = AUDIO_STARTUP_SYNC_POLL_INTERVAL_MS) {
  if (
    !audioStartupSyncEnabled ||
    audioStartupGateSatisfied ||
    sessionEnded ||
    unloadSent ||
    isLive ||
    audioStartupGateTimer ||
    audioStartupGateCheckInFlight
  ) {
    return;
  }

  noteAudioStartupGateStarted(reason);
  audioStartupGateTimer = window.setTimeout(async () => {
    audioStartupGateTimer = null;
    audioStartupGateCheckInFlight = true;
    try {
      if (
        !audioStartupSyncEnabled ||
        audioStartupGateSatisfied ||
        sessionEnded ||
        unloadSent ||
        isLive
      ) {
        return;
      }

      const elapsedMs = getAudioStartupGateElapsedMs();
      if (elapsedMs >= AUDIO_STARTUP_SYNC_MAX_WAIT_MS) {
        audioStartupGateSatisfied = true;
        debugLog("audio-startup-gate-timeout", {
          elapsedMs: Math.round(elapsedMs),
          hasRemoteAudio,
          audioEnabled,
        });
        maybeMarkLiveState("audio-startup-timeout");
        return;
      }

      if (!hasRemoteAudio) {
        scheduleAudioStartupGateCheck(reason, AUDIO_STARTUP_SYNC_POLL_INTERVAL_MS);
        return;
      }

      if (!audioEnabled) {
        scheduleAudioEnableRetry("audio-startup-gate", 0);
        scheduleAudioStartupGateCheck(reason, AUDIO_STARTUP_SYNC_POLL_INTERVAL_MS);
        return;
      }

      if (workerAudioReady) {
        audioStartupGateSatisfied = true;
        debugLog("audio-startup-gate-ready", {
          elapsedMs: Math.round(elapsedMs),
          source: "worker-media",
        });
        maybeMarkLiveState("audio-startup-ready");
        return;
      }

      const progress = await sampleInboundAudioProgress().catch((error) => {
        debugLog("audio-startup-gate-stats-failed", error?.message || String(error));
        return null;
      });

      if (!progress) {
        scheduleAudioStartupGateCheck(reason, AUDIO_STARTUP_SYNC_POLL_INTERVAL_MS);
        return;
      }

      if (!audioStartupLastProgress) {
        audioStartupAdvancingPolls = hasMeaningfulAudioStartupProgress(progress) ? 1 : 0;
      } else if (hasMeaningfulAudioStartupProgress(progress, audioStartupLastProgress)) {
        audioStartupAdvancingPolls += 1;
      } else {
        audioStartupAdvancingPolls = 0;
      }
      audioStartupLastProgress = progress;

      if (audioStartupAdvancingPolls >= AUDIO_STARTUP_SYNC_MIN_ADVANCING_POLLS) {
        audioStartupGateSatisfied = true;
        debugLog("audio-startup-gate-ready", {
          elapsedMs: Math.round(elapsedMs),
          progress,
        });
        maybeMarkLiveState("audio-startup-ready");
        return;
      }

      scheduleAudioStartupGateCheck(reason, AUDIO_STARTUP_SYNC_POLL_INTERVAL_MS);
    } finally {
      audioStartupGateCheckInFlight = false;
    }
  }, delayMs);
}

function scheduleAudioEnableRetry(reason = "", delayMs = AUDIO_ENABLE_RETRY_INTERVAL_MS) {
  if (
    audioEnableRetryTimer ||
    sessionEnded ||
    unloadSent ||
    !hasRemoteAudio ||
    audioEnabled
  ) {
    return;
  }

  audioEnableRetryTimer = window.setTimeout(async () => {
    audioEnableRetryTimer = null;

    if (
      sessionEnded ||
      unloadSent ||
      !hasRemoteAudio ||
      audioEnabled ||
      !(remoteVideo.srcObject instanceof MediaStream)
    ) {
      return;
    }

    audioEnableRetryAttempts += 1;
    const enabled = await setAudioEnabled(true, { silent: true });
    if (enabled) {
      debugLog("audio-enable-retry-succeeded", `${reason}:${audioEnableRetryAttempts}`);
      audioEnableRetryAttempts = 0;
      return;
    }

    if (audioEnableRetryAttempts < AUDIO_ENABLE_RETRY_MAX_ATTEMPTS) {
      scheduleAudioEnableRetry(reason, AUDIO_ENABLE_RETRY_INTERVAL_MS);
    }
  }, delayMs);
}

function schedulePlaybackKick(reason = "", delayMs = 120) {
  if (playbackKickTimer || sessionEnded || unloadSent) {
    return;
  }

  playbackKickTimer = window.setTimeout(async () => {
    playbackKickTimer = null;

    if (sessionEnded || unloadSent || !hasRemoteVideo || !(remoteVideo.srcObject instanceof MediaStream)) {
      return;
    }

    if (!remoteVideo.paused && remoteVideo.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
      maybeMarkLiveState(`${reason}-playback-ready`);
      return;
    }

    playbackKickAttempts += 1;
    await ensureVideoPlayback(`${reason}:${playbackKickAttempts}`);
    if (!maybeMarkLiveState(`${reason}-kick`)) {
      const nextDelayMs = Math.min(1000, 120 + playbackKickAttempts * 60);
      if (playbackKickAttempts < 25) {
        schedulePlaybackKick(reason, nextDelayMs);
      }
    }
  }, delayMs);
}

async function setAudioEnabled(enabled, { silent = false } = {}) {
  if (!hasRemoteAudio) {
    clearAudioEnableRetryTimer();
    audioEnableRetryAttempts = 0;
    audioEnabled = false;
    syncAudioButton();
    return false;
  }

  if (!enabled) {
    clearAudioEnableRetryTimer();
    audioEnableRetryAttempts = 0;
    remoteVideo.muted = true;
    audioEnabled = false;
    syncAudioButton();
    return true;
  }

  try {
    remoteVideo.muted = false;
    remoteVideo.volume = 1;
    await remoteVideo.play();
    clearAudioEnableRetryTimer();
    audioEnableRetryAttempts = 0;
    audioEnabled = true;
    syncAudioButton();
    return true;
  } catch (error) {
    remoteVideo.muted = true;
    audioEnabled = false;
    syncAudioButton();
    if (!silent) {
      console.error("[viewer] failed to enable audio", error);
    }
    scheduleAudioEnableRetry("play-blocked");
    return false;
  }
}

function scheduleWheel(payload) {
  if (pendingWheel) {
    pendingWheel = {
      ...payload,
      deltaX: pendingWheel.deltaX + payload.deltaX,
      deltaY: pendingWheel.deltaY + payload.deltaY,
    };
  } else {
    pendingWheel = payload;
  }

  if (wheelTimer) {
    return;
  }

  wheelTimer = window.setTimeout(() => {
    wheelTimer = null;
    if (pendingWheel) {
      sendInput(pendingWheel);
      pendingWheel = null;
    }
  }, WHEEL_BATCH_INTERVAL_MS);
}

function clearSlowStartTimer() {
  if (!slowStartTimer) {
    return;
  }
  window.clearTimeout(slowStartTimer);
  slowStartTimer = null;
}

function clearDisconnectTimer() {
  if (!disconnectTimer) {
    return;
  }
  window.clearTimeout(disconnectTimer);
  disconnectTimer = null;
}

function armDisconnectTimer(message = "Connection interrupted. Trying to recover.") {
  if (disconnectTimer) {
    return;
  }
  recoveryAttemptCount += 1;
  setViewerStage("media", {
    detail: "Recovering connection",
    statusText: "Reconnecting",
    overlay: message,
    actionLabel: "Start fresh session",
    telemetry: {
      reason: message,
      attempt: recoveryAttemptCount,
    },
  });
  disconnectTimer = window.setTimeout(() => {
    disconnectTimer = null;
    const state = peer?.connectionState;
    if (state === "connected") {
      return;
    }
    setViewerStage("ended", {
      detail: "Connection lost",
      statusKind: "ended",
      statusText: "Disconnected",
      overlay: "Connection lost",
      actionLabel: "Start fresh session",
    });
  }, 12000);
}

function clearSignalingReconnectTimer() {
  if (!signalingReconnectTimer) {
    return;
  }
  window.clearTimeout(signalingReconnectTimer);
  signalingReconnectTimer = null;
}

function clearSignalingHeartbeatTimer() {
  if (!signalingHeartbeatTimer) {
    return;
  }
  window.clearInterval(signalingHeartbeatTimer);
  signalingHeartbeatTimer = null;
}

function clearRestartIceTimer() {
  if (!restartIceTimer) {
    return;
  }
  window.clearTimeout(restartIceTimer);
  restartIceTimer = null;
}

function clearStreamProfileSyncTimer() {
  if (!streamProfileSyncTimer) {
    return;
  }
  window.clearTimeout(streamProfileSyncTimer);
  streamProfileSyncTimer = null;
}

function clearPostLiveStreamProfileSyncTimer() {
  if (!postLiveStreamProfileTimer) {
    return;
  }
  window.clearTimeout(postLiveStreamProfileTimer);
  postLiveStreamProfileTimer = null;
}

function roundToEven(value) {
  const rounded = Math.max(2, Math.round(value));
  return rounded % 2 === 0 ? rounded : rounded - 1;
}

function buildStreamProfiles() {
  const desktopWidth = remoteDesktopWidth || 1280;
  const desktopHeight = remoteDesktopHeight || 720;
  const profiles = new Map();

  STREAM_PROFILE_SCALES.forEach((scale) => {
    const width = Math.max(320, Math.min(desktopWidth, roundToEven(desktopWidth * scale)));
    const height = Math.max(180, Math.min(desktopHeight, roundToEven(desktopHeight * scale)));
    profiles.set(`${width}x${height}`, {
      width,
      height,
      key: `${width}x${height}`,
    });
  });

  return Array.from(profiles.values()).sort((left, right) => left.width - right.width);
}

function sendSignalMessage(payload) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    return false;
  }
  ws.send(JSON.stringify(payload));
  return true;
}

function sendMediaRelayMessage(payload) {
  if (!mediaRelayWs || mediaRelayWs.readyState !== WebSocket.OPEN) {
    return false;
  }
  mediaRelayWs.send(JSON.stringify(payload));
  return true;
}

function getViewerMediaRelayToken() {
  return normalizeViewerMediaRelayValue(
    session?.viewerMediaRelayToken || session?.viewerSignalingToken || session?.viewerToken,
  );
}

function closeMediaRelayCanary() {
  const current = mediaRelayWs;
  mediaRelayWs = null;
  mediaRelayRegistered = false;
  if (!current) {
    return;
  }
  try {
    current.close();
  } catch {
    // Ignore shutdown races while preserving the primary WebRTC path.
  }
}

function connectMediaRelayCanary() {
  mediaRelayConfig = buildViewerMediaRelayConfig(session, {
    canaryEnabled: isViewerMediaRelayCanaryAllowed(params),
  });

  if (!mediaRelayConfig.enabled) {
    debugLog("media-relay-canary-disabled", mediaRelayConfig.reason);
    return false;
  }
  if (
    mediaRelayWs &&
    (mediaRelayWs.readyState === WebSocket.OPEN || mediaRelayWs.readyState === WebSocket.CONNECTING)
  ) {
    return true;
  }

  const token = getViewerMediaRelayToken();
  if (!token) {
    mediaRelayConfig = {
      ...mediaRelayConfig,
      enabled: false,
      reason: "missing-viewer-media-relay-token",
    };
    debugLog("media-relay-canary-disabled", mediaRelayConfig.reason);
    return false;
  }

  mediaRelayRegistered = false;
  mediaRelayReceivedFrames = 0;
  const socket = new WebSocket(mediaRelayConfig.mediaRelayUrl);
  mediaRelayWs = socket;

  socket.addEventListener("open", () => {
    if (socket !== mediaRelayWs) {
      socket.close();
      return;
    }
    const sent = sendMediaRelayMessage(buildViewerMediaRelayRegisterMessage(sessionId, token));
    debugLog("media-relay-canary-open", {
      sent,
      mode: mediaRelayConfig.mode,
      replaceWebRtc: mediaRelayConfig.replaceWebRtc,
    });
  });

  socket.addEventListener("message", (event) => {
    let message = null;
    try {
      message = JSON.parse(event.data);
    } catch {
      mediaRelayReceivedFrames += 1;
      debugLog("media-relay-canary-frame", { frames: mediaRelayReceivedFrames });
      return;
    }

    if (message.type === "media-registered") {
      mediaRelayRegistered = true;
      debugLog("media-relay-canary-registered", { role: message.role || "viewer" });
      return;
    }
    if (message.type === "error") {
      debugLog("media-relay-canary-error", message.message || "media relay error");
      return;
    }

    mediaRelayReceivedFrames += 1;
    debugLog("media-relay-canary-envelope", {
      type: message.type || "unknown",
      frames: mediaRelayReceivedFrames,
    });
  });

  socket.addEventListener("close", () => {
    if (socket !== mediaRelayWs) {
      return;
    }
    debugLog("media-relay-canary-close");
    mediaRelayWs = null;
    mediaRelayRegistered = false;
  });

  socket.addEventListener("error", (event) => {
    debugLog("media-relay-canary-socket-error", event?.message || "websocket error");
  });

  return true;
}

function startSignalingHeartbeat() {
  clearSignalingHeartbeatTimer();
  signalingHeartbeatTimer = window.setInterval(() => {
    sendSignalMessage({
      type: "heartbeat",
      sessionId,
      role: "viewer",
      ts: Date.now(),
    });
  }, SIGNALING_HEARTBEAT_INTERVAL_MS);
}

function scheduleSignalingReconnect(reason = "Reconnecting to secure control channel.") {
  if (sessionEnded || unloadSent) {
    return;
  }
  if (signalingReconnectTimer) {
    return;
  }

  const alreadyOpen = ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING);
  if (alreadyOpen) {
    return;
  }

  const delay = Math.min(1000 * 2 ** reconnectAttempts, SIGNALING_RECONNECT_MAX_DELAY_MS);
  reconnectAttempts += 1;
  signalingReconnectTimer = window.setTimeout(() => {
    signalingReconnectTimer = null;
    connectSignaling();
  }, delay);

  if (peer?.connectionState !== "connected") {
    setViewerStage("media", {
      detail: "Reconnecting control channel",
      statusText: "Reconnecting",
      overlay: reason,
      actionLabel: "Start fresh session",
    });
  }
}

async function requestIceRestart(reason = "Refreshing secure stream.") {
  if (!peer || sessionEnded || unloadSent) {
    return;
  }

  if (!canRequestIceRestart) {
    pendingIceRestart = true;
    return;
  }

  if (restartIceTimer) {
    return;
  }

  restartIceTimer = window.setTimeout(async () => {
    restartIceTimer = null;

    if (!peer || sessionEnded || unloadSent) {
      return;
    }

    if (peer.connectionState === "connected") {
      pendingIceRestart = false;
      return;
    }

    if (peer.signalingState !== "stable") {
      pendingIceRestart = true;
      return;
    }

    if (isViewerGatewayWebrtcRelaySession()) {
      try {
        pendingIceRestart = false;
        setViewerStage("media", {
          detail: "Refreshing secure stream",
          statusText: "Reconnecting",
          overlay: reason,
          actionLabel: "Start fresh session",
          telemetry: { reason },
        });
        await negotiateViewerGatewayWebrtc("ice-restart", { iceRestart: true });
      } catch (error) {
        pendingIceRestart = true;
        console.error("[viewer] failed to restart gateway webrtc", error);
        armDisconnectTimer("Connection interrupted. Trying to recover.");
      }
      return;
    }

    if (!ws || ws.readyState !== WebSocket.OPEN) {
      pendingIceRestart = true;
      scheduleSignalingReconnect("Reconnecting to secure control channel.");
      return;
    }

    try {
      pendingIceRestart = false;
      setViewerStage("media", {
        detail: "Refreshing secure stream",
        statusText: "Reconnecting",
        overlay: reason,
        actionLabel: "Start fresh session",
        telemetry: { reason },
      });
      const sent = sendSignalMessage({
        type: "ice-restart-request",
        sessionId,
        reason,
      });
      if (!sent) {
        pendingIceRestart = true;
        scheduleSignalingReconnect("Reconnecting to secure control channel.");
        return;
      }
      debugLog("sent-ice-restart-request");
    } catch (error) {
      pendingIceRestart = true;
      console.error("[viewer] failed to restart ice", error);
      scheduleSignalingReconnect("Connection interrupted. Trying to recover.");
    }
  }, ICE_RESTART_DELAY_MS);
}

function armSlowStartTimer() {
  clearSlowStartTimer();
  slowStartTimer = window.setTimeout(() => {
    if (isLive) {
      return;
    }
    if (isStubWorkerSession()) {
      setViewerStage("worker-ready", {
        detail: "Harness session",
        statusKind: "harness",
        statusText: "Harness",
        overlay: describeSessionState(session?.state || "allocating"),
      });
      return;
    }
    const message =
      session?.state === "ready"
        ? "Worker is ready. Finalizing the secure stream."
        : "Session startup is taking longer than expected.";
    setViewerStage(session?.state === "ready" ? "worker-ready" : "allocating", {
      detail: message,
      statusText: "Connecting",
      overlay: message,
      actionLabel: "Start fresh session",
      telemetry: { reason: "slow-start" },
    });
  }, 15000);
}

function stopSessionPolling() {
  if (!sessionPollTimer) {
    return;
  }
  window.clearInterval(sessionPollTimer);
  sessionPollTimer = null;
}

function describeSessionState(state) {
  if (isStubWorkerSession() && state !== "terminated" && state !== "streaming") {
    return isSwgSession()
      ? "SWG launch and signed handoff succeeded. This local harness uses a stub worker, so no live browser stream will start."
      : "This local harness uses a stub worker, so no live browser stream will start.";
  }
  switch (state) {
    case "allocating":
      return "Provisioning isolated browser worker";
    case "ready":
      return "Worker ready, establishing secure stream";
    case "streaming":
      return "Remote browser live";
    case "idle":
      return "Viewer disconnected";
    case "terminated":
      return "Session ended";
    default:
      return "Connecting";
  }
}

function getRestartTargetUrl() {
  return session?.targetUrl || targetUrlHint || "";
}

function isSwgSession() {
  return String(session?.sessionMode || "").toLowerCase() === "swg";
}

function isStubWorkerSession() {
  return String(session?.workerRuntimeKind || "").toLowerCase() === "stub";
}

function canFallbackToLaunch() {
  return !isSwgSession();
}

function getLaunchUrl() {
  const targetUrl = getRestartTargetUrl();
  if (!targetUrl) {
    return "/";
  }
  const next = new URL("/launch", window.location.origin);
  next.searchParams.set("targetUrl", targetUrl);
  return `${next.pathname}${next.search}`;
}

function resolveViewportCap(value, fallback) {
  const parsed = Number(value);
  if (Number.isFinite(parsed) && parsed > 0) {
    return Math.round(parsed);
  }
  return fallback;
}

function buildPreferredViewport() {
  const frameRect = viewerFrameEl?.getBoundingClientRect();
  const nativeWidth = Math.max(0, Math.round(frameRect?.width || window.innerWidth || 0));
  const nativeHeight = Math.max(
    0,
    Math.round(
      frameRect?.height || window.innerHeight || window.document?.documentElement?.clientHeight || 0,
    ),
  );
  const maxWidth = resolveViewportCap(
    Math.min(
      1920,
      Math.max(nativeWidth || 0, session?.viewport?.width || remoteDesktopWidth || streamWidth || 0),
    ),
    1920,
  );
  const maxHeight = resolveViewportCap(
    Math.min(
      1080,
      Math.max(nativeHeight || 0, session?.viewport?.height || remoteDesktopHeight || streamHeight || 0),
    ),
    1080,
  );
  return computeViewportForWindow({
    innerWidth: nativeWidth,
    innerHeight: nativeHeight,
    topbarHeight: 0,
    maxWidth,
    maxHeight,
    deviceScaleFactor: 1,
  });
}

function syncWorkerViewportToViewer({ force = false, reason = "viewer-size" } = {}) {
  if (!hasOpenInputControlChannel()) {
    return false;
  }
  const preferredViewport = buildPreferredViewport();
  if (!preferredViewport) {
    return false;
  }
  const key = `${preferredViewport.width}x${preferredViewport.height}`;
  if (!force && key === activeViewportResizeKey) {
    return false;
  }
  activeViewportResizeKey = key;
  remoteDesktopWidth = preferredViewport.width;
  remoteDesktopHeight = preferredViewport.height;
  streamWidth = preferredViewport.width;
  streamHeight = preferredViewport.height;
  activeStreamProfileKey = "";
  sendInput({
    type: "viewport.resize",
    width: preferredViewport.width,
    height: preferredViewport.height,
    desktopWidth: preferredViewport.width,
    desktopHeight: preferredViewport.height,
    deviceScaleFactor: preferredViewport.deviceScaleFactor || 1,
    reason,
  }, { preferControl: true });
  queueViewerTelemetry("viewer.viewport_resize", {
    reason,
    width: preferredViewport.width,
    height: preferredViewport.height,
    deviceScaleFactor: preferredViewport.deviceScaleFactor || 1,
  });
  scheduleStreamProfileSync({ force: true });
  return true;
}

function getPreferredWorkerRegions() {
  const fromSession = Array.isArray(session?.client?.preferredWorkerRegions)
    ? session.client.preferredWorkerRegions
    : [];
  const fromQuery = String(params.get("workerRegions") || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  return [...new Set([...fromSession, ...fromQuery])];
}

function buildViewerClientContext() {
  return {
    browser: "viewer-page",
    sourceSessionId: sessionId,
    language: navigator.language || "",
    preferredWorkerRegions: getPreferredWorkerRegions(),
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "",
  };
}

async function createSession(viewport, reason = "") {
  const response = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/refresh`, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      viewport,
      client: {
        ...buildViewerClientContext(),
        refreshReason: reason || "",
      },
      experiments: {
        sourceCoupledAv: true,
      },
    }),
  });

  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    throw new Error(payload.error || `Session creation failed: ${response.status}`);
  }

  return response.json();
}

async function terminateSessionById(id) {
  if (!id) {
    return;
  }
  try {
    await fetch(`/api/sessions/${encodeURIComponent(id)}`, {
      method: "DELETE",
      credentials: "same-origin",
      keepalive: true,
    });
  } catch {
    // Ignore teardown races while redirecting.
  }
}

async function replaceWithFreshSession({ reason = "", fallbackToLaunch = false } = {}) {
  const targetUrl = getRestartTargetUrl();
  const allowLaunchFallback = fallbackToLaunch && canFallbackToLaunch();
  if (!targetUrl) {
    window.location.replace(allowLaunchFallback ? getLaunchUrl() : "/");
    return true;
  }

  const viewport = buildPreferredViewport();
  if (!viewport) {
    if (allowLaunchFallback) {
      window.location.replace(getLaunchUrl());
      return true;
    }
    return false;
  }

  setViewerStage("allocating", {
    detail: "Preparing fresh session",
    statusText: "Preparing",
    overlay: reason || "Preparing a fresh remote browser for this viewer.",
    telemetry: { reason: reason || "fresh-session" },
  });

  try {
    const nextSession = await createSession(viewport, reason);
    void terminateSessionById(sessionId);
    window.location.replace(buildViewerModeUrl(nextSession.viewerUrl));
    return true;
  } catch (error) {
    console.error("[viewer] replace-session-failed", error);
    if (allowLaunchFallback) {
      window.location.replace(getLaunchUrl());
      return true;
    }
    return false;
  }
}

async function maybeReplaceSessionForViewport() {
  if (handoffMode === "hybrid") {
    return false;
  }
  if (isSwgSession() && !isLive) {
    recordViewerMilestone("viewport.refresh.skipped", {
      reason: "swg-initial-handoff",
    });
    return false;
  }
  const targetUrl = getRestartTargetUrl();
  const currentViewport = session?.viewport;
  if (!targetUrl || !currentViewport) {
    return false;
  }

  const preferredViewport = buildPreferredViewport();
  if (!preferredViewport) {
    return false;
  }

  if (!viewportNeedsRefresh(currentViewport, preferredViewport)) {
    return false;
  }

  recordViewerMilestone("viewport.refresh.skipped", {
    reason: "in-place-worker-resize",
    currentWidth: currentViewport.width,
    currentHeight: currentViewport.height,
    preferredWidth: preferredViewport.width,
    preferredHeight: preferredViewport.height,
  });
  syncWorkerViewportToViewer({ force: true, reason: "initial-viewer-size" });
  return false;
}

function getAuthHeaders() {
  return {};
}

async function fetchSession() {
  const response = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}`, {
    credentials: "same-origin",
    cache: "no-store",
  });

  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || `Failed to load session: ${response.status}`);
  }

  session = await response.json();
  syncRestartButton();
  updateCurrentPageState(
    {
      href: session.targetUrl || session.targetOrigin || targetUrlHint,
      title: session.targetOrigin || "",
      readyState: "",
    },
    "session-fetch",
  );
  syncEnterpriseBanner();
  startEnterpriseBannerTimer();
  recordViewerMilestone("session.fetch", {
    state: session.state,
    sessionMode: session.sessionMode || "",
    viewerEntryMode: session.viewerEntryMode || "",
  });
  remoteDesktopWidth = session.viewport?.width || remoteDesktopWidth;
  remoteDesktopHeight = session.viewport?.height || remoteDesktopHeight;
  if (!activeStreamProfileKey) {
    activeStreamProfileKey = `${remoteDesktopWidth}x${remoteDesktopHeight}`;
  }
  return session;
}

async function refreshSessionState({ initial = false } = {}) {
  try {
    const current = await fetchSession();
    persistActiveViewerSession();
    if (!isLive) {
      const text = describeSessionState(current.state);
      if (current.state === "terminated") {
        setViewerStage("ended", {
          detail: text,
          statusKind: "ended",
          statusText: "Ended",
          overlay: text,
          actionLabel: "Start fresh session",
        });
      } else if (isStubWorkerSession()) {
        setViewerStage("worker-ready", {
          detail: text,
          statusKind: "harness",
          statusText: "Harness",
          overlay: text,
        });
      } else {
        const stage = current.state === "ready" ? "worker-ready" : current.state === "streaming" ? "media" : "allocating";
        setViewerStage(stage, {
          detail: text,
          statusText: "Connecting",
          overlay: text,
          telemetry: { sessionState: current.state },
        });
      }
    }
    return current;
  } catch (error) {
    if (initial && shouldRecoverStaleViewerEntry(error)) {
      if (recoverToStoredActiveViewerSession()) {
        return null;
      }
      recoverStaleViewerEntry();
      return null;
    }
    if (!initial) {
      setViewerStage("ended", {
        detail: "Session unavailable",
        statusKind: "ended",
        statusText: "Ended",
        overlay: error.message || "Session is no longer available",
        actionLabel: "Start fresh session",
      });
    }
    stopSessionPolling();
    clearSlowStartTimer();
    throw error;
  }
}

function startSessionPolling() {
  stopSessionPolling();
  sessionPollTimer = window.setInterval(async () => {
    if (isLive || unloadSent) {
      stopSessionPolling();
      return;
    }
    try {
      const current = await refreshSessionState();
      if (current.state === "streaming" || current.state === "terminated") {
        stopSessionPolling();
      }
    } catch {
      // refreshSessionState already updates the UI
    }
  }, 2000);
}

function createPeerConnection() {
  remoteMediaStream = new MediaStream();
  remoteVideo.srcObject = remoteMediaStream;
  remoteVideo.muted = true;
  remoteVideo.volume = 1;
  hasRemoteAudio = false;
  hasRemoteVideo = false;
  workerStreaming = false;
  audioEnabled = false;
  playbackKickAttempts = 0;
  firstFrameRecorded = false;
  audioStartupGateStartedAt = 0;
  audioStartupGateSatisfied = !audioStartupSyncEnabled;
  audioStartupAdvancingPolls = 0;
  audioStartupLastProgress = null;
  workerAudioReady = !audioStartupSyncEnabled;
  clearPlaybackKickTimer();
  clearAudioStartupGateTimer();
  clearPostLiveStreamProfileSyncTimer();
  clearVideoStallWatch();
  activeStreamProfileKey = "";
  pendingStreamProfileSync = false;
  inputChannel = null;
  inputPointerChannel = null;
  inputControlChannel = null;
  inputLegacyChannel = null;
  syncAudioButton();

  peer = new RTCPeerConnection({
    iceServers: session.iceServers,
    iceTransportPolicy: session.iceTransportPolicy || "all",
  });
  window.__rbiViewerDebug = {
    get peer() {
      return peer;
    },
    get ws() {
      return ws;
    },
    get session() {
      return session;
    },
    get audioStartupSyncEnabled() {
      return audioStartupSyncEnabled;
    },
    get sourceCoupledAvEnabled() {
      return sourceCoupledAvEnabled;
    },
    get audioStartupGateSatisfied() {
      return audioStartupGateSatisfied;
    },
    get workerAudioReady() {
      return workerAudioReady;
    },
    get mediaRelayConfig() {
      return mediaRelayConfig;
    },
    get mediaRelayWs() {
      return mediaRelayWs;
    },
    get mediaRelayRegistered() {
      return mediaRelayRegistered;
    },
    get mediaRelayReceivedFrames() {
      return mediaRelayReceivedFrames;
    },
    get gatewayWebrtcConfig() {
      return viewerGatewayWebrtcConfig;
    },
    get inputChannels() {
      return {
        pointer: inputPointerChannel,
        control: inputControlChannel,
        legacy: inputLegacyChannel || inputChannel,
      };
    },
    get inputAckStats() {
      return { ...inputAckStats };
    },
    get inputSloWindow() {
      return buildViewerInputSloReport(inputSloSessionWindow.snapshot(), getInputChannels());
    },
    get stage() {
      return {
        stage: currentViewerStage,
        detail: currentViewerStageDetail,
        startedAt: currentViewerStageStartedAt,
      };
    },
  };

  configureViewerGatewayPeer();

  peer.addEventListener("icecandidate", (event) => {
    if (isViewerGatewayWebrtcRelaySession()) {
      return;
    }
    if (!event.candidate || !ws || ws.readyState !== WebSocket.OPEN) {
      return;
    }
    const candidate = {
      ...event.candidate.toJSON(),
      type: event.candidate.type || extractCandidateType(event.candidate.candidate),
    };
    if (!isAllowedCandidate(candidate)) {
      debugLog("skip-local-ice", candidate.type || "unknown");
      return;
    }
    debugLog("local-ice", candidate.type, candidate.candidate);
    sendSignalMessage({
      type: "ice-candidate",
      sessionId,
      candidate,
    });
  });

  peer.addEventListener("track", (event) => {
    const stream = ensureRemoteMediaStream();
    const alreadyPresent = stream.getTracks().some((track) => track.id === event.track.id);
    if (!alreadyPresent) {
      stream.addTrack(event.track);
    }

    if (event.track.kind === "audio") {
      recordViewerMilestone("track.audio", { streamId: stream.id });
      hasRemoteAudio = true;
      syncAudioButton();
      void setAudioEnabled(true, { silent: true });
      scheduleAudioEnableRetry("audio-track", 0);
    }
    if (event.track.kind === "video") {
      recordViewerMilestone("track.video", { streamId: stream.id });
      setViewerStage("media", {
        detail: "Video track received",
        statusText: "Connecting",
        overlay: "Secure channel established. Waiting for video.",
      });
      hasRemoteVideo = true;
      void ensureVideoPlayback("video-track");
      schedulePlaybackKick("video-track", 0);
      noteVideoFrameProgress("video-track");
      ensureVideoStallWatch();
    }

    event.track.addEventListener("ended", () => {
      stream.removeTrack(event.track);
      hasRemoteAudio = stream.getAudioTracks().length > 0;
      hasRemoteVideo = stream.getVideoTracks().length > 0;
      if (!hasRemoteVideo) {
        clearVideoStallWatch();
      }
      if (!hasRemoteAudio) {
        void setAudioEnabled(false, { silent: true });
      } else {
        syncAudioButton();
        scheduleAudioEnableRetry("audio-track-ended");
      }
    });

    syncStreamDimensions();
    scheduleStreamProfileSync({ force: true });
    void ensureVideoPlayback("track");
    debugLog("track", event.track.kind, stream.id);
    if (event.track.kind === "video") {
      maybeMarkLiveState("video-track");
    }
  });

  peer.addEventListener("datachannel", (event) => {
    registerInputChannel(event.channel);
  });

  peer.addEventListener("connectionstatechange", () => {
    const state = peer.connectionState;
    debugLog("connection-state", state);
    queueViewerTelemetry("viewer.peer_state", { state });
    if (state === "connected") {
      recordViewerMilestone("peer.connected");
      maybeMarkLiveState("peer-connected");
      return;
    }
    if (state === "disconnected") {
      armDisconnectTimer();
      void requestIceRestart();
      return;
    }
    if (state === "failed") {
      armDisconnectTimer("Connection failed. Trying to recover.");
      void requestIceRestart("Connection failed. Re-establishing secure stream.");
      return;
    }
    if (state === "closed") {
      clearVideoStallWatch();
      clearDisconnectTimer();
      clearRestartIceTimer();
      setViewerStage("ended", {
        detail: "Connection lost",
        statusKind: "ended",
        statusText: "Disconnected",
        overlay: "Connection lost",
        actionLabel: "Start fresh session",
      });
    }
  });

  peer.addEventListener("iceconnectionstatechange", () => {
    debugLog("ice-connection-state", peer.iceConnectionState);
    if (peer.iceConnectionState === "disconnected" || peer.iceConnectionState === "failed") {
      void requestIceRestart();
    }
  });

  peer.addEventListener("icegatheringstatechange", () => {
    debugLog("ice-gathering-state", peer.iceGatheringState);
  });

  remoteVideo.addEventListener("loadedmetadata", () => {
    recordViewerMilestone("video.loadedmetadata", {
      videoWidth: remoteVideo.videoWidth || 0,
      videoHeight: remoteVideo.videoHeight || 0,
    });
    syncStreamDimensions();
    scheduleHybridHandoffReplayClick("loadedmetadata");
    if (hasRemoteAudio && !audioEnabled) {
      scheduleAudioEnableRetry("loadedmetadata", 0);
    }
    void ensureVideoPlayback("loadedmetadata");
    schedulePlaybackKick("loadedmetadata", 0);
    noteVideoFrameProgress("loadedmetadata");
    maybeMarkFirstFrame("loadedmetadata");
    maybeMarkLiveState("loadedmetadata");
  });

  remoteVideo.addEventListener("loadeddata", () => {
    recordViewerMilestone("video.loadeddata", {
      videoWidth: remoteVideo.videoWidth || 0,
      videoHeight: remoteVideo.videoHeight || 0,
    });
    syncStreamDimensions();
    scheduleHybridHandoffReplayClick("loadeddata");
    if (hasRemoteAudio && !audioEnabled) {
      scheduleAudioEnableRetry("loadeddata", 0);
    }
    void ensureVideoPlayback("loadeddata");
    schedulePlaybackKick("loadeddata", 0);
    noteVideoFrameProgress("loadeddata");
    maybeMarkFirstFrame("loadeddata");
    maybeMarkLiveState("loadeddata");
  });

  remoteVideo.addEventListener("canplay", () => {
    recordViewerMilestone("video.canplay");
    scheduleHybridHandoffReplayClick("canplay");
    if (hasRemoteAudio && !audioEnabled) {
      scheduleAudioEnableRetry("canplay", 0);
    }
    void ensureVideoPlayback("canplay");
    schedulePlaybackKick("canplay", 0);
    noteVideoFrameProgress("canplay");
    maybeMarkFirstFrame("canplay");
    maybeMarkLiveState("canplay");
  });

  remoteVideo.addEventListener("playing", () => {
    recordViewerMilestone("video.playing");
    clearPlaybackKickTimer();
    if (hasRemoteAudio && !audioEnabled) {
      scheduleAudioEnableRetry("playing", 0);
    }
    noteVideoFrameProgress("playing");
    maybeMarkFirstFrame("playing");
    maybeMarkLiveState("playing");
  });

  remoteVideo.addEventListener("pause", () => {
    if (sessionEnded || unloadSent || !hasRemoteVideo) {
      return;
    }
    schedulePlaybackKick("pause");
  });

  remoteVideo.addEventListener("resize", () => {
    syncStreamDimensions();
    noteVideoFrameProgress("resize");
    maybeMarkLiveState("video-resize");
  });

  peer.addEventListener("signalingstatechange", () => {
    debugLog("signaling-state", peer.signalingState);
    if (peer.signalingState !== "stable") {
      return;
    }
    if (!canRequestIceRestart) {
      return;
    }
    if (pendingIceRestart) {
      void requestIceRestart("Refreshing secure stream.");
    }
  });

  peer.addEventListener("icecandidateerror", (event) => {
    console.error("[viewer] ice-candidate-error", event.errorCode, event.errorText, event.url);
  });
}

function syncStreamDimensions() {
  if (remoteVideo.videoWidth > 0 && remoteVideo.videoHeight > 0) {
    streamWidth = remoteVideo.videoWidth;
    streamHeight = remoteVideo.videoHeight;
  }
}

function configureRemoteVideoSurface() {
  remoteVideo.controls = false;
  remoteVideo.autoplay = true;
  remoteVideo.muted = true;
  remoteVideo.playsInline = true;
  remoteVideo.setAttribute("playsinline", "");
  remoteVideo.setAttribute("webkit-playsinline", "");
  remoteVideo.setAttribute("disablepictureinpicture", "");
  remoteVideo.setAttribute("disableremoteplayback", "");
  remoteVideo.setAttribute("controlslist", "nodownload nofullscreen noremoteplayback");
  remoteVideo.removeAttribute("controls");

  if ("disablePictureInPicture" in remoteVideo) {
    try {
      remoteVideo.disablePictureInPicture = true;
    } catch {
      // Browser-specific readonly implementations still honor the attribute above.
    }
  }
  if ("disableRemotePlayback" in remoteVideo) {
    try {
      remoteVideo.disableRemotePlayback = true;
    } catch {
      // Browser-specific readonly implementations still honor the attribute above.
    }
  }
  if (remoteVideo.controlsList?.add) {
    for (const token of ["nodownload", "nofullscreen", "noremoteplayback"]) {
      try {
        remoteVideo.controlsList.add(token);
      } catch {
        // Ignore unsupported controlsList tokens.
      }
    }
  }
}

async function exitNativeVideoPictureInPicture(reason = "native-video-pip") {
  if (document.pictureInPictureElement !== remoteVideo) {
    return;
  }
  recordViewerMilestone("native_video_affordance_blocked", { reason });
  try {
    await document.exitPictureInPicture?.();
  } catch {
    // Nothing else to do; the disablePictureInPicture flag prevents future prompts.
  }
}

async function exitNativeVideoFullscreen(reason = "native-video-fullscreen") {
  if (document.fullscreenElement !== remoteVideo) {
    return;
  }
  recordViewerMilestone("native_video_affordance_blocked", { reason });
  try {
    await document.exitFullscreen?.();
  } catch {
    // The event guard is best-effort for browser-provided video fullscreen.
  }
}

function getVideoContentRect() {
  const rect = remoteVideo.getBoundingClientRect();
  const aspectWidth = remoteDesktopWidth || streamWidth || 1280;
  const aspectHeight = remoteDesktopHeight || streamHeight || 720;

  if (!rect.width || !rect.height || !aspectWidth || !aspectHeight) {
    return null;
  }

  const rectAspect = rect.width / rect.height;
  const sourceAspect = aspectWidth / aspectHeight;

  let width = rect.width;
  let height = rect.height;
  let left = rect.left;
  let top = rect.top;

  if (rectAspect > sourceAspect) {
    width = rect.height * sourceAspect;
    left = rect.left + (rect.width - width) / 2;
  } else if (rectAspect < sourceAspect) {
    height = rect.width / sourceAspect;
    top = rect.top + (rect.height - height) / 2;
  }

  return {
    left,
    top,
    width,
    height,
    desktopWidth: remoteDesktopWidth || aspectWidth,
    desktopHeight: remoteDesktopHeight || aspectHeight,
  };
}

function normalizePoint(event) {
  syncStreamDimensions();
  const rect = getVideoContentRect();
  if (!rect) {
    return null;
  }

  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;

  if (x < 0 || y < 0 || x > rect.width || y > rect.height) {
    return null;
  }

  return {
    x: Math.round((x / rect.width) * rect.desktopWidth),
    y: Math.round((y / rect.height) * rect.desktopHeight),
  };
}

function computePreferredStreamProfile() {
  const desktopWidth = remoteDesktopWidth || 1280;
  const desktopHeight = remoteDesktopHeight || 720;
  const profiles = buildStreamProfiles();
  if (!isLive) {
    const initialWidth = Math.max(
      320,
      Math.min(desktopWidth, roundToEven(desktopWidth * INITIAL_STREAM_PROFILE_SCALE)),
    );
    const initialHeight = Math.max(
      180,
      Math.min(desktopHeight, roundToEven(desktopHeight * INITIAL_STREAM_PROFILE_SCALE)),
    );
    return (
      profiles.find((profile) => profile.width >= initialWidth && profile.height >= initialHeight) ||
      profiles[profiles.length - 1]
    );
  }

  const rect = getVideoContentRect();
  const deviceScaleFactor = Math.max(
    1,
    Math.min(window.devicePixelRatio || 1, MAX_STREAM_DEVICE_SCALE_FACTOR),
  );

  let desiredWidth = desktopWidth;
  let desiredHeight = desktopHeight;
  if (rect) {
    desiredWidth = Math.max(320, Math.min(desktopWidth, roundToEven(rect.width * deviceScaleFactor)));
    desiredHeight = Math.max(
      180,
      Math.min(desktopHeight, roundToEven(rect.height * deviceScaleFactor)),
    );
  }

  return (
    profiles.find((profile) => profile.width >= desiredWidth && profile.height >= desiredHeight) ||
    profiles[profiles.length - 1]
  );
}

function applyPreferredStreamProfile({ force = false } = {}) {
  if (!peer || sessionEnded || unloadSent) {
    return;
  }

  if (!hasOpenInputControlChannel()) {
    pendingStreamProfileSync = true;
    return;
  }

  const profile = computePreferredStreamProfile();
  if (!profile) {
    return;
  }

  if (!force && profile.key === activeStreamProfileKey) {
    return;
  }

  activeStreamProfileKey = profile.key;
  pendingStreamProfileSync = false;
  debugLog("stream-profile", {
    force,
    profile,
    isLive,
    remoteDesktopWidth,
    remoteDesktopHeight,
  });
  sendInput({
    type: "stream.configure",
    width: profile.width,
    height: profile.height,
    desktopWidth: remoteDesktopWidth,
    desktopHeight: remoteDesktopHeight,
  }, { preferControl: true });
}

function scheduleStreamProfileSync({ force = false } = {}) {
  clearStreamProfileSyncTimer();
  streamProfileSyncTimer = window.setTimeout(() => {
    streamProfileSyncTimer = null;
    applyPreferredStreamProfile({ force });
  }, force ? 0 : STREAM_PROFILE_SYNC_DELAY_MS);
}

function schedulePostLiveStreamProfileSync() {
  clearPostLiveStreamProfileSyncTimer();
  postLiveStreamProfileTimer = window.setTimeout(() => {
    postLiveStreamProfileTimer = null;
    scheduleStreamProfileSync({ force: true });
  }, POST_LIVE_STREAM_PROFILE_SYNC_DELAY_MS);
}

function getInputChannels() {
  return {
    pointer: inputPointerChannel,
    control: inputControlChannel,
    legacy: inputLegacyChannel || inputChannel,
  };
}

function hasOpenInputControlChannel() {
  return Boolean(chooseViewerInputChannel({ type: "control" }, getInputChannels(), {
    preferControl: true,
  }));
}

function hasOpenSplitInputControlChannel() {
  return isViewerInputChannelOpen(inputControlChannel);
}

function startInputAckStatsTimer() {
  if (inputAckStatsTimer) {
    return;
  }
  inputAckStatsTimer = window.setInterval(() => {
    if (!inputAckStats.sent && !inputAckStats.droppedPointerMoves && !inputAckStats.acks) {
      return;
    }
    debugLog("input-ack-stats", { ...inputAckStats });
    emitInputSloTelemetry("input-interval");
  }, INPUT_ACK_STATS_INTERVAL_MS);
}

function clearInputAckStatsTimer() {
  if (!inputAckStatsTimer) {
    return;
  }
  window.clearInterval(inputAckStatsTimer);
  inputAckStatsTimer = null;
}

function handleInputChannelAck(rawMessage, channel) {
  const ack = extractViewerInputAck(rawMessage);
  if (!ack) {
    return;
  }
  const now = Date.now();
  inputAckStats.acks += 1;
  inputAckStats.lastAckSeq = Math.max(inputAckStats.lastAckSeq, ack.seq);
  inputAckStats.lastAckAt = now;
  inputAckStats.lastAckChannel =
    ack.channel || getViewerInputChannelLabel(channel, LEGACY_INPUT_CHANNEL_LABEL);
  inputSloWindow.recordAckBatch(ack, now);
  inputSloSessionWindow.recordAckBatch(ack, now);
}

function emitInputSloTelemetry(reason = "interval", { reset = true } = {}) {
  const snapshot = inputSloWindow.snapshot({ reset });
  if (!Object.keys(snapshot.byClass).length) {
    return false;
  }
  const report = buildViewerInputSloReport(snapshot, getInputChannels());
  const violations = evaluateViewerInputSloViolations(report, {
    ackP95Ms: INPUT_ACK_P95_WARN_MS,
    clickApplyP95Ms: INPUT_CLICK_APPLY_P95_WARN_MS,
    controlBacklogBytes: INPUT_CONTROL_BACKLOG_WARN_BYTES,
  });
  queueViewerTelemetry("viewer.input_slo", {
    reason,
    ...report,
    violations,
  }, { flush: reason !== "input-interval" });
  return true;
}

function registerInputChannel(channel) {
  const role = classifyViewerInputChannel(channel?.label);
  let openHandled = false;
  if (role === "pointer") {
    inputPointerChannel = channel;
  } else if (role === "control") {
    inputControlChannel = channel;
  } else {
    inputLegacyChannel = channel;
    inputChannel = channel;
  }

  const handleOpen = () => {
    if (openHandled) {
      return;
    }
    openHandled = true;
    debugLog("input-channel-open", getViewerInputChannelLabel(channel), role);
    maybeMarkLiveState("datachannel-open");
    startInputAckStatsTimer();
    if (role !== "pointer") {
      syncWorkerViewportToViewer({ force: true, reason: "input-control-open" });
      scheduleStreamProfileSync({ force: true });
      scheduleHybridHandoffReplayClick("datachannel-open");
      textInsertBatcher.flush("channel-open");
    }
  };

  channel.addEventListener("open", handleOpen);

  channel.addEventListener("message", (event) => {
    handleInputChannelAck(event.data, channel);
  });

  channel.addEventListener("close", () => {
    if (inputPointerChannel === channel) {
      inputPointerChannel = null;
    }
    if (inputControlChannel === channel) {
      inputControlChannel = null;
    }
    if (inputLegacyChannel === channel) {
      inputLegacyChannel = null;
    }
    if (inputChannel === channel) {
      inputChannel = inputLegacyChannel;
    }
    const channels = getInputChannels();
    if (
      !isViewerInputChannelOpen(channels.pointer) &&
      !isViewerInputChannelOpen(channels.control) &&
      !isViewerInputChannelOpen(channels.legacy)
    ) {
      clearInputAckStatsTimer();
    }
  });

  if (isViewerInputChannelOpen(channel)) {
    window.setTimeout(handleOpen, 0);
  }
}

function sendInput(message, options = {}) {
  const channel = chooseViewerInputChannel(message, getInputChannels(), options);
  if (!channel) {
    return false;
  }
  if (
    message?.type === "pointer.move" &&
    !options.preferControl &&
    getViewerInputChannelLabel(channel) === INPUT_POINTER_CHANNEL_LABEL &&
    shouldDropViewerPointerMove(channel, POINTER_CHANNEL_BUFFER_HIGH_WATERMARK_BYTES)
  ) {
    inputAckStats.droppedPointerMoves += 1;
    inputSloWindow.recordDrop(
      classifyViewerInputSloClass(message),
      getViewerInputChannelLabel(channel),
    );
    inputSloSessionWindow.recordDrop(
      classifyViewerInputSloClass(message),
      getViewerInputChannelLabel(channel),
    );
    return false;
  }

  const now = Date.now();
  inputSeq += 1;
  const channelLabel = getViewerInputChannelLabel(channel);
  const envelope = buildViewerInputEnvelope(message, {
    seq: inputSeq,
    now,
    channelLabel,
  });
  channel.send(JSON.stringify(envelope));
  inputSloWindow.recordSent({
    seq: inputSeq,
    inputClass: classifyViewerInputSloClass(message),
    channel: channelLabel,
    sentAt: now,
  });
  inputSloSessionWindow.recordSent({
    seq: inputSeq,
    inputClass: classifyViewerInputSloClass(message),
    channel: channelLabel,
    sentAt: now,
  });
  inputAckStats.sent += 1;
  inputAckStats.sentByChannel[channelLabel] =
    (inputAckStats.sentByChannel[channelLabel] || 0) + 1;
  return true;
}

function clearPointerMoveFrame() {
  if (!pointerMoveFrame) {
    return;
  }
  if (pointerMoveFrameUsesAnimationFrame && typeof window.cancelAnimationFrame === "function") {
    window.cancelAnimationFrame(pointerMoveFrame);
  } else {
    window.clearTimeout(pointerMoveFrame);
  }
  pointerMoveFrame = 0;
  pointerMoveFrameUsesAnimationFrame = false;
  pendingPointerMove = null;
}

function schedulePointerMove(payload) {
  pendingPointerMove = payload;
  if (pointerMoveFrame) {
    return;
  }

  pointerMoveFrameUsesAnimationFrame = typeof window.requestAnimationFrame === "function";
  const scheduleFrame = pointerMoveFrameUsesAnimationFrame
    ? window.requestAnimationFrame.bind(window)
    : (callback) => window.setTimeout(() => callback(Date.now()), 16);

  pointerMoveFrame = scheduleFrame(() => {
    pointerMoveFrame = 0;
    pointerMoveFrameUsesAnimationFrame = false;
    if (pendingPointerMove) {
      sendInput(pendingPointerMove);
      pendingPointerMove = null;
    }
  });
}

function sendReliablePointerSync(point) {
  clearPointerMoveFrame();
  return sendInput({
    type: "pointer.move",
    ...point,
    width: remoteDesktopWidth,
    height: remoteDesktopHeight,
  }, { preferControl: true });
}

function isLocalTextInputTarget(target) {
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLButtonElement ||
    Boolean(target?.isContentEditable) ||
    Boolean(target?.closest?.(".topbar, .overlay-card"))
  );
}

function isTextInsertKeyEvent(event) {
  return (
    hasOpenSplitInputControlChannel() &&
    !event.isComposing &&
    !event.altKey &&
    !event.ctrlKey &&
    !event.metaKey &&
    typeof event.key === "string" &&
    event.key.length === 1
  );
}

function getKeyboardEventId(event) {
  return normalizeViewerInputChannelLabel(event.code || event.key);
}

function installInputHandlers() {
  remoteVideo.tabIndex = 0;
  configureRemoteVideoSurface();

  remoteVideo.addEventListener("contextmenu", (event) => {
    event.preventDefault();
  });

  remoteVideo.addEventListener("dblclick", (event) => {
    event.preventDefault();
    remoteVideo.focus();
  });

  remoteVideo.addEventListener("enterpictureinpicture", () => {
    void exitNativeVideoPictureInPicture("enterpictureinpicture");
  });

  remoteVideo.addEventListener("webkitbeginfullscreen", (event) => {
    event.preventDefault();
    recordViewerMilestone("native_video_affordance_blocked", {
      reason: "webkitbeginfullscreen",
    });
    try {
      remoteVideo.webkitExitFullscreen?.();
    } catch {
      // Safari-specific video fullscreen may not expose an exit method.
    }
  });

  document.addEventListener("fullscreenchange", () => {
    void exitNativeVideoFullscreen("fullscreenchange");
  });

  window.addEventListener(
    "pointerdown",
    () => {
      if (hasRemoteAudio && !audioEnabled) {
        void setAudioEnabled(true, { silent: true });
      }
    },
    { capture: true },
  );

  if (typeof ResizeObserver === "function" && !resizeObserver) {
    resizeObserver = new ResizeObserver(() => {
      syncWorkerViewportToViewer({ reason: "video-surface-resize" });
      scheduleStreamProfileSync();
    });
    resizeObserver.observe(remoteVideo);
  }

  remoteVideo.addEventListener("pointermove", (event) => {
    const point = normalizePoint(event);
    if (!point) {
      return;
    }
    schedulePointerMove({
      type: "pointer.move",
      ...point,
      width: remoteDesktopWidth,
      height: remoteDesktopHeight,
    });
  });

  remoteVideo.addEventListener("mousedown", (event) => {
    event.preventDefault();
    remoteVideo.focus();
    void setAudioEnabled(true, { silent: true });
    const point = normalizePoint(event);
    if (!point) {
      return;
    }
    sendReliablePointerSync(point);
    sendInput({
      type: "pointer.button",
      action: "down",
      button: event.button,
      ...point,
    }, { preferControl: true });
  });

  remoteVideo.addEventListener("mouseup", (event) => {
    const point = normalizePoint(event);
    if (!point) {
      return;
    }
    sendReliablePointerSync(point);
    sendInput({
      type: "pointer.button",
      action: "up",
      button: event.button,
      ...point,
    }, { preferControl: true });
  });

  remoteVideo.addEventListener(
    "wheel",
    (event) => {
      event.preventDefault();
      void setAudioEnabled(true, { silent: true });
      const point = normalizePoint(event);
      if (!point) {
        return;
      }
      scheduleWheel({
        type: "wheel",
        deltaX: event.deltaX,
        deltaY: event.deltaY,
        deltaMode: event.deltaMode,
        ...point,
      });
    },
    { passive: false },
  );

  window.addEventListener("beforeinput", (event) => {
    if (isLocalTextInputTarget(event.target)) {
      return;
    }
    const text = String(event.data || "");
    if (!text || !hasOpenSplitInputControlChannel()) {
      return;
    }
    const inputType = String(event.inputType || "");
    if (inputType && !inputType.startsWith("insert")) {
      return;
    }
    event.preventDefault();
    void setAudioEnabled(true, { silent: true });
    textInsertBatcher.enqueue(text);
  });

  window.addEventListener("paste", (event) => {
    if (isLocalTextInputTarget(event.target) || !hasOpenSplitInputControlChannel()) {
      return;
    }
    const text = String(event.clipboardData?.getData("text/plain") || "");
    if (!text) {
      return;
    }
    event.preventDefault();
    void setAudioEnabled(true, { silent: true });
    textInsertBatcher.enqueue(text);
  });

  window.addEventListener("keydown", (event) => {
    if (isLocalTextInputTarget(event.target)) {
      return;
    }
    if (isTextInsertKeyEvent(event)) {
      event.preventDefault();
      void setAudioEnabled(true, { silent: true });
      const keyId = getKeyboardEventId(event);
      if (keyId) {
        textInsertSuppressedKeyIds.add(keyId);
      }
      textInsertBatcher.enqueue(event.key);
      return;
    }
    event.preventDefault();
    void setAudioEnabled(true, { silent: true });
    sendInput({
      type: "key",
      action: "down",
      code: event.code,
      key: event.key,
      altKey: event.altKey,
      ctrlKey: event.ctrlKey,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey,
    }, { preferControl: true });
  });

  window.addEventListener("keyup", (event) => {
    if (isLocalTextInputTarget(event.target)) {
      return;
    }
    const keyId = getKeyboardEventId(event);
    if (keyId && textInsertSuppressedKeyIds.has(keyId)) {
      textInsertSuppressedKeyIds.delete(keyId);
      event.preventDefault();
      return;
    }
    event.preventDefault();
    sendInput({
      type: "key",
      action: "up",
      code: event.code,
      key: event.key,
      altKey: event.altKey,
      ctrlKey: event.ctrlKey,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey,
    }, { preferControl: true });
  });

  window.addEventListener("resize", () => {
    syncWorkerViewportToViewer({ reason: "window-resize" });
    scheduleStreamProfileSync();
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") {
      return;
    }
    void ensureVideoPlayback("visibility-visible");
    schedulePlaybackKick("visibility-visible", 0);
  });

  window.addEventListener("popstate", handleViewerPopState);
  window.addEventListener("pageshow", restoreViewerHistorySentinel);
}

async function reportProblem() {
  const supportId = formatShortSessionId(session?.sessionId || sessionId);
  if (reportProblemButton) {
    reportProblemButton.disabled = true;
    reportProblemButton.textContent = "Reporting";
  }
  queueViewerTelemetry("viewer.report_problem", {
    supportId,
    stage: currentViewerStage,
    targetHost: deriveTargetHost(),
    mediaMode: session?.transport?.mediaPlaneMode || session?.transport?.mediaTermination?.mode || "",
  }, { flush: true });
  await flushViewerTelemetry({ reason: "report-problem" });
  if (reportProblemButton) {
    reportProblemButton.textContent = `Reported ${supportId}`;
    window.setTimeout(() => {
      reportProblemButton.disabled = false;
      reportProblemButton.textContent = "Report issue";
    }, 4000);
  }
}

async function endSession() {
  if (unloadSent || !sessionId) {
    return;
  }
  emitInputSloTelemetry("viewer-end-session");
  queueViewerTelemetry("viewer.session_end_requested", {}, { flush: true });
  await flushViewerTelemetry({ reason: "viewer-end-session", beacon: true });
  unloadSent = true;
  sessionEnded = true;
  clearAudioStartupGateTimer();
  clearStoredActiveViewerSession();
  clearStreamProfileSyncTimer();
  clearInputAckStatsTimer();
  clearViewerTelemetryTimer();
  clearEnterpriseBannerTimer();
  clearPointerMoveFrame();
  textInsertBatcher.cancel();
  textInsertSuppressedKeyIds.clear();
  try {
    await fetch(`/api/sessions/${encodeURIComponent(sessionId)}`, {
      method: "DELETE",
      credentials: "same-origin",
      keepalive: true,
    });
  } catch {
    // Ignore local unload races.
  }
}

async function restartSession() {
  const replaced = await replaceWithFreshSession({
    reason: "Starting a fresh session for this viewer.",
    fallbackToLaunch: true,
  });
  if (!replaced) {
    if (canFallbackToLaunch()) {
      window.location.replace(getLaunchUrl());
      return;
    }
    setStatus("ended", "Ended");
    setOverlay("This SWG session must be relaunched through the signed SWG entry path.", true);
  }
}

function cleanupForUnload() {
  emitInputSloTelemetry("unload");
  queueViewerTelemetry("viewer.unload", {}, { flush: false });
  void flushViewerTelemetry({ reason: "unload", beacon: true });
  window.removeEventListener("popstate", handleViewerPopState);
  window.removeEventListener("pageshow", restoreViewerHistorySentinel);
  resizeObserver?.disconnect();
  clearPlaybackKickTimer();
  clearAudioStartupGateTimer();
  clearHybridHandoffReplayClickTimer();
  clearVideoStallWatch();
  clearDisconnectTimer();
  clearSlowStartTimer();
  clearRestartIceTimer();
  clearStreamProfileSyncTimer();
  clearPostLiveStreamProfileSyncTimer();
  clearSignalingHeartbeatTimer();
  clearSignalingReconnectTimer();
  clearInputAckStatsTimer();
  clearViewerTelemetryTimer();
  clearEnterpriseBannerTimer();
  clearPointerMoveFrame();
  textInsertBatcher.cancel();
  textInsertSuppressedKeyIds.clear();
  if (wheelTimer) {
    window.clearTimeout(wheelTimer);
    wheelTimer = null;
    pendingWheel = null;
  }

  try {
    ws?.close();
  } catch {
    // Ignore unload races while the browser tears down the page.
  }
  closeMediaRelayCanary();

  try {
    peer?.close();
  } catch {
    // Ignore unload races while the browser tears down the page.
  }
}

function connectSignaling() {
  clearSignalingReconnectTimer();
  clearSignalingHeartbeatTimer();
  ws = new WebSocket(session.signalingUrl);

  ws.addEventListener("open", () => {
    debugLog("signaling-open");
    recordViewerMilestone("signaling.open");
    setViewerStage("media", {
      detail: "Registering viewer",
      statusText: "Connecting",
      overlay: "Registering secure viewer",
    });
    reconnectAttempts = 0;
    sendSignalMessage({
      type: "register",
      role: "viewer",
      sessionId,
      generation: session?.generation || null,
      token: session?.viewerSignalingToken || undefined,
      viewerMode: "pixel-stream",
    });
    startSignalingHeartbeat();
  });

  ws.addEventListener("message", async (event) => {
    const message = JSON.parse(event.data);
    debugLog("recv", message.type);
    if (message.type === "heartbeat-ack") {
      return;
    }
    if (message.type === "registered") {
      recordViewerMilestone("signaling.registered");
      if (
        canRequestIceRestart &&
        (pendingIceRestart ||
          peer?.connectionState === "disconnected" ||
          peer?.connectionState === "failed")
      ) {
        void requestIceRestart("Refreshing secure stream.");
      }
      if (peer?.connectionState === "connected" || isLive) {
        setOverlay("Remote browser live", false);
      } else if (isStubWorkerSession()) {
        setViewerStage("worker-ready", {
          detail: "Harness session",
          statusKind: "harness",
          statusText: "Harness",
          overlay: describeSessionState(session?.state || "allocating"),
        });
      } else if (session?.state === "streaming") {
        if (!isAudioStartupGatePending()) {
          setViewerStage("media", {
            detail: "Waiting for video",
            statusText: "Connecting",
            overlay: "Secure channel established. Waiting for video.",
          });
        }
      } else {
        const state = session?.state || "allocating";
        setViewerStage(state === "ready" ? "worker-ready" : "allocating", {
          detail: describeSessionState(state),
          statusText: "Connecting",
          overlay: describeSessionState(state),
        });
      }
      return;
    }

    if (message.type === "worker-state") {
      updateCurrentPageState(message.page, "worker-state");
      if (message.display && typeof message.display === "object") {
        const width = Number(message.display.width || 0);
        const height = Number(message.display.height || 0);
        if (Number.isFinite(width) && width > 0) {
          remoteDesktopWidth = Math.round(width);
        }
        if (Number.isFinite(height) && height > 0) {
          remoteDesktopHeight = Math.round(height);
        }
      }
      session = {
        ...(session || {}),
        state: message.state,
      };
      queueViewerTelemetry("viewer.worker_state", { state: message.state });
      if (isStubWorkerSession()) {
        setViewerStage("worker-ready", {
          detail: "Harness session",
          statusKind: "harness",
          statusText: "Harness",
          overlay: describeSessionState(message.state),
        });
        return;
      }
      if (message.state === "ready") {
        workerStreaming = false;
        setViewerStage("worker-ready", {
          detail: "Worker ready",
          statusText: "Connecting",
          overlay: "Worker ready, establishing secure stream",
        });
      }
      if (message.state === "connecting" && !hasRenderableVideo()) {
        workerStreaming = false;
        setViewerStage("media", {
          detail: "Establishing secure media path",
          statusText: "Connecting",
          overlay: "Establishing secure media path",
        });
      }
      if (message.state === "streaming") {
        workerStreaming = true;
        if (!maybeMarkLiveState("worker-streaming") && !isAudioStartupGatePending()) {
          setViewerStage("media", {
            detail: "Waiting for video",
            statusText: "Connecting",
            overlay: "Secure channel established. Waiting for video.",
          });
        }
      }
      return;
    }

    if (message.type === "worker-media") {
      workerAudioReady = workerAudioReady || Boolean(message.audioReady);
      debugLog("worker-media", {
        audioReady: Boolean(message.audioReady),
        rms: Number(message.rms || 0),
        maxRms: Number(message.maxRms || 0),
        activeFrames: Number(message.activeFrames || 0),
      });
      if (
        workerAudioReady &&
        audioStartupSyncEnabled &&
        !audioStartupGateSatisfied &&
        hasRemoteAudio &&
        audioEnabled
      ) {
        audioStartupGateSatisfied = true;
        maybeMarkLiveState("worker-audio-ready");
      }
      return;
    }

    if (
      isViewerGatewayWebrtcRelaySession() &&
      (message.type === "sdp-offer" ||
        message.type === "sdp-answer" ||
        message.type === "ice-candidate")
    ) {
      debugLog("ignore-legacy-webrtc-signal", message.type);
      return;
    }

    if (message.type === "sdp-offer") {
      if (peer.signalingState !== "stable" && peer.signalingState !== "have-remote-offer") {
        debugLog("defer-sdp-offer", "signalingState=" + peer.signalingState);
        pendingIceRestart = true;
        return;
      }
      try {
        await peer.setRemoteDescription({
          type: "offer",
          sdp: filterSdpCandidates(message.sdp),
        });
        debugLog("set-remote-description", "offer");
        const answer = await peer.createAnswer();
        await peer.setLocalDescription(answer);
        debugLog("created-answer");
        ws.send(
          JSON.stringify({
            type: "sdp-answer",
            sessionId,
            sdp: filterSdpCandidates(peer.localDescription?.sdp || answer.sdp || ""),
          }),
        );
        pendingIceRestart = false;
      } catch (err) {
        console.error("[viewer] failed to handle sdp-offer", err);
        pendingIceRestart = true;
      }
      return;
    }

    if (message.type === "sdp-answer") {
      if (peer.signalingState !== "have-local-offer") {
        debugLog("ignore-sdp-answer", "signalingState=" + peer.signalingState);
        return;
      }
      try {
        await peer.setRemoteDescription({
          type: "answer",
          sdp: filterSdpCandidates(message.sdp),
        });
        debugLog("set-remote-description", "answer");
        pendingIceRestart = false;
      } catch (err) {
        console.error("[viewer] failed to handle sdp-answer", err);
        pendingIceRestart = true;
      }
      return;
    }

    if (message.type === "ice-candidate" && message.candidate) {
      if (!isAllowedCandidate(message.candidate)) {
        debugLog(
          "skip-remote-ice",
          message.candidate.type || extractCandidateType(message.candidate.candidate),
        );
        return;
      }
      debugLog("remote-ice", message.candidate.type, message.candidate.candidate);
      try {
        await peer.addIceCandidate(message.candidate);
      } catch (err) {
        debugLog("failed-add-ice-candidate", err.message);
      }
      return;
    }

    if (message.type === "session-terminated") {
      sessionEnded = true;
      emitInputSloTelemetry("session-terminated");
      queueViewerTelemetry("viewer.session_ended", {
        reason: message.reason || "session-terminated",
      }, { flush: true });
      clearAudioStartupGateTimer();
      clearStoredActiveViewerSession();
      clearVideoStallWatch();
      clearDisconnectTimer();
      clearRestartIceTimer();
      clearStreamProfileSyncTimer();
      clearPostLiveStreamProfileSyncTimer();
      clearSignalingHeartbeatTimer();
      clearSignalingReconnectTimer();
      clearInputAckStatsTimer();
      clearViewerTelemetryTimer();
      textInsertBatcher.cancel();
      closeMediaRelayCanary();
      setViewerStage("ended", {
        detail: "Session ended",
        statusKind: "ended",
        statusText: "Ended",
        overlay: message.reason || "Session ended",
        actionLabel: "Start fresh session",
      });
      void flushViewerTelemetry({ reason: "session-terminated", beacon: true });
      try {
        ws?.close();
      } catch {
        // Ignore already-closed sockets.
      }
      try {
        peer?.close();
      } catch {
        // Ignore already-closed peer connections.
      }
      return;
    }

    if (message.type === "error") {
      sessionEnded = true;
      emitInputSloTelemetry("session-error");
      queueViewerTelemetry("viewer.session_error", {
        message: message.message || "Signaling error",
      }, { flush: true });
      clearAudioStartupGateTimer();
      clearVideoStallWatch();
      clearDisconnectTimer();
      clearRestartIceTimer();
      clearStreamProfileSyncTimer();
      clearPostLiveStreamProfileSyncTimer();
      clearSignalingHeartbeatTimer();
      clearSignalingReconnectTimer();
      clearInputAckStatsTimer();
      clearViewerTelemetryTimer();
      textInsertBatcher.cancel();
      closeMediaRelayCanary();
      setViewerStage("ended", {
        detail: "Signaling error",
        statusKind: "ended",
        statusText: "Error",
        overlay: message.message || "Signaling error",
        actionLabel: "Start fresh session",
      });
      void flushViewerTelemetry({ reason: "session-error", beacon: true });
    }
  });

  ws.addEventListener("close", () => {
    debugLog("signaling-close");
    clearSignalingHeartbeatTimer();
    ws = null;
    if (sessionEnded || unloadSent) {
      return;
    }
    if (peer?.connectionState === "connected") {
      scheduleSignalingReconnect();
      return;
    }
    armDisconnectTimer("Signaling disconnected. Trying to recover.");
    pendingIceRestart = true;
    scheduleSignalingReconnect("Signaling disconnected. Trying to recover.");
  });

  ws.addEventListener("error", (event) => {
    console.error("[viewer] signaling-error", event);
    if (sessionEnded || unloadSent) {
      return;
    }
    pendingIceRestart = true;
    scheduleSignalingReconnect("Signaling error. Trying to recover.");
  });
}

async function main() {
  syncRestartButton();
  syncWatermark();
  installPageNavigationControls();
  startViewerTelemetryTimer();
  recordViewerMilestone("page.loaded", {
    hasSessionId: Boolean(sessionId),
  });

  if (!sessionId) {
    setViewerStage("ended", {
      detail: "Missing session",
      statusKind: "ended",
      statusText: "Missing session",
      overlay: "This viewer URL is missing a session.",
      actionLabel: "Start fresh session",
    });
    return;
  }

  armViewerHistoryTrap();
  setViewerStage("loading", {
    detail: "Loading session",
    statusText: "Connecting",
    overlay: "Loading session",
  });
  const initialSession = await refreshSessionState({ initial: true });
  if (!initialSession) {
    return;
  }
  if (await maybeReplaceSessionForViewport()) {
    return;
  }
  viewerGatewayWebrtcConfig = buildViewerGatewayWebrtcConfig(session);
  if (viewerGatewayWebrtcConfig.enabled) {
    debugLog("gateway-webrtc-enabled", {
      offerUrl: viewerGatewayWebrtcConfig.offerUrl,
      mediaPlaneMode: viewerGatewayWebrtcConfig.mediaPlaneMode,
      protocol: viewerGatewayWebrtcConfig.protocol,
    });
  } else {
    debugLog("gateway-webrtc-disabled", viewerGatewayWebrtcConfig.reason);
  }
  armSlowStartTimer();
  startSessionPolling();
  remoteVideo.addEventListener("loadedmetadata", () => {
    syncStreamDimensions();
    syncWorkerViewportToViewer({ force: true, reason: "video-loadedmetadata" });
    scheduleStreamProfileSync({ force: true });
  });
  remoteVideo.addEventListener("resize", () => {
    syncStreamDimensions();
    syncWorkerViewportToViewer({ reason: "video-resize" });
    scheduleStreamProfileSync();
  });
  createPeerConnection();
  installInputHandlers();
  setViewerStage("media", {
    detail: "Opening secure control channel",
    statusText: "Connecting",
    overlay: "Opening secure control channel",
  });
  connectSignaling();
  if (isViewerGatewayWebrtcRelaySession()) {
    await negotiateViewerGatewayWebrtc("initial");
  } else {
    connectMediaRelayCanary();
  }
}

restartSessionButton?.addEventListener("click", async () => {
  await restartSession();
});

audioToggleButton?.addEventListener("click", async () => {
  await setAudioEnabled(!audioEnabled);
});

overlayActionButton?.addEventListener("click", async () => {
  await restartSession();
});

reportProblemButton?.addEventListener("click", async () => {
  await reportProblem();
});

endSessionButton?.addEventListener("click", async () => {
  await endSession();
  window.location.assign("/");
});

window.addEventListener("beforeunload", () => {
  cleanupForUnload();
});

main().catch((error) => {
  console.error(error);
  queueViewerTelemetry("viewer.start_failed", {
    message: error?.message || "Failed to start viewer",
  }, { flush: true });
  setViewerStage("ended", {
    detail: "Failed to start",
    statusKind: "ended",
    statusText: "Failed",
    overlay: error.message || "Failed to start viewer",
    actionLabel: "Start fresh session",
  });
});
