import crypto from "node:crypto";
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import { promisify } from "node:util";

import { ECSClient, RunTaskCommand, StopTaskCommand } from "@aws-sdk/client-ecs";
import { buildGatewaySignalingUrl, usesGatewaySignaling } from "../shared/gateway-signaling.js";

const execFileAsync = promisify(execFile);
const WORKER_GATEWAY_WEBRTC_RELAY_MODE = "gateway-webrtc-relay";
const WORKER_WEBRTC_SRTP_PROTOCOL = "webrtc-srtp";

function fetchWithNodeHttp(url, options = {}) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const transport = parsed.protocol === "http:" ? http : https;
    const body = options.body || null;
    const headers = { ...(options.headers || {}) };
    if (body && !Object.prototype.hasOwnProperty.call(headers, "Content-Length")) {
      headers["Content-Length"] = Buffer.byteLength(body);
    }

    const request = transport.request(
      parsed,
      {
        method: options.method || "GET",
        headers,
        ca: options.ca,
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          resolve({
            ok: response.statusCode >= 200 && response.statusCode < 300,
            status: response.statusCode,
            statusText: response.statusMessage || "",
            text: async () => text,
          });
        });
      },
    );

    request.on("error", reject);
    if (options.signal) {
      if (options.signal.aborted) {
        request.destroy(new Error("Request aborted"));
        return;
      }
      options.signal.addEventListener(
        "abort",
        () => request.destroy(new Error("Request aborted")),
        { once: true },
      );
    }
    if (body) {
      request.write(body);
    }
    request.end();
  });
}

function buildEnvArgs(env) {
  const args = [];
  for (const [key, value] of Object.entries(env)) {
    args.push("-e", `${key}=${value}`);
  }
  return args;
}

function buildTurnCredentials(session, config) {
  if (session.turnCredentials?.worker) {
    return {
      username: session.turnCredentials.worker.username,
      password: session.turnCredentials.worker.credential,
    };
  }
  return {
    username: "",
    password: "",
  };
}

function normalizeRegion(value) {
  return String(value || "").trim().toLowerCase();
}

function rotateByIndex(items, index = 0) {
  if (!items.length) {
    return [];
  }
  const offset = ((Math.trunc(index) % items.length) + items.length) % items.length;
  return [...items.slice(offset), ...items.slice(0, offset)];
}

export function getPreferredHostAgentRegions(session, config = {}) {
  const preferred = [];
  const client = session?.client || {};
  const append = (value) => {
    const normalized = normalizeRegion(value);
    if (normalized && !preferred.includes(normalized)) {
      preferred.push(normalized);
    }
  };

  for (const value of client.preferredWorkerRegions || []) {
    append(value);
  }
  append(client.workerRegion);
  append(client.regionHint);
  for (const value of config.hostAgentPreferredRegions || []) {
    append(value);
  }
  append(config.awsRegion);
  return preferred;
}

export function orderHostAgentTargets(targets, preferredRegions = [], startIndex = 0) {
  const uniqueTargets = [];
  const seen = new Set();
  for (const target of targets || []) {
    const baseUrl = String(target?.baseUrl || "").trim().replace(/\/+$/, "");
    if (!baseUrl || seen.has(baseUrl)) {
      continue;
    }
    seen.add(baseUrl);
    uniqueTargets.push({ ...target, baseUrl });
  }

  const ordered = [];
  const appended = new Set();
  const normalizedPreferredRegions = preferredRegions
    .map((value) => normalizeRegion(value))
    .filter(Boolean);

  for (const region of normalizedPreferredRegions) {
    const matches = rotateByIndex(
      uniqueTargets.filter((target) => normalizeRegion(target.region) === region),
      startIndex,
    );
    for (const target of matches) {
      if (!appended.has(target.baseUrl)) {
        appended.add(target.baseUrl);
        ordered.push(target);
      }
    }
  }

  for (const target of rotateByIndex(uniqueTargets, startIndex)) {
    if (!appended.has(target.baseUrl)) {
      appended.add(target.baseUrl);
      ordered.push(target);
    }
  }

  return ordered;
}

