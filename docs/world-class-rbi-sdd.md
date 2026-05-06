# Remote Browser Isolation for SASE/SSE
## Target-State Product System Design Document (SDD)

**Document status:** Proposed target-state architecture  
**Audience:** Security architecture, platform engineering, product, SRE, compliance, legal/IP review  
**Scope:** World-class enterprise RBI capability integrated into a global SASE/SSE platform  
**Authoring note:** This document deliberately avoids vendor-specific protocols and proprietary implementation details. Any advanced non-pixel remoting work described here is **FTO-gated** and must not proceed without legal review.

---

## 1. Executive Summary

This SDD defines a production-grade RBI architecture for a SASE/SSE platform operating across **15+ data centers** and serving **100k to 2M+ endpoints**. The design is intentionally split into two tracks:

1. **Competitive GA track** that can be shipped safely and quickly using strong browser isolation, optimized pixel transport, a hardened policy/file/clipboard broker, regional media gateways, and a high-quality telemetry and forensics pipeline.
2. **Differentiation track** for advanced render acceleration and higher-assurance isolation, gated by legal/IP review and operational maturity.

The design goal is to provide:

- Strong endpoint protection from web-borne malware and zero-day browser exploitation.
- Low-friction enterprise usability for SaaS, internal apps, contractor access, and risky browsing.
- Tight integration with SWG, ZTNA, DLP, CASB, threat intelligence, and endpoint posture.
- Regional scale, observability, and fault containment suitable for a top-tier SASE offering.
- A clean legal posture that does **not** depend on copying or reverse-engineering competitor remoting methods.

### Strategic architecture decisions

- **Do not expose workers directly to viewers.** Terminate client transport at a **regional media gateway**.
- **Do not rely on containers alone** for the strategic isolation boundary. Use **VM-backed isolation** for production browsing sessions, with microVM or lightweight VM tiers depending on assurance requirements.
- **Do not retrofit data controls later.** Build **clipboard, file, print, upload, download, and extension controls** into the session contract from the start.
- **Do not make advanced vector/DOM remoting the GA dependency.** Keep a high-performance **pixel path** for GA and treat advanced render acceleration as an **FTO-gated plug-in renderer**.
- **Do not over-collect telemetry.** Build an **evidence fabric**: always-on metrics + trigger-based artifacts + deterministic sketches.

---

## 2. Product Goals, Non-Goals, and Design Principles

### 2.1 Goals

1. Protect endpoints and managed/unmanaged devices from active web content while preserving business usability.
2. Support policy-driven isolation for:
   - Unknown or risky internet destinations.
   - Sensitive internal web applications.
   - Third-party access to enterprise apps.
   - Download viewing and detonation workflows.
   - High-risk user groups, unmanaged devices, and contractor access.
3. Integrate natively with SWG, ZTNA, DLP, CASB, UEBA, and endpoint posture.
4. Provide strong operational economics at large enterprise scale.
5. Offer a credible roadmap to higher assurance, regional data residency, and government-aligned deployment profiles.

### 2.2 Non-goals

1. Full remote desktop or arbitrary application remoting.
2. Windows application compatibility inside the isolated runtime.
3. Blanket isolation of all browser traffic at 1M+ active sessions from day one.
4. Dependence on a proprietary local browser fork for MVP/GA.

### 2.3 Design principles

- **Security before convenience**, but not at the expense of unusability.
- **Explicit trust boundaries**; assume worker compromise is possible.
- **Regionality and data sovereignty** are first-class requirements.
- **Operational simplicity in the hot path**; complexity belongs in offline analysis and slow control planes.
- **Clean-room innovation**; no cloning of competitor thin clients, protocols, or rendering schemes.

---

## 3. IP, Patent, and Open-Source Guardrails

This section is mandatory. It is part of the product design, not legal boilerplate.

### 3.1 What this program must not do

1. **Do not reverse-engineer** competitor RBI clients, browser extensions, on-wire protocols, proprietary encodings, or draw-command formats.
2. **Do not reproduce patented methods** based on blog posts, white papers, product demos, or packet captures.
3. **Do not assume** that “vector rendering,” “adaptive rastering,” “DOM reconstruction,” “speculative rendering,” or “session forensics” are legally unencumbered implementation spaces.
4. **Do not build feature parity by imitation** of a named vendor implementation.

### 3.2 FTO-gated workstreams

The following workstreams require counsel-led **freedom-to-operate (FTO)** review before design freeze or implementation:

