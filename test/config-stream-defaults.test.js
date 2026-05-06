import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function readConfig(envOverrides = {}) {
  const env = {
    ...process.env,
    NODE_ENV: "test",
    TOKEN_SECRET: "unit-token-secret",
    TURN_SHARED_SECRET: "unit-turn-secret",
    SWG_SHARED_SECRET: "unit-swg-secret",
    ...envOverrides,
  };
  for (const name of ["INITIAL_STREAM_SCALE", "VIDEO_CODEC_PREFERENCES"]) {
    if (!Object.prototype.hasOwnProperty.call(envOverrides, name)) {
      delete env[name];
    }
  }

  const result = spawnSync(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      "import { config } from './app/config.js'; console.log(JSON.stringify({ initialStreamScale: config.initialStreamScale, preferredVideoCodecs: config.preferredVideoCodecs }));",
    ],
    {
      cwd: rootDir,
      env,
      encoding: "utf8",
    },
  );
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

test("stream defaults start at full scale and prefer VP8", () => {
  assert.deepEqual(readConfig(), {
    initialStreamScale: 1,
    preferredVideoCodecs: ["VP8"],
  });
});

test("stream defaults keep env rollback overrides", () => {
  assert.deepEqual(
    readConfig({
      INITIAL_STREAM_SCALE: "0.5",
      VIDEO_CODEC_PREFERENCES: "H264,VP8",
    }),
    {
      initialStreamScale: 0.5,
      preferredVideoCodecs: ["H264", "VP8"],
    },
  );
});
