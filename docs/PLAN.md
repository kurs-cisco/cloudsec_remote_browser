# In-House RBI Execution Plan

## Summary
- Follow the current dual-provider model: `Menlo = Cat-A`, `in-house RBI = Cat-B`, with Cat-B limited to **top-level browser `GET`/`HEAD` only** until gateway and broker integrations are proven in the runtime path.
- Keep **Zeus** as the front door and keep the current runtime bootstrap surface for the first executable slice: `POST /api/swg/sessions` plus `/swg/handoff` with an opaque token. Do not introduce a `/v2` cut now; move that refactor to the Session Authority phase.
- Choose **Kata Containers on dedicated bare-metal EKS node groups** for the first VM-backed worker tier, with **Kata + Cloud Hypervisor (`kata-clh`)** as the default `RuntimeClass`. Reject `crosvm` for the mainline plan.
- Reason for the substrate choice: `Kata` is already shaped for Kubernetes/containerd and is Apache-2.0 licensed with an explicit patent grant; `crosvm` is a strong VMM, but it is BSD-3-Clause, has no explicit patent grant in the license text, and would force us to build our own worker runtime/scheduler/integration layer.
- Current workspace status is **M4 locally implemented / production closeout pending** for the planned Cat-B canary slice: opaque handoff, provider-aware prefs metadata, `OriginTypeId = 64` gating, Zeus bootstrap redirect, managed local bootstrap/handoff proof, managed target-env proof modes, rendered nginx artifact validation, Session Authority, gateway viewer/signaling, explicit media-termination capability reporting, relay-mode admission guardrails, gateway WebRTC/SRTP relay, Wave 3 Kata/EKS scaffolding, local file/clipboard brokers, and downstream `X-SIG-RBI-*` parity helpers all exist. What still cannot be closed from this workspace alone is the **captured target Zeus/nginx/runtime evidence**, **live VM-backed worker rollout**, **real scanner/DLP/storage integrations**, and **tenant rollout drill evidence**.

## Status Snapshot
- Last validated: `2026-04-27`.
- `Wave 1`: materially implemented but not acceptance-complete.
  - Done: provider-aware Cat-B routing for `OriginTypeId = 64`, opaque bootstrap/handoff, Zeus bootstrap caller, top-level browser `GET`/`HEAD` document gating, stricter malformed-redirect fallback, provider canary/kill-switch/fallback metadata in prefs output, managed local bootstrap/handoff proof, managed target-env JSON and redirect proof modes, target-env proof lane for supplied deployments, and deterministic nginx artifact validation.
  - Remaining: captured target-env Zeus/nginx/runtime proof evidence, rendered nginx validation with real deployment inputs, and populated operational dashboard/runbook evidence.
- `Wave 2`: gateway-backed Cat-B canary implemented locally with gateway WebRTC/SRTP media relay as the production-default media mode.
  - Done: Session Authority service, gateway-hosted viewer entry, gateway signaling relay, relay-only ICE policy for gateway sessions, gateway admission/quota summary, session/transport persistence, runtime-to-gateway lifecycle callbacks, explicit `transport.mediaTermination` reporting, `/v1/summary.mediaTermination`, rejection of unsupported/direct relay modes, direct worker endpoint exposure rejection, viewer and worker gateway WebRTC offer/answer flows, runtime-to-worker relay env propagation, VP8 default codec preference, full-scale 720p initial worker stream, and gateway WebRTC relay tests.
  - Remaining: captured target deployment proof, scale/soak evidence, and operational rollback drill evidence.
- `Wave 3`: offline deployment readiness implemented.
  - Done: `RuntimeClass kata-clh`, worker namespace/network policy/service account, pool and per-session worker manifests, bare-metal nodegroup template, launch-template renderer, host bootstrap scripts/docs, offline deploy wiring validation, node label/taint proof script, AMI/image promotion checklist script, proof kustomization, and live-cluster proof manifests/runbook.
  - Remaining: live AWS/EKS execution with a real custom AMI, signed worker image digest, launch-template version, managed nodegroup, and captured proof evidence. A read-only live proof attempt from this workspace could not reach the active EKS API endpoint.
- `Wave 4`: local broker and downstream parity lane implemented.
  - Done: shared broker contract, standalone Go file broker, standalone Go clipboard broker, provider-neutral metadata envelope, temporary `X-SIG-RBI-*` compatibility helper, broker unit tests, and downstream parity tests.
  - Remaining: runtime/gateway data-path wiring to call brokers for real file and clipboard actions, scanner/DLP/storage integrations, durable telemetry export, tenant kill-switch drill evidence, and app-profile certification.
