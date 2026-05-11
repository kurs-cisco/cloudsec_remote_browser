import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

async function loadProofHarness() {
  return readFile(
    fileURLToPath(new URL("../scripts/rbi-windows-rdp-visual-proof.sh", import.meta.url)),
    "utf8",
  );
}

test("windows RDP visual proof waits for viewer input readiness before dispatch", async () => {
  const source = await loadProofHarness();

  assert.match(source, /function Get-ProofInputReadiness/);
  assert.match(source, /input-channel-not-open/);
  assert.match(source, /input-slo-pending/);
  assert.match(source, /Invoke-ProofInput -Readiness \$readiness/);
  assert.match(source, /proof\.inputNotReady/);
});

test("windows RDP visual proof types through key events instead of insertText", async () => {
  const source = await loadProofHarness();

  assert.match(source, /function Send-ProofKey/);
  assert.match(source, /Input\.dispatchKeyEvent/);
  assert.doesNotMatch(source, /Input\.insertText/);
});

test("windows RDP visual proof budgets only interactive input ACK classes", async () => {
  const source = await loadProofHarness();

  assert.match(
    source,
    /\$interactiveInputClasses = @\("pointer_move","pointer_button","wheel","key","text_insert"\)/,
  );
  assert.match(source, /\$interactiveInputClasses -notcontains \$prop\.Name/);
  assert.match(source, /click-to-apply latency was not captured/);
});

test("windows RDP visual proof redacts token-like URL values in artifacts", async () => {
  const source = await loadProofHarness();

  assert.match(source, /__rbiRedactProofValue/);
  assert.match(source, /token\|sig\|signature\|hmac\|secret\|key\|auth\|jwt/);
  assert.match(source, /href: window\.__rbiRedactProofValue\(location\.href\)/);
  assert.match(source, /args:a\.map\(window\.__rbiRedactProofValue\)/);
});

test("windows RDP visual proof redacts requested URL before persistence and stdout", async () => {
  const source = await loadProofHarness();

  assert.match(source, /function Redact-ProofValue/);
  assert.match(source, /url = Redact-ProofValue \$Config\.Url/);
  assert.match(source, /artifact_config\["Url"\] = redact_proof_value\(config\["Url"\]\)/);
  assert.match(source, /\$RuntimeConfigPath = Join-Path \$BaseDir "\$\(.*RunId.*\)-runtime-config\.json"/);
  assert.match(source, /Set-Content -LiteralPath \$ConfigPath -Encoding UTF8/);
  assert.match(source, /printf 'Proof URL: %s\\n' "\$\{PROOF_URL_REDACTED\}"/);
  assert.match(source, /INVOCATION_REDACTED="\$\(redact_proof_value <<<"\$\{INVOCATION\}"\)"/);
  assert.match(source, /printf '%s\\n' "\$\{INVOCATION_REDACTED\}"/);
});