function normalizeWorkerMediaValue(value) {
  return String(value || "").trim().toLowerCase();
}

export function usesWorkerGatewayWebrtcRelay(session) {
  const mediaRelay = buildWorkerMediaRelayConfig(session);
  return Boolean(
    mediaRelay.mediaGatewayUrl &&
      normalizeWorkerMediaValue(mediaRelay.mediaPlaneMode) === WORKER_GATEWAY_WEBRTC_RELAY_MODE &&
      normalizeWorkerMediaValue(mediaRelay.protocol) === WORKER_WEBRTC_SRTP_PROTOCOL,
  );
}

function prioritizeVp8CodecPreferences(preferredVideoCodecs = []) {
  const unique = [];
  const append = (codec) => {
    const value = String(codec || "").trim().toUpperCase();
    if (value && !unique.includes(value)) {
      unique.push(value);
    }
  };
  append("VP8");
  for (const codec of preferredVideoCodecs) {
    append(codec);
  }
  return unique;
}

function buildWorkerPerformanceEnv(config, session) {
  const preferredVideoCodecs = usesWorkerGatewayWebrtcRelay(session)
    ? prioritizeVp8CodecPreferences(config.preferredVideoCodecs)
    : config.preferredVideoCodecs || [];
  return {
    INITIAL_STREAM_SCALE: String(config.initialStreamScale),
    CAPTURE_FRAMERATE: String(config.captureFramerate),
    VIDEO_CAPTURE_BACKEND: String(config.videoCaptureBackend || "x11grab"),
    VIDEO_CODEC_PREFERENCES: preferredVideoCodecs.join(","),
    VIDEO_MIN_BITRATE_BPS: String(config.videoMinBitrateBps),
    VIDEO_START_BITRATE_BPS: String(config.videoStartBitrateBps),
    VIDEO_MAX_BITRATE_BPS: String(config.videoMaxBitrateBps),
    AUDIO_SYNC_DELAY_MS: String(config.audioSyncDelayMs),
    PULSE_CAPTURE_LATENCY_MSEC: String(config.pulseCaptureLatencyMsec),
    HYBRID_DOM_SNAPSHOT_TIMEOUT_SEC: String(config.hybridDomSnapshotTimeoutSec),
    CHROMIUM_USE_DEV_SHM: config.chromiumUseDevShm ? "1" : "0",
    HYBRID_DOM_BRIDGE_ENABLED: config.hybridDomBridgeEnabled ? "1" : "0",
  };
}

function buildWorkerExperimentalEnv(session) {
  return {
    EXPERIMENTAL_SOURCE_COUPLED_AV:
      session?.experiments?.sourceCoupledAv === false ? "0" : "1",
  };
}

function buildWorkerSignalingUrl(session, config) {
  if (!usesGatewaySignaling(session)) {
    return config.workerWsUrl;
  }
  const workerBaseUrl = String(config.workerWsUrl || "").trim();
  if (workerBaseUrl) {
    return buildGatewaySignalingUrl(workerBaseUrl, session.id, "worker", {
      relay: session?.sessionPlacement?.gatewayAssignment?.relayMode || "",
    });
  }
  const baseUrl =
    String(
      session?.sessionPlacement?.gatewayAssignment?.publicWsURL ||
        session?.sessionPlacement?.gatewayAssignment?.publicWsUrl ||
        "",
    ).trim() || config.workerWsUrl;
  return buildGatewaySignalingUrl(baseUrl, session.id, "worker", {
    relay: session?.sessionPlacement?.gatewayAssignment?.relayMode || "",
  });
}

function buildWorkerSignalingConnectHost(session, config, signalingUrl) {
  const fallback = String(config.workerWsConnectHost || "").trim();
  if (!fallback) {
    return "";
  }
  try {
    const direct = new URL(config.workerWsUrl);
    const target = new URL(signalingUrl);
    return direct.host === target.host ? fallback : "";
  } catch {
    return fallback;
  }
}

