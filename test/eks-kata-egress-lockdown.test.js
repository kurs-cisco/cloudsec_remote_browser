import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function readRepoFile(relativePath) {
  return readFileSync(resolve(repoRoot, relativePath), "utf8");
}

function assertContains(haystack, needle, message) {
  assert.ok(haystack.includes(needle), message);
}

function assertContainsAssignment(haystack, key, value) {
  assert.match(
    haystack,
    new RegExp(`${key}\\s*=\\s*"${value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`),
    `missing ${key} = "${value}"`,
  );
}

test("EKS worker NetworkPolicy does not allow direct public CIDR egress", () => {
  const policy = readRepoFile("deploy/eks/rbi-worker-network-policy.yaml");

  assert.doesNotMatch(policy, /^\s*cidr:\s*0\.0\.0\.0\/0(?:\s|$)/m);
  assert.doesNotMatch(policy, /^\s*ipBlock:/m);
});

test("EKS worker NetworkPolicy allows only labeled egress targets on expected ports", () => {
  const policy = readRepoFile("deploy/eks/rbi-worker-network-policy.yaml");

  for (const expected of [
    "k8s-app: kube-dns",
    "cloudsec.cisco.com/rbi-plane: control",
    "cloudsec.cisco.com/rbi-plane: media",
    "app.kubernetes.io/component: media-gateway",
    "app.kubernetes.io/component: turn",
    "cloudsec.cisco.com/egress-plane: swg",
    "app.kubernetes.io/component: swg-proxy",
    "port: 53",
    "port: 3478",
    "port: 3128",
  ]) {
    assertContains(policy, expected, `missing ${expected}`);
  }
});

test("EKS worker shared ConfigMap carries SWG proxy defaults", () => {
  const configMap = readRepoFile("deploy/eks/rbi-worker-shared-configmap.yaml");

  for (const expected of [
    "SWG_EGRESS_PROXY_URL: http://swg-proxy.cloudsec-swg.svc.cluster.local:3128",
    "POOL_WS_URL: ws://runtime.cloudsec-rbi-control.svc.cluster.local:8080/ws/pool",
    "SIGNALING_URL: ws://runtime.cloudsec-rbi-control.svc.cluster.local:8080/ws/worker",
    "WORKER_ICE_URLS: turn:turn.cloudsec-rbi-media.svc.cluster.local:3478?transport=udp",
    "WORKER_REGION: ap-south-1",
    "WORKER_RUNTIME_CLASS: kata-clh",
    "WORKER_MEDIA_MODE: gateway-webrtc-relay",
    "HTTP_PROXY: http://swg-proxy.cloudsec-swg.svc.cluster.local:3128",
    "HTTPS_PROXY: http://swg-proxy.cloudsec-swg.svc.cluster.local:3128",
    "NO_PROXY:",
    "http_proxy: http://swg-proxy.cloudsec-swg.svc.cluster.local:3128",
    "https_proxy: http://swg-proxy.cloudsec-swg.svc.cluster.local:3128",
    "no_proxy:",
  ]) {
    assertContains(configMap, expected, `missing ${expected}`);
  }
});

test("Terraform RBI app module defaults to locked-down worker egress", () => {
  const moduleMain = readRepoFile("infra/terraform/aws-standalone-rbi/modules/rbi-apps/main.tf");
  const moduleVars = readRepoFile("infra/terraform/aws-standalone-rbi/modules/rbi-apps/variables.tf");

  for (const [key, value] of [
    ["POOL_WS_URL", "ws://runtime.${var.control_namespace}.svc.cluster.local:8080/ws/pool"],
    ["WORKER_ICE_URLS", "turn:turn.cloudsec-rbi-media.svc.cluster.local:3478?transport=udp"],
    ["WORKER_MEDIA_MODE", "gateway-webrtc-relay"],
    ["POOL_RECYCLE_AFTER_SESSION", "1"],
    ["SWG_EGRESS_PROXY_URL", "http://swg-proxy.cloudsec-swg.svc.cluster.local:3128"],
  ]) {
    assertContainsAssignment(moduleMain, key, value);
  }

  for (const expected of [
    '"app.kubernetes.io/component" = "media-gateway"',
    '"app.kubernetes.io/component" = "turn"',
    '"app.kubernetes.io/component" = "swg-proxy"',
    '"cloudsec.cisco.com/egress-plane" = "swg"',
    "port     = 3128",
  ]) {
    assertContains(moduleMain, expected, `missing ${expected}`);
  }

  assertContains(
    moduleVars,
    'description = "Dev-only rollback: allow worker egress to public IP space',
    "public egress must be documented as a dev-only rollback",
  );
  assertContains(moduleVars, "default     = false", "public egress must default off");
});

