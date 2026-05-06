# Plan: cloudsec_remote_browser Gen-2 SDD

Upgrade `cloudsec_remote_browser` from a Gen-1 pixel-streamed RBI runtime to a Gen-2,
SASE-tier browser security platform: adaptive hybrid remoting, runtime semantic threat
engine, high-assurance microVM worker tier with attestation, endpoint co-processing,
and evidence-fabric telemetry — all built on open standards to avoid competitor IP.

Current doc: cloudsec_remote_browser/docs/rbi-arch.md
Scope boundary: this plan is an SDD outline for engineering + security + legal review.
No implementation starts until FTO opinion and threat-model sign-off are complete.

## IP Guardrails (blocking)
- FTO opinion scoped to: draw-command remoting, DOM-diff streaming, clientless
  rendering, confidential-compute browser attestation, agentic endpoint isolation.
- Engineering must not consult Menlo/Cloudflare/Zscaler/PAN internal docs while
  building rendering, telemetry, or attestation modules.
- All novel combinations receive defensive publication within 90 days of PoC.
- Provenance + license scan on contractor and LLM-generated code in sensitive modules.
- Prohibit cloning of any Menlo ACR / Cloudflare NVR / Zscaler Turbo serialization
  format; our vector path uses only public Skia/Chromium viz APIs.

## Architectural Pillars (P1–P5)
P1. Adaptive Hybrid Remoting Plane (vector / pixel / safe-HTML fallback)
P2. Runtime Semantic Threat Engine (in-worker, CDP-instrumented, LLM-assisted)
P3. High-Assurance Worker Tiers (container → microVM → confidential VM w/ attestation)
P4. Endpoint Co-Processing (signed micro-policy + local QoE steering + risk hints)
P5. Evidence-Fabric Telemetry (control / semantic deltas / trigger-based artifacts;
    content-addressed, hash-deduped, WebTransport-ready)

## Language / Runtime Strategy (polyglot, not single-rewrite)

Node.js is retained only where it is a good fit; hot paths move to Go and Rust.
Single-language mandate is rejected: all-Go caps density; all-Rust slows delivery.

### Keep on Node.js + TypeScript (low-QPS, I/O-bound, request/response)
- SWG bootstrap HTTPS endpoint, JWE handoff mint, admin/tenant REST, policy CRUD.
- Viewer-side application code (browser JS/TS).
- Rationale: current code in app/server.js and shared/swg-handoff.js is close to
  idiomatic; Fastify + strict TS + OpenAPI is productive; rewrite ROI is low.

### Move to Go (distributed services, many long-lived connections, gRPC)
- Signaling broker (WebTransport + WS fallback) — 100k+ concurrent conns/DC.
- Session Authority (sharded by tenant+region, admission, quota, affinity).
- Scheduler API (abstraction over container/microVM/confidential runtimes).
- Telemetry aggregator (per-DC fan-in, OpenTelemetry gRPC, sketches).
- Rationale: goroutines + M:N scheduler handle idle conns with predictable tail
  latency; mature quic-go/webtransport-go; strong stdlib; operational precedent
  at Cloudflare/Tailscale/HashiCorp. Avoids Node's V8 GC tail pauses (50–300ms
  at >2GB heap) that would be user-visible in the SDP/ICE path.