export function buildWorkerMediaRelayConfig(session) {
  const workerBridge = session?.workerBridge || {};
  const transport = session?.transport || {};
  const mediaTermination = transport.mediaTermination || {};
  const mediaRelayUrl = String(
    workerBridge.mediaRelayUrl ||
      workerBridge.mediaRelayURL ||
      "",
  ).trim();
  const mediaGatewayUrl = String(
    workerBridge.mediaGatewayUrl ||
      workerBridge.mediaGatewayURL ||
      transport.mediaGatewayUrl ||
      transport.mediaGatewayURL ||
      "",
  ).trim();
  const relayMode = String(
    workerBridge.relayMode ||
      session?.sessionPlacement?.gatewayAssignment?.relayMode ||
      "",
  ).trim();
  const protocol = String(workerBridge.protocol || transport.protocol || "").trim();
  const mediaPlaneMode = String(transport.mediaPlaneMode || mediaTermination.mediaPlaneMode || "").trim();

  return {
    mediaRelayUrl,
    mediaGatewayUrl,
    relayMode,
    protocol,
    mediaPlaneMode,
    inputPointerName: String(workerBridge.inputPointerName || transport.inputPointerName || "input-pointer"),
    inputControlName: String(workerBridge.inputControlName || transport.inputControlName || "input-control"),
    gatewayTerminatesMedia: mediaTermination.gatewayTerminatesMedia === true,
  };
}

function buildWorkerMediaRelayEnv(session) {
  const mediaRelay = buildWorkerMediaRelayConfig(session);
  return {
    MEDIA_RELAY_URL: mediaRelay.mediaRelayUrl,
    MEDIA_GATEWAY_URL: mediaRelay.mediaGatewayUrl,
    MEDIA_RELAY_MODE: mediaRelay.relayMode,
    MEDIA_PLANE_MODE: mediaRelay.mediaPlaneMode,
    MEDIA_RELAY_PROTOCOL: mediaRelay.protocol,
    INPUT_POINTER_CHANNEL_NAME: mediaRelay.inputPointerName,
    INPUT_CONTROL_CHANNEL_NAME: mediaRelay.inputControlName,
    MEDIA_RELAY_GATEWAY_TERMINATES_MEDIA: mediaRelay.gatewayTerminatesMedia ? "1" : "0",
  };
}

export function buildWorkerEnvironment(session, config) {
  const turn = buildTurnCredentials(session, config);
  const signalingUrl = buildWorkerSignalingUrl(session, config);
  return {
    SESSION_ID: session.id,
    TARGET_URL: session.targetUrl,
    SIGNALING_URL: signalingUrl,
    SIGNALING_CONNECT_HOST: buildWorkerSignalingConnectHost(session, config, signalingUrl),
    WORKER_TOKEN: session.workerToken,
    DISPLAY_WIDTH: String(session.viewport.width || config.displayWidth),
    DISPLAY_HEIGHT: String(session.viewport.height || config.displayHeight),
    DISABLE_CHROMIUM_SANDBOX: config.workerDisableChromiumSandbox ? "1" : "0",
    TURN_USERNAME: turn.username,
    TURN_PASSWORD: turn.password,
    WORKER_ICE_URLS: config.workerIceUrls.join(","),
    ALLOWED_CANDIDATE_TYPES: config.allowedIceCandidateTypes.join(","),
    ...buildWorkerMediaRelayEnv(session),
    ...buildWorkerPerformanceEnv(config, session),
    ...buildWorkerExperimentalEnv(session),
  };
}

function buildContainerOverrideEnvironment(env) {
  return Object.entries(env).map(([name, value]) => ({
    name,
    value: String(value ?? ""),
  }));
}

class DockerWorkerRuntime {
  constructor(config) {
    this.config = config;
  }

  async launch(session) {
    const containerName = `rbi-worker-${session.id}`;
    const env = buildWorkerEnvironment(session, this.config);

    const args = [
      "run",
      "-d",
      "--shm-size=1g",
    ];

    if (this.config.workerDockerUseInit) {
      args.push("--init");
    }

    if (this.config.workerDockerAutoRemove) {
      args.push("--rm");
    }

    if (this.config.workerSeccompProfile) {
      args.push("--security-opt", `seccomp=${this.config.workerSeccompProfile}`);
    }

    args.push(
      "--network",
      this.config.workerNetwork,
      "--name",
      containerName,
      ...buildEnvArgs(env),
      this.config.workerImage,
    );

    const { stdout } = await execFileAsync("docker", args);
    return {
      launchMode: "docker",
      containerId: stdout.trim(),
      containerName,
      workerId: containerName,
    };
  }

