# Wave 1 And Wave 2 Gap Assessment

Date: 2026-04-27

This document records the current implementation evidence for the first two RBI
waves in `PLAN.md`. It is intentionally limited to implementation readiness for
Cat-B BDR traffic alongside Menlo.

## Current Verdict

Wave 1 is materially implemented with prior local proof coverage and target
contract documentation. The npm proof helpers have been removed from the active
command surface, so full production acceptance now requires evidence from a
target Zeus/nginx/runtime deployment.

Wave 2 is implemented for the gateway-backed Cat-B canary slice. Gateway entry,
signaling, quota, observability, strict worker-exposure guardrails, and a gated
`gateway-media-relay` WebSocket relay path exist and are covered by a
bidirectional relay test. Production SFU/WebRTC media cutover is still not
complete.

## Wave 1: Contract Freeze And Cat-B Edge Path

Implemented:

- Policy emits provider-neutral RBI fields: `rbi-provider`,
  `rbi-provider-category`, `rbi-provider-canary`,
  `rbi-provider-kill-switch`, and `rbi-provider-fallback-reason`.
- Policy sends only `OriginTypeId = 64` BDR isolate traffic to the in-house
  provider lane. Other isolate traffic remains on Menlo.
- Zeus owns the Cat-B edge path and calls the runtime bootstrap route through
  the internal nginx location.
- Zeus limits in-house bootstrap to browser main-request `GET` or `HEAD`
  document navigations with document fetch metadata, HTML-capable `Accept`,
  no request body, and empty request `Content-Type`.
- Zeus falls back to Menlo when the bootstrap setup fails, the runtime returns
  a non-redirect status, the redirect is missing, or the redirect is malformed.
- Runtime bootstrap and handoff are opaque-token based and covered by unit
  tests for tampering, canonicalization, and replay-sensitive token handling.
- Target proof requirements are documented for the hardcoded Cat-B
  `OriginTypeId = 64` request shape, signed bootstrap, opaque handoff,
  malformed handoff token rejection, bootstrap replay rejection, valid handoff,
  handoff replay, cleanup, and configured fallback redirects for bad-signature
  or replay drills where the edge is expected to fall back to Menlo.
- Rendered nginx artifact validation now checks SWG/Zeus/RBI templates,
  in-house bootstrap headers, consul defaults, and Zeus directive fixtures.

Remaining:

- Live Zeus -> nginx -> runtime bootstrap proof evidence must be collected per
  target deployment; evidence is environment-specific and must record target routing,
  target secrets, target time skew, fallback behavior, and target worker
  capacity.
- Rendered deployment nginx validation using the real deploy inputs for the
  target environment, beyond the deterministic no-secret artifact validation.
- Populated operational dashboard evidence for bootstrap success, fallback
  reasons, handoff success, replay rejection, and worker cleanup. The evidence
  template now exists in `docs/wave1-wave2-ops-evidence-runbook.md`.

## Wave 2: Gateway-Backed Cat-B Canary

Implemented:

- Session Authority exists as a Go service and can call the runtime, register a
  gateway session, and patch runtime session placement.
- Media Gateway owns gateway viewer entry, viewer/API proxying, gateway
  signaling sockets, session registration, admission/quota decisions, and
  summary telemetry.
- Gateway sessions force relay-only ICE policy in runtime session payloads.
- Gateway summary exposes session counts, signaling counts, pending signal
  backlog, admission decisions, rejection reasons, and transport counts.
- Gateway transport now reports `mediaTermination` capability explicitly.
- Gateway rejects unsupported relay modes instead of implying that media
  termination is complete.
- Gateway rejects public viewer or signaling endpoints that expose worker IDs or
  direct IP literals.
- `gateway-media-relay` can be enabled with `MEDIA_GATEWAY_ENABLE_MEDIA_RELAY`
  for canary sessions. It returns viewer and worker media relay URLs, terminates
  the gateway-owned media relay WebSocket path, and reports frame/byte counters
  in `/v1/summary`.
- Media Gateway unit tests now open real viewer and worker WebSocket relay
  connections, register both roles, forward payloads in both directions through
  the gateway, and verify relay frame/byte counters.

Remaining:

- Production media cutover. Default sessions still rely on WebRTC media between
  viewer and worker after gateway signaling; the new gateway media relay is a
  gated canary path, not yet the default viewer/worker transport.
- Session Authority is not yet the only lifecycle authority. The Node runtime
  still owns core session state and cleanup behavior.
- Live proof that worker addresses are never exposed in browser-facing payloads
  across the whole target stack.
- QoE metrics for WebRTC/SFU quality are not available yet; gateway media relay
  currently reports relay frame and byte counters.

## Validation Entry Point

Use the Bash deployment wrappers, Go test/build tooling, Kubernetes proof
manifests, and target deployment runbooks directly. The former npm validation
wrapper has been removed.

Recommended validation coverage:

- Wave 1 target bootstrap proof capability and captured target evidence.
- Wave 2 gateway WebRTC/SRTP media relay acceptance and direct worker exposure rejection.
- Wave 3 Kata/EKS worker-plane manifests/bootstrap.
- Go control-plane build and unit tests.
- Policy settings and prefs tests in their owning repos.
- Zeus/SWG rendered nginx artifact validation in their owning repos.
- EKS Kata worker-plane kustomize render.
- Kata node bootstrap shell syntax check.

Tracked validation entries:

| Entry | Current deterministic proof | Remaining live proof |
| --- | --- | --- |
| Wave 1 target bootstrap proof | Contract requirements and target evidence checklist. | Run the target proof against every canary deployment and attach dashboard/runbook evidence. |
| Wave 2 media relay | `gateway-media-relay` acceptance, direct worker exposure rejection, media termination summary, gateway WebRTC/SRTP offer/answer relay tests, VP8 default codec preference, and full-scale initial stream defaults. | Run target deployment proof, scale/soak tests, and rollback drills against the gateway relay path. |
| Wave 3 Kata/EKS | `kata-clh` RuntimeClass and worker manifests render through kustomize; Kata host bootstrap script passes shell syntax validation. | Launch real Kata worker sessions on dedicated bare-metal EKS nodes and capture teardown/network-policy evidence. |

## Next Patch Order

1. Collect target proof evidence against every canary Zeus/nginx/runtime base URL
   before widening Cat-B traffic.
2. Add deployment nginx render validation using real target values.
3. Run viewer/worker `gateway-media-relay` scale, soak, and rollback drills with
   captured Media Gateway `/v1/summary` evidence.
4. Move lifecycle ownership out of the Node runtime and into Session Authority.
5. Add dashboard/runbook artifacts from the validation script output and gateway
   `/v1/summary`.

## Ops Evidence Runbook

Use `docs/wave1-wave2-ops-evidence-runbook.md` for the Wave 1/2 evidence packet.
It defines the required target proof, `/v1/summary` fields, fallback
reason capture, replay rejection proof, worker cleanup proof, and go/no-go gates.
