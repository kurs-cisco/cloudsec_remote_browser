import test from "node:test";
import assert from "node:assert/strict";

import {
  CLOUDSEC_WORKER_POOL_KEY_PREFIX,
  WorkerPoolStore,
  buildWorkerPoolKeys,
} from "../app/worker-pool-store.js";

function makeStore(overrides = {}) {
  return new WorkerPoolStore({
    workerPoolStoreBackend: "memory",
    ...overrides,
  });
}

test("memory worker pool registers, allocates, idles, and unregisters workers", async () => {
  const store = makeStore();
  await store.initialize();

  const first = await store.registerWorker({
    workerId: "worker-a",
    taskArn: "task-a",
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-a" },
    metadata: { zone: "a", region: "us-west-2", runtimeClass: "kata-clh", displayClass: "1280x720" },
  });
  const second = await store.registerWorker({
    workerId: "worker-b",
    taskArn: "task-b",
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-b" },
    metadata: { region: "us-east-1", runtimeClass: "kata-clh", displayClass: "1280x720" },
  });

  assert.equal(first.state, "idle");
  assert.equal(second.state, "idle");

  const allocated = await store.allocateWorker("session-1", {
    region: "us-west-2",
    runtimeClass: "kata-clh",
    displayClass: "1280x720",
  });
  assert.equal(allocated.workerId, "worker-a");
  assert.equal(allocated.state, "assigned");
  assert.equal(allocated.sessionId, "session-1");

  assert.equal((await store.allocateWorker("session-2", { region: "us-east-1" })).workerId, "worker-b");
  assert.equal(await store.allocateWorker("session-3"), null);

  const idle = await store.markWorkerIdle("worker-a", { metadata: { zone: "b" } });
  assert.equal(idle.state, "idle");
  assert.equal(idle.sessionId, null);
  assert.deepEqual(idle.metadata, { zone: "b" });

  const busy = await store.markWorkerBusy("worker-a", { state: "draining", sessionId: "session-4" });
  assert.equal(busy.state, "draining");
  assert.equal(busy.sessionId, "session-4");

  assert.equal(await store.unregisterWorker("worker-a"), true);
  assert.equal(await store.getWorker("worker-a"), null);
});

test("memory worker pool atomically allocates and queues matching assignments", async () => {
  const store = makeStore();
  await store.initialize();

  await store.registerWorker({
    workerId: "worker-a",
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-a" },
    metadata: {
      region: "us-west-2",
      runtimeClass: "kata-clh",
      mediaMode: "gateway-webrtc-relay",
      imageDigest: "sha256:abc",
      displayClass: "1280x720",
    },
  });
  await store.registerWorker({
    workerId: "worker-b",
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-b" },
    metadata: {
      region: "us-east-1",
      runtimeClass: "kata-clh",
      mediaMode: "gateway-webrtc-relay",
      imageDigest: "sha256:abc",
      displayClass: "1280x720",
    },
  });

  const assignment = { type: "session-assignment", sessionId: "session-1" };
  const allocated = await store.allocateWorkerWithAssignment("session-1", assignment, {
    region: "us-west-2",
    runtimeClass: "kata-clh",
    mediaMode: "gateway-webrtc-relay",
    imageDigest: "sha256:abc",
    displayClass: "1280x720",
  });

  assert.equal(allocated.workerId, "worker-a");
  assert.deepEqual(await store.drainPendingAssignments("worker-a"), [assignment]);
  assert.deepEqual(await store.drainPendingAssignments("worker-b"), []);
});

test("memory worker pool skips expired leases", async () => {
  const store = makeStore({ workerPoolLeaseTtlMs: 10 });
  await store.initialize();

  await store.registerWorker({
    workerId: "worker-a",
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-a" },
    expiresAt: Date.now() - 1,
  });

  assert.equal(await store.allocateWorker("session-1"), null);
  assert.equal(await store.getWorker("worker-a"), null);
});

test("memory worker pool drains pending assignments once", async () => {
  const store = makeStore();
  await store.initialize();

  await store.addPendingAssignment("worker-a", { sessionId: "session-1" });
  await store.addPendingAssignment("worker-a", { sessionId: "session-2" });

  assert.deepEqual(await store.drainPendingAssignments("worker-a"), [
    { sessionId: "session-1" },
    { sessionId: "session-2" },
  ]);
  assert.deepEqual(await store.drainPendingAssignments("worker-a"), []);
});

test("pool worker socket ownership only releases for the current connection", async () => {
  const store = makeStore();
  await store.initialize();
  const ownerA = { instanceId: "instance-a", connectionId: "conn-a" };
  const ownerB = { instanceId: "instance-b", connectionId: "conn-b" };

  await store.registerWorker({
    workerId: "pool-worker-1",
    taskArn: "task-1",
    socketOwner: ownerA,
    metadata: { mode: "warm-pool" },
  });

  assert.deepEqual(await store.getSocketOwner("pool-worker-1"), ownerA);
  assert.equal(await store.releaseSocketOwnership("pool-worker-1", ownerB), false);
  assert.deepEqual(await store.getSocketOwner("pool-worker-1"), ownerA);

  await store.claimSocketOwnership("pool-worker-1", ownerB);
  assert.deepEqual(await store.getSocketOwner("pool-worker-1"), ownerB);

  assert.equal(await store.releaseSocketOwnership("pool-worker-1", ownerA), false);
  assert.deepEqual(await store.getSocketOwner("pool-worker-1"), ownerB);

  assert.equal(await store.releaseSocketOwnership("pool-worker-1", ownerB), true);
  assert.equal(await store.getSocketOwner("pool-worker-1"), null);
});

test("worker pool Redis keys use the CloudSec namespace", () => {
  const keys = buildWorkerPoolKeys();

  assert.equal(CLOUDSEC_WORKER_POOL_KEY_PREFIX, "cloudsec-rbi:pool");
  assert.equal(keys.workersIndex, "cloudsec-rbi:pool:workers");
  assert.equal(keys.idleIndex, "cloudsec-rbi:pool:idle");
  assert.equal(keys.worker("worker-a"), "cloudsec-rbi:pool:worker:worker-a");
  assert.equal(keys.workerPrefix, "cloudsec-rbi:pool:worker:");
  assert.equal(keys.pendingAssignment("worker-a"), "cloudsec-rbi:pool:worker:worker-a:pending");
});