  async stop(worker) {
    if (!worker?.containerName) {
      return;
    }
    try {
      await execFileAsync("docker", ["rm", "-f", worker.containerName]);
    } catch (error) {
      const stderr = String(error.stderr || "");
      if (
        !stderr.includes("No such container") &&
        !stderr.includes("removal of container") &&
        !stderr.includes("is already in progress")
      ) {
        throw error;
      }
    }
  }

  async ensureReady() {
    await execFileAsync("docker", ["image", "inspect", this.config.workerImage]);
  }
}

class EcsWorkerRuntime {
  constructor(config) {
    this.config = config;
    this.client = new ECSClient({
      region: config.awsRegion,
    });
  }

  buildOverrides(session) {
    return {
      containerOverrides: [
        {
          name: this.config.ecsWorkerContainerName,
          environment: buildContainerOverrideEnvironment(
            buildWorkerEnvironment(session, this.config),
          ),
        },
      ],
    };
  }

  async launch(session) {
    const request = {
      cluster: this.config.ecsWorkerClusterArn,
      taskDefinition: this.config.ecsWorkerTaskDefinitionArn,
      count: 1,
      overrides: this.buildOverrides(session),
      enableECSManagedTags: true,
      enableExecuteCommand: false,
      networkConfiguration: {
        awsvpcConfiguration: {
          subnets: this.config.ecsWorkerSubnets,
          securityGroups: this.config.ecsWorkerSecurityGroups,
          assignPublicIp: this.config.ecsWorkerAssignPublicIp ? "ENABLED" : "DISABLED",
        },
      },
      tags: [
        { key: "service", value: "rbi-worker" },
        { key: "session-id", value: session.id },
      ],
    };

    if (this.config.ecsWorkerCapacityProvider) {
      request.capacityProviderStrategy = [
        {
          capacityProvider: this.config.ecsWorkerCapacityProvider,
          weight: 1,
        },
      ];
    } else {
      request.launchType = this.config.ecsWorkerLaunchType;
    }

    const response = await this.client.send(new RunTaskCommand(request));
    if (response.failures?.length) {
      const failure = response.failures[0];
      throw new Error(
        `Failed to launch worker task: ${failure.reason || "unknown"} ${failure.detail || ""}`.trim(),
      );
    }

    const task = response.tasks?.[0];
    if (!task?.taskArn) {
      throw new Error("Failed to launch worker task: ECS returned no task ARN");
    }

    return {
      launchMode: "ecs",
      clusterArn: this.config.ecsWorkerClusterArn,
      taskArn: task.taskArn,
      workerId: task.taskArn,
    };
  }

  async stop(worker) {
    if (!worker?.taskArn) {
      return;
    }
    try {
      await this.client.send(
        new StopTaskCommand({
          cluster: worker.clusterArn || this.config.ecsWorkerClusterArn,
          task: worker.taskArn,
          reason: "session terminated",
        }),
      );
    } catch (error) {
      const message = String(error.message || "");
      if (
        !message.includes("TaskNotFoundException") &&
        !message.includes("task was not found")
      ) {
        throw error;
      }
    }
  }

  async ensureReady() {}
}

function sanitizeKubernetesName(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/--+/g, "-");
}

function buildKubernetesJobName(sessionId) {
  const hash = crypto.createHash("sha256").update(String(sessionId || "")).digest("hex").slice(0, 10);
  const prefix = "rbi-worker";
  const maxBaseLength = 63 - prefix.length - hash.length - 2;
  const base = sanitizeKubernetesName(sessionId).slice(0, maxBaseLength).replace(/-+$/g, "") || "session";
  return `${prefix}-${base}-${hash}`;
}

