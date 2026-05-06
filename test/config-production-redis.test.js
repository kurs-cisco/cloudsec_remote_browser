import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function importConfig(envOverrides = {}) {
  const env = {
    ...process.env,
    NODE_ENV: "production",
    TOKEN_SECRET: "unit-token-secret",
    TURN_SHARED_SECRET: "unit-turn-secret",
    SWG_SHARED_SECRET: "unit-swg-secret",
    REDIS_URL: "redis://127.0.0.1:6379",
    ENABLE_SWG_BOOTSTRAP: "1",
    ...envOverrides,
  };
  for (const name of [
    "SESSION_STORE_BACKEND",
    "SIGNAL_BUS_BACKEND",
    "WORKER_POOL_STORE_BACKEND",
    "WORKER_POOL_BUS_BACKEND",
  ]) {
    if (!Object.prototype.hasOwnProperty.call(envOverrides, name)) {
      delete env[name];
    }
  }
  return spawnSync(process.execPath, ["--input-type=module", "-e", "import './app/config.js';"], {
    cwd: rootDir,
    env,
    encoding: "utf8",
  });
}

test("production Redis-only proof mode rejects non-Redis backends", () => {
  const result = importConfig({ PRODUCTION_REDIS_ONLY: "1" });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /SESSION_STORE_BACKEND=redis/);
  assert.match(result.stderr, /SIGNAL_BUS_BACKEND=redis/);
  assert.match(result.stderr, /WORKER_POOL_STORE_BACKEND=redis/);
  assert.match(result.stderr, /WORKER_POOL_BUS_BACKEND=redis/);
});

test("production Redis-only proof mode accepts all Redis backends", () => {
  const result = importConfig({
    PRODUCTION_REDIS_ONLY: "1",
    SESSION_STORE_BACKEND: "redis",
    SIGNAL_BUS_BACKEND: "redis",
    WORKER_POOL_STORE_BACKEND: "redis",
    WORKER_POOL_BUS_BACKEND: "redis",
  });

  assert.equal(result.status, 0, result.stderr);
});
