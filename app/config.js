import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, "..");

function hasEnv(name) {
  return Object.prototype.hasOwnProperty.call(process.env, name);
}

function toNumber(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) ? value : fallback;
}

function toBoolean(name, fallback = false) {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  return ["1", "true", "yes", "on"].includes(raw.toLowerCase());
}

function toRedisKeyPrefix(name, fallback) {
  const raw = process.env[name];
  const value = String(raw || fallback || "").trim().replace(/:+$/g, "");
  return value || fallback;
}

function toList(name, fallback = []) {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  return raw
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function toKeyValueMap(name, fallback = {}) {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  return raw
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .reduce((result, entry) => {
      const separator = entry.indexOf("=");
      if (separator <= 0) {
        return result;
      }
      const key = entry.slice(0, separator).trim();
      const value = entry.slice(separator + 1).trim();
      if (key) {
        result[key] = value;
      }
      return result;
    }, {});
}

function toJsonValue(name, fallback) {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  return JSON.parse(raw);
}

function clampNumber(raw, minimum, maximum, fallback) {
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    return fallback;
  }
  return Math.max(minimum, Math.min(maximum, value));
}

function toCandidateTypeList(name, fallback) {
  const values = toList(name, fallback)
    .map((value) => value.toLowerCase())
    .filter((value) => ["host", "srflx", "relay"].includes(value));
  return values.length ? [...new Set(values)] : fallback;
}

function detectHostIp() {
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        return entry.address;
      }
    }
  }
  return "127.0.0.1";
}

const hostIp = process.env.HOST_IP || detectHostIp();
const publicBaseUrl = process.env.PUBLIC_BASE_URL || "http://localhost:8080";
const publicBase = new URL(publicBaseUrl);
const publicWsPath = process.env.PUBLIC_WS_PATH || "/ws";
const workerWsPath = process.env.WORKER_WS_PATH || "/ws/worker";
const publicScheme = publicBase.protocol.replace(":", "");
const publicWsUrl =
  process.env.PUBLIC_WS_URL ||
  `${publicBase.protocol === "https:" ? "wss" : "ws"}://${publicBase.host}${publicWsPath}`;
const serviceHostname =
  process.env.SERVICE_HOSTNAME ||
  (["localhost", "127.0.0.1"].includes(publicBase.hostname)
    ? "remote-browser.local"
    : publicBase.hostname);
const turnHostname = process.env.TURN_HOSTNAME || `turn.${serviceHostname}`;
const isLocalDefault = ["localhost", "127.0.0.1"].includes(publicBase.hostname);
const workerTurnHost = process.env.WORKER_TURN_HOST || (isLocalDefault ? "coturn" : turnHostname);
const workerWsUrl =
  process.env.WORKER_WS_URL ||
  (isLocalDefault
    ? `ws://host.docker.internal:8080${workerWsPath}`
    : `${publicScheme === "https" ? "wss" : "ws"}://${serviceHostname}${workerWsPath}`);
const signalBusBackend =
  process.env.SIGNAL_BUS_BACKEND || process.env.SESSION_STORE_BACKEND || "memory";
const workerPoolStoreBackend =
  process.env.WORKER_POOL_STORE_BACKEND || process.env.SESSION_STORE_BACKEND || "memory";
const workerPoolBusBackend = process.env.WORKER_POOL_BUS_BACKEND || signalBusBackend;
const redisKeyPrefix = toRedisKeyPrefix("REDIS_KEY_PREFIX", "cloudsec-rbi");
const workerPoolKeyPrefix = toRedisKeyPrefix("WORKER_POOL_KEY_PREFIX", `${redisKeyPrefix}:pool`);
const productionRedisOnly =
  process.env.NODE_ENV === "production" &&
  (toBoolean("PRODUCTION_REDIS_ONLY", false) ||
    toBoolean("PRODUCTION_PROOF_REDIS_ONLY", false) ||
    toBoolean("RBI_PRODUCTION_PROOF", false) ||
    toBoolean("RBI_REDIS_ONLY", false) ||
    toBoolean("REQUIRE_REDIS_BACKENDS", false));