function buildKubernetesLabelValue(value) {
  const sanitized = String(value || "")
    .replace(/[^A-Za-z0-9_.-]+/g, "-")
    .replace(/^[^A-Za-z0-9]+|[^A-Za-z0-9]+$/g, "");
  return sanitized.slice(0, 63).replace(/[^A-Za-z0-9]+$/g, "") || "unknown";
}

function buildKubernetesEnv(env) {
  return Object.entries(env).map(([name, value]) => ({
    name,
    value: String(value ?? ""),
  }));
}

function buildImagePullSecrets(names = []) {
  return names.map((name) => String(name || "").trim()).filter(Boolean).map((name) => ({ name }));
}

function buildWorkerVolumes() {
  return [
    {
      name: "tmp",
      emptyDir: {
        medium: "Memory",
        sizeLimit: "1Gi",
      },
    },
    {
      name: "dev-shm",
      emptyDir: {
        medium: "Memory",
        sizeLimit: "1Gi",
      },
    },
    {
      name: "home",
      emptyDir: {
        sizeLimit: "6Gi",
      },
    },
  ];
}

function buildWorkerVolumeMounts() {
  return [
    {
      name: "tmp",
      mountPath: "/tmp",
    },
    {
      name: "dev-shm",
      mountPath: "/dev/shm",
    },
    {
      name: "home",
      mountPath: "/home/rbi",
    },
  ];
}

export function buildKubernetesWorkerJob(session, config) {
  const jobName = buildKubernetesJobName(session.id);
  const labels = {
    "app.kubernetes.io/name": "cloudsec-remote-browser",
    "app.kubernetes.io/component": "rbi-session-worker",
    "cloudsec.cisco.com/rbi-plane": "worker",
    "cloudsec.cisco.com/worker-mode": "session",
    "cloudsec.cisco.com/session-id": buildKubernetesLabelValue(session.id),
    ...(config.kubernetesWorkerLabels || {}),
  };
  const container = {
    name: config.kubernetesWorkerContainerName || "worker",
    image: config.workerImage,
    imagePullPolicy: config.kubernetesWorkerImagePullPolicy || "IfNotPresent",
    env: buildKubernetesEnv({
      WORKER_MODE: "session",
      ...buildWorkerEnvironment(session, config),
    }),
    resources: config.kubernetesWorkerResources,
    securityContext: {
      allowPrivilegeEscalation: false,
      capabilities: {
        drop: ["ALL"],
      },
      readOnlyRootFilesystem: true,
    },
    volumeMounts: buildWorkerVolumeMounts(),
  };

  if (config.kubernetesWorkerConfigMapName) {
    container.envFrom = [
      {
        configMapRef: {
          name: config.kubernetesWorkerConfigMapName,
        },
      },
    ];
  }

  const podSpec = {
    automountServiceAccountToken: false,
    enableServiceLinks: false,
    hostIPC: false,
    hostNetwork: false,
    hostPID: false,
    restartPolicy: "Never",
    serviceAccountName: config.kubernetesWorkerServiceAccountName || "rbi-worker",
    terminationGracePeriodSeconds: config.kubernetesWorkerTerminationGracePeriodSeconds ?? 30,
    nodeSelector: config.kubernetesWorkerNodeSelector || {},
    tolerations: config.kubernetesWorkerTolerations || [],
    securityContext: {
      fsGroup: 1000,
      fsGroupChangePolicy: "OnRootMismatch",
      runAsNonRoot: true,
      runAsGroup: 1000,
      runAsUser: 1000,
      seccompProfile: {
        type: "RuntimeDefault",
      },
    },
    containers: [container],
    volumes: buildWorkerVolumes(),
  };

  if (config.kubernetesWorkerRuntimeClassName) {
    podSpec.runtimeClassName = config.kubernetesWorkerRuntimeClassName;
  }

  const imagePullSecrets = buildImagePullSecrets(config.kubernetesWorkerImagePullSecretNames);
  if (imagePullSecrets.length) {
    podSpec.imagePullSecrets = imagePullSecrets;
  }

  return {
    apiVersion: "batch/v1",
    kind: "Job",
    metadata: {
      name: jobName,
      namespace: config.kubernetesWorkerNamespace,
      labels,
      annotations: config.kubernetesWorkerAnnotations || {},
    },
    spec: {
      backoffLimit: config.kubernetesWorkerBackoffLimit ?? 0,
      completions: 1,
      parallelism: 1,
      activeDeadlineSeconds: config.kubernetesWorkerActiveDeadlineSeconds ?? 7200,
      ttlSecondsAfterFinished: config.kubernetesWorkerTtlSecondsAfterFinished ?? 3600,
      template: {
        metadata: {
          labels,
          annotations: config.kubernetesWorkerAnnotations || {},
        },
        spec: podSpec,
      },
    },
  };
}