test("EKS worker egress proof kustomization mounts the Python stdlib script", () => {
  const kustomization = readRepoFile("deploy/eks/proof/egress/kustomization.yaml");

  for (const expected of [
    "namespace: cloudsec-rbi-workers",
    "disableNameSuffixHash: true",
    "rbi-worker-egress-proof-script",
    "rbi_worker_egress_proof.py=scripts/rbi_worker_egress_proof.py",
    "rbi-worker-egress-proof-job.yaml",
    "cloudsec-remote-browser-worker",
  ]) {
    assertContains(kustomization, expected, `missing ${expected}`);
  }
});

test("EKS worker egress proof Job runs the worker image under Kata policy", () => {
  const job = readRepoFile("deploy/eks/proof/egress/rbi-worker-egress-proof-job.yaml");

  for (const expected of [
    "kind: Job",
    "name: rbi-worker-egress-proof",
    "runtimeClassName: kata-clh",
    "serviceAccountName: rbi-worker",
    "automountServiceAccountToken: false",
    "enableServiceLinks: false",
    'cloudsec.cisco.com/rbi-worker-plane: "true"',
    "image: cloudsec-remote-browser-worker:latest",
    "- python3",
    "- -B",
    "- /proof/rbi_worker_egress_proof.py",
    "name: rbi-worker-shared-config",
    "readOnlyRootFilesystem: true",
    "name: rbi-worker-egress-proof-script",
  ]) {
    assertContains(job, expected, `missing ${expected}`);
  }
});

test("EKS worker egress proof Job declares deny and allow proof targets", () => {
  const job = readRepoFile("deploy/eks/proof/egress/rbi-worker-egress-proof-job.yaml");

  for (const expected of [
    "EGRESS_PROOF_PUBLIC_URL",
    "https://example.com/",
    "EGRESS_PROOF_METADATA_URL",
    "169.254.169.254",
    "EGRESS_PROOF_KUBE_API_TARGET",
    "kubernetes.default.svc:443",
    "EGRESS_PROOF_REDIS_TARGET",
    "redis.cloudsec-rbi-control.svc.cluster.local:6379",
    "EGRESS_PROOF_PUBLIC_DNS_TARGET",
    "8.8.8.8:53",
    "EGRESS_PROOF_INTERNAL_TCP_TARGETS",
    "10.0.0.1:443,172.16.0.1:443,192.168.0.1:443",
    "EGRESS_PROOF_PROXY_DENY_URLS",
  ]) {
    assertContains(job, expected, `missing ${expected}`);
  }
});

test("EKS worker egress proof script covers direct deny, proxy allow, and media allow probes", () => {
  const script = readRepoFile("deploy/eks/proof/egress/scripts/rbi_worker_egress_proof.py");

  for (const expected of [
    "urllib.request.ProxyHandler({})",
    "proxied_public_https",
    "direct_public_https",
    "direct_metadata_http",
    "direct_kube_api",
    "direct_redis",
    "direct_public_dns_8_8_8_8_53",
    "proxied_internal_deny_",
    "control_wss",
    "media_gateway_wss",
    "turn_udp",
    "STUN_MAGIC_COOKIE",
    "ssl._create_unverified_context()",
  ]) {
    assertContains(script, expected, `missing ${expected}`);
  }

  assert.doesNotMatch(script, /^\s*(?:import|from)\s+(requests|websockets|aiohttp|httpx)\b/m);
});

test("Wave 3 validator exposes the worker egress proof mode", () => {
  const validator = readRepoFile("deploy/eks/scripts/validate-wave3-kata-eks.sh");

  for (const expected of [
    'PROOF_EGRESS_DIR="${PROOF_DIR}/egress"',
    'KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"',
    '"${KUBECTL}" --context "${KUBECTL_CONTEXT}" "$@"',
    "ast.parse(pathlib.Path(sys.argv[1]).read_text",
    'kubectl_cmd kustomize "${PROOF_EGRESS_DIR}"',
    "egress_proof_static_checks",
    "live_egress_prereq_checks",
    "preflight-egress",
    "live worker NetworkPolicy still allows broad 0.0.0.0/0 direct egress",
    "live worker shared config missing SWG_EGRESS_PROXY_URL",
    "apply-egress-proof",
    "egress_proof_apply",
    "job/rbi-worker-egress-proof",
    "PASS live Wave 3 Kata worker egress proof",
  ]) {
    assertContains(validator, expected, `missing ${expected}`);
  }
});

test("Wave 3 node proof supports an explicit kube context", () => {
  const proofScript = readRepoFile("deploy/eks/scripts/prove-rbi-worker-node-contract.sh");

  for (const expected of [
    'KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"',
    '"${KUBECTL}" --context "${KUBECTL_CONTEXT}" "$@"',
    "kubectl_cmd get nodes",
    "kubectl_cmd get node",
  ]) {
    assertContains(proofScript, expected, `missing ${expected}`);
  }
});
