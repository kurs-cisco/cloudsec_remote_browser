import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  WorkerRuntime,
  buildKubernetesWorkerJob,
  buildWorkerEnvironment,
  buildWorkerMediaRelayConfig,
  usesWorkerGatewayWebrtcRelay,
} from "../app/worker-runtime.js";

function makeConfig(overrides = {}) {
  return {
    workerImage: "123456789012.dkr.ecr.us-east-1.amazonaws.com/rbi-worker:prod",
    workerWsUrl: "wss://runtime.example.com/ws/worker",
    workerWsConnectHost: "",
    workerDisableChromiumSandbox: false,
    displayWidth: 1920,
    displayHeight: 1080,
    workerIceUrls: ["turn:turn.example.com:3478?transport=udp"],
    allowedIceCandidateTypes: ["relay"],
    initialStreamScale: 1,
    captureFramerate: 20,
    videoCaptureBackend: "x11grab",
    preferredVideoCodecs: ["VP8"],
    videoMinBitrateBps: 600000,
    videoStartBitrateBps: 1500000,
    videoMaxBitrateBps: 3000000,
    audioSyncDelayMs: 0,
    pulseCaptureLatencyMsec: 20,
    hybridDomSnapshotTimeoutSec: 8,
    chromiumUseDevShm: true,
    hybridDomBridgeEnabled: false,
    kubernetesWorkerNamespace: "cloudsec-rbi-workers",
    kubernetesWorkerContainerName: "worker",
    kubernetesWorkerServiceAccountName: "rbi-worker",
    kubernetesWorkerRuntimeClassName: "kata-clh",
    kubernetesWorkerImagePullPolicy: "IfNotPresent",
    kubernetesWorkerConfigMapName: "",
    kubernetesWorkerBackoffLimit: 0,
    kubernetesWorkerActiveDeadlineSeconds: 7200,
    kubernetesWorkerTtlSecondsAfterFinished: 3600,
    kubernetesWorkerTerminationGracePeriodSeconds: 30,
    kubernetesWorkerNodeSelector: {
      "cloudsec.cisco.com/rbi-worker-plane": "true",
      "cloudsec.cisco.com/node-pool": "rbi-workers",
    },
    kubernetesWorkerLabels: {},
    kubernetesWorkerAnnotations: {},
    kubernetesWorkerTolerations: [
      {
        key: "cloudsec.cisco.com/rbi-worker-plane",
        operator: "Equal",
        value: "true",
        effect: "NoSchedule",
      },
    ],
    kubernetesWorkerResources: {
      requests: {
        cpu: "1500m",
        memory: "3Gi",
      },
      limits: {
        cpu: "3000m",
        memory: "6Gi",
      },
    },
    kubernetesWorkerImagePullSecretNames: [],
    ...overrides,
  };
}

function makeSession(overrides = {}) {
  return {
    id: "sess_Test_123",
    targetUrl: "https://example.com/app",
    workerToken: "worker-token",
    viewport: {
      width: 1280,
      height: 720,
    },
    turnCredentials: {
      worker: {
        username: "turn-user",
        credential: "turn-pass",
      },
    },
    experiments: {
      sourceCoupledAv: true,
    },
    workerBridge: {
      relayMode: "gateway-media-relay",
      mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_Test_123/worker",
      mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_Test_123/worker",
      protocol: "webrtc-srtp",
    },
    transport: {
      mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_Test_123/viewer",
      mediaPlaneMode: "gateway-webrtc-relay",
      protocol: "webrtc-srtp",
      mediaTermination: {
        gatewayTerminatesMedia: true,
      },
    },
    ...overrides,
  };
}

function envMap(envList) {
  return Object.fromEntries(envList.map((entry) => [entry.name, entry.value]));
}

test("worker media relay config exposes gateway-media-relay assignment", () => {
  const config = buildWorkerMediaRelayConfig({
    sessionPlacement: {
      gatewayAssignment: {
        relayMode: "gateway-media-relay",
      },
    },
    transport: {
      mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_123/viewer",
      mediaTermination: {
        gatewayTerminatesMedia: true,
      },
    },
    workerBridge: {
      relayMode: "gateway-media-relay",
      mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_123/worker",
      mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_123/worker",
      protocol: "webrtc-srtp",
    },
  });

  assert.deepEqual(config, {
    mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_123/worker",
    mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_123/worker",
    relayMode: "gateway-media-relay",
    protocol: "webrtc-srtp",
    mediaPlaneMode: "",
    inputPointerName: "input-pointer",
    inputControlName: "input-control",
    gatewayTerminatesMedia: true,
  });
});

test("worker gateway webrtc relay detection requires gateway URL, mode, and protocol", () => {
  assert.equal(usesWorkerGatewayWebrtcRelay(makeSession()), true);
  assert.equal(
    usesWorkerGatewayWebrtcRelay(
      makeSession({
        workerBridge: {
          relayMode: "gateway-media-relay",
          mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_Test_123/worker",
          protocol: "websocket",
        },
        transport: {
          mediaPlaneMode: "gateway-webrtc-relay",
          protocol: "websocket",
          mediaTermination: { gatewayTerminatesMedia: true },
        },
      }),
    ),
    false,
  );
});

