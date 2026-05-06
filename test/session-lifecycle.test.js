import test from "node:test";
import assert from "node:assert/strict";

import { SessionStore } from "../app/session-store.js";
import { signToken, verifyToken } from "../app/token.js";

const TOKEN_SECRET = "test-secret-key";

function makeStore(overrides = {}) {
  return new SessionStore({
    sessionStoreBackend: "memory",
    sessionTtlMs: 30_000,
    idleTimeoutMs: 5_000,
    ...overrides,
  });
}

async function makeSession(store, overrides = {}) {
  const session = await store.createSession({
    targetUrl: "https://example.com",
    viewport: { width: 1280, height: 720, deviceScaleFactor: 1 },
    client: {},
    viewerToken: "",
    workerToken: "",
    ...overrides,
  });
  const viewerToken = signToken(
    { role: "viewer", sessionId: session.id, exp: session.expiresAt },
    TOKEN_SECRET,
  );
  const workerToken = signToken(
    { role: "worker", sessionId: session.id, exp: session.expiresAt },
    TOKEN_SECRET,
  );
  await store.update(session.id, { viewerToken, workerToken });
  return store.get(session.id);
}

test("session creation assigns correct initial state", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  assert.equal(session.state, "allocating");
  assert.ok(session.id.startsWith("sess_"));
  assert.equal(session.targetUrl, "https://example.com");
  assert.equal(session.targetOrigin, "https://example.com");
  assert.equal(session.viewerConnectedAt, null);
  assert.equal(session.viewerDisconnectedAt, null);
  assert.equal(session.viewerDisconnectReason, null);
  assert.equal(session.lastViewerAt, null);
  assert.ok(session.expiresAt > Date.now());
});

test("session state transitions: allocating → ready → streaming → terminated", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  await store.setState(session.id, "ready");
  assert.equal((await store.get(session.id)).state, "ready");

  await store.setState(session.id, "streaming");
  assert.equal((await store.get(session.id)).state, "streaming");

  await store.setState(session.id, "terminated");
  assert.equal((await store.get(session.id)).state, "terminated");
});

test("markViewerConnected sets viewerConnectedAt only once", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  await store.markViewerConnected(session.id);
  const first = (await store.get(session.id)).viewerConnectedAt;
  assert.ok(first !== null);

  await new Promise((r) => setTimeout(r, 10));
  await store.markViewerConnected(session.id);
  const second = (await store.get(session.id)).viewerConnectedAt;
  assert.equal(first, second);
});

test("markViewerSeen updates lastViewerAt", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  await store.markViewerSeen(session.id);
  const first = (await store.get(session.id)).lastViewerAt;
  assert.ok(first !== null);

  await new Promise((r) => setTimeout(r, 10));
  await store.markViewerSeen(session.id);
  const second = (await store.get(session.id)).lastViewerAt;
  assert.ok(second >= first);
});

test("markViewerDisconnected records durable idle reference and reconnect clears it", async () => {
  const store = makeStore({ idleTimeoutMs: 50 });
  await store.initialize();
  const session = await makeSession(store);

  await store.markViewerConnected(session.id);
  await store.markViewerDisconnected(session.id, "viewer unload");
  const disconnected = await store.get(session.id);
  assert.ok(disconnected.viewerDisconnectedAt !== null);
  assert.equal(disconnected.viewerDisconnectReason, "viewer unload");
  assert.equal(await store.shouldIdleTerminate(session.id), false);

  await new Promise((r) => setTimeout(r, 60));
  assert.equal(await store.shouldIdleTerminate(session.id), true);

  await store.markViewerConnected(session.id);
  const reconnected = await store.get(session.id);
  assert.equal(reconnected.viewerDisconnectedAt, null);
  assert.equal(reconnected.viewerDisconnectReason, null);
  assert.equal(await store.shouldIdleTerminate(session.id), false);
});

test("termination lock prevents double-terminate", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  const first = await store.acquireTerminationLock(session.id, 5_000);
  assert.equal(first, true);

  const second = await store.acquireTerminationLock(session.id, 5_000);
  assert.equal(second, false);
});

test("single-session guard serializes access until released", async () => {
  const store = makeStore();
  await store.initialize();

  const first = await store.acquireSingleSessionGuard(5_000);
  assert.ok(first);

  const second = await store.acquireSingleSessionGuard(5_000);
  assert.equal(second, null);

  assert.equal(await store.releaseSingleSessionGuard(first), true);

  const third = await store.acquireSingleSessionGuard(5_000);
  assert.ok(third);
  assert.notEqual(third, first);
});

