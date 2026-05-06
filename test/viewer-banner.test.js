import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

async function loadViewerBannerHelpers() {
  const source = await readFile(
    fileURLToPath(new URL("../viewer/viewer.js", import.meta.url)),
    "utf8",
  );
  const match = source.match(
    /\/\/ Viewer banner\/progress helpers BEGIN\n(?<helpers>[\s\S]*?)\/\/ Viewer banner\/progress helpers END/,
  );
  assert.ok(match?.groups?.helpers, "viewer banner/progress helper block must be present");

  return vm.runInNewContext(
    `
      const VIEWER_PROGRESS_STAGES = [
        "loading",
        "allocating",
        "worker-ready",
        "media",
        "first-frame",
        "live",
      ];
      function truncateTelemetryValue(value, maxLength = 180) {
        const text = String(value ?? "");
        return text.length <= maxLength ? text : \`\${text.slice(0, maxLength - 3)}...\`;
      }
      function formatElapsedDuration() {
        return "00:42";
      }
      ${match.groups.helpers}
      ({
        buildEnterpriseBannerModel,
        deriveProfileLabelForSession,
        deriveTenantLabelForSession,
        getProgressStageState,
      });
    `,
    { URL },
  );
}

test("viewer banner model uses Cisco label and masks tenant/profile fallback IDs", async () => {
  const {
    buildEnterpriseBannerModel,
    deriveProfileLabelForSession,
    deriveTenantLabelForSession,
  } = await loadViewerBannerHelpers();
  const session = {
    sessionMode: "swg",
    state: "streaming",
    targetOrigin: "https://example.com",
    createdAt: "2026-05-06T00:00:00.000Z",
    swgContext: {
      tenantId: "raw-tenant-123",
      profileId: "raw-profile-456",
      policy: "isolate",
    },
    transport: {
      mediaPlaneMode: "gateway-webrtc-relay",
    },
  };

  assert.match(deriveTenantLabelForSession(session), /^Tenant t-[a-f0-9]{8}$/);
  assert.match(deriveProfileLabelForSession(session), /^Profile p-[a-f0-9]{8}$/);

  const model = buildEnterpriseBannerModel(session, {
    currentViewerStage: "first-frame",
    targetUrlHint: "",
  });

  assert.equal(model.mode, "Cisco Secure Browsers");
  assert.equal(model.connection, "First frame rendered");
  assert.doesNotMatch(JSON.stringify(model), /raw-tenant-123|raw-profile-456/);
  assert.match(model.policy, /^isolate · Profile p-[a-f0-9]{8}$/);
});

test("viewer progress helper marks done, active, and terminal error states", async () => {
  const { getProgressStageState } = await loadViewerBannerHelpers();

  assert.deepEqual(plain(getProgressStageState("media", "worker-ready")), {
    done: true,
    active: false,
    error: false,
  });
  assert.deepEqual(plain(getProgressStageState("media", "media")), {
    done: false,
    active: true,
    error: false,
  });
  assert.deepEqual(plain(getProgressStageState("ended", "live")), {
    done: false,
    active: false,
    error: true,
  });
});

test("viewer HTML exposes Cisco Secure Browsers as the visible product label", async () => {
  const html = await readFile(
    fileURLToPath(new URL("../viewer/index.html", import.meta.url)),
    "utf8",
  );

  assert.match(html, /<title>Cisco Secure Browsers<\/title>/);
  assert.match(html, /class="watermark-cluster"/);
  assert.match(html, /id="urlReveal"/);
  assert.match(html, /class="url-tooltip" role="tooltip"/);
  assert.match(html, /class="protected-prefix">Protected by<\/span>/);
  assert.match(html, /<strong>Cisco Secure Browser<\/strong>/);
  assert.doesNotMatch(html, /Protected by Cisco Secure Browser ·/);
});

test("viewer watermark exposes page navigation and removes session controls", async () => {
  const html = await readFile(
    fileURLToPath(new URL("../viewer/index.html", import.meta.url)),
    "utf8",
  );

  assert.match(html, /id="navBack"/);
  assert.match(html, /id="navForward"/);
  assert.match(html, /id="navReload"/);
  assert.match(html, /id="protectedMark"/);
  assert.doesNotMatch(html, /id="audioToggle"/);
  assert.doesNotMatch(html, /id="restartSession"/);
  assert.doesNotMatch(html, /id="endSession"/);
});