class KubernetesApiClient {
  constructor(config) {
    this.config = config;
    this.fetchImpl = config.kubernetesFetch || fetchWithNodeHttp;
    this.ca = null;
  }

  buildBaseUrl() {
    const configured = String(this.config.kubernetesApiServer || "").trim();
    if (configured) {
      return configured.replace(/\/+$/, "");
    }
    const host = process.env.KUBERNETES_SERVICE_HOST;
    if (!host) {
      throw new Error("Kubernetes API server is not configured");
    }
    const port =
      process.env.KUBERNETES_SERVICE_PORT_HTTPS ||
      process.env.KUBERNETES_SERVICE_PORT ||
      "443";
    const normalizedHost = host.includes(":") && !host.startsWith("[") ? `[${host}]` : host;
    return `https://${normalizedHost}:${port}`;
  }

  async readToken() {
    /*
     * Projected Kubernetes service-account tokens rotate while the runtime pod is
     * alive. Do not cache this value, otherwise worker launches start failing with
     * 401 Unauthorized after the old token expires.
     */
    const token = (await fs.readFile(this.config.kubernetesServiceAccountTokenPath, "utf8")).trim();
    if (!token) {
      throw new Error("Kubernetes serviceaccount token is empty");
    }
    return token;
  }

  async readCa() {
    if (this.ca !== null) {
      return this.ca;
    }
    if (!this.config.kubernetesServiceAccountCaPath) {
      this.ca = "";
      return this.ca;
    }
    this.ca = await fs.readFile(this.config.kubernetesServiceAccountCaPath, "utf8");
    return this.ca;
  }

  async request(pathname, options = {}) {
    const headers = {
      Accept: "application/json",
      Authorization: `Bearer ${await this.readToken()}`,
      ...(options.headers || {}),
    };
    let body;
    if (options.body !== undefined) {
      headers["Content-Type"] = "application/json";
      body = JSON.stringify(options.body);
    }

    const url = new URL(pathname, `${this.buildBaseUrl()}/`);
    for (const [key, value] of Object.entries(options.query || {})) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }

    const response = await this.fetchImpl(url.toString(), {
      method: options.method || "GET",
      headers,
      body,
      ca: await this.readCa(),
      signal: options.signal,
    });
    const text = await response.text();
    let payload = {};
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = { message: text };
      }
    }

    const okStatuses = options.okStatuses || [];
    if (!response.ok && !okStatuses.includes(response.status)) {
      const statusMessage =
        payload.message ||
        payload.reason ||
        response.statusText ||
        `Kubernetes request failed: ${response.status}`;
      const error = new Error(statusMessage);
      error.status = response.status;
      error.payload = payload;
      throw error;
    }
    return payload;
  }
}

export class KubernetesWorkerRuntime {
  constructor(config) {
    this.config = config;
    this.client = config.kubernetesClient || new KubernetesApiClient(config);
  }

  get namespace() {
    return this.config.kubernetesWorkerNamespace;
  }

  async launch(session) {
    const job = buildKubernetesWorkerJob(session, this.config);
    const namespace = job.metadata.namespace || this.namespace;
    const response = await this.client.request(
      `/apis/batch/v1/namespaces/${encodeURIComponent(namespace)}/jobs`,
      {
        method: "POST",
        body: job,
      },
    );
    const jobName = response?.metadata?.name || job.metadata.name;
    return {
      launchMode: "kubernetes",
      workerId: jobName,
      jobName,
      namespace,
      runtimeKind: "kubernetes-job",
    };
  }