- Detailed Wave 1/2 gap tracking is maintained in `docs/wave1-wave2-gap-assessment.md`. The npm-based deterministic validation helpers have been removed from the active command surface; use the Bash Terraform deployment wrappers, Go service tests, Kubernetes proof manifests, and `docs/wave1-wave2-ops-evidence-runbook.md` to collect operational evidence and go/no-go records.

## Current Pass Results
- `Wave 1` deterministic completion was previously covered by local bootstrap/handoff helpers. Final acceptance now depends on real Zeus/nginx/runtime target evidence captured through the runbook.
- Cat-B browser HTTPS parity now follows the Cat-A/Menlo pattern: Zeus still does not redirect raw `CONNECT`, but PE-authoritative `rbi-provider=in_house` / `rbi-provider-category=cat-b` isolate decisions force the internal CONNECT prefs lookup into decrypted-document handling. The resulting browser `GET`/`HEAD` document request can then use the existing signed in-house RBI bootstrap.
- `Wave 2` gateway-backed canary completion is covered by viewer registration, Session Authority propagation/validation, runtime worker env propagation, worker bridge hooks, gateway WebRTC/SRTP offer/answer relay, VP8 codec defaults, and full-scale initial 720p stream defaults. Final acceptance still requires target deployment evidence and scale/rollback drills.
- `Wave 3` has moved from plan-only to offline-verifiable deploy readiness. The next executable step is live EKS/Kata proof on dedicated bare-metal worker nodes with a real AMI and signed worker image. The current kube context exists, but the active EKS API endpoint timed out during read-only proof.
- `Wave 4` has moved from plan-only to local broker/parity implementation. The next executable step is wiring file and clipboard events from the runtime/gateway path into the brokers and replacing default local policy labels with real SWG/DLP/scanner verdict contracts.

## Temporary Dev Override Tracking
- `cloudsec-atlantis-policy-engine/internal/pkg/api/prefsapi/prefsapi.go` contains an env-gated RBI E2E override controlled by `RBI_E2E_FORCE_CATB_PROVIDER_FOR_ISOLATE`; the default is `false`.
- When enabled for local validation, the override does **not** make traffic match isolate rules and does **not** mutate the evaluator `originMap`. Rule evaluation still uses the real source/origin type from policy data.
- The override only affects the post-verdict RBI provider/category router: if the final action is isolate, provider selection is forced to Cat-B/in-house, the outgoing temporary `origin-type` is marked as BDR `64`, and `rbi_provider_mode=menlo` still disables the force path.
- Temporary tenant/profile bootstrap metadata is also limited to already-isolated traffic after the dev-only Cat-B router force. This is only to unblock SWG-to-in-house-RBI E2E validation before real BDR tenant/profile settings exist.
- This is not product behavior, not safe for production, and must remain disabled outside controlled local/dev tests.
- Stale origin-type-force naming has been removed from the active code path. The remaining temporary dev-only symbols are `forceCatBProviderForIsolateE2E`, `forcedRbiCatBProviderE2ETenantID`, `forcedRbiCatBProviderE2EProfileID`, `shouldForceCatBProviderForIsolateE2E`, and `applyDevRbiCatBBootstrapContext`.
- Removal scope: delete the remaining temporary dev-only override symbols once real BDR/Cat-B source resolution and provider-scoped tenant/profile settings exist.
- Removal criteria: real BDR/Cat-B origin resolution exists, policy-debug reports natural `OriginTypeId = 64`, provider settings supply tenant/profile metadata, and Zeus reaches the in-house RBI bootstrap without a forced policy-engine override.

## Implemented Now
- Runtime baseline exists in `cloudsec_remote_browser`: opaque SWG handoff, signed bootstrap/handoff flow, WebRTC/TURN/Redis session lifecycle, disposable worker model, and current-state hardening docs.
- Policy baseline exists in `cloudsec-atlantis-policy-engine`: provider scaffolding, provider-neutral RBI metadata, and Cat-B routing limited to `OriginTypeId = 64`.
- Deploy baseline exists in `cloudsec_Athena_swg-nginx-proxy-https` and `cloudsec_Athena_deploy-sig-eks`: in-house provider knobs are present.
- Broker/downstream baseline exists in `cloudsec_remote_browser`: shared broker contract, file broker, clipboard broker, provider-neutral metadata envelope, and temporary `X-SIG-RBI-*` compatibility helper.
- Not implemented yet: no live Kata worker deployment in the product deploy path, no runtime/gateway broker call sites for real file and clipboard actions, and no scanner/DLP/storage integrations.