test("worker media relay config stays empty for default gateway signaling", () => {
  const config = buildWorkerMediaRelayConfig({
    sessionPlacement: {
      gatewayAssignment: {
        relayMode: "gateway-relay",
      },
    },
    transport: {
      mediaTermination: {
        gatewayTerminatesMedia: false,
      },
    },
    workerBridge: {
      relayMode: "gateway-relay",
    },
  });

  assert.deepEqual(config, {
    mediaRelayUrl: "",
    mediaGatewayUrl: "",
    relayMode: "gateway-relay",
    protocol: "",
    mediaPlaneMode: "",
    inputPointerName: "input-pointer",
    inputControlName: "input-control",
    gatewayTerminatesMedia: false,
  });
});

test("worker environment contains the runtime variables used by allocators", () => {
  const env = buildWorkerEnvironment(makeSession(), makeConfig());

  assert.equal(env.SESSION_ID, "sess_Test_123");
  assert.equal(env.TARGET_URL, "https://example.com/app");
  assert.equal(env.SIGNALING_URL, "wss://runtime.example.com/ws/worker");
  assert.equal(env.WORKER_TOKEN, "worker-token");
  assert.equal(env.DISPLAY_WIDTH, "1280");
  assert.equal(env.DISPLAY_HEIGHT, "720");
  assert.equal(env.DISABLE_CHROMIUM_SANDBOX, "0");
  assert.equal(env.TURN_USERNAME, "turn-user");
  assert.equal(env.TURN_PASSWORD, "turn-pass");
  assert.equal(env.WORKER_ICE_URLS, "turn:turn.example.com:3478?transport=udp");
  assert.equal(env.ALLOWED_CANDIDATE_TYPES, "relay");
  assert.equal(env.MEDIA_RELAY_MODE, "gateway-media-relay");
  assert.equal(env.MEDIA_GATEWAY_URL, "https://gateway.example.com/gateway/webrtc/sess_Test_123/worker");
  assert.equal(env.MEDIA_PLANE_MODE, "gateway-webrtc-relay");
  assert.equal(env.MEDIA_RELAY_PROTOCOL, "webrtc-srtp");
  assert.equal(env.MEDIA_RELAY_GATEWAY_TERMINATES_MEDIA, "1");
  assert.equal(env.INITIAL_STREAM_SCALE, "1");
  assert.equal(env.VIDEO_CODEC_PREFERENCES, "VP8");
  assert.equal(env.CAPTURE_FRAMERATE, "20");
  assert.equal(env.EXPERIMENTAL_SOURCE_COUPLED_AV, "1");
});

test("kubernetes worker job exposes per-session worker environment and hardening", () => {
  const job = buildKubernetesWorkerJob(
    makeSession(),
    makeConfig({
      kubernetesWorkerConfigMapName: "rbi-worker-shared-config",
      kubernetesWorkerLabels: {
        "cloudsec.cisco.com/test": "true",
      },
      kubernetesWorkerAnnotations: {
        "cloudsec.cisco.com/owner": "runtime",
      },
      kubernetesWorkerImagePullSecretNames: ["ecr-pull"],
    }),
  );

  assert.equal(job.apiVersion, "batch/v1");
  assert.equal(job.kind, "Job");
  assert.match(job.metadata.name, /^rbi-worker-sess-test-123-[a-f0-9]{10}$/);
  assert.equal(job.metadata.namespace, "cloudsec-rbi-workers");
  assert.equal(job.metadata.labels["cloudsec.cisco.com/worker-mode"], "session");
  assert.equal(job.metadata.labels["cloudsec.cisco.com/test"], "true");
  assert.equal(job.metadata.annotations["cloudsec.cisco.com/owner"], "runtime");

  const podSpec = job.spec.template.spec;
  assert.equal(podSpec.runtimeClassName, "kata-clh");
  assert.equal(podSpec.serviceAccountName, "rbi-worker");
  assert.equal(podSpec.automountServiceAccountToken, false);
  assert.equal(podSpec.restartPolicy, "Never");
  assert.equal(podSpec.securityContext.runAsNonRoot, true);
  assert.deepEqual(podSpec.imagePullSecrets, [{ name: "ecr-pull" }]);
  assert.equal(podSpec.nodeSelector["cloudsec.cisco.com/rbi-worker-plane"], "true");
  assert.deepEqual(podSpec.tolerations, [
    {
      key: "cloudsec.cisco.com/rbi-worker-plane",
      operator: "Equal",
      value: "true",
      effect: "NoSchedule",
    },
  ]);

  const container = podSpec.containers[0];
  const env = envMap(container.env);
  assert.equal(container.image, "123456789012.dkr.ecr.us-east-1.amazonaws.com/rbi-worker:prod");
  assert.deepEqual(container.envFrom, [{ configMapRef: { name: "rbi-worker-shared-config" } }]);
  assert.equal(container.securityContext.allowPrivilegeEscalation, false);
  assert.deepEqual(container.securityContext.capabilities.drop, ["ALL"]);
  assert.equal(container.securityContext.readOnlyRootFilesystem, true);
  assert.equal(env.WORKER_MODE, "session");
  assert.equal(env.SESSION_ID, "sess_Test_123");
  assert.equal(env.TARGET_URL, "https://example.com/app");
  assert.equal(env.WORKER_TOKEN, "worker-token");
  assert.equal(env.MEDIA_RELAY_URL, "wss://gateway.example.com/gateway/media/sess_Test_123/worker");
  assert.equal(env.MEDIA_GATEWAY_URL, "https://gateway.example.com/gateway/webrtc/sess_Test_123/worker");
  assert.equal(env.VIDEO_CODEC_PREFERENCES, "VP8");
});