- Any renderer that reconstructs page output from remote compositing/display lists.
- Any clientless DOM reconstruction or semantic remoting of remote browser content.
- Any adaptive switching mechanism between DOM/vector/raster paths driven by remote compositing internals.
- Any “speculative rendering” or input prediction tied to surrogate browsing.
- Any browsing forensics mode that records keystrokes, page resources, or session replay artifacts beyond normal security logging.
- Any endpoint or remote extension framework that injects into isolated page execution contexts.

### 3.3 Clean-room engineering policy

1. Architecture team writes a **vendor-neutral functional specification**.
2. Implementation team receives only the neutral spec and open standards references.
3. Competitive intelligence material is segregated from implementers where necessary.
4. Legal reviews all candidate designs before implementation of FTO-gated features.
5. Maintain a written record of sources, prior art consulted, and design rationale.

### 3.4 Open-source policy

- Prefer permissive licenses for core runtime building blocks.
- Maintain SBOM, provenance, signature verification, and vulnerability scanning for browser images, kernels, microVM artifacts, and model bundles.
- No transitive dependency is allowed into the hot path without security review.

---

## 4. Assumptions and Capacity Envelope

### 4.1 Platform assumptions

- Global footprint: **15+ regions / data centers**.
- Tenant mix: commercial enterprise, regulated enterprise, public sector, and contractor/BYOD.
- Endpoint population: **100k to 2M+ protected devices**.
- Isolation is **policy-selective**, not universal, unless and until a legally cleared non-pixel accelerator materially changes economics.

### 4.2 Concurrency planning assumptions

The design must tolerate the following without customer-visible instability:

- **Normal concurrency:** 1–3% of protected endpoints in isolation.
- **Burst concurrency:** 5–10% for incident-driven or policy-driven campaigns.
- **Regional imbalance:** 2× short-term traffic skew into a subset of data centers.

### 4.3 Target SLOs

- **Warm session time to first visual response (TTFV):** p95 <= 2.5 s.
- **Cold session TTFV:** p95 <= 4.5 s.
- **Input echo latency:** p95 <= 120 ms intra-continent; p95 <= 220 ms inter-continent.
- **Session establishment success:** >= 99.5% monthly.
- **Policy action correctness:** >= 99.99% for allow/block/isolate routing.
- **Regional failover RTO for new sessions:** < 5 min.
- **Artifact availability for escalated sessions:** >= 99.9%.

### 4.4 Product posture by session class

- **Standard isolation:** general untrusted browsing.
- **Protected isolation:** sensitive SaaS and internal apps; stricter clipboard/file rules.
- **Assured isolation:** privileged users, admins, contractors, regulated tenants.
- **High-assurance isolation:** confidential-compute-backed tier for select tenants and specific workflows, subject to platform support.

---

## 5. High-Level Architecture

### 5.1 Major planes

1. **Decision plane** – SWG, ZTNA, CASB, DLP, policy engine, endpoint posture, threat intelligence.
2. **Session control plane** – session admission, token service, region selection, quota enforcement, scheduler control, config distribution.
3. **Render and interaction plane** – viewer, media gateway, render abstraction layer, input broker, session runtime.
4. **Data control plane** – clipboard broker, file broker, print broker, download viewer, upload staging, extension controls.
5. **Evidence plane** – telemetry bus, sketches, semantic deltas, artifacts, search and forensics.

### 5.2 Regional topology

Each region contains:

- **Regional ingress** for viewer bootstrap and API traffic.
- **Regional media gateway cluster** for viewer-facing low-latency transport.
- **Regional session admission cache** and ephemeral state store.
- **Regional session scheduler** for VM-backed workers.
- **Worker host pool** segmented by trust tier.
- **Regional evidence collector** and telemetry forwarder.
- **Regional DLP/file processing path** for uploads/downloads.

Global services provide:

- Tenant config distribution.
- Billing and entitlements.
- Long-term evidence storage and analytics.
- Global policy references and software/image release metadata.
- Cross-region control-plane health and failover orchestration.

### 5.3 Critical change from the current design

The viewer must **not** establish a direct session with the worker as the default data path. Instead:

- The viewer connects to a **regional media gateway**.
- The media gateway connects to the assigned worker over an internal, policy-constrained transport.
- Worker IPs are never exposed to clients.
- Viewer NAT traversal, QoE, policy, observability, abuse controls, and failover become tractable.

---

## 6. Detailed Component Design

## 6.1 Endpoint Agent and Local Steering

### Responsibilities

- Device posture collection.
- Local risk hinting for navigation events.
- Region affinity selection and health cache.
- Optional isolate recommendation for degraded WAN or high-risk destinations.
- Enforcement support for clipboard, print, file, and screenshot policies when local cooperation is required.

### Local model

Deploy a small, signed model bundle to the endpoint agent for:

- URL lexical analysis.
- Known-brand phishing heuristics.
- Destination novelty.
- User-role/device-posture weighting.
- Browser process anomaly hints.

The local model **does not make final policy**. It emits a risk hint consumed by SWG/policy. This cuts decision latency and provides resilience under partial loss of cloud reachability.

### Implementation details

- Model format: ONNX or equivalent.
- Update cadence: daily or on-demand.
- Runtime budget: < 20 ms p95 on supported endpoints.
- Output schema: `{risk_hint, reasons[], model_version, confidence}`.
- Agent policy cache TTL: 5 min hard, 1 min soft refresh.

---

## 6.2 SWG and Policy Engine Integration

### Isolation decision inputs

- URL/domain category.
- Threat intel score.
- Destination age and reputation.
- User identity and group.
- Device posture and agent hint.
- Session context: managed/unmanaged, location, network risk.
- App sensitivity and DLP tags.
- Tenant policy profile.

### Policy outputs

- `ALLOW`
- `BLOCK`
- `ISOLATE_STANDARD`
- `ISOLATE_PROTECTED`
- `ISOLATE_ASSURED`
- `OPEN_IN_REMOTE_VIEWER` for documents/downloads

### Bootstrap API

SWG calls:

`POST /v2/rbi/sessions`

Request fields:

- tenant_id
- user_id
- device_id
- policy_ref
- action_class
- target_url
- requested_region
- posture_claims_hash
- dlp_profile_ref
- correlation_id
- traceparent
- isolate_reason_codes[]
- client_capabilities (browser family/version, codecs, WebRTC, WebTransport, WebCodecs, clipboard API posture)

### Security

- Request authenticated with **mTLS + signed JWT** from SWG.
- Payload fields with sensitive context are **encrypted at application layer** where needed.
- No plaintext target or policy metadata is placed in redirect query parameters.

---

## 6.3 Session Admission Service

This is the control-plane brain for new and resumed sessions.

### Responsibilities

- Validate entitlements.
- Apply quota and abuse controls.
- Choose region, worker tier, and transport profile.
- Allocate session ID and token bundle.
- Attach telemetry/trace context.
- Determine render mode and data-control defaults.

### Region selection algorithm

Inputs:

- Endpoint region/latency estimate.
- Data residency constraints.
- Regional capacity headroom.
- Application locality for internal apps.
- Tenant routing policy.
- Warm-pool availability.

Outputs:

- `selected_region`
- `worker_class`
- `transport_profile`
- `fallback_regions[]`

### Admission controls

- Max concurrent sessions per tenant.
- Max session creation rate per tenant and per identity.
- Burst budget per region.
- Kill switch and deny-list for destinations, users, devices, and tenants.
- Controlled fallback to incumbent provider or native block page if RBI capacity is exhausted.

---

## 6.4 Regional Media Gateway

This component is mandatory in the target-state architecture.

### Responsibilities

- Terminate viewer-facing transport.
- Enforce client auth and session binding.
- Apply per-session QoE and bandwidth policy.
- Hide worker topology from the client.
- Bridge the viewer to the worker’s render/input channels.
- Emit precise media metrics.

### Why it exists

Direct viewer-to-worker connectivity causes avoidable problems:

- Worker address exposure.
- Weak observability.
- TURN abuse risk.
- Hard session migration.
- Difficult DDoS and quota control.
- Mixed trust boundary between internet clients and worker hosts.

### Transport support

- **GA path:** WebRTC from viewer to media gateway.
- **Internal path:** SRTP/QUIC or low-latency internal RTP from media gateway to worker.
- **Optional future path:** WebTransport for specific control/vector channels or server-anchored media workloads after maturity validation.

### Features

- Relay-only mode per tenant.
- Candidate filtering and network policy enforcement.
- Jitter buffer tuning by session class.
- Frame pacing and bitrate adaptation by app profile.
- Session transfer token to allow worker replacement without full client restart where feasible.

---

## 6.5 Session Runtime and Isolation Boundary

### 6.5.1 Worker classes

#### Worker Class S: Standard VM-backed session

- Linux guest image with hardened Chromium.
- Ephemeral root/overlay.
- Standard SWG egress.
- Suitable for general untrusted browsing.

#### Worker Class P: Protected session

- Stricter local feature lockdown.
- Stronger file/clipboard controls.
- Separate host pool and tighter egress rules.
- Used for sensitive SaaS and internal apps.

#### Worker Class A: Assured session

- Dedicated host pool or stronger placement policy.
- Remote attestation of approved image hash before secrets release.
- Restricted extensions, stricter evidence capture, and stronger DLP enforcement.