test("session removal cleans up completely", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  await store.addPendingSignal(session.id, "viewer", { type: "test" });
  await store.addPendingSignal(session.id, "worker", { type: "test" });

  await store.remove(session.id);
  assert.equal(await store.get(session.id), null);

  const viewerSignals = await store.drainPendingSignals(session.id, "viewer");
  assert.equal(viewerSignals.length, 0);
});

test("pending signals are queued and drained correctly", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  await store.addPendingSignal(session.id, "viewer", { type: "sdp-offer", sdp: "v=0..." });
  await store.addPendingSignal(session.id, "viewer", { type: "ice-candidate", candidate: {} });
  await store.addPendingSignal(session.id, "worker", { type: "sdp-answer", sdp: "v=0..." });

  const viewerSignals = await store.drainPendingSignals(session.id, "viewer");
  assert.equal(viewerSignals.length, 2);
  assert.equal(viewerSignals[0].type, "sdp-offer");
  assert.equal(viewerSignals[1].type, "ice-candidate");

  const workerSignals = await store.drainPendingSignals(session.id, "worker");
  assert.equal(workerSignals.length, 1);

  const drained = await store.drainPendingSignals(session.id, "viewer");
  assert.equal(drained.length, 0);
});

test("viewer telemetry is retained per session with a bounded window", async () => {
  const store = makeStore({ viewerTelemetryMaxEvents: 2 });
  await store.initialize();
  const session = await makeSession(store);

  await store.appendViewerTelemetry(session.id, { reason: "one" });
  await store.appendViewerTelemetry(session.id, { reason: "two" });
  await store.appendViewerTelemetry(session.id, { reason: "three" });

  const events = await store.listViewerTelemetry(session.id);
  assert.equal(events.length, 2);
  assert.equal(events[0].payload.reason, "two");
  assert.equal(events[1].payload.reason, "three");
  assert.ok(events[0].receivedAt);

  await store.remove(session.id);
  assert.deepEqual(await store.listViewerTelemetry(session.id), []);
});

test("listExpired returns only sessions past their expiry", async () => {
  const store = makeStore({ sessionTtlMs: 50 });
  await store.initialize();

  const session = await makeSession(store);
  const fresh = await makeSession(store);

  await store.update(session.id, { expiresAt: Date.now() - 1 });

  const expired = await store.listExpired(Date.now());
  const expiredIds = expired.map((s) => s.id);
  assert.ok(expiredIds.includes(session.id));
  assert.ok(!expiredIds.includes(fresh.id));
});

test("shouldIdleTerminate returns true after idle timeout", async () => {
  const store = makeStore({ idleTimeoutMs: 50 });
  await store.initialize();
  const session = await makeSession(store);

  assert.equal(await store.shouldIdleTerminate(session.id), false);

  await store.markViewerSeen(session.id);
  assert.equal(await store.shouldIdleTerminate(session.id), false);

  await new Promise((r) => setTimeout(r, 60));
  assert.equal(await store.shouldIdleTerminate(session.id), true);
});

test("viewer token validates for correct session and role", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  const payload = verifyToken(session.viewerToken, TOKEN_SECRET);
  assert.equal(payload.role, "viewer");
  assert.equal(payload.sessionId, session.id);
});

test("worker token validates for correct session and role", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  const payload = verifyToken(session.workerToken, TOKEN_SECRET);
  assert.equal(payload.role, "worker");
  assert.equal(payload.sessionId, session.id);
});

test("token with wrong secret is rejected", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  assert.throws(() => verifyToken(session.viewerToken, "wrong-secret"));
});

test("expired token is rejected", () => {
  const token = signToken(
    { role: "viewer", sessionId: "sess_test", exp: Date.now() - 1000 },
    TOKEN_SECRET,
  );
  assert.throws(() => verifyToken(token, TOKEN_SECRET), /expired/i);
});

test("snapshot produces serializable output", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);
  await store.setState(session.id, "streaming");
  await store.markViewerConnected(session.id);
  await store.setWorker(session.id, { containerName: "worker-123" });

  const snap = store.snapshot(await store.get(session.id));
  assert.equal(snap.sessionId, session.id);
  assert.equal(snap.state, "streaming");
  assert.equal(snap.sessionMode, "standard");
  assert.equal(snap.viewerEntryMode, "direct-viewer");
  assert.equal(snap.workerId, "worker-123");
  assert.equal(snap.workerLaunchMode, null);
  assert.equal(snap.workerRuntimeKind, null);
  assert.equal(snap.workerRegion, null);
  assert.equal(snap.workerAvailabilityZone, null);
  assert.ok(snap.createdAt);
  assert.ok(snap.viewerConnectedAt);
  assert.equal(snap.viewerDisconnectedAt, null);
  assert.equal(snap.viewerDisconnectReason, null);

  const serialized = JSON.parse(JSON.stringify(snap));
  assert.deepEqual(serialized, snap);
});