## Implementation Changes
### Wave 1: Contract Freeze and Cat-B Edge Path
- **Agent 1: Policy contract** in `cloudsec-atlantis-policy-engine`.
  - Freeze the Cat-A/Cat-B decision shape.
  - Keep `rbi-provider`, `rbi-provider-category`, `rbi-tenant-*`, kill-switch, canary, and fallback-reason fields.
  - Keep `OriginTypeId = 64` as the Cat-B selector, and use a hardcoded header for tests now.
- **Agent 2: Zeus adapter** in `cloudsec_Athena_zeus-nginx` and `cloudsec_Athena_swg-nginx-proxy-https`.
  - Consume the Cat-B decision only for top-level browser `GET`/`HEAD`.
  - Call `POST /api/swg/sessions`.
  - Redirect to `/swg/handoff` using the opaque token returned by the runtime.
  - Fall back to Menlo on any bootstrap, timeout, unsupported-flow, or policy mismatch failure.
- **Agent 3: Runtime hardening** in `cloudsec_remote_browser`.
  - Freeze the bootstrap response contract used by Zeus.
  - Tighten replay rejection, TTLs, log redaction, telemetry schema, and kill-switch behavior.
  - Keep legacy compatibility only where Zeus or downstreams still require it.
- **Agent 4: Validation lane** across the same repos.
  - Build bootstrap success/failure dashboards, replay-rejection checks, worker cleanup checks, and fallback evidence.

### Wave 2: Gateway-Backed Cat-B Canary
- **Agent 5: Session Authority** in new Go services adjacent to `cloudsec_remote_browser`.
  - Own session issuance, opaque handoff generation, regional placement, worker assignment, and lifecycle state.
  - Replace ad hoc session bootstrap logic in the Node runtime, but keep the external edge contract stable.
- **Agent 6: Regional media gateway** in Go.
  - Terminate viewer traffic at the gateway.
  - Relay media/input to workers.
  - Hide worker addresses from viewers.
  - Enforce regional quotas, QoE metrics, and abuse controls.
- **Agent 7: Runtime bridge changes** in `cloudsec_remote_browser`.
  - Keep viewer and worker media on gateway WebRTC/SRTP legs by default.
  - Keep direct viewer-to-worker signaling only as rollback/development behavior.
  - Keep TURN/STUN only where required by the new gateway flow, not as the long-term public topology.

### Wave 3: VM-Backed Worker Tier on EKS + Kata
- Put **control-plane services** on standard EKS.
- Put **RBI workers** on dedicated **bare-metal EKS node groups** with taints, labels, and a separate `RuntimeClass` for Kata.
- Default the worker plane to **`kata-clh`**.
  - This fits browser workloads better than a raw `crosvm` path and avoids Firecracker’s earlier filesystem/CRI tradeoffs for the first browser tier.
- Build:
  - custom AMI pipeline with KVM, containerd, Kata, and the chosen hypervisor installed;
  - node isolation rules, separate security groups, egress proxying, no hostPath, no privileged pods, no Docker socket;
  - image signing, SBOM, provenance, guest image rotation, and runtime attestation hooks where available.
- Keep Firecracker as a benchmark lane only. Do not block implementation on it.

### Wave 4: Broker and Downstream Parity
- **Agent 8: File and clipboard brokers** in Go.
  - Add brokered download, upload, and clipboard surfaces for Cat-B.
  - Keep unsupported data flows on Menlo until the brokered path is live.
- **Agent 9: Downstream parity** across MPS and related consumers.
  - Preserve temporary `X-SIG-RBI-*` compatibility.
  - Define the provider-neutral contract underneath it so the legacy surface can be retired later.
- **Agent 10: Release and support lane**.
  - App-profile certification, kill-switch drills, fallback drills, SLOs, runbooks, and tenant rollout gates.

## Public Interfaces and Contracts
- Keep the first edge contract as:
  - `prefs`/policy emits Cat-B eligibility and provider metadata.
  - Zeus calls `POST /api/swg/sessions`.
  - Runtime returns an opaque handoff token and redirect target.
  - Zeus redirects the browser to `/swg/handoff`.
- Add internal control-plane contracts in Wave 2:
  - `Zeus -> Session Authority`
  - `Session Authority -> media gateway`
  - `Session Authority -> worker allocator`
  - `media gateway -> worker bridge`
- Add platform contracts in Wave 3:
  - EKS node labels and taints for RBI workers
  - `RuntimeClass: kata-clh`
  - separate namespaces, network policies, and egress rules for gateway and worker planes