#### Worker Class H: High-assurance session

- Confidential-compute-backed lightweight VM where platform support is production-ready.
- Attestation gate for session secret release.
- Reserved for select workloads and regulated tenants.

### 6.5.2 Runtime choice

The strategic target is **VM-backed isolation**. Acceptable implementations include:

- Lightweight VM / microVM scheduler on dedicated hosts.
- OCI-compatible VM runtime where security and density are acceptable.

Raw containers on shared host kernels are acceptable for internal dev/test only and are **not** the strategic production boundary.

### 6.5.3 Guest image design

- Read-only base image.
- Ephemeral writable overlay in tmpfs or short-lived encrypted scratch volume.
- Pre-installed hardened browser binary and runtime libs.
- Minimal userspace, no package manager in production image.
- Separate image channels: stable, canary, emergency.

### 6.5.4 Browser hardening baseline

- Site isolation enforced.
- Unneeded browser services disabled.
- No user sync or cloud account coupling.
- No persistent local storage across sessions unless policy explicitly requires a temporary isolation workspace.
- DevTools access disabled for end users.
- Explicit allowlist for browser features such as camera, mic, WebUSB, local fonts, and local file access.
- Restricted extension model; only signed and policy-approved remote extensions.

### 6.5.5 Warm pools and startup

- Maintain warm pools per region for each worker class.
- Pre-warm browser process and profile skeletons.
- Attach user session only after token validation.
- Recycle warm instances after configurable TTL or patch generation change.

Warm-pool targets:

- 70%+ of enterprise traffic should hit a warm worker under normal steady-state.
- Cold starts are acceptable only under burst or regional recovery conditions.

---

## 6.6 Render Abstraction Layer (RAL)

The RAL is the long-term product hedge against transport and economics risk.

### GA-safe renderer modes

#### Mode 1: Pixel-RTC

- Full raster output from remote browser.
- Encoded on the worker or an internal encoder sidecar.
- Viewer receives stream via media gateway.
- Primary path for GA and universal compatibility.

#### Mode 2: Pixel-RTC with semantic assists

- Same as Mode 1, but with optional out-of-band semantic signals for:
  - text selection hints,
  - accessibility annotations,
  - form-field typing optimizations,
  - remote clipboard mediation,
  - local cursor prediction.

This improves UX and policy fidelity without requiring a patented clientless renderer.

### FTO-gated renderer modes

#### Mode 3: Advanced render acceleration

- Generic placeholder for future non-pixel rendering or partial client-side replay.
- Not part of GA dependency.
- Requires dedicated legal review, design review, and clean-room implementation controls.

### Mode selection policy

Mode is chosen by session admission using:

- tenant entitlement,
- legal/FTO enablement,
- app compatibility profile,
- browser capability,
- network quality,
- region feature flags.

---

## 6.7 Pixel Transport and QoE

### Viewer-facing pixel transport profile

- Current implementation default: **VP8** for gateway WebRTC/SRTP compatibility.
- H.264 can remain an explicit rollback or compatibility override, but it is not in
  the default worker preference list.
- Optional enhancement on capable endpoints: **AV1 pilot** under explicit feature flag.
- Avoid making HEVC/H.265 a core dependency.

### Content classes

1. **Text/UI class** – low frame rate, aggressive quality for text sharpness.
2. **Office/canvas class** – higher frame pacing, adaptive bitrate.
3. **Media/video class** – allow higher bitrate or remote-view-only policy depending on tenant.
4. **Protected internal app class** – prioritize fidelity and input latency over visual richness.

### QoE controller

The media gateway owns:

- target bitrate,
- frame rate cap,
- keyframe interval,
- congestion response,
- path switch thresholds,
- rebuffer policies,
- user-visible degraded mode triggers.

### Degraded modes

When network quality drops:

1. reduce frame rate,
2. preserve text sharpness,
3. disable high-motion enhancements,
4. fall back to protected read-only mode for critical operations,
5. allow user or policy to reopen in remote document viewer if the page is primarily document content.

---

## 6.8 Identity, SSO, and Session Continuity

### Problems to solve

- Existing non-isolated cookies do not automatically apply to remote sessions.
- IdP redirects can break if the app is isolated but the IdP is not.
- Users distrust visible origin changes.

### Design

1. **Opaque handoff token** instead of query-rich redirect.
2. **IdP isolation map** maintained per tenant and app profile.
3. **Session continuity broker** for enterprise apps where tenant policy allows it.
4. **App origin policy** supporting three models:
   - external web isolation,
   - internal app isolation via ZTNA connector,
   - remote document view mode.

### Rules