const publicTurnTlsPort = Math.round(clampNumber(process.env.PUBLIC_TURN_TLS_PORT, 1, 65535, 443));
const allowedCandidateTypes = toCandidateTypeList(
  "ALLOWED_ICE_CANDIDATE_TYPES",
  isLocalDefault ? ["host", "srflx", "relay"] : ["srflx", "relay"],
);
const viewerIceTransportPolicy =
  process.env.VIEWER_ICE_TRANSPORT_POLICY ||
  (allowedCandidateTypes.length === 1 && allowedCandidateTypes[0] === "relay" ? "relay" : "all");

const initialStreamScale = clampNumber(process.env.INITIAL_STREAM_SCALE, 0.5, 1, 1);
const captureFramerate = Math.round(clampNumber(process.env.CAPTURE_FRAMERATE, 15, 30, 20));
const videoMinBitrateBps = Math.round(
  clampNumber(process.env.VIDEO_MIN_BITRATE_BPS, 200_000, 20_000_000, 600_000),
);
const videoStartBitrateBps = Math.round(
  clampNumber(process.env.VIDEO_START_BITRATE_BPS, videoMinBitrateBps, 20_000_000, 1_500_000),
);
const videoMaxBitrateBps = Math.round(
  clampNumber(process.env.VIDEO_MAX_BITRATE_BPS, videoStartBitrateBps, 30_000_000, 3_000_000),
);

