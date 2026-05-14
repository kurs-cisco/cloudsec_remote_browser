import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { buildSwgHeaders } from "../shared/swg-handoff.js";

async function findFreePort() {
  const server = net.createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  return port;
}

async function readRequestBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function startFakeHostAgent({ launchDelayMs = 0 } = {}) {
  const port = await findFreePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const launches = [];
  const server = http.createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/api/ready") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        region: "us-west-2",
        availabilityZone: "us-west-2a",
        hostPrivateIp: "10.0.0.10",
      }));
      return;
    }

    if (req.method === "POST" && req.url === "/api/workers/session") {
      launches.push(await readRequestBody(req));
      if (launchDelayMs > 0) {
        await sleep(launchDelayMs);
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        workerId: `worker-${launches.length}`,
        containerId: `container-${launches.length}`,
        containerName: `container-${launches.length}`,
        agentBaseUrl: baseUrl,
        region: "us-west-2",
        availabilityZone: "us-west-2a",
        runtimeKind: "host-agent",
      }));
      return;
    }

    if (req.method === "DELETE" && req.url?.startsWith("/api/workers/")) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  });
  server.listen(port, "127.0.0.1");
  await once(server, "listening");
  return {
    baseUrl,
    launches,
    async close() {
      await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    },
  };
}

async function waitForRedis(port, deadlineMs = 4000) {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    try {
      await new Promise((resolve, reject) => {
        const socket = net.connect(port, "127.0.0.1");
        socket.setTimeout(250);
        socket.once("connect", () => {
          socket.end();
          resolve();
        });
        socket.once("timeout", () => {
          socket.destroy();
          reject(new Error("timeout"));
        });
        socket.once("error", reject);
      });
      return;
    } catch {
      await sleep(50);
    }
  }
  throw new Error("redis-server did not become ready");
}

async function startRedis() {
  const port = await findFreePort();
  const dir = await mkdtemp(join(tmpdir(), "cloudsec-rbi-swg-redis-"));
  const child = spawn("redis-server", [
    "--bind",
    "127.0.0.1",
    "--port",
    String(port),
    "--save",
    "",
    "--appendonly",
    "no",
    "--dir",
    dir,
  ], {
    stdio: "ignore",
  });
  await waitForRedis(port);
  return {
    url: `redis://127.0.0.1:${port}/0`,
    async close() {
      child.kill("SIGTERM");
      await Promise.race([
        once(child, "exit"),
        sleep(1000),
      ]);
      await rm(dir, { recursive: true, force: true });
    },
  };
}

async function waitForServer(baseUrl, child, deadlineMs = 5000) {
  const deadline = Date.now() + deadlineMs;
  let lastError = null;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`server exited early with code ${child.exitCode}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) {
        return;
      }
      lastError = new Error(`health returned ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw lastError || new Error("server did not become ready");
}

async function waitForCondition(predicate, message, deadlineMs = 5000) {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    if (predicate()) {
      return;
    }
    await sleep(25);
  }
  throw new Error(message);
}

async function stopChild(child) {
  if (child.exitCode !== null) {
    return;
  }
  child.kill("SIGTERM");
  await Promise.race([
    once(child, "exit"),
    new Promise((resolve) => setTimeout(resolve, 1000)),
  ]);
  if (child.exitCode === null) {
    child.kill("SIGKILL");
    await Promise.race([
      once(child, "exit"),
      new Promise((resolve) => setTimeout(resolve, 1000)),
    ]);
  }
}

function buildBootstrapHeaders({ targetUrl, transactionId, secret }) {
  return buildSwgHeaders(
    {
      method: "POST",
      contractVersion: "v2",
      requestKind: "http-document",
      originalMethod: "GET",
      targetUrl,
      timestamp: String(Date.now()),
      transactionId,
      orgId: "tenant-a",
      boundaryType: "org",
      boundaryId: "tenant-a",
      originId: "origin-a",
      originType: "64",
      tenantId: "tenant-a",
      profileId: "profile-a",
      policy: "policy-a",
      provider: "in_house",
      providerCategory: "cat-b",
      fallbackProvider: "menlo",
      fallbackReason: "",
      nonce: `nonce-${transactionId}`,
      keyId: "key-a",
    },
    secret,
  );
}