- If an isolated app relies on third-party IdP cookies, isolate the IdP path as part of the app profile.
- Maintain user-facing URL transparency only where technically safe and policy-approved.
- Explicitly tag all telemetry with `session_origin_mode` to debug auth issues.

---

## 6.9 File, Clipboard, Print, and Upload/Download Broker

This broker is core product surface, not a later bolt-on.

### 6.9.1 Clipboard broker

#### Capabilities

- Copy remote -> local
- Paste local -> remote
- Copy/paste only within isolated sessions
- Data-type restrictions: text/plain, text/html, images, files, custom formats
- Regex/content/DLP scanning on both directions
- Audit trails with policy reason codes

#### Controls

- Per-tenant and per-app directionality
- Size limits
- MIME/type whitelist
- redaction or block on detected sensitive data
- local agent assist when browser clipboard APIs are constrained

### 6.9.2 Download broker

All downloads take one of four paths:

1. **Block**
2. **View in remote browser / remote document viewer**
3. **Quarantine and detonate**
4. **Allow to local device after broker approval**

#### Download flow

1. Remote browser writes file to session scratch.
2. Worker submits file descriptor to file broker over internal API.
3. File broker computes hash, type, entropy, archive structure.
4. Type detection via signature + ML classifier.
5. Route to AV/CDR/sandbox pipeline according to policy.
6. Return verdict and permitted disposition.

### 6.9.3 Upload broker

Uploads from local to remote pass through staged upload controls:

- local agent assist where present,
- browser file picker mediation where possible,
- DLP and malware scan,
- size/type restrictions,
- optional content fingerprinting.

### 6.9.4 Print broker

- disable by default for high-risk sessions,
- allow to PDF only where policy permits,
- watermark and classify generated output,
- route generated file through same broker as downloads.

### 6.9.5 File intelligence stack

- signature-based type detection,
- ML-backed type classification,
- archive and nested archive inspection,
- password-protected archive detection,
- CDR for supported document types,
- sandbox detonation for ambiguous or suspicious content.

---

## 6.10 Runtime Threat Engine

RBI prevents endpoint compromise, but it does not inherently prevent credential theft or data misuse. A runtime threat engine is required.

### Sensors

Collect structured events from the isolated browser runtime:

- navigation and redirect chain,
- form creation and password field detection,
- WebAuthn invocation,
- Blob/data URL usage,
- download attribute use,
- service worker registration,
- clipboard APIs,
- File System Access API,
- suspicious cross-origin messaging,
- DOM mutations associated with overlays or credential lures,
- script creation/evaluation patterns,
- WebAssembly instantiation,
- network beacons and exfil patterns.

### Detection layers

1. **Deterministic rules** for well-known abuse.
2. **Statistical models** for phishing and anomaly scoring.
3. **Selective LLM-assisted analysis** on suspicious script bundles or session traces.
4. **Threat intel joins** on domains, brands, and indicators.

### Policy actions

- mark session read-only,
- block keyboard input to sensitive forms,
- require step-up auth,
- terminate session,
- force download/viewer-only mode,
- create forensic artifact bundle,
- escalate to SOC.

### Design constraint

LLM-based analysis is advisory at first. It must not be the sole inline blocking control until validated at production precision/latency.

---

## 6.11 Remote Extensions and App Compatibility

### Remote extensions

- Extensions run only in the remote browser.
- Only tenant-approved, signed, and scanned extensions are permitted.
- Persist extension list at tenant/user scope if allowed.
- Extension actions are auditable.

### App compatibility profiles

Maintain a profile catalog for common destinations and app families:

- Microsoft 365
- Google Workspace
- Salesforce
- ServiceNow
- internal apps via ZTNA
- common IdPs
- finance and admin portals

Each profile defines:

- preferred worker class,
- codec/QoE settings,
- clipboard and file policy,
- SSO behavior,
- browser feature flags,
- expected domains and subresources,
- evidence verbosity.

---

## 6.12 Networking and Egress Controls

### Worker egress

Workers never egress directly to the internet without policy mediation.

- External web traffic egresses via SWG-controlled proxy stack.
- DNS resolution goes through controlled, logged resolvers or DoH/DoT under enterprise policy.
- Internal app traffic goes through ZTNA/private app connectors.
- Per-session egress allow/deny and rate-limiting apply.

### Media plane

- Viewer-facing media terminates at regional media gateway.
- TURN, where used, is region-local and quota-controlled.
- TURN credentials are short-lived and bound to session and destination policy.
- Peer destination restrictions apply.

### Abuse controls

- allocation quotas,
- bandwidth caps,
- per-tenant max relay usage,
- anomaly detection for relay abuse,
- worker-side egress anomaly detection.