test("snapshot marks SWG sessions and exposes SWG context", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store, {
    client: {
      authMode: "swg",
      swg: {
        transactionId: "txn-123",
        tenantId: "tenant-a",
        profileId: "profile-a",
        policy: "isolate-web",
        upstreamHost: "example.com",
        upstreamScheme: "https",
        upstreamPort: "443",
      },
    },
  });

  const snap = store.snapshot(await store.get(session.id));
  assert.equal(snap.sessionMode, "swg");
  assert.equal(snap.viewerEntryMode, "swg-handoff");
	  assert.deepEqual(snap.swgContext, {
	    transactionId: "txn-123",
	    tenantId: "tenant-a",
	    profileId: "profile-a",
	    policy: "isolate-web",
    upstreamHost: "example.com",
	    upstreamScheme: "https",
	    upstreamPort: "443",
	  });
	  assert.equal(snap.viewerPolicySummary.targetHost, "example.com");
	  assert.equal(snap.viewerPolicySummary.policyReason, "isolate-web");
	  assert.equal(snap.viewerPolicySummary.isolationMode, "SWG isolated browser");
	  assert.match(snap.viewerPolicySummary.tenantLabel, /^Tenant t-[a-f0-9]{8}$/);
	  assert.match(snap.viewerPolicySummary.profileLabel, /^Profile p-[a-f0-9]{8}$/);
	  assert.notEqual(snap.viewerPolicySummary.tenantLabel, "tenant-a");
	  assert.notEqual(snap.viewerPolicySummary.profileLabel, "profile-a");
	});

test("snapshot exposes gateway and worker placement assignments", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store, {
    sessionPlacement: {
      gatewayAssignment: {
        gatewayId: "gw-use1a-01",
        region: "us-east-1",
        relayMode: "webrtc-relay",
        signalingUrl: "wss://gateway.example/ws",
      },
      workerAssignment: {
        workerId: "worker-catb-01",
        runtimeClass: "kata-clh",
        nodePool: "cloudsec-rbi-workers",
        availabilityZone: "us-east-1a",
      },
    },
  });

  const snap = store.snapshot(await store.get(session.id));
  assert.deepEqual(snap.gatewayAssignment, {
    gatewayId: "gw-use1a-01",
    region: "us-east-1",
    relayMode: "webrtc-relay",
    signalingUrl: "wss://gateway.example/ws",
  });
  assert.deepEqual(snap.workerAssignment, {
    workerId: "worker-catb-01",
    runtimeClass: "kata-clh",
    nodePool: "cloudsec-rbi-workers",
    availabilityZone: "us-east-1a",
  });
});

test("snapshot exposes gateway transport and worker bridge metadata", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store, {
    transport: {
      preferred: "webrtc",
      supported: ["webrtc", "websocket"],
      viewerUrl: "https://gateway.example.com/gateway/viewer/sess_123?transport=webrtc",
      signalingUrl: "wss://gateway.example.com/gateway/signaling/sess_123/viewer?transport=webrtc",
    },
    workerBridge: {
      bridgeId: "bridge-sess_123",
      relayMode: "gateway-relay",
    },
  });

  const snap = store.snapshot(await store.get(session.id));
  assert.deepEqual(snap.transport, {
    preferred: "webrtc",
    supported: ["webrtc", "websocket"],
    viewerUrl: "https://gateway.example.com/gateway/viewer/sess_123?transport=webrtc",
    signalingUrl: "wss://gateway.example.com/gateway/signaling/sess_123/viewer?transport=webrtc",
  });
  assert.deepEqual(snap.workerBridge, {
    bridgeId: "bridge-sess_123",
    relayMode: "gateway-relay",
  });
});

test("snapshot exposes stub worker runtime metadata", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);
  await store.setWorker(session.id, {
    workerId: "stub-worker-123",
    launchMode: "host-agent",
    runtimeKind: "stub",
  });

  const snap = store.snapshot(await store.get(session.id));
  assert.equal(snap.workerId, "stub-worker-123");
  assert.equal(snap.workerLaunchMode, "host-agent");
  assert.equal(snap.workerRuntimeKind, "stub");
  assert.equal(snap.workerRegion, null);
  assert.equal(snap.workerAvailabilityZone, null);
});