## Test Plan and Exit Gates
- **Wave 1 acceptance**
  - `OriginTypeId = 64` routes only eligible top-level `GET`/`HEAD` traffic to the in-house bootstrap path.
  - All other isolate traffic stays on Menlo.
  - Zeus falls back to Menlo on bootstrap failure, timeout, malformed token, or unsupported method/content type.
  - Replay rejection and worker cleanup are verified.
  - Validation tracker: collect live target Zeus -> nginx -> runtime evidence through the ops runbook; npm proof helpers are no longer part of the active repo command surface.
- **Wave 2 acceptance**
  - New Cat-B sessions terminate at the gateway, not directly at workers.
  - Worker addresses are never exposed to the viewer.
  - QoE, quota, and abuse telemetry are live.
  - Validation tracker: verify `gateway-media-relay` acceptance, direct worker exposure rejection, Media Gateway package health, VP8/default-scale worker settings, and target deployment evidence.
- **Wave 3 acceptance**
  - Kata `RuntimeClass` sessions launch reliably on dedicated node groups.
  - Worker pods cannot reach internal services except explicit dependencies.
  - Session teardown removes the browser profile, worker instance, and session state.
  - Validation tracker: render the EKS worker plane, check `kata-clh` manifest coverage, and validate Kata host bootstrap shell syntax with Bash/Kubernetes tooling. Live EKS/Kata launch proof remains a separate closeout gate.
- **Wave 4 acceptance**
  - Brokered download/upload/clipboard flows work for the supported Cat-B slice.
  - Temporary `X-SIG-RBI-*` compatibility is preserved.
  - Kill-switch and Menlo fallback drills are proven per tenant and region.
  - Validation tracker: check broker contract artifacts, run file/clipboard broker Go tests, and run downstream metadata compatibility tests directly. Runtime/gateway broker call-site proof and tenant drill evidence remain separate closeout gates.

## Drawbacks and Improvement Suggestions
- **EKS + Kata drawback:** this requires **bare-metal node groups** on AWS for KVM-backed Kata workloads, which raises node cost and operational burden.
  - Improvement: keep only the control plane on standard EKS, isolate worker nodes aggressively, and benchmark a later external worker pool only after beta.
- **Current runtime drawback:** gateway WebRTC/SRTP relay is implemented, but production readiness still lacks captured target deployment proof, scale data, and rollback drill evidence.
  - Improvement: collect the live Zeus/nginx/runtime/gateway proof bundle and run gateway relay scale/rollback drills before widening Cat-B.
- **Edge integration drawback:** Zeus bootstrap wiring exists, but the stack still lacks live Zeus -> nginx -> runtime proof and rendered deployment validation for target environments.
  - Improvement: make live bootstrap proof and deploy-template validation the next Wave 1 closeout items before widening Cat-B traffic.
- **Parity drawback:** Cat-B now has local broker/downstream parity components, but it is not broad-production-ready until runtime/gateway call sites, scanner/DLP/storage integrations, and tenant drills are complete.
  - Improvement: keep the Cat-B scope narrow and explicitly route unsupported, blocked, oversized, or scan-required flows back to Menlo.
- **Substrate drawback:** `crosvm` would give lower-level control, but it would slow delivery and increase integration ownership.
  - Improvement: keep `crosvm` as an R&D option only if later benchmark data proves a need for a custom worker supervisor.

## Assumptions and Defaults
- Zeus is the only front door for Cat-B.
- Cat-B remains limited to top-level browser `GET`/`HEAD` until broker and gateway integrations are proven in the runtime path and production drill evidence is captured.
- `OriginTypeId = 64` is the sole Cat-B selector for now, and tests may hardcode that header.
- Node/TypeScript remains acceptable for the current runtime/bootstrap surface.
- New control-plane and gateway services are written in Go.
- Temporary `X-SIG-RBI-*` compatibility remains in scope.
- Recommended external basis:
  - Kata is Apache-2.0 licensed and integrates with Kubernetes/containerd: https://katacontainers.io/ , https://github.com/kata-containers/kata-containers
  - Kata’s own virtualization guide documents Cloud Hypervisor, Firecracker, and CRI tradeoffs: https://github.com/kata-containers/kata-containers/blob/main/docs/design/virtualization.md
  - crosvm is a VMM, BSD-3-Clause licensed, with minijail/seccomp sandboxing: https://crosvm.dev/book/ , https://github.com/google/crosvm
  - AWS’s EKS + Kata guidance uses bare-metal nodes and warns about operational burden: https://aws.amazon.com/blogs/containers/enhancing-kubernetes-workload-isolation-and-security-using-kata-containers/
  - Apache 2.0 includes an explicit patent license, unlike BSD-3-Clause: https://www.apache.org/licenses/LICENSE-2.0.html , https://opensource.org/license/bsd-3-clause