export const config = {
  rootDir,
  host: process.env.HOST || "0.0.0.0",
  hostIp,
  port: toNumber("PORT", 8080),
  publicBaseUrl,
  publicOrigin: `${publicBase.protocol}//${publicBase.host}`,
  publicWsUrl,
  workerWsUrl,
  workerWsConnectHost: process.env.WORKER_WS_CONNECT_HOST || "",
  poolWsUrl: process.env.POOL_WS_URL || workerWsUrl,
  poolWsConnectHost:
    process.env.POOL_WS_CONNECT_HOST || process.env.WORKER_WS_CONNECT_HOST || "",
  serviceHostname,
  serviceHostnameAliases: toList("SERVICE_HOSTNAME_ALIASES", []),
  turnHostname,
  debug: toBoolean("DEBUG_RBI", false),

  tokenSecret: process.env.TOKEN_SECRET || "",
  turnSharedSecret: process.env.TURN_SHARED_SECRET || "",
  turnCredentialTtlSeconds: toNumber("TURN_CREDENTIAL_TTL_SECONDS", 300),
  swgSharedSecret: process.env.SWG_SHARED_SECRET || "",
  enableSwgBootstrap: toBoolean("ENABLE_SWG_BOOTSTRAP", true),
  swgBootstrapLocalOnly: toBoolean("SWG_BOOTSTRAP_LOCAL_ONLY", isLocalDefault),
  swgBootstrapAllowedContractVersions: toList("SWG_BOOTSTRAP_ALLOWED_CONTRACT_VERSIONS", ["v2"]),
  swgBootstrapAllowedRequestKinds: toList("SWG_BOOTSTRAP_ALLOWED_REQUEST_KINDS", [
    "http-document",
    "https-decrypted-document",
  ]),
  swgBootstrapAllowedOriginalMethods: toList("SWG_BOOTSTRAP_ALLOWED_ORIGINAL_METHODS", [
    "GET",
    "HEAD",
  ]),
  swgBootstrapAllowedProviders: toList("SWG_BOOTSTRAP_ALLOWED_PROVIDERS", ["in_house"]),
  swgBootstrapAllowedProviderCategories: toList("SWG_BOOTSTRAP_ALLOWED_PROVIDER_CATEGORIES", [
    "cat-b",
  ]),
  rbiFallbackProvider: process.env.RBI_FALLBACK_PROVIDER || "menlo",
  swgTimestampToleranceMs: toNumber(
    "SWG_TIMESTAMP_TOLERANCE_MS",
    isLocalDefault ? 5 * 60 * 1000 : 90 * 1000,
  ),
  swgReplayTtlMs: toNumber("SWG_REPLAY_TTL_MS", 10 * 60 * 1000),
  sessionAuthorityBootstrapUrl: process.env.SESSION_AUTHORITY_BOOTSTRAP_URL || "",
  sessionAuthorityTimeoutMs: toNumber("SESSION_AUTHORITY_TIMEOUT_MS", 5000),
  gatewayControlTimeoutMs: toNumber("GATEWAY_CONTROL_TIMEOUT_MS", 3000),
  rbiInternalSharedSecret: process.env.RBI_INTERNAL_SHARED_SECRET || "",

  sessionStoreBackend: process.env.SESSION_STORE_BACKEND || "memory",
  signalBusBackend,
  workerPoolStoreBackend,
  workerPoolBusBackend,
  redisUrl: process.env.REDIS_URL || "",
  redisTls: toBoolean("REDIS_TLS", false),
  redisKeyPrefix,
  signalBusChannel: process.env.SIGNAL_BUS_CHANNEL || `${redisKeyPrefix}:signals:pending`,
  workerPoolKeyPrefix,
  workerPoolPendingChannel:
    process.env.WORKER_POOL_PENDING_CHANNEL || `${workerPoolKeyPrefix}:pending`,
  swgReplayKeyPrefix: process.env.SWG_REPLAY_KEY_PREFIX || `${redisKeyPrefix}:swg-replay`,
  swgBootstrapIdempotencyKeyPrefix:
    process.env.SWG_BOOTSTRAP_IDEMPOTENCY_KEY_PREFIX || `${redisKeyPrefix}:swg-bootstrap`,
  productionRedisOnly,
  sessionTtlMs: toNumber("SESSION_TTL_MS", 3 * 60 * 60 * 1000),
  idleTimeoutMs: toNumber("IDLE_TIMEOUT_MS", 5 * 60 * 1000),
  viewerConnectTimeoutMs: toNumber("VIEWER_CONNECT_TIMEOUT_MS", 90 * 1000),
  idleReaperIntervalMs: toNumber("IDLE_REAPER_INTERVAL_MS", 30 * 1000),
  singleActiveSessionMode: toBoolean("SINGLE_ACTIVE_SESSION_MODE", false),
  warmPoolEnabled: toBoolean("WARM_POOL_ENABLED", false),
  warmPoolAllocationWaitMs: toNumber("WARM_POOL_ALLOCATION_WAIT_MS", 1500),
  workerPoolLeaseTtlMs: toNumber("WORKER_POOL_LEASE_TTL_MS", 45_000),
  swgBootstrapIdempotencyTtlMs: toNumber("SWG_BOOTSTRAP_IDEMPOTENCY_TTL_MS", 10 * 60 * 1000),
  swgBootstrapIdempotencyWaitMs: toNumber("SWG_BOOTSTRAP_IDEMPOTENCY_WAIT_MS", 5000),
  viewerRefreshMinSessionAgeMs: toNumber("VIEWER_REFRESH_MIN_SESSION_AGE_MS", 2000),
  viewerEventMaxBytes: toNumber("VIEWER_EVENT_MAX_BYTES", 4096),
  viewerTelemetryMaxEvents: toNumber("VIEWER_TELEMETRY_MAX_EVENTS", 200),
  poolWorkerSecret: process.env.POOL_WORKER_SECRET || process.env.POOL_SHARED_SECRET || "",

  staticDir: path.join(rootDir, "viewer"),
  sharedStaticDir: path.join(rootDir, "shared"),
  workerSeccompProfile: hasEnv("WORKER_SECCOMP_PROFILE")
    ? process.env.WORKER_SECCOMP_PROFILE
    : path.join(rootDir, "deploy", "chromium-seccomp.json"),

  displayWidth: toNumber("DISPLAY_WIDTH", 1280),
  displayHeight: toNumber("DISPLAY_HEIGHT", 720),
  initialStreamScale,
  captureFramerate,
  preferredVideoCodecs: toList("VIDEO_CODEC_PREFERENCES", ["VP8"])
    .map((value) => value.toUpperCase())
    .filter(Boolean),
  videoCaptureBackend: String(process.env.VIDEO_CAPTURE_BACKEND || "x11grab").toLowerCase(),
  videoMinBitrateBps,
  videoStartBitrateBps,
  videoMaxBitrateBps,
  audioSyncDelayMs: Math.round(clampNumber(process.env.AUDIO_SYNC_DELAY_MS, 0, 1000, 0)),
  pulseCaptureLatencyMsec: Math.round(
    clampNumber(process.env.PULSE_CAPTURE_LATENCY_MSEC, 5, 250, 20),
  ),
  chromiumUseDevShm: toBoolean("CHROMIUM_USE_DEV_SHM", true),
  hybridDomSnapshotTimeoutSec: toNumber("HYBRID_DOM_SNAPSHOT_TIMEOUT_SEC", 8),
  hybridDomBridgeEnabled: false,
  experimentalSourceCoupledAvEnabled: toBoolean("EXPERIMENTAL_SOURCE_COUPLED_AV_ENABLED", true),
  experimentalSourceCoupledAvDefault: toBoolean("EXPERIMENTAL_SOURCE_COUPLED_AV_DEFAULT", true),

  viewerIceUrls: toList(
    "VIEWER_ICE_URLS",
    isLocalDefault
      ? [
          `stun:${hostIp}:3478`,
          `turn:${hostIp}:3478?transport=udp`,
          `turn:${hostIp}:3478?transport=tcp`,
        ]
      : [
          `stun:${turnHostname}:3478`,
          `turn:${turnHostname}:3478?transport=udp`,
          `turn:${turnHostname}:3478?transport=tcp`,
          `turns:${turnHostname}:${publicTurnTlsPort}?transport=tcp`,
        ],
  ),
  workerIceUrls: toList(
    "WORKER_ICE_URLS",
    isLocalDefault
      ? [
          `stun:${workerTurnHost}:3478`,
          `turn:${workerTurnHost}:3478?transport=udp`,
          `turn:${workerTurnHost}:3478?transport=tcp`,
        ]
      : [
          `stun:${workerTurnHost}:3478`,
          `turn:${workerTurnHost}:3478?transport=udp`,
          `turn:${workerTurnHost}:3478?transport=tcp`,
        ],
  ),
  viewerIceTransportPolicy,
  allowedIceCandidateTypes: allowedCandidateTypes,

  workerLaunchMode: process.env.WORKER_LAUNCH_MODE || "docker",
  workerImage: process.env.WORKER_IMAGE || "cloudsec-remote-browser-worker",
  workerImageDigest: process.env.WORKER_IMAGE_DIGEST || "",
  workerNetwork: process.env.WORKER_NETWORK || "cloudsec_remote_browser_default",
  workerDockerAutoRemove: toBoolean("WORKER_DOCKER_AUTO_REMOVE", true),
  workerDockerUseInit: toBoolean("WORKER_DOCKER_USE_INIT", true),
  workerDisableChromiumSandbox: toBoolean("WORKER_DISABLE_CHROMIUM_SANDBOX", false),
  hostAgentDiscoveryUrls: toList("HOST_AGENT_DISCOVERY_URLS", []),
  hostAgentPreferredRegions: toList("HOST_AGENT_PREFERRED_REGIONS", []),
  hostAgentSecret: process.env.HOST_AGENT_SECRET || "",
  awsRegion: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || "us-east-1",
  ecsWorkerClusterArn: process.env.ECS_WORKER_CLUSTER_ARN || "",
  ecsWorkerTaskDefinitionArn: process.env.ECS_WORKER_TASK_DEFINITION_ARN || "",
  ecsWorkerContainerName: process.env.ECS_WORKER_CONTAINER_NAME || "browser-worker",
  ecsWorkerSubnets: toList("ECS_WORKER_SUBNETS", []),
  ecsWorkerSecurityGroups: toList("ECS_WORKER_SECURITY_GROUPS", []),
  ecsWorkerAssignPublicIp: toBoolean("ECS_WORKER_ASSIGN_PUBLIC_IP", false),
  ecsWorkerLaunchType: process.env.ECS_WORKER_LAUNCH_TYPE || "EC2",
  ecsWorkerCapacityProvider: process.env.ECS_WORKER_CAPACITY_PROVIDER || "",
  kubernetesApiServer: process.env.KUBERNETES_API_SERVER || "",
  kubernetesServiceAccountTokenPath:
    process.env.KUBERNETES_SERVICEACCOUNT_TOKEN_PATH ||
    "/var/run/secrets/kubernetes.io/serviceaccount/token",
  kubernetesServiceAccountCaPath:
    process.env.KUBERNETES_SERVICEACCOUNT_CA_PATH ||
    "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
  kubernetesServiceAccountNamespacePath:
    process.env.KUBERNETES_SERVICEACCOUNT_NAMESPACE_PATH ||
    "/var/run/secrets/kubernetes.io/serviceaccount/namespace",
  kubernetesWorkerNamespace: process.env.KUBERNETES_WORKER_NAMESPACE || "cloudsec-rbi-workers",
  kubernetesWorkerContainerName: process.env.KUBERNETES_WORKER_CONTAINER_NAME || "worker",
  kubernetesWorkerServiceAccountName:
    process.env.KUBERNETES_WORKER_SERVICE_ACCOUNT ||
    process.env.KUBERNETES_WORKER_SERVICEACCOUNT_NAME ||
    "rbi-worker",
  kubernetesWorkerRuntimeClassName: process.env.KUBERNETES_WORKER_RUNTIME_CLASS_NAME || "kata-clh",
  kubernetesWorkerImagePullPolicy: process.env.KUBERNETES_WORKER_IMAGE_PULL_POLICY || "IfNotPresent",
  kubernetesWorkerConfigMapName: process.env.KUBERNETES_WORKER_CONFIG_MAP_NAME || "",
  kubernetesWorkerBackoffLimit: Math.round(toNumber("KUBERNETES_WORKER_BACKOFF_LIMIT", 0)),
  kubernetesWorkerActiveDeadlineSeconds: Math.round(
    toNumber("KUBERNETES_WORKER_ACTIVE_DEADLINE_SECONDS", 7200),
  ),
  kubernetesWorkerTtlSecondsAfterFinished: Math.round(
    toNumber("KUBERNETES_WORKER_TTL_SECONDS_AFTER_FINISHED", 3600),
  ),
  kubernetesOrphanReaperEnabled: toBoolean("KUBERNETES_ORPHAN_REAPER_ENABLED", false),
  kubernetesOrphanReaperIntervalMs: toNumber("KUBERNETES_ORPHAN_REAPER_INTERVAL_MS", 60 * 1000),
  kubernetesOrphanWorkerGraceMs: toNumber("KUBERNETES_ORPHAN_WORKER_GRACE_MS", 5 * 60 * 1000),
  kubernetesWorkerTerminationGracePeriodSeconds: Math.round(
    toNumber("KUBERNETES_WORKER_TERMINATION_GRACE_PERIOD_SECONDS", 30),
  ),
  kubernetesWorkerNodeSelector: toKeyValueMap("KUBERNETES_WORKER_NODE_SELECTOR", {
    "kubernetes.io/arch": "amd64",
    "kubernetes.io/os": "linux",
    "cloudsec.cisco.com/rbi-worker-plane": "true",
    "cloudsec.cisco.com/node-pool": "rbi-workers",
  }),
  kubernetesWorkerLabels: toKeyValueMap("KUBERNETES_WORKER_LABELS", {}),
  kubernetesWorkerAnnotations: toKeyValueMap("KUBERNETES_WORKER_ANNOTATIONS", {}),
  kubernetesWorkerTolerations: toJsonValue("KUBERNETES_WORKER_TOLERATIONS_JSON", [
    {
      key: "cloudsec.cisco.com/rbi-worker-plane",
      operator: "Equal",
      value: "true",
      effect: "NoSchedule",
    },
  ]),
  kubernetesWorkerResources: toJsonValue("KUBERNETES_WORKER_RESOURCES_JSON", {
    requests: {
      cpu: process.env.KUBERNETES_WORKER_CPU_REQUEST || "1500m",
      memory: process.env.KUBERNETES_WORKER_MEMORY_REQUEST || "3Gi",
      "ephemeral-storage": process.env.KUBERNETES_WORKER_EPHEMERAL_STORAGE_REQUEST || "4Gi",
    },
    limits: {
      cpu: process.env.KUBERNETES_WORKER_CPU_LIMIT || "3000m",
      memory: process.env.KUBERNETES_WORKER_MEMORY_LIMIT || "6Gi",
      "ephemeral-storage": process.env.KUBERNETES_WORKER_EPHEMERAL_STORAGE_LIMIT || "8Gi",
    },
  }),
  kubernetesWorkerImagePullSecretNames: toList("KUBERNETES_WORKER_IMAGE_PULL_SECRET_NAMES", []),
};