test("worker runtime launches and deletes kubernetes jobs", async () => {
  const calls = [];
  const fakeClient = {
    async request(path, options = {}) {
      calls.push({ path, options });
      if (options.method === "POST") {
        return {
          metadata: {
            name: options.body.metadata.name,
          },
        };
      }
      return {};
    },
  };
  const runtime = new WorkerRuntime(
    makeConfig({
      workerLaunchMode: "kubernetes",
      kubernetesClient: fakeClient,
    }),
  );

  const worker = await runtime.launch(makeSession());
  assert.equal(worker.launchMode, "kubernetes");
  assert.match(worker.jobName, /^rbi-worker-sess-test-123-[a-f0-9]{10}$/);
  assert.equal(worker.workerId, worker.jobName);
  assert.equal(worker.namespace, "cloudsec-rbi-workers");
  assert.equal(worker.runtimeKind, "kubernetes-job");
  assert.equal(calls[0].path, "/apis/batch/v1/namespaces/cloudsec-rbi-workers/jobs");
  assert.equal(calls[0].options.method, "POST");
  assert.equal(calls[0].options.body.metadata.name, worker.jobName);

  await runtime.stop(worker);
  assert.equal(
    calls[1].path,
    `/apis/batch/v1/namespaces/cloudsec-rbi-workers/jobs/${worker.jobName}`,
  );
  assert.equal(calls[1].options.method, "DELETE");
  assert.equal(calls[1].options.query.propagationPolicy, "Background");
  assert.equal(calls[1].options.body.kind, "DeleteOptions");
});

test("worker runtime lists kubernetes session worker jobs for orphan cleanup", async () => {
  const calls = [];
  const runtime = new WorkerRuntime(
    makeConfig({
      workerLaunchMode: "kubernetes",
      kubernetesClient: {
        async request(path, options = {}) {
          calls.push({ path, options });
          return {
            items: [
              {
                metadata: {
                  name: "rbi-worker-sess-test-123-deadbeef00",
                  namespace: "cloudsec-rbi-workers",
                  creationTimestamp: "2026-05-06T09:00:00.000Z",
                  labels: {
                    "cloudsec.cisco.com/session-id": "sess_Test_123",
                    "cloudsec.cisco.com/worker-mode": "session",
                  },
                },
                status: {
                  active: 1,
                },
              },
            ],
          };
        },
      },
    }),
  );

  const workers = await runtime.listSessionWorkers();
  assert.equal(calls[0].path, "/apis/batch/v1/namespaces/cloudsec-rbi-workers/jobs");
  assert.equal(
    calls[0].options.query.labelSelector,
    "app.kubernetes.io/component=rbi-session-worker,cloudsec.cisco.com/worker-mode=session",
  );
  assert.equal(workers.length, 1);
  assert.equal(workers[0].jobName, "rbi-worker-sess-test-123-deadbeef00");
  assert.equal(workers[0].sessionId, "sess_Test_123");
  assert.equal(workers[0].namespace, "cloudsec-rbi-workers");
  assert.equal(workers[0].active, 1);
  assert.ok(workers[0].createdAtMs > 0);
});

test("kubernetes worker runtime rereads rotated service-account tokens", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "rbi-k8s-token-"));
  const tokenPath = join(tempDir, "token");
  const authHeaders = [];

  await writeFile(tokenPath, "token-one\n", "utf8");
  try {
    const runtime = new WorkerRuntime(
      makeConfig({
        workerLaunchMode: "kubernetes",
        kubernetesApiServer: "https://kubernetes.example.test",
        kubernetesServiceAccountTokenPath: tokenPath,
        kubernetesServiceAccountCaPath: "",
        kubernetesFetch: async (_url, options = {}) => {
          authHeaders.push(options.headers.Authorization);
          return {
            ok: true,
            status: 200,
            statusText: "OK",
            text: async () => JSON.stringify({ metadata: { name: "rbi-worker-session" } }),
          };
        },
      }),
    );

    const worker = await runtime.launch(makeSession());
    await writeFile(tokenPath, "token-two\n", "utf8");
    await runtime.stop(worker);

    assert.deepEqual(authHeaders, ["Bearer token-one", "Bearer token-two"]);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});