async function postSwgBootstrapSession(publicBaseUrl, body, headers) {
  const response = await fetch(`${publicBaseUrl}/api/swg/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let payload = {};
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = { raw: text };
    }
  }
  return { status: response.status, payload };
}

test("SWG bootstrap is idempotent and viewer events use viewer cookie", async (t) => {
  const hostAgent = await startFakeHostAgent();
  const port = await findFreePort();
  const publicBaseUrl = `http://127.0.0.1:${port}`;
  const swgSecret = "test-swg-secret";
  const env = {
    ...process.env,
    PORT: String(port),
    HOST: "127.0.0.1",
    PUBLIC_BASE_URL: publicBaseUrl,
    TOKEN_SECRET: "test-token-secret",
    TURN_SHARED_SECRET: "test-turn-secret",
    SWG_SHARED_SECRET: swgSecret,
    ENABLE_SWG_BOOTSTRAP: "1",
    WORKER_LAUNCH_MODE: "host-agent",
    HOST_AGENT_SECRET: "agent-secret",
    HOST_AGENT_DISCOVERY_URLS: hostAgent.baseUrl,
    VIEWER_REFRESH_MIN_SESSION_AGE_MS: "0",
    WARM_POOL_ENABLED: "0",
  };
  const child = spawn(process.execPath, ["app/server.js"], {
    cwd: new URL("..", import.meta.url),
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const logs = [];
  child.stdout.on("data", (chunk) => logs.push(String(chunk)));
  child.stderr.on("data", (chunk) => logs.push(String(chunk)));
  t.after(async () => {
    await stopChild(child);
    await hostAgent.close();
  });

  await waitForServer(publicBaseUrl, child);

  const targetUrl = "https://example.com/";
  const legacyHeaders = {
    ...buildSwgHeaders(
      {
        method: "POST",
        targetUrl,
        timestamp: String(Date.now()),
        transactionId: "tx-missing-provider-envelope",
        orgId: "tenant-a",
        boundaryType: "org",
        boundaryId: "tenant-a",
        originId: "origin-a",
        originType: "64",
        tenantId: "tenant-a",
        profileId: "profile-a",
        policy: "policy-a",
        nonce: "nonce-missing-provider-envelope",
        keyId: "key-a",
      },
      swgSecret,
    ),
    "Content-Type": "application/json",
  };
  const legacyResponse = await fetch(`${publicBaseUrl}/api/swg/sessions`, {
    method: "POST",
    headers: legacyHeaders,
    body: JSON.stringify({
      targetUrl,
      viewport: { width: 1280, height: 720, deviceScaleFactor: 1 },
      client: { browser: "cloudsec-swg" },
    }),
  });
  assert.equal(legacyResponse.status, 400, logs.join(""));
  assert.match((await legacyResponse.json()).error, /Missing SWG fields: contractVersion/);

  const tenantMismatchHeaders = {
    ...buildSwgHeaders(
      {
        method: "POST",
        contractVersion: "v2",
        requestKind: "http-document",
        originalMethod: "GET",
        targetUrl,
        timestamp: String(Date.now()),
        transactionId: "tx-tenant-boundary-mismatch",
        orgId: "tenant-a",
        boundaryType: "org",
        boundaryId: "tenant-a",
        originId: "origin-a",
        originType: "64",
        tenantId: "tenant-b",
        profileId: "profile-a",
        policy: "policy-a",
        provider: "in_house",
        providerCategory: "cat-b",
        fallbackProvider: "menlo",
        fallbackReason: "",
        nonce: "nonce-tenant-boundary-mismatch",
        keyId: "key-a",
      },
      swgSecret,
    ),
    "Content-Type": "application/json",
  };
  const tenantMismatchResponse = await fetch(`${publicBaseUrl}/api/swg/sessions`, {
    method: "POST",
    headers: tenantMismatchHeaders,
    body: JSON.stringify({
      targetUrl,
      viewport: { width: 1280, height: 720, deviceScaleFactor: 1 },
      client: { browser: "cloudsec-swg" },
    }),
  });
  assert.equal(tenantMismatchResponse.status, 422, logs.join(""));
  assert.match((await tenantMismatchResponse.json()).error, /tenant boundary mismatch/);

  const transactionId = "tx-idem-1";
  const body = {
    targetUrl,
    viewport: { width: 1280, height: 720, deviceScaleFactor: 1 },
    client: { browser: "cloudsec-swg" },
  };
  const headers = {
    ...buildBootstrapHeaders({ targetUrl, transactionId, secret: swgSecret }),
    "Content-Type": "application/json",
  };

  const firstResponse = await fetch(`${publicBaseUrl}/api/swg/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const first = await firstResponse.json();
  assert.equal(firstResponse.status, 201, logs.join(""));
  assert.ok(first.sessionId);
  assert.equal(first.viewerEntryMode, "swg-handoff");

  const secondResponse = await fetch(`${publicBaseUrl}/api/swg/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const second = await secondResponse.json();
  assert.equal(secondResponse.status, 200, logs.join(""));
  assert.equal(second.idempotentReplay, true);
  assert.equal(second.sessionId, first.sessionId);
  assert.equal(hostAgent.launches.length, 1);
  assert.equal(hostAgent.launches[0].sessionId, first.sessionId);

  const cookie = `${first.viewerCookie.name}=${encodeURIComponent(first.viewerCookie.value)}`;
  const eventResponse = await fetch(`${publicBaseUrl}/api/sessions/${first.sessionId}/viewer-events`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Origin: publicBaseUrl,
      Cookie: cookie,
	    },
	    body: JSON.stringify({
	      type: "viewer-telemetry",
	      viewport: { width: 1280, height: 720 },
	      session: { url: `${targetUrl}?token=secret`, token: "secret-token" },
	      events: [
	        {
	          name: "viewer.milestone",
	          viewerElapsedMs: 100,
	          fields: { milestone: "page.loaded" },
	        },
	        {
	          name: "viewer.milestone",
	          viewerElapsedMs: 1250,
	          fields: { milestone: "video.first_rendered" },
	        },
	        {
	          name: "viewer.input_slo",
	          fields: {
	            byClass: {
	              pointer_button: {
	                ackMs: { p95: 180 },
	              },
	            },
	            clickToApplyMs: { p95: 90 },
	            controlBacklog: { bufferedAmount: 0 },
	            violations: [],
	          },
	        },
	      ],
	    }),
	  });
	  assert.equal(eventResponse.status, 202, logs.join(""));
	  assert.deepEqual(await eventResponse.json(), { ok: true, sessionId: first.sessionId });
	  assert.match(logs.join(""), /viewer-telemetry-summary/);
	  assert.match(logs.join(""), /"ttfvMs":1250/);
	  assert.doesNotMatch(logs.join(""), /secret-token|token=secret/);

  const exportResponse = await fetch(`${publicBaseUrl}/api/sessions/${first.sessionId}/viewer-events?limit=5`, {
    headers: {
      Cookie: cookie,
    },
  });
  const exported = await exportResponse.json();
  assert.equal(exportResponse.status, 200, logs.join(""));
  assert.equal(exported.sessionId, first.sessionId);
  assert.equal(exported.count, 1);
  assert.equal(exported.events[0].payload.events[1].fields.milestone, "video.first_rendered");
  assert.equal(exported.events[0].payload.summary.firstRenderedFrameMs, 1250);
  assert.doesNotMatch(JSON.stringify(exported), /secret-token|token=secret/);

  const refreshResponse = await fetch(`${publicBaseUrl}/api/sessions/${first.sessionId}/refresh`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Origin: publicBaseUrl,
      Cookie: cookie,
    },
    body: JSON.stringify({ viewport: { width: 1366, height: 768 } }),
  });
  assert.equal(refreshResponse.status, 409, logs.join(""));
  assert.equal(hostAgent.launches.length, 1);
});