const missingRequired = [];
if (!config.tokenSecret) {
  missingRequired.push("TOKEN_SECRET");
}
if (!config.turnSharedSecret) {
  missingRequired.push("TURN_SHARED_SECRET");
}
if (config.enableSwgBootstrap && !config.swgSharedSecret) {
  missingRequired.push("SWG_SHARED_SECRET");
}
if (config.sessionAuthorityBootstrapUrl && !config.rbiInternalSharedSecret) {
  missingRequired.push("RBI_INTERNAL_SHARED_SECRET");
}
if (
  (config.sessionStoreBackend === "redis" ||
    config.signalBusBackend === "redis" ||
    config.workerPoolStoreBackend === "redis" ||
    config.workerPoolBusBackend === "redis") &&
  !config.redisUrl
) {
  missingRequired.push("REDIS_URL");
}
if (config.warmPoolEnabled && !config.poolWorkerSecret) {
  missingRequired.push("POOL_WORKER_SECRET");
}
if (config.productionRedisOnly) {
  for (const [name, value] of [
    ["SESSION_STORE_BACKEND", config.sessionStoreBackend],
    ["SIGNAL_BUS_BACKEND", config.signalBusBackend],
    ["WORKER_POOL_STORE_BACKEND", config.workerPoolStoreBackend],
    ["WORKER_POOL_BUS_BACKEND", config.workerPoolBusBackend],
  ]) {
    if (value !== "redis") {
      missingRequired.push(`${name}=redis`);
    }
  }
}
if (config.workerLaunchMode === "host-agent") {
  if (!config.hostAgentSecret) {
    missingRequired.push("HOST_AGENT_SECRET");
  }
  if (!config.hostAgentDiscoveryUrls.length) {
    missingRequired.push("HOST_AGENT_DISCOVERY_URLS");
  }
}

if (missingRequired.length && process.env.NODE_ENV === "production") {
  console.error(`[FATAL] Missing required runtime configuration: ${missingRequired.join(", ")}`);
  process.exit(1);
}