  async stop(worker) {
    const jobName = worker?.jobName || worker?.workerId;
    const namespace = worker?.namespace || this.namespace;
    if (!jobName || !namespace) {
      return;
    }
    try {
      await this.client.request(
        `/apis/batch/v1/namespaces/${encodeURIComponent(namespace)}/jobs/${encodeURIComponent(jobName)}`,
        {
          method: "DELETE",
          query: {
            propagationPolicy: "Background",
          },
          body: {
            apiVersion: "meta.k8s.io/v1",
            kind: "DeleteOptions",
            propagationPolicy: "Background",
          },
          okStatuses: [404],
        },
      );
    } catch (error) {
      if (error.status !== 404) {
        throw error;
      }
    }
  }

  async listSessionWorkers() {
    const namespace = this.namespace;
    const response = await this.client.request(
      `/apis/batch/v1/namespaces/${encodeURIComponent(namespace)}/jobs`,
      {
        query: {
          labelSelector:
            "app.kubernetes.io/component=rbi-session-worker,cloudsec.cisco.com/worker-mode=session",
        },
      },
    );
    return (response.items || []).map((job) => {
      const metadata = job.metadata || {};
      const labels = metadata.labels || {};
      const createdAt = metadata.creationTimestamp || "";
      const createdAtMs = createdAt ? Date.parse(createdAt) : 0;
      const status = job.status || {};
      return {
        jobName: metadata.name || "",
        namespace: metadata.namespace || namespace,
        sessionId: labels["cloudsec.cisco.com/session-id"] || "",
        labels,
        createdAt,
        createdAtMs: Number.isFinite(createdAtMs) ? createdAtMs : 0,
        active: Number(status.active || 0),
        succeeded: Number(status.succeeded || 0),
        failed: Number(status.failed || 0),
      };
    });
  }

  async ensureReady() {
    await this.client.request("/version");
  }
}

class HostAgentWorkerRuntime {
  constructor(config) {
    this.config = config;
    this.discoveryIndex = 0;
    this.discoveryMetadata = new Map();
  }

  get discoveryUrls() {
    const urls = this.config.hostAgentDiscoveryUrls || [];
    if (!urls.length) {
      throw new Error("HOST_AGENT_DISCOVERY_URLS is not configured");
    }
    return urls;
  }

  buildHeaders() {
    return {
      "Content-Type": "application/json",
      "x-rbi-host-agent-secret": this.config.hostAgentSecret,
    };
  }