---

## 6.13 Viewer Security

The viewer is an attack surface and must be treated as a hardened web application.

### Requirements

- Strict CSP.
- `frame-ancestors 'none'` unless explicitly embedded by policy.
- Trusted Types.
- Subresource Integrity for static assets where applicable.
- COOP/COEP where compatible.
- CSRF protection on all mutating endpoints.
- `__Host-` prefixed secure cookies.
- Same-origin and `Sec-Fetch-*` enforcement.
- Input rate limiting and anomaly detection.
- Full content security review for third-party JS: default deny.

### Token model

- Opaque handoff token: JWE or equivalent AEAD-wrapped blob; TTL <= 60 s.
- Viewer session token: cookie-bound, short TTL, rotation on reconnect.
- Worker token: never exposed to client.
- Generation counter to prevent stale-worker or stale-viewer claim.

---

## 6.14 Data Model and State Stores

### State categories

1. **Global config state** – tenant config, app profiles, entitlements, image channels.
2. **Regional ephemeral state** – session liveness, socket/gateway claims, media stats, admission caches.
3. **Evidence metadata** – artifact references, verdicts, hashes, search keys.
4. **Long-term analytics** – aggregated metrics and retained evidence under policy.

### Storage recommendations

- Global config: strongly consistent distributed store.
- Regional ephemeral state: in-memory or low-latency KV store per region.
- Evidence/object storage: content-addressed blob store.
- Event pipeline: durable message bus.

### Design rules

- Session liveness is region-local first.
- Do not make global databases part of the media hot path.
- Artifact references should be immutable and content-addressed.

---

## 6.15 Telemetry, Evidence, and Forensics

### 6.15.1 Evidence model

Three telemetry classes:

1. **Always-on operational metrics**
   - TTFV, session duration, bitrate, loss, reconnects, policy latency, relay ratio.
2. **Structured semantic events**
   - clipboard actions, download attempts, risky DOM features, credential entry, IdP redirects.
3. **Trigger-based artifacts**
   - screenshot, DOM snapshot, network trace summary, downloaded objects, JS bundles, redacted HAR-like evidence.

### 6.15.2 Pipeline

- Edge collectors publish via gRPC to the regional telemetry bus.
- Regional bus forwards to central lakehouse/search pipeline.
- Use deterministic sketches and histograms to reduce ingest volume.
- Full-fidelity artifacts only on risk triggers, sampling, or explicit admin policy.

### 6.15.3 Trace model

Every session and sub-operation carries:

- session_id
- tenant_id
- region
- worker_class
- viewer_transport
- app_profile
- policy_ref
- trace_id / span_id
- evidence_level

### 6.15.4 Privacy and governance

- Capture policies are configurable by tenant, user group, app, and risk level.
- Sensitive fields are redacted or tokenized before long-term retention.
- Artifact encryption keys are tenant-scoped or region-scoped depending on policy.
- Customer-controlled storage option for regulated tenants.

---

## 6.16 Observability and Admin Experience

### Operator views

- Regional capacity and burn rate
- session establishment funnel
- relay/TURN ratio
- p50/p95/p99 TTFV
- codec split
- QoE heatmap
- app compatibility failures
- DLP/clipboard/file broker actions
- runtime threat verdicts
- worker image/channel drift

### Customer-facing analytics

- isolated session counts
- risky destinations isolated
- blocked clipboard/download/upload actions
- policy impact by user/app/category
- session latency and app health insights
- browsing forensics timeline for selected incidents

---

## 7. Security Architecture and Threat Model Summary

### 7.1 Threats addressed

- endpoint malware delivery via web content
- browser zero-days and exploit kits
- HTML smuggling and in-browser payload assembly
- phishing credential theft and malicious input prompts
- malicious downloads and staged archives
- data exfiltration via clipboard, file transfer, print, or uploads
- cross-tenant escape and worker abuse
- relay/TURN abuse

### 7.2 Residual risks

- users can still be socially engineered unless runtime threat controls and identity protections are enabled
- high-motion or GPU-heavy apps may remain costly in pixel mode
- confidentiality against a malicious cloud operator requires additional platform measures beyond ordinary VM isolation
- compatibility for media/WebGL/WebGPU/video-conference workloads remains constrained

### 7.3 Key hardening requirements

- VM-backed isolation
- remote attestation where enabled
- controlled DNS and egress
- viewer web security hardening
- no plaintext metadata in redirects
- per-session short-lived secrets
- explicit abuse controls on media/relay plane
- signed images and measured boot chain

---

## 8. APIs and Session Contracts