test("snapshot exposes worker region metadata", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);
  await store.setWorker(session.id, {
    workerId: "rbi-worker-123",
    launchMode: "host-agent",
    runtimeKind: "docker",
    region: "us-west-2",
    availabilityZone: "us-west-2a",
  });

  const snap = store.snapshot(await store.get(session.id));
  assert.equal(snap.workerRegion, "us-west-2");
  assert.equal(snap.workerAvailabilityZone, "us-west-2a");
});

test("listSessions returns sessions sorted by creation time", async () => {
  const store = makeStore();
  await store.initialize();

  const s1 = await makeSession(store);
  await store.update(s1.id, { createdAt: 1000 });

  const s2 = await makeSession(store);
  await store.update(s2.id, { createdAt: 2000 });

  const s3 = await makeSession(store);
  await store.update(s3.id, { createdAt: 3000 });

  const sessions = await store.listSessions(10);
  assert.ok(sessions.length >= 3);
  assert.equal(sessions[0].id, s3.id);
  assert.equal(sessions[1].id, s2.id);
  assert.equal(sessions[2].id, s1.id);
});

test("generation starts at 1 and increments", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  assert.equal(session.generation, 1);

  await store.incrementGeneration(session.id);
  const updated = await store.get(session.id);
  assert.equal(updated.generation, 2);

  await store.incrementGeneration(session.id);
  const updated2 = await store.get(session.id);
  assert.equal(updated2.generation, 3);
});

test("incrementGeneration returns null for missing session", async () => {
  const store = makeStore();
  await store.initialize();

  const result = await store.incrementGeneration("sess_nonexistent");
  assert.equal(result, null);
});

test("terminatedAt is set when state transitions to terminated", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);

  assert.equal(session.terminatedAt, null);

  await store.setState(session.id, "ready");
  const ready = await store.get(session.id);
  assert.equal(ready.terminatedAt, null);

  await store.setState(session.id, "terminated");
  const terminated = await store.get(session.id);
  assert.ok(terminated.terminatedAt !== null);
  assert.ok(terminated.terminatedAt <= Date.now());
});

test("listTerminated returns only aged terminated sessions", async () => {
  const store = makeStore();
  await store.initialize();

  const s1 = await makeSession(store);
  const s2 = await makeSession(store);
  const s3 = await makeSession(store);

  await store.setState(s1.id, "terminated");
  await store.setState(s2.id, "terminated");

  const recentlyTerminated = await store.listTerminated(60_000);
  assert.equal(recentlyTerminated.length, 0);

  await store.update(s1.id, { terminatedAt: Date.now() - 120_000 });
  const aged = await store.listTerminated(60_000);
  assert.equal(aged.length, 1);
  assert.equal(aged[0].id, s1.id);
});

test("snapshot includes generation and terminatedAt", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);
  await store.incrementGeneration(session.id);
  await store.setState(session.id, "terminated");

  const snap = store.snapshot(await store.get(session.id));
  assert.equal(snap.generation, 2);
  assert.ok(snap.terminatedAt !== null);

  const serialized = JSON.parse(JSON.stringify(snap));
  assert.deepEqual(serialized, snap);
});

test("socket ownership only releases for the current connection", async () => {
  const store = makeStore();
  await store.initialize();
  const session = await makeSession(store);
  const ownerA = { instanceId: "instance-a", connectionId: "conn-a" };
  const ownerB = { instanceId: "instance-a", connectionId: "conn-b" };

  await store.claimSocketOwnership(session.id, "viewer", ownerA);
  assert.deepEqual(await store.getSocketOwner(session.id, "viewer"), ownerA);

  assert.equal(await store.releaseSocketOwnership(session.id, "viewer", ownerB), false);
  assert.deepEqual(await store.getSocketOwner(session.id, "viewer"), ownerA);

  await store.claimSocketOwnership(session.id, "viewer", ownerB);
  assert.deepEqual(await store.getSocketOwner(session.id, "viewer"), ownerB);

  assert.equal(await store.releaseSocketOwnership(session.id, "viewer", ownerA), false);
  assert.deepEqual(await store.getSocketOwner(session.id, "viewer"), ownerB);

  assert.equal(await store.releaseSocketOwnership(session.id, "viewer", ownerB), true);
  assert.equal(await store.getSocketOwner(session.id, "viewer"), null);
});