  async fetchJson(url, options = {}) {
    const response = await fetch(url, options);
    const text = await response.text();
    let payload = {};
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = { error: text };
      }
    }
    if (!response.ok) {
      throw new Error(payload.error || `Host agent request failed: ${response.status}`);
    }
    return payload;
  }

  nextDiscoveryUrl() {
    const urls = this.discoveryUrls;
    const url = urls[this.discoveryIndex % urls.length];
    this.discoveryIndex += 1;
    return url.replace(/\/+$/, "");
  }

  async loadDiscoveryTargets() {
    const urls = this.discoveryUrls.map((url) => url.replace(/\/+$/, ""));
    const results = await Promise.allSettled(
      urls.map(async (baseUrl) => {
        const payload = await this.fetchJson(`${baseUrl}/api/ready`, {
          headers: this.buildHeaders(),
        });
        return {
          baseUrl,
          region: payload.region || null,
          availabilityZone: payload.availabilityZone || null,
          hostPrivateIp: payload.hostPrivateIp || null,
        };
      }),
    );

    const targets = [];
    for (const [index, result] of results.entries()) {
      const baseUrl = urls[index];
      if (result.status === "fulfilled") {
        this.discoveryMetadata.set(baseUrl, result.value);
        targets.push(result.value);
        continue;
      }

      const cached = this.discoveryMetadata.get(baseUrl);
      if (cached) {
        targets.push(cached);
      }
    }

    if (!targets.length) {
      const firstFailure = results.find((result) => result.status === "rejected");
      if (firstFailure?.reason) {
        throw firstFailure.reason;
      }
      throw new Error("No host-agent discovery endpoints are ready");
    }

    return targets;
  }

  buildLaunchPayload(session) {
    const turn = buildTurnCredentials(session, this.config);
    const signalingUrl = buildWorkerSignalingUrl(session, this.config);
    const mediaRelay = buildWorkerMediaRelayConfig(session);
    return {
      sessionId: session.id,
      targetUrl: session.targetUrl,
      signalingUrl,
      signalingConnectHost: buildWorkerSignalingConnectHost(session, this.config, signalingUrl),
      mediaRelayUrl: mediaRelay.mediaRelayUrl,
      mediaGatewayUrl: mediaRelay.mediaGatewayUrl,
      mediaRelayMode: mediaRelay.relayMode,
      mediaPlaneMode: mediaRelay.mediaPlaneMode,
      mediaRelayProtocol: mediaRelay.protocol,
      mediaRelayGatewayTerminatesMedia: mediaRelay.gatewayTerminatesMedia,
      workerToken: session.workerToken,
      displayWidth: session.viewport.width || this.config.displayWidth,
      displayHeight: session.viewport.height || this.config.displayHeight,
      turnUsername: turn.username,
      turnPassword: turn.password,
      workerIceUrls: this.config.workerIceUrls,
      allowedCandidateTypes: this.config.allowedIceCandidateTypes,
      experiments: session.experiments || {},
    };
  }

  async launch(session) {
    const preferredRegions = getPreferredHostAgentRegions(session, this.config);
    const targets = orderHostAgentTargets(
      await this.loadDiscoveryTargets(),
      preferredRegions,
      this.discoveryIndex,
    );
    this.discoveryIndex += 1;

    let lastError = null;
    for (const target of targets) {
      try {
        const payload = await this.fetchJson(`${target.baseUrl}/api/workers/session`, {
          method: "POST",
          headers: this.buildHeaders(),
          body: JSON.stringify(this.buildLaunchPayload(session)),
        });

        return {
          launchMode: "host-agent",
          workerId: payload.workerId,
          containerId: payload.containerId || null,
          containerName: payload.containerName,
          agentBaseUrl: payload.agentBaseUrl,
          hostPrivateIp: payload.hostPrivateIp || null,
          region: payload.region || target.region || null,
          availabilityZone: payload.availabilityZone || target.availabilityZone || null,
          runtimeKind: payload.runtimeKind || null,
        };
      } catch (error) {
        lastError = error;
      }
    }

    throw lastError || new Error("Unable to launch worker from any host agent");
  }

  async stop(worker) {
    if (!worker?.containerName) {
      return;
    }
    const baseUrl = String(worker.agentBaseUrl || this.nextDiscoveryUrl()).replace(/\/+$/, "");
    try {
      await this.fetchJson(
        `${baseUrl}/api/workers/${encodeURIComponent(worker.containerName)}`,
        {
          method: "DELETE",
          headers: this.buildHeaders(),
        },
      );
    } catch (error) {
      const message = String(error.message || "");
      if (!message.includes("Worker not found")) {
        throw error;
      }
    }
  }

  async ensureReady() {
    await this.loadDiscoveryTargets();
  }
}

export class WorkerRuntime {
  constructor(config) {
    this.impl =
      config.workerLaunchMode === "ecs"
        ? new EcsWorkerRuntime(config)
        : config.workerLaunchMode === "host-agent"
          ? new HostAgentWorkerRuntime(config)
          : config.workerLaunchMode === "kubernetes"
            ? new KubernetesWorkerRuntime(config)
            : new DockerWorkerRuntime(config);
  }

  async launch(session) {
    return this.impl.launch(session);
  }

  async stop(worker) {
    return this.impl.stop(worker);
  }

  async ensureReady() {
    return this.impl.ensureReady();
  }

  async listSessionWorkers() {
    if (typeof this.impl.listSessionWorkers !== "function") {
      return [];
    }
    return this.impl.listSessionWorkers();
  }
}