## 8.1 Session create request (conceptual)

```json
{
  "tenant_id": "t_123",
  "user_id": "u_456",
  "device_id": "d_789",
  "policy_ref": "policy://rbi/protected-v3",
  "action_class": "ISOLATE_PROTECTED",
  "target_url": "https://example-app.com/",
  "requested_region": "ap-south-1",
  "posture_claims_hash": "sha256:...",
  "dlp_profile_ref": "dlp://finance/high",
  "correlation_id": "corr_...",
  "client_capabilities": {
    "browser_family": "Chrome",
    "browser_major": 136,
    "webrtc": true,
    "webtransport": true,
    "webcodecs": true,
    "clipboard_api": true
  },
  "reasons": ["unknown-domain", "unmanaged-device"]
}
```

## 8.2 Session create response (conceptual)

```json
{
  "session_id": "sess_...",
  "region": "ap-south-1",
  "worker_class": "P",
  "viewer_entry": "https://rbi.example.com/h/opaque_token",
  "expires_in_sec": 60,
  "qoe_profile": "office-standard",
  "controls": {
    "clipboard": "remote_only",
    "downloads": "view_remote",
    "uploads": "brokered",
    "print": "deny"
  }
}
```

## 8.3 Session lifecycle states

- `CREATED`
- `ADMITTED`
- `WORKER_ASSIGNING`
- `WARM_ATTACHING` or `COLD_STARTING`
- `VIEWER_READY`
- `STREAMING`
- `DEGRADED`
- `QUARANTINED`
- `TERMINATING`
- `TERMINATED`
- `FAILED`

---

## 9. Capacity Planning and Admission Control

### 9.1 Worker density planning

Do not size on peak theoretical codec throughput. Size on:

- browser RSS,
- encode CPU,
- page complexity,
- worker class,
- artifact capture load,
- broker interactions,
- network egress,
- patch generation skew.

Use three capacity metrics per region:

1. **Browser slots**
2. **Media slots**
3. **Broker slots**

The admission service must deny or reroute when any of the three becomes the bottleneck.

### 9.2 Regional admission behavior

When thresholds are crossed:

1. prefer warm workers in secondary region if residency allows,
2. downgrade to stricter low-bandwidth profile,
3. isolate only explicit high-risk flows,
4. fail over to incumbent provider or block page according to tenant policy,
5. never accept sessions that cannot maintain minimum security guarantees.

### 9.3 Key dashboards for capacity

- sessions per worker host
- CPU per session class
- memory per active browser
- bitrate per app profile
- relay percentage
- broker queue depth
- evidence storage ingest rate
- app profile error rate

---

## 10. Failure Handling, Recovery, and Chaos Requirements

### 10.1 Failure domains

- viewer/browser failure
- media gateway node failure
- worker guest failure
- worker host failure
- regional state-store degradation
- DLP/file broker outage
- telemetry pipeline backpressure
- global config lag

### 10.2 Recovery behavior

- media gateway failure: reconnect to same session via replacement gateway where possible.
- worker failure before sensitive input: restart from warm pool and restore URL if policy permits.
- worker failure after sensitive interaction: fail closed or require re-auth depending on policy.
- broker outage: downloads/uploads/clipboard default to deny or remote-view-only.
- telemetry backpressure: degrade artifact capture before dropping control-plane metrics.

### 10.3 Chaos tests

- kill active worker hosts
- exhaust TURN/media quotas
- inject packet loss and bandwidth collapse
- break regional KV store quorum
- revoke image attestation policy mid-session
- simulate browser 0-day requiring emergency image rollout

---

## 11. Compliance and High-Assurance Profile

### 11.1 Baseline enterprise controls

- strong identity binding
- tenant isolation
- detailed audit logging
- key management and encryption at rest/in transit
- retention control and region pinning
- role-based administration and break-glass controls

### 11.2 High-assurance enhancements

- attested worker boot chain
- optional confidential-compute runtime where supported
- customer-managed keys for evidence and artifacts
- stricter admin dual-control for capture policies
- private-region or dedicated-host deployment option

### 11.3 Important caveat

VM isolation and attestation materially improve assurance, but they do **not** by themselves satisfy government accreditation or zero-trust requirements. Full control mapping, operational processes, logging, identity, and platform hardening are still required.

---

## 12. Implementation Phases

## Phase 0: Current Runtime Hardening (0–10 weeks)

### Objective

Convert the existing runtime from a prototype into a safely canaried service.

### Deliverables