### Move to Rust (density-critical hot path, zero-GC, FFI to C++)
- Worker harness replacing Python/aiortc on the media hot path.
- Vector capture agent (FFI into Chromium //components/viz + Skia via C++ shim).
- Pixel encode agent (WebCodecs-compatible AV1/H.264, WebRTC SVC via str0m or
  webrtc-rs).
- In-process semantic probe event capture (>50k events/s/worker).
- Rationale: GIL-bound Python caps density; density target +5–10× vs current
  aiortc prototype. Tokio + zero-copy I/O fits long-lived peer connections.

### Keep Python, narrowly
- Inference sidecar for JS deobfuscation + multimodal phishing (model iteration).
- Production serving via Triton/vLLM/ONNX-Runtime; Rust (ort/candle) replaces
  Python in hot path once models stabilize.
- Legacy worker.py retained only as reference implementation, not on hot path.

### Endpoint co-processor
- Integrate into the existing SASE agent in its existing language. New modules
  in Rust. No Node on endpoint.

### Why not all-Go / all-Rust
- All-Go: caps worker density because GC + heap pressure under SRTP/codec work
  costs 2–3× vs Rust. Acceptable for services, not for the data plane.
- All-Rust: slows time-to-market for request/response services where Node/TS
  already works. Rust's value is in the hot path, not CRUD.

### Migration sequencing (non-blocking of architecture phases)
- Phase 0: freeze Node to bootstrap/handoff/admin surface; feature-flag Go
  signaling broker alongside current Node WS; Node WS is fallback.
- Phase 1–2: Go Session Authority + Scheduler API behind stable gRPC contracts;
  Node calls them. Rust worker harness PoC behind per-tenant canary.
- Phase 3: Rust worker harness default for vector tier; Python/aiortc removed
  from hot path.
- Phase 4+: Go telemetry aggregator + Rust in-proc probe; Node shrinks to
  bootstrap/handoff/admin only (~≤15% of runtime LoC).

### Library shortlist (open-source, permissive/clean licensing required)
- Go: quic-go, webtransport-go, google.golang.org/grpc, opentelemetry-go,
  go-redis, pion (reference only — not production SFU).
- Rust: tokio, hyper, quinn, webtransport-rs (or wtransport), str0m or
  webrtc-rs, tracing, opentelemetry-rust, ort/candle.
- TS/Node: Fastify, jose (JWE), pino, zod, @opentelemetry/*.
- License scan required on every new dependency; no GPL/AGPL in shipped code.

## Cross-Cutting Design Decisions
- Transport strategy: migrate signaling + low-latency control to WebTransport (HTTP/3)
  with WebSocket fallback. Media stays WebRTC for pixel tier, WebTransport datagrams
  + WebCodecs for vector tier. Eliminates Redis pending-signal hot path for new flows.
- Identity model: `BrowserPrincipal` = {human | agent}, carries IdP claims, device
  posture, risk score, tenant, policy, session continuity tokens.
- Session multiplexing: tab-per-session inside a hardened Chromium process pool per
  tenant risk class; strict site-isolation + origin-keyed agent clusters; no
  cross-tenant reuse; cold pool for high-assurance tier.
- Handoff payload: JWE (AEAD-wrapped opaque session id), replay TTL ≤ 60s, no PII
  in query string.
- SSO continuity: first-party IdP cookie bridge via signed SAML/OIDC state relay +
  WebAuthn origin attestation for the isolated origin (documented, user-visible).
- Federation with existing SWG DLP, CDR, AV, FTC pipelines — not reimplementation.
- Default fallback to existing Menlo path on any gate failure (deterministic, <1s).

## Component Architecture (Gen-2)

### Control plane (Node/TypeScript)
- Session Authority (region-local shard): owns session lifecycle, tokens,
  admission control, quota, canary routing. Sharded by tenant+region.
- Bootstrap service: SWG HMAC verify + JWE handoff mint + replay window.
- Signaling broker (WebTransport-first, WS fallback).
- Scheduler API: abstraction over worker runtimes; Gen-2 adds microVM + confidential.
- Identity service: principal resolution, IdP bridge, WebAuthn relay, posture fetch.
- Policy resolver: reads SWG/PE verdict + tenant config; selects rendering tier,
  worker tier, feature gates (clipboard/upload/download/print/extensions).

### Worker runtime (Chromium + harness)
- Harness: Go or Rust (replace Python/aiortc prototype on the hot path for density).
- Rendering agents (selected per page or per region, hot-switchable):
  * Vector agent: Skia PaintOp capture → protobuf frame → WebTransport → viewer
    OffscreenCanvas replay. Text remains glyphs; events remain semantic.
  * Pixel agent: hardware-accelerated H.264/AV1 via WebCodecs or WebRTC simulcast/SVC.
    Used for canvas/WebGL/WebGPU/DRM/video regions.
  * Safe-HTML agent: server-side sanitized DOM + CSP-locked iframe for degraded
    networks or ultra-low-risk static content.
- Semantic probe: CDP client tapping Network, Page, Runtime, Debugger, Security,
  Storage domains; emits structured event stream.
- Egress broker: all worker network flows via tenant-scoped SWG egress with DoH,
  denied-peer allowlist, RFC1918/metadata-IP blocks, per-destination rate limits.
- File broker: downloads/uploads cross a sidecar that invokes existing CDR/AV/DLP;
  no direct filesystem path to user endpoint.
- Clipboard broker: policy-gated, direction-aware, DLP-scanned, format-whitelisted.

### Endpoint agent (extension of existing SASE client)
- Local risk classifier (ONNX int8, <50MB) for URL/DOM pre-scoring.
- QoE steerer: selects region/transport based on observed path metrics.
- Credential-entry watcher + WebAuthn step-up.
- Screenshot watermarking (optional), print/clipboard egress gate at OS layer.
- Policy bundle signed with tenant key; periodic refresh via gRPC stream.

### Telemetry plane
- Tier 1 (always-on): control+QoE metrics via OpenTelemetry over gRPC.
- Tier 2 (semantic deltas): probe events aggregated with sketches (HLL/t-digest/CMS)
  per session; per-tenant anomaly stream.
- Tier 3 (trigger-based artifacts): DOM snapshots, screenshots, HAR, download
  objects — content-addressed (SHA-256), hash-deduped, stored in tenant-scoped
  object store, referenced by ID in the lake.
- eBPF attestation probes on worker hosts for tamper-evident syscall/net evidence
  (high-assurance tier only).

## Security Controls (Gen-2 additions on top of current)
- JWE handoff; 60s replay TTL; no PII in URL.
- Input-plane rate limit + anomaly detector on viewer data channel.
- TURN per-credential allocation cap + allowed-peer-IP + denied-peer-IP; realm
  isolation per tenant tier; `turns:443` required in restricted networks.
- Worker Chromium: site-isolation enforced, `--disable-features` hardening set,
  optional `--v8-sandbox` + JIT-less mode for high-assurance tier.
- DNS egress via tenant-scoped DoH only.
- Secrets released to worker only after attestation in confidential tier
  (SEV-SNP / TDX measurement verified against signed image manifest).
- Extension support: signed manifest allowlist, per-tenant curation, supply-chain
  verification (Sigstore/cosign), no unvetted Chrome Web Store path.
- CSP/COOP/COEP/Trusted-Types on viewer HTML; frame-ancestors deny by default.
- WebAuthn origin bridge for IdP flows; audit trail of step-up events.

## Capacity + SLO Targets (per DC)
- Session density target: vector tier 200+ concurrent / vCPU, pixel tier 8–12 / vCPU.
- p95 time-to-first-pixel: vector ≤ 400ms, pixel ≤ 900ms in-region.
- p99 input-to-render latency: vector ≤ 80ms, pixel ≤ 150ms on healthy path.
- Relay ratio ceiling: ≤ 55% (trigger capacity alarm above).
- Bandwidth budget (median): vector ≤ 300 kbps, pixel ≤ 2.5 Mbps.
- Admission control: deterministic fallback to Menlo on breach, logged with reason.

## Phases (with gates)

### Phase 0 — Legal, Threat Model, and Foundation (blocking gate)
- FTO opinion complete. Formal STRIDE + LINDDUN threat model signed off.
- Provider-canary framework in SWG with per-tenant allowlist + kill switch.
- Observability baseline: session metrics, TURN metrics, OpenTelemetry spans
  end-to-end, SLO dashboards, alerting.
- Harden current pixel path: JWE handoff, 60s replay, relay-only default for
  production, TURN quotas, DNS egress policy, input rate-limit, Redis TLS+ACL,
  scheduler narrowed to one adapter, worker Chromium hardening flag set.
- Viewer security headers (CSP/COOP/COEP/Trusted-Types).
- Redis sharding model + regional affinity documented; admission control with
  Menlo fallback wired.
Exit: Gen-1 production-acceptable for controlled canary traffic only.

### Phase 1 — High-Assurance Worker Tier (P3 partial)
- Introduce microVM scheduler (Firecracker or Cloud Hypervisor) alongside
  container scheduler. Per-session VM + ephemeral tmpfs overlay.
- Warm-pool with sub-second cold start; session boot measurement captured.
- Worker egress through SWG proxy; DoH resolver; metadata-IP block enforced.
- File broker + clipboard broker MVP (block by default; log attempts).
Exit: microVM tier available for tenants flagged "high assurance"; container
tier remains for commodity traffic.

### Phase 2 — Runtime Semantic Threat Engine (P2)
- CDP probe + structured event stream on every worker.
- Rule engine (Rego/OPA or equivalent) for HTML-smuggling patterns (Blob/download
  attribute abuse), suspicious Service Worker, File System Access, canvas
  extraction, high-entropy postMessage, mass form capture.
- Sidecar inference service per DC: distilled model for JS deobfuscation + URL/DOM
  phishing multimodal classifier (ONNX int4, GPU-pooled). Verdicts fed back as
  policy signals (downgrade-to-safe-html, block-input, terminate).
- Forensic artifact capture on trigger; content-addressed storage.
Exit: semantic detection demonstrably blocks a curated HTML-smuggling + runtime-
assembled-JS test corpus; false-positive rate within tenant-acceptable bounds.

### Phase 3 — Adaptive Hybrid Remoting (P1)
- Vector rendering agent PoC using public Skia PaintOp capture APIs.
- Viewer OffscreenCanvas replay library (clean-room, no competitor format reference).
- WebTransport transport for vector + signaling; WebRTC retained for pixel tier.
- Per-page/region mode selector (heuristic first, ML-assisted later).
- WebCodecs + SVC pixel agent replaces aiortc on hot path (Rust/Go).
- Safe-HTML fallback agent for ultra-degraded networks.
- SSO continuity bridge (WebAuthn-attested origin + IdP state relay).
Exit: vector tier meets density + bandwidth targets; pixel tier retains parity
for WebGL/video; fallback proven on lossy links.

### Phase 4 — Endpoint Co-Processing (P4)
- Policy bundle signing + distribution via gRPC streaming to SASE agent.
- Local URL/DOM risk classifier integrated with SWG decision hint path.
- Local QoE steerer (region/transport preference).
- Credential-entry step-up with WebAuthn; clipboard/print OS-layer gates.
- Watermarking option for regulated tenants.
Exit: ≥30% of isolation decisions short-circuited locally with measurable latency
improvement; measurable reduction in risky clipboard/print attempts.

### Phase 5 — Confidential Compute + Agent Principals (P3 full)
- SEV-SNP / TDX confidential VM worker tier.
- Attestation-gated secret release (signed image manifest; Sigstore-verified).
- BrowserPrincipal schema extended to non-human agents (AI agent sessions with
  constrained scopes, rate limits, audit trail, explicit consent gates).
- IL5/IL6-candidate deployment pattern documented.
Exit: confidential tier available for regulated and agent workloads; full audit
path from SWG decision to attestation verdict to artifact store.

### Phase 6 — Evidence Fabric + Long-Tail (P5 full)
- Content-addressed artifact store with per-tenant key material.
- eBPF-attested event streams on high-assurance hosts.
- Differential-privacy aggregation for customer-facing analytics.
- Defensive-publication pass on novel combinations.
Exit: forensics capability at parity with leading SSE vendors; customer-visible
analytics dashboard.

## Parallelism
- P1 rendering PoC (Phase 3) can start in parallel with P2 semantic engine
  (Phase 2) once Phase 0 gates pass. They share the CDP probe substrate.
- Endpoint agent work (P4) parallels Phases 1–3 after policy bundle format is
  frozen (end of Phase 0).
- Confidential compute (P3 full, Phase 5) parallels Phase 4 once microVM
  scheduler (Phase 1) is stable.

## Relevant files
- cloudsec_remote_browser/docs/rbi-arch.md — current runtime doc, superseded
  by Gen-2 SDD once written.
- cloudsec_remote_browser/app/server.js — control plane entry.
- cloudsec_remote_browser/shared/swg-handoff.js — handoff signing; swap to JWE.
- cloudsec_remote_browser/app/session-store.js — add sharding + admission.
- cloudsec_remote_browser/app/signal-bus.js — migrate to WebTransport.
- cloudsec_remote_browser/app/worker-runtime.js — narrow to one container
  adapter now; add microVM adapter in Phase 1; add confidential adapter Phase 5.
- cloudsec_remote_browser/worker/worker.py — prototype; replace with Go/Rust
  harness on hot path during Phase 3.
- cloudsec_remote_browser/viewer/* — add OffscreenCanvas replay module Phase 3;
  tighten CSP/COOP/COEP Phase 0.

## Verification
- Phase 0: chaos test TURN outage, Redis partition, SWG timeout → Menlo fallback
  within SLO. Pen test on handoff/JWE, viewer CSP bypass, input rate-limit.
- Phase 1: container escape test suite (CVE replay) in container tier vs microVM
  tier; cold-start p95 budget; egress policy red-team.
- Phase 2: HTML-smuggling corpus, Unit42-style runtime-JS-assembly corpus,
  phishing multimodal corpus; verdict latency + FP/FN curves.
- Phase 3: bandwidth A/B (vector vs pixel) on 50-site corpus; codec/SVC
  adaptation under induced loss; text legibility scoring; IdP SSO continuity.
- Phase 4: endpoint classifier FP/FN; decision short-circuit ratio; OS-layer
  clipboard/print gate functional tests; policy bundle signature tamper tests.
- Phase 5: attestation negative tests (tampered image → secret withheld);
  agent-principal scope-escape tests; IL5 control mapping review.
- Phase 6: dedup ratio on artifact store; DP epsilon budget review; defensive
  publication filings.

## Decisions captured
- Rendering strategy: tiered (vector primary for text/UI, pixel for rich media,
  safe-HTML for degraded). No monolithic choice.
- Transport strategy: WebTransport-first for new flows; WebRTC retained for
  pixel media; WebSocket only as fallback.
- Isolation strategy: two production tiers (microVM standard; confidential VM
  for regulated/agent). Container tier sunsetted by end of Phase 5.
- Identity strategy: BrowserPrincipal supports human + agent from day one.
- Fallback: deterministic Menlo fallback on any gate/SLO breach.
- IP strategy: clean-room on all rendering/attestation modules; FTO-gated.

## Further Considerations
1. Build-vs-buy on confidential compute tier: Firecracker+SEV-SNP in-house vs
   AWS Nitro Enclaves / GCP Confidential VMs. Recommendation: hybrid — Nitro
   for AWS footprint, custom Firecracker+SEV-SNP for sovereign/on-prem.
2. Worker harness language: Rust (best safety + density) vs Go (fastest to
   ship). Recommendation: Rust for rendering hot path, Go for orchestration.
3. Semantic inference placement: per-DC GPU pool vs per-worker sidecar.
   Recommendation: per-DC pool with per-tenant rate budget; sidecar only for
   regulated tenants with data-residency constraints.