test("concurrent SWG bootstrap storm creates one runtime session and rejects conflicts", async (t) => {
  const hostAgent = await startFakeHostAgent({ launchDelayMs: 250 });
  const redis = await startRedis();
  const port = await findFreePort();
  const publicBaseUrl = `http://127.0.0.1:${port}`;
  const swgSecret = "test-swg-storm-secret";
  const env = {
    ...process.env,
    PORT: String(port),
    HOST: "127.0.0.1",
    PUBLIC_BASE_URL: publicBaseUrl,
    TOKEN_SECRET: "test-token-secret",
    TURN_SHARED_SECRET: "test-turn-secret",
    SWG_SHARED_SECRET: swgSecret,
    ENABLE_SWG_BOOTSTRAP: "1",
    WORKER_LAUNCH_MODE: "host-agent",
    HOST_AGENT_SECRET: "agent-secret",
    HOST_AGENT_DISCOVERY_URLS: hostAgent.baseUrl,
    WARM_POOL_ENABLED: "0",
    SESSION_STORE_BACKEND: "redis",
    SIGNAL_BUS_BACKEND: "redis",
    WORKER_POOL_STORE_BACKEND: "redis",
    WORKER_POOL_BUS_BACKEND: "redis",
    REDIS_URL: redis.url,
    REDIS_TLS: "0",
    REDIS_KEY_PREFIX: `cloudsec-rbi:test:${process.pid}:swg-storm`,
    SWG_BOOTSTRAP_IDEMPOTENCY_WAIT_MS: "3000",
  };
  const child = spawn(process.execPath, ["app/server.js"], {
    cwd: new URL("..", import.meta.url),
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const logs = [];
  child.stdout.on("data", (chunk) => logs.push(String(chunk)));
  child.stderr.on("data", (chunk) => logs.push(String(chunk)));
  t.after(async () => {
    await stopChild(child);
    await hostAgent.close();
    await redis.close();
  });

  await waitForServer(publicBaseUrl, child);

  const targetUrl = "https://example.com/";
  const transactionId = "tx-concurrent-storm";
  const body = {
    targetUrl,
    viewport: { width: 1280, height: 720, deviceScaleFactor: 1 },
    client: { browser: "cloudsec-swg" },
  };
  const headers = {
    ...buildBootstrapHeaders({ targetUrl, transactionId, secret: swgSecret }),
    "Content-Type": "application/json",
  };

  const firstRequest = postSwgBootstrapSession(publicBaseUrl, body, headers);
  await waitForCondition(
    () => hostAgent.launches.length === 1,
    `first bootstrap did not reach host agent: ${logs.join("")}`,
  );

  const duplicateRequests = Array.from({ length: 10 }, () =>
    postSwgBootstrapSession(publicBaseUrl, body, headers),
  );
  const conflictTargetUrl = "https://conflict.example/";
  const conflictBody = {
    ...body,
    targetUrl: conflictTargetUrl,
  };
  const conflictHeaders = {
    ...buildBootstrapHeaders({ targetUrl: conflictTargetUrl, transactionId, secret: swgSecret }),
    "Content-Type": "application/json",
  };
  const conflictRequests = Array.from({ length: 4 }, () =>
    postSwgBootstrapSession(publicBaseUrl, conflictBody, conflictHeaders),
  );

  const [first, ...stormResults] = await Promise.all([
    firstRequest,
    ...duplicateRequests,
    ...conflictRequests,
  ]);
  const duplicateResults = stormResults.slice(0, duplicateRequests.length);
  const conflictResults = stormResults.slice(duplicateRequests.length);

  assert.equal(first.status, 201, logs.join(""));
  assert.ok(first.payload.sessionId, logs.join(""));
  assert.equal(first.payload.viewerEntryMode, "swg-handoff");

  for (const replay of duplicateResults) {
    assert.equal(replay.status, 200, logs.join(""));
    assert.equal(replay.payload.idempotentReplay, true);
    assert.equal(replay.payload.sessionId, first.payload.sessionId);
    assert.equal(replay.payload.viewerEntryMode, "swg-handoff");
  }

  for (const conflict of conflictResults) {
    assert.equal(conflict.status, 409, logs.join(""));
    assert.match(conflict.payload.error, /reused with different bootstrap input/);
  }

  assert.equal(hostAgent.launches.length, 1, logs.join(""));
  assert.equal(hostAgent.launches[0].sessionId, first.payload.sessionId);
});

test("gateway media sessions launch workers only after gateway transport is patched", async (t) => {
  const hostAgent = await startFakeHostAgent();
  const port = await findFreePort();
  const publicBaseUrl = `http://127.0.0.1:${port}`;
  const internalSecret = "test-internal-secret";
  const env = {
    ...process.env,
    PORT: String(port),
    HOST: "127.0.0.1",
    PUBLIC_BASE_URL: publicBaseUrl,
    TOKEN_SECRET: "test-token-secret",
    TURN_SHARED_SECRET: "test-turn-secret",
    RBI_INTERNAL_SHARED_SECRET: internalSecret,
    ENABLE_SWG_BOOTSTRAP: "0",
    WORKER_LAUNCH_MODE: "host-agent",
    HOST_AGENT_SECRET: "agent-secret",
    HOST_AGENT_DISCOVERY_URLS: hostAgent.baseUrl,
    WARM_POOL_ENABLED: "0",
  };
  const child = spawn(process.execPath, ["app/server.js"], {
    cwd: new URL("..", import.meta.url),
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const logs = [];
  child.stdout.on("data", (chunk) => logs.push(String(chunk)));
  child.stderr.on("data", (chunk) => logs.push(String(chunk)));
  t.after(async () => {
    await stopChild(child);
    await hostAgent.close();
  });

  await waitForServer(publicBaseUrl, child);

  const sessionPlacement = {
    gatewayAssignment: {
      sessionId: "",
      gatewayId: "gateway-ap-south-1-01",
      region: "ap-south-1",
      relayMode: "gateway-media-relay",
      publicBaseUrl,
      publicWsUrl: publicBaseUrl.replace(/^http:/, "ws:"),
    },
    workerAssignment: {
      sessionId: "",
      workerId: "worker-ap-south-1-001",
      region: "ap-south-1",
      runtimeClass: "kata-clh",
    },
  };

  const createResponse = await fetch(`${publicBaseUrl}/api/internal/sessions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-RBI-Internal-Secret": internalSecret,
    },
    body: JSON.stringify({
      targetUrl: "https://example.com/",
      viewport: { width: 1280, height: 720, deviceScaleFactor: 1 },
      requestContext: { mode: "swg", tenantId: "tenant-a", profileId: "profile-a" },
      sessionPlacement,
    }),
  });
  const created = await createResponse.json();
  assert.equal(createResponse.status, 201, logs.join(""));
  assert.equal(created.state, "allocating");
  assert.equal(hostAgent.launches.length, 0, logs.join(""));

  const patchResponse = await fetch(`${publicBaseUrl}/api/internal/sessions/${created.sessionId}`, {
    method: "PATCH",
    headers: {
      "Content-Type": "application/json",
      "X-RBI-Internal-Secret": internalSecret,
    },
    body: JSON.stringify({
      sessionPlacement,
      transport: {
        preferred: "webrtc",
        supported: ["webrtc", "websocket"],
        viewerUrl: `${publicBaseUrl}/gateway/viewer/${created.sessionId}`,
        signalingUrl: `${publicBaseUrl.replace(/^http:/, "ws:")}/gateway/signaling/${created.sessionId}/viewer`,
        mediaGatewayUrl: `${publicBaseUrl}/gateway/webrtc/${created.sessionId}/viewer`,
        mediaPlaneMode: "gateway-webrtc-relay",
        protocol: "webrtc-srtp",
        mediaTermination: {
          relayMode: "gateway-media-relay",
          mediaPlaneMode: "gateway-webrtc-relay",
          protocol: "webrtc-srtp",
          gatewayTerminatesMedia: true,
        },
      },
      workerBridge: {
        bridgeId: `bridge-${created.sessionId}`,
        relayMode: "gateway-media-relay",
        mediaGatewayUrl: `${publicBaseUrl}/gateway/webrtc/${created.sessionId}/worker`,
        protocol: "webrtc-srtp",
      },
    }),
  });
  const patched = await patchResponse.json();
  assert.equal(patchResponse.status, 200, logs.join(""));
  assert.equal(patched.state, "allocating");
  assert.equal(hostAgent.launches.length, 1, logs.join(""));
  assert.equal(hostAgent.launches[0].sessionId, created.sessionId);
  assert.equal(hostAgent.launches[0].mediaPlaneMode, "gateway-webrtc-relay");
  assert.equal(hostAgent.launches[0].mediaRelayProtocol, "webrtc-srtp");
  assert.match(hostAgent.launches[0].mediaGatewayUrl, /\/gateway\/webrtc\/.+\/worker$/);
});