- Replace query-rich handoff with opaque encrypted handoff token.
- Harden viewer: CSP, frame protections, CSRF, cookie model, input rate limits.
- Introduce regional media gateway in front of workers.
- Enforce worker egress through SWG-controlled paths and controlled DNS.
- Define file/clipboard/print/upload broker APIs, even if initially set to deny.
- Region-local admission quotas and better SLO instrumentation.
- Per-session trace IDs and telemetry schema.
- Transparent fallback to incumbent RBI provider when session create or establish fails.

### Exit criteria

- 30-day canary with no critical auth bypass or worker exposure issues.
- p95 TTFV, relay ratio, and establish-success dashboards in place.
- Security review passed for viewer, token model, and worker networking.

## Phase 1: Competitive Enterprise GA (2–5 months)

### Objective

Ship a market-credible RBI product for selective isolation use cases.

### Deliverables

- VM-backed worker tier for production sessions.
- Warm pools and regional scheduler.
- Clipboard broker with directional policies.
- Download/upload broker with AV/CDR/sandbox integration.
- Identity continuity support for common IdP patterns.
- App profile catalog for top SaaS and internal app patterns.
- Runtime threat engine v1: rules + statistical phishing scoring.
- Customer-facing analytics for policy actions and user friction.

### Exit criteria

- 10+ enterprise design partners in production.
- Stable support for external risky browsing + protected SaaS + internal app isolation.
- p95 warm TTFV <= 2.5 s for target geographies.

## Phase 2: Enterprise Parity+ (5–9 months)

### Objective

Close key UX and operations gaps against leading RBI products.

### Deliverables

- Remote extension support with strict approval workflow.
- Better SSO/IdP mapping and app compatibility tooling.
- Remote document viewer and “open in remote” workflow for common file types.
- Runtime threat engine v2 with HTML smuggling and runtime assembly detectors.
- Browsing evidence model with selective screenshots, DOM snapshots, and JS bundle capture.
- QoE controller with content-class tuning.
- Endpoint agent risk hinting and regional steering.

### Exit criteria

- Reduced help-desk volume for auth, clipboard, and downloads.
- Evidence pipeline supports SOC triage for selected incidents.
- Strong operational visibility into session failures by app profile and geography.

## Phase 3: Differentiation Program (9–15 months)

### Objective

Create defensible advantages beyond table-stakes RBI.

### Deliverables

- Assured worker tier with remote attestation and separate host pools.
- Confidential-compute pilot where platform support is mature.
- LLM-assisted analysis pipeline for suspicious JS/session traces under strict latency guardrails.
- Advanced app-specific QoE and low-bandwidth modes.
- Customer-controlled evidence storage option.
- Optional remote step-up/credential guard actions on detected phishing behavior.

### Exit criteria

- Demonstrated protection against runtime-assembled browser attacks in controlled validation.
- Assured tier adopted by privileged and contractor use cases.

## Phase 4: FTO-Gated Advanced Rendering (parallel R&D, not critical path)

### Objective

Evaluate legally safe render acceleration options that materially improve economics and UX.

### Preconditions

- Legal FTO completed.
- Clean-room design package approved.
- Separate engineering workstream from GA product delivery.

### Deliverables

- RAL plug-in interface finalized.
- Prototype advanced renderer behind lab-only flag.
- App-compatibility matrix and bandwidth/latency comparisons.
- Go/No-go review with legal, product, and architecture.

### Exit criteria

- Clear legal posture.
- Measurable gains over pixel mode.
- No regressions in DLP, accessibility, or auth flows.

---

## 13. What to Ship First vs. What to Defer

### Ship first

- regional media gateway,
- opaque handoff token,
- viewer hardening,
- VM-backed workers,
- worker egress and DNS control,
- file and clipboard broker,
- app profiles,
- runtime threat engine v1,
- evidence and tracing pipeline,
- warm pools and region admission control.

### Defer until validated or legally cleared

- non-pixel clientless rendering,
- broad session replay / keystroke forensics,
- browser fork strategy,
- full confidential-compute scale-out,
- inline LLM-only blocking decisions.

---

## 14. Final Architecture Recommendation

For a market-leading but legally safe product trajectory:

1. **Build the best possible pixel-based enterprise RBI first**, not the most exotic renderer.
2. **Move the isolation boundary to VM-backed sessions** and place a **media gateway** between the internet and workers.
3. **Treat data controls and runtime detection as core**, not add-ons.
4. **Exploit the broader SASE platform**: SWG, ZTNA, DLP, endpoint agent, telemetry bus, and threat intel.
5. **Run advanced rendering as an FTO-gated R&D stream**, not as the foundation of GA.

This path yields a product that is competitive in the near term, operationally defensible at enterprise scale, and capable of becoming differentiated without creating avoidable IP risk.
