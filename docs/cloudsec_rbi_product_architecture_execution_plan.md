% cloudsec Remote Browser Security Platform
% Product Architecture and End-to-End Execution Plan
% Version 1.0 - Proposed target state

**Document status:** Proposed architecture and execution plan  
**Audience:** Product architecture, platform engineering, browser/runtime engineering, SRE, security engineering, compliance, legal/IP review, executive sponsors  
**Supersedes:** `cloudsec_remote_browser/docs/rbi-arch.md`  
**Program intent:** Deliver an enterprise-grade, SASE-native remote browser security platform that is competitive at GA and extensible toward higher-assurance and advanced rendering modes without avoidable IP or patent exposure.

\newpage

# 1. Executive summary

This document defines the product architecture, implementation strategy, and phased execution plan to evolve `cloudsec_remote_browser` from a Gen-1 pixel-streamed RBI runtime into a Gen-2 browser security platform integrated into a global SASE/SSE fabric.

The target product is not "just an isolated browser." It is a policy-driven browsing control plane with the following properties:

- Regional, multi-tenant scale suitable for 100k to 2M+ protected endpoints.
- Strong isolation boundaries for commodity, high-risk, and regulated traffic.
- Tight integration with SWG, ZTNA, DLP, CASB, UEBA, endpoint posture, threat intel, and data lake analytics.
- Low-friction enterprise usability for modern SaaS and internal web apps.
- A runtime semantic threat engine that inspects behavior inside the isolated session instead of relying on URL/category alone.
- An evidence fabric that supports customer analytics, detections, triage, and forensics without shipping every session artifact by default.
- A clean legal posture: competitive GA does not depend on cloning any competitor remoting method or on entering FTO-sensitive feature areas before counsel approval.

## 1.1 Product strategy in one sentence

Ship the best enterprise-grade, VM-backed pixel RBI first, make the session semantically aware and operationally excellent, then add accelerated rendering only as an optional, clean-room, FTO-gated enhancement.

## 1.2 Non-negotiable strategic decisions

1. **Viewer traffic must terminate at a regional media gateway, not at workers.**
2. **GA must not depend on advanced vector or clientless rendering.**
3. **Production browsing isolation must converge on VM-backed workers.**
4. **Clipboard, file, upload, download, print, and extension controls must be designed now, not bolted on later.**
5. **Confidential-compute and attestation are distinct from host telemetry; eBPF is evidence, not the attestation root.**
6. **FTO/IP review is a gating input for renderer acceleration work, not an afterthought.**

## 1.3 Outcome by phase

- **Competitive GA:** hardened regional pixel RBI with media gateway, microVM standard tier, file and clipboard brokers, runtime rules, evidence pipeline, app certification, and strong SLOs.
- **Enterprise parity+:** endpoint co-processing, richer SaaS/IdP continuity, remote extension curation, customer-visible analytics, and assured workloads.
- **Differentiation:** confidential-compute tiers, attestation-gated secret release, non-human BrowserPrincipal support, and FTO-cleared renderer acceleration.

\newpage

# 2. Scope, goals, assumptions, and non-goals

## 2.1 In-scope

This plan covers:

- Product architecture for internet and internal web isolation inside a broader SASE/SSE platform.
- End-to-end control, signaling, media, data-control, and telemetry flows.
- Runtime choices across control services, media/data plane, worker isolation, endpoint integration, and storage.
- Program phases, exit criteria, dependencies, test strategy, and operational requirements.
- IP/FTO, open-source, compliance, and release-engineering guardrails.

## 2.2 Goals

The product must:

1. Protect managed and unmanaged endpoints from active web content and browser-borne exploitation.
2. Preserve business workflows for common SaaS and internal web apps.
3. Support selective isolation at global scale without exploding bandwidth or compute cost.
4. Provide differentiated controls for commodity, sensitive, privileged, and regulated browsing.
5. Expose enough telemetry and evidence to support policy tuning, incident response, and forensics.
6. Integrate naturally into an industry-grade SWG/ZTNA/CASB/DLP stack.
7. Preserve optionality for future renderer acceleration and assured-compute tiers.

## 2.3 Assumptions

- Global footprint of at least 15 data centers or equivalent cloud regions.
- Existing SASE platform already has policy distribution, identity integration, endpoint agents, DLP/CDR/AV infrastructure, and streaming telemetry paths.
- Isolation is policy-selective, not universal, at least through GA.
- Different customers will require different residency, assurance, and third-party fallback policies.

## 2.4 Non-goals

- Full remote desktop for arbitrary applications.
- Windows desktop application compatibility inside the RBI runtime.
- A proprietary enterprise browser fork as the primary product strategy.
- Blanket vector/clientless rendering in the initial release.
- Open-ended browser-extension support sourced directly from public extension stores.

## 2.5 Design principles

- **Trust boundaries are explicit.** Treat workers as potentially compromised and design containment around that assumption.
- **Data control is part of the session contract.** Upload, download, clipboard, print, and extension surfaces are first-class APIs.
- **Operational simplicity in the hot path.** Keep latency-sensitive planes small and deterministic.
- **Policy and telemetry must be regional by default.** Global services exist for distribution, not for synchronous handoffs.
- **Standards where possible, proprietary where necessary, imitation nowhere.**

\newpage

# 3. IP, patent, and open-source guardrails

This section is mandatory and blocking.

## 3.1 Program rules

1. No reverse engineering of competitor viewer clients, browser extensions, wire formats, or remote-render protocols.
2. No design work that reproduces a named vendor's proprietary remoting, reconstruction, or session-forensics scheme from demos, blog posts, packet captures, or trial software.
3. No assumption that public Chromium or Skia APIs create freedom to operate. They are technical substrates, not legal safe harbors.
4. All FTO-sensitive features require a written design review with legal before code freeze.
5. All source code in FTO-sensitive modules requires provenance recording, license scanning, and documented implementation sources.

## 3.2 FTO-sensitive feature families

These workstreams are blocked behind counsel-led FTO review:

- Draw-command remoting and compositor/display-list transport.
- DOM-diff streaming or clientless DOM reconstruction.
- Hybrid remoting that switches between semantic and raster transports based on compositor or layout internals.
- Session replay or browsing-forensics features that capture semantically rich user/session state beyond ordinary security logging.
- Browser-origin bridging mechanisms that replicate local-origin cookie continuity for remote sessions.
- Advanced remote extension models that execute privileged logic in or adjacent to isolated page contexts.

## 3.3 Clean-room process

1. Architecture writes a vendor-neutral functional specification.
2. Legal designates approved source materials.
3. Implementers receive only the neutral spec and approved open standards or official platform documentation.
4. Code reviewers confirm provenance records and implementation notes before merge.
5. Within 90 days of any novel, potentially protectable design, engineering files an invention disclosure; legal decides patent filing, defensive publication, or trade-secret treatment.

## 3.4 Open-source policy

- Only permissive or otherwise pre-approved licenses may enter shipped runtime or agent code.
- No GPL or AGPL components in distributed binaries unless separately approved.
- Browser images, kernels, VMM binaries, models, and control-plane services must emit SBOMs and provenance attestations.
- Contractors and LLM-generated code are subject to the same provenance and review rules as employee-authored code.

\newpage

# 4. Product architecture overview

## 4.1 Architecture at a glance

![Target architecture](rbi_architecture_overview.png)

## 4.2 Major planes

The target system is organized into six planes.

### A. Decision plane

- SWG, ZTNA, CASB, DLP, UEBA, and threat-intel inputs.
- Evaluates destination, user identity, device posture, risk, tenant policy, and app profile.
- Produces an isolate/allow/block/view-only decision and selects feature gates.

### B. Control plane

- Bootstrap service, identity service, session authority, admission control, quota, routing, and scheduler APIs.
- Generates opaque handoff tokens and session metadata.
- Maintains the session lifecycle state machine.

### C. Render and interaction plane

- Viewer client.
- Regional media gateway.
- Worker runtime with render agents.
- Input broker and app-compatibility handlers.

### D. Data-control plane

- File upload/download broker.
- Clipboard broker.
- Print broker.
- Remote extension curation and policy.
- Optional remote document view/conversion path.

### E. Evidence plane

- Metrics.
- Semantic deltas and browser events.
- Trigger-based artifacts.
- Search, triage, analytics, and forensic retention.

### F. Assurance plane

- Runtime tiering between canary container, standard microVM, and assured/confidential workers.
- Attestation, image trust, secret release, and per-tier operational policy.

## 4.3 Topology principles

1. **Viewer never connects directly to a worker in production.** The viewer terminates at a regional media gateway.
2. **Regional media gateways are the public ingress for active sessions.** They hide worker addressing, own QoE logic, and enforce abuse controls.
3. **Workers are private and egress through policy-controlled paths.**
4. **Evidence collection is regional first.** Only aggregated signals and selected artifacts go to global analytics.
5. **Global control services distribute state; they do not sit in the critical session path.**

\newpage

# 5. Product tiers and deployment models

## 5.1 User-visible service tiers

| Tier | Intended use | Isolation boundary | Default controls | Allowed fallback |
|---|---|---|---|---|
| Standard | General risky browsing | MicroVM or equivalent lightweight VM | Policy-driven clipboard/file/print, standard DLP | Yes, if policy allows |
| Protected | Sensitive SaaS, internal apps, unmanaged BYOD access | MicroVM with stricter app profile | Tighter upload/download/clipboard, step-up on credential entry | Limited |
| Assured | Privileged users, administrators, contractors, sensitive data handling | Dedicated VM-backed worker, higher logging and stricter data controls | Default-deny uploads, extension curation, stricter secrets handling | Only approved equivalent providers |
| Confidential | Regulated or government-aligned workloads | Confidential VM with attestation-gated secret release | Residency lock, customer or sovereign key options, explicit workload scopes | Usually none |

## 5.2 Deployment models

1. **Commercial multi-tenant cloud:** standard and protected tiers, selective assured workloads.
2. **Sovereign or regional cloud:** protected, assured, and possibly confidential workloads under strict residency.
3. **On-premises or customer-managed edge:** selected regulated use cases with reduced feature surface.
4. **Hybrid provider-fallback mode:** existing third-party isolation service can remain as a fallback for approved tenants only. This path is disabled for tiers that require residency or assurance equivalence.

## 5.3 Why the tier model matters

The tier model prevents one isolation posture from becoming a universal compromise. It lets the product scale economically while still serving regulated or privileged workflows that cannot share the same runtime, fallback policy, or evidence model as commodity traffic.

\newpage

# 6. Core component design

## 6.1 Endpoint plane

### Responsibilities

- Device posture collection and reporting.
- Local risk hints for navigation and app context.
- Transport and region steering based on observed path health.
- Optional local enforcement hooks for clipboard, print, and screenshot rules.
- Optional enterprise-browser or browser-extension sensor path for richer local signals.

### Important design constraint

The endpoint agent does **not** automatically have DOM visibility. Rich DOM-based pre-scoring requires one of:

- An approved browser extension.
- Integration with a managed enterprise browser.
- OS/browser platform hooks that expose the needed metadata.

Without one of those, endpoint pre-scoring is limited to URL, browser process, network, user, device, and posture signals.

### Local model strategy

- Signed model bundles, typically ONNX or equivalent.
- Output is a hint, not the final policy decision.
- Model budget targets: small footprint, bounded CPU usage, deterministic fallback when model execution fails.
- For regulated tiers, the agent can operate in a minimal mode with no local ML and still preserve policy correctness.

### Recommended endpoint modules

- `risk-hint-engine`
- `qoe-steerer`
- `credential-entry-watcher`
- `os-egress-gates` for clipboard/print where supported
- `policy-bundle-cache`

## 6.2 SWG, ZTNA, and policy resolver

### Inputs

- URL, category, content type, reputation.
- User identity and group.
- Device posture.
- Destination type: internet, SaaS, internal web, admin plane, file-view flow.
- Tenant feature entitlements and residency constraints.
- App profile metadata.
- Endpoint risk hints.

### Outputs

- `allow`, `block`, `isolate`, `view-only`, or `download-to-remote-viewer`.
- Session feature gates: clipboard, upload, download, print, watermarking, audio, video, extension allowlist, credential step-up, screenshot policy.
- Runtime tier: standard, protected, assured, confidential.
- Fallback permission and allowed regions.

### Design requirement

The policy decision must be deterministic and reproducible from audit logs. Routing to fallback providers, alternate regions, or lower-assurance paths must be explicit in policy and visible to operators.

## 6.3 Identity service and BrowserPrincipal model

The SDD standardizes all session identity into a `BrowserPrincipal` object.

```json
{
  "principal_type": "human | agent",
  "subject_id": "stable-tenant-scoped-id",
  "tenant_id": "tenant-123",
  "idp": {
    "issuer": "https://idp.example.com",
    "groups": ["finance", "admins"],
    "claims_ref": "opaque"
  },
  "device": {
    "device_id": "managed-device-id",
    "posture_level": "managed | unmanaged | high_assurance",
    "risk_score": 23
  },
  "session_policy": {
    "tier": "protected",
    "allow_fallback": false,
    "residency": "eu-west-only"
  },
  "continuity": {
    "sso_mode": "isolated | extension-assisted | bypass-for-trusted-apps",
    "webauthn_step_up": true
  }
}
```

### SSO continuity model

The design does **not** promise universal cookie bridging between local and isolated sessions. Instead, it supports a matrix:

- Fully isolated IdP/auth flow.
- Extension-assisted continuity on approved managed devices.
- Trusted-app bypass or alternate handling for selected first-party apps.
- Explicitly unsupported or degraded cases documented per app profile.

This avoids over-promising a capability that is hard to deliver uniformly across browsers, platforms, and enterprise identity topologies.

## 6.4 Bootstrap service and handoff

### Requirements

- Verify the SWG-originated request or equivalent policy assertion.
- Mint a **JWE** or equivalent AEAD-wrapped opaque handoff token.
- No user identity, destination URL, policy, or transaction metadata is exposed in browser-visible query strings beyond opaque references.
- Replay window is short, typically <= 60 seconds.
- Viewer cookies are HttpOnly, Secure, and bound to anti-CSRF and session-binding mechanisms.

### Handoff flow

1. SWG or policy gateway decides `isolate`.
2. Bootstrap receives a signed decision envelope and validates policy provenance.
3. Session Authority is asked to allocate region and runtime tier.
4. Bootstrap mints opaque handoff and viewer bootstrap response.
5. Viewer connects to the regional media gateway using the capability-negotiated transport set.

## 6.5 Session Authority

Session Authority is the regional brain for session lifecycle and the most important control-plane service after policy.

### Responsibilities

- Admission control and quota enforcement.
- Region affinity and fail-open/fail-closed logic based on policy.
- Warm-pool allocation.
- Worker assignment and migration orchestration.
- Session state transitions.
- Per-tenant and per-tier concurrency accounting.
- Fallback routing when allowed.

### Session state machine

`Requested -> Admitted -> WorkerAssigned -> ViewerConnected -> Active -> Degraded -> Suspended -> Terminated -> EvidenceFinalized`

Each state transition is auditable. Terminal transitions include a reason code such as `user_exit`, `idle_timeout`, `policy_terminate`, `worker_failure`, `gateway_rebalance`, or `fallback_redirect`.

### Data model

Keyed by `tenant_id + region + session_id`. The state store is regional and sharded. It is not Redis-only by assumption; the implementation can use Redis for hot ephemeral state and a durable regional store for journaling, provided the latency budget is maintained.

## 6.6 Regional media gateway

This is the most important architecture addition relative to Gen-1.

### Responsibilities

- Public session ingress.
- Capability negotiation: WebTransport preferred where supported, WebRTC for pixel media, WebSocket/HTTPS fallback.
- Transport termination and abuse control.
- QoE decisions, bitrate class selection, transport fallback, and session health signals.
- Hiding worker addresses from the viewer.
- Rate limiting, anti-abuse, and anomaly controls.
- Session migration support where possible.
- Unified observability for connection establishment and live session quality.

### Why it exists

Without the media gateway, the product inherits all the weak points of direct viewer-to-worker topology: exposed worker network surface, fragile NAT traversal, poor QoE control, weak failover options, and fragmented telemetry.

### Minimum functions

- Per-principal connection quotas.
- Per-session input/message rate limits.
- DDoS shaping and handshake anomaly detection.
- Region-local session cache.
- Transport performance sampling.
- Session mirroring hooks for controlled migration and debugging.

## 6.7 Scheduler API and runtime abstraction

The runtime abstraction isolates control-plane logic from the underlying worker technology.

### Runtime classes

1. **Canary container runtime:** for development, controlled canary, and emergency use only.
2. **Standard microVM runtime:** default production tier.
3. **Dedicated assured runtime:** dedicated worker footprint with stricter controls and higher cost.
4. **Confidential VM runtime:** attested worker path for regulated tiers.

### Recommended strategic choices

- Standard commercial tier: Firecracker-class microVM or equivalent lightweight VM where operationally suitable.[^firecracker]
- Confidential tier: Cloud Hypervisor, QEMU/Kata/Confidential Containers, or managed confidential VMs depending on platform support and attestation tooling.[^cloudhypervisor][^coco]
- Container tier is sunset from production except where an explicitly approved exception exists.

### Important note on confidential compute

Do not plan the confidential tier around Firecracker today. Public project statements indicate Firecracker does not currently support AMD SEV, while Cloud Hypervisor and Confidential Containers document attestation and confidential workload paths.[^firecrackersev][^cloudhypervisor][^coco]

## 6.8 Worker runtime

Each worker image contains:

- Minimal Linux guest image.
- Hardened Chromium build and runtime flags.
- Render harness.
- Semantic probe.
- Local brokers for file, clipboard, and print coordination.
- Telemetry emitter.
- Minimal configuration bootstrap path.

### Isolation defaults

- Non-root execution.
- Read-only base image plus ephemeral writable overlay.
- Strict egress policy to SWG-controlled paths.
- Metadata-IP and RFC1918 blocks unless explicitly allowed for private-app tiers.
- Site isolation enforced where possible.
- JIT-less or stricter JavaScript posture for high-assurance profiles when compatible.

### Warm pool

Warm pools exist per tier, region, browser image channel, and app-profile class. Warm pools are required to reduce TTFV and to absorb burst concurrency. Pool sizing is derived from observed session arrival rates and target cold-start error budgets.

## 6.9 Rendering subsystem

The rendering subsystem is intentionally tiered.

### GA rendering path

**Pixel remoting** is the GA baseline because it is operationally understandable, legally safer, and broadly compatible.

Requirements:

- Regional media gateway terminates transport.
- Hardware acceleration where available.
- Capability negotiation across codec, frame rate class, and transport.
- Tight bitrate classing for text-dominant, mixed, and video-dominant sessions.
- App-specific knobs for SaaS that are especially sensitive to frame pacing or canvas behavior.

### FTO-gated acceleration path

An accelerated path may be added later under clean-room and FTO controls.

Allowed design posture:

- Treat accelerated rendering as a **plugin renderer** behind a stable internal interface.
- It must not be a GA dependency.
- It must be feature-flagged and canary-only until legal, security, QA, and app-certification gates are met.

### Safe-HTML path

Safe-HTML is a narrow, limited mode only for:

- Remote document viewing.
- Read-only degraded-network mode.
- Very low-risk static content.

It is **not** a general browsing mode in early phases.

### Accessibility and IME requirements

Any accelerated viewer path must explicitly support:

- Text selection semantics.
- Keyboard shortcuts and input methods.
- Screen reader interoperability where feasible.
- Find-in-page and search affordances.
- High-DPI and scaling correctness.
- Clipboard semantics under policy.

Without this, accelerated rendering may reduce bandwidth but still fail enterprise UX.

## 6.10 Data control brokers

### File broker

All uploads and downloads traverse a broker. No direct file path from worker to endpoint is allowed.

Functions:

- Upload staging.
- Download staging.
- CDR/AV/DLP invocation through existing platform services.
- Password-protected archive handling policy.
- MIME/type verification and structural classification.
- Remote view or detonation mode for disallowed direct downloads.
- Audit trail with policy reason and operator visibility.

### Clipboard broker

Functions:

- Direction-aware policy: local-to-remote, remote-to-local, remote-to-remote.
- Format allowlist.
- DLP scanning before egress.
- Copy length and frequency controls.
- App-profile-specific rules.
- Optional watermark or provenance tagging.

### Print broker

Functions:

- Allow, deny, remote-rendered PDF, or approved enterprise print route.
- Audit and policy binding.
- Watermark insertion where required.

### Remote extension service

- Curated allowlist only.
- Signed manifest and package validation.
- Supply-chain verification.
- No arbitrary marketplace installs.

## 6.11 Runtime semantic threat engine

The semantic engine is the key security differentiator beyond RBI.

### Data sources

- Chromium DevTools Protocol domains such as Network, Page, Runtime, Debugger, Security, and Storage.
- Browser DOM and JavaScript behavior metadata.
- File creation and download events.
- Service Worker and storage activity.
- Clipboard and form interactions.
- User/session context from the control plane.

### Rule engine

The first enforcement layer is deterministic rules, not an LLM.

Examples:

- HTML smuggling indicators using Blob APIs, data URLs, dynamic downloads, and browser-side file creation patterns.[^mitre_html][^mitre_det]
- Suspicious Service Worker registration or persistence behavior.
- File System Access or storage abuse inconsistent with app profile.
- High-entropy or highly obfuscated JavaScript execution patterns.
- Mass credential harvesting patterns.
- Abnormal postMessage or cross-frame behavior.

### Model-assisted layer

A model-assisted layer is added after rules are stable.

Use cases:

- JavaScript deobfuscation triage.
- URL plus DOM plus screenshot phishing scoring.
- Runtime-generated content classification.
- Suspicious form, brand, or MFA workflow detection.

The model layer starts **advisory by default**. It becomes inline-enforcing only after precision and drift are validated.

### Why this matters

HTML Smuggling is a recognized ATT&CK technique, and modern research shows attacks can assemble malicious JavaScript at runtime inside the browser, including by abusing trusted LLM services, which bypasses many static or network-centric controls.[^mitre_html][^unit42_runtime]

## 6.12 Telemetry and evidence fabric

The telemetry system is not a flat log stream. It has three levels.

### Tier 1: always-on metrics

- Session counts.
- Connection success/failure.
- TTFV, latency, frame pacing.
- Broker decisions.
- Worker lifecycle metrics.
- Gateway and scheduler health.

### Tier 2: semantic deltas

- Structured browser events.
- Aggregated per-session and per-tenant sketches.
- Detection verdicts and rule hits.
- Drift metrics for model-assisted detectors.

### Tier 3: trigger-based artifacts

- DOM snapshots.
- Screenshots.
- HAR-like traces.
- Downloaded objects.
- Serialized evidence bundles for escalated sessions.

### Privacy and oracle controls

Artifact deduplication is content-addressed internally, but customer-visible evidence references must be tenant-scoped to avoid cross-tenant existence oracles. Tenant-scoped encryption and access control are mandatory.

### Attestation vs host evidence

- Hardware-backed attestation is used for the confidential tier and secret release.[^intel_attest][^coco]
- eBPF-derived host telemetry can provide signed or tamper-evident host evidence, but it is **not** the attestation root.

## 6.13 Browser release engineering

This is a mandatory product function, not an operational detail.

### Required capabilities

- Browser image channels: canary, beta, stable, emergency.
- Chromium rebase cadence and patch intake policy.
- Emergency zero-day patch SLA.
- Signed browser image manifests.
- App-certification ring that runs SaaS/IdP regression suites before promotion.
- Kernel and VMM compatibility testing for VM images.
- Per-region and per-tenant rollback controls.

### Why it is essential

RBI products fail in practice when the browser image train is slower than the browser threat landscape or the enterprise app compatibility burden.

\newpage

# 7. Transport and runtime strategy

## 7.1 Language and runtime allocation

The product is intentionally polyglot.

| Area | Recommended language/runtime | Why |
|---|---|---|
| Bootstrap, admin APIs, tenant CRUD | Node.js + TypeScript | Existing codebase leverage, fast iteration, strong request/response productivity |
| Session Authority, signaling, telemetry fan-in, scheduler APIs | Go | Good fit for connection-heavy distributed services, gRPC, and regional control-plane services |
| Worker harness, render hot path, high-frequency event capture | Rust | Better fit for density-critical, low-latency, zero-GC media and probe paths |
| Model experimentation and offline analysis | Python | Fast iteration for research and detection tuning |

This is a target allocation, not a purity doctrine. Services move only when there is a clear hot-path or operability reason.

## 7.2 Transport policy

- **Preferred:** WebTransport for new control and accelerated-render channels where browser and network support are healthy.[^webtransport]
- **First-class retained path:** WebRTC for pixel media and compatible low-latency session transport.
- **Fallback:** WebSocket or HTTPS for conservative networks and control-plane bootstrap.

Capability negotiation is required. The SDD does **not** assume WebTransport is universal on day one.

## 7.3 Signaling architecture

- Regional signaling service owned by the media gateway tier.
- No Redis-dependent pending-signal hot path in the steady-state design.
- Regional state cache plus durable control journal.
- Observability for handshake timings, transport fallback reasons, and session-establishment failures.

\newpage

# 8. End-to-end sequence flows

## 8.1 Standard risky internet browsing flow

1. Endpoint or SWG sees navigation request.
2. Policy resolver evaluates destination, user, device, risk, and tenant policy.
3. Decision is `isolate` on standard tier.
4. Bootstrap validates decision provenance and asks Session Authority for an allocation.
5. Session Authority selects region, warm-pool worker image, runtime tier, and feature gates.
6. Bootstrap returns opaque viewer handoff.
7. Viewer connects to regional media gateway.
8. Media gateway binds session to worker and negotiates pixel transport.
9. Worker opens target URL via SWG-controlled egress.
10. Runtime semantic engine begins event capture.
11. File/clipboard/print requests are mediated through brokers.
12. Metrics and semantic deltas stream regionally; artifacts are created only on trigger.
13. Session terminates on user exit, idle timeout, or policy event.
14. Evidence is finalized, summarized, and retained according to policy.

## 8.2 Sensitive internal app flow

1. ZTNA/private-app resolver identifies internal destination.
2. Policy selects protected or assured tier.
3. Region and residency rules are applied.
4. Session Authority picks an app profile and stricter feature-gate set.
5. Worker egress is limited to approved internal destinations via the private-app path.
6. Credential-entry watcher and step-up rules activate.
7. Clipboard and upload policies are tightened by app profile.
8. Any forbidden behavior triggers downgrade to view-only or session termination.

## 8.3 Download flow

1. Worker detects a download attempt.
2. Download is intercepted and moved to the file broker.
3. Broker classifies file type and invokes CDR/AV/DLP.
4. Depending on policy, user receives one of: remote view only, sanitized file, blocked action, or approved download.
5. Evidence includes file hash, policy reason, and scan verdicts.

## 8.4 Threat-detection escalation flow

1. Semantic rule detects HTML-smuggling or phishing indicators.
2. Session is tagged high-risk.
3. Policy action may be one of: input disabled, view-only, forced step-up, artifact capture, or terminate.
4. Escalation artifacts are stored in tenant-scoped evidence store.
5. Detection is correlated with tenant analytics, SOC workflows, and incident cases.

## 8.5 Failure and fallback flow

1. Session Authority sees capacity breach, region degradation, or unsupported feature combination.
2. Policy checks whether fallback is allowed for this tenant/tier/app.
3. If yes, user is deterministically routed to approved external provider or alternate region.
4. If no, action is fail-closed or show a controlled error page based on policy.
5. Fallback reason is logged and exposed to operators and, where appropriate, customers.

\newpage

# 9. Security architecture and hardening controls

## 9.1 Viewer hardening

- Strict CSP.
- `frame-ancestors` deny by default.
- COOP and COEP where compatible.
- Trusted Types where feasible.
- Anti-CSRF protection bound to session.
- Input-plane anomaly detection and rate limiting.
- Extension risk guidance and supported-browser policy.

## 9.2 Gateway hardening

- Connection quotas and handshake rate limiting.
- Transport abuse detection.
- Per-session cryptographic binding.
- No worker network identifiers exposed to clients.
- Separate admin and session ingress.

## 9.3 Worker hardening

- Hardened Chromium flags.
- No direct internet egress except through policy-controlled path.
- Private-app destinations only through approved private routing.
- DNS through approved resolver path only.
- Read-only image and ephemeral overlay.
- Secrets delivered only on need, and in assured/confidential tiers only after appropriate checks.

## 9.4 TURN and relay controls

Where TURN is used, configure:

- Short-lived credentials.
- Allocation quotas.
- Allowed-peer and denied-peer controls.
- Restricted realms or tenant separation where required.
- Explicit fallback behavior for TCP/TLS relay in restricted enterprise networks.

## 9.5 Credential and phishing controls

RBI protects endpoints, not user intent. Therefore:

- Sensitive forms trigger additional scrutiny.
- High-risk apps can require step-up or allow only approved origins.
- Known brand and origin mismatches can shift session to view-only.
- WebAuthn and phishing-resistant auth are preferred where supported.

## 9.6 Secrets and attestation

For confidential tiers:

- Worker image identity and configuration are measured.
- Attestation verifier evaluates evidence and policy.
- Secrets are released only after policy-matched attestation token or equivalent evidence.
- Runtime policy and init data are cryptographically linked to measurement where supported.[^intel_attest][^coco]

\newpage

# 10. Capacity, SLOs, and admission control

## 10.1 Capacity model

The platform must plan around:

- Normal selective-isolation concurrency.
- Burst campaigns during incidents or policy changes.
- Regional imbalance.
- Session mix across text-dominant, mixed, and media-heavy applications.

## 10.2 Core SLOs

| Metric | Target |
|---|---|
| Session establishment success | >= 99.5% monthly |
| Warm session time to first visual response | p95 <= 2.5 s |
| Cold session time to first visual response | p95 <= 4.5 s |
| Input-to-render latency, healthy in-region path | p95 <= 120 ms |
| Policy decision correctness | >= 99.99% |
| Artifact availability for escalated sessions | >= 99.9% |

These are starting targets. Renderer-specific targets are benchmarked before hard commitment.

## 10.3 Admission control

Admission control is mandatory.

Inputs:

- Session tier.
- Tenant quotas.
- Region health.
- Warm-pool availability.
- Gateway capacity.
- Predicted session class.
- Fallback allowability.

Actions:

- Admit in-region.
- Admit cross-region if policy allows.
- Degrade feature surface.
- Route to approved fallback provider.
- Fail closed or present controlled unavailable response.

## 10.4 Do not hardcode unverified economics

Numeric claims about exact sessions per core, exact bandwidth per session, or exact density uplift from runtime/language rewrites are explicitly excluded from the normative architecture. They belong in the benchmarking appendix and are validated per phase.

\newpage

# 11. Compliance, sovereignty, and high-assurance posture

## 11.1 Zero-trust alignment

The architecture supports zero-trust principles by:

- Evaluating user, device, and app context for every isolated session.
- Enforcing least-privilege and app-profile-specific controls.
- Segmenting internet, SaaS, and internal destinations.
- Auditing every decision and session transition.

## 11.2 Government or IL5-style considerations

To move toward government-aligned workloads, the product needs:

- Regional and sovereign deployment modes.
- Explicit residency guarantees.
- Approved fallback restrictions.
- Stronger image control and change-management discipline.
- Confidential-compute option with attestation and controlled secret release.
- Customer-visible audit evidence and retention controls.

## 11.3 Data-handling principles

- Tenant-scoped encryption keys.
- Evidence retention by tier and policy.
- Explicit controls over screenshot, clipboard, download, and printing artifacts.
- Regional storage where required.

\newpage

# 12. Detailed execution plan and phases

![Program roadmap](rbi_program_roadmap.png)

This program is split into a **GA track** and an **acceleration track**.

- The **GA track** delivers a competitive enterprise product without FTO-sensitive renderer work.
- The **acceleration track** advances optional rendering improvements under legal, QA, and performance gates.

## 12.1 Phase 0 - Foundation, legal gates, and Gen-1 hardening

### Objectives

- Establish legal and threat-model basis.
- Make the current Gen-1 architecture safe enough for controlled canaries.
- Insert the media-gateway concept and observability foundation.
- Freeze unsupported shortcuts that would become technical debt.

### Mandatory deliverables

- FTO scoping memo and approved-source list for sensitive workstreams.
- STRIDE and privacy threat model with sign-off.
- Media gateway architecture and initial implementation plan.
- JWE handoff and short replay window.
- Viewer security headers and CSRF/session binding.
- Redis/state-store sharding and regionality plan.
- Gateway, worker, and bootstrap observability with end-to-end tracing.
- Runtime adapter reduction: pick one production canary adapter instead of keeping a broad matrix alive.
- Browser release-engineering charter.

### Engineering work packages

1. Control-plane hardening.
2. Viewer hardening.
3. Media gateway skeleton.
4. SLO dashboards and alerting.
5. Regional admission-control scaffolding.
6. Policy surface definition for brokered controls.

### Exit criteria

- Controlled canary works with deterministic failure handling.
- Any transport or capacity failure leads to explicit, logged fallback or controlled denial.
- No PII or sensitive session metadata is exposed in handoff URLs.
- Browser release-engineering owner and process are assigned.

## 12.2 Phase 1 - Competitive GA core

### Objectives

- Deliver a production-ready, VM-backed RBI service for standard and protected tiers.
- Make file, clipboard, and print controls real product surfaces.
- Establish regional gateway and admission-control behavior.

### Deliverables

- Standard microVM tier in production.
- Warm-pool manager.
- File broker MVP integrated with existing DLP/CDR/AV stack.
- Clipboard broker MVP with format and direction policy.
- Print policy surface.
- Gateway-based session ingress.
- App-profile framework for SaaS and internal apps.
- Customer-visible admin controls and basic analytics.

### Key risks

- Warm-pool sizing mistakes.
- Browser/app incompatibilities.
- Broker latency causing poor UX.
- Under-specified gateway observability.

### Exit criteria

- GA readiness review passed.
- Defined app-certification corpus has acceptable pass rate.
- Production SLOs achieved for standard use cases.
- Container runtime is no longer the default production path.

## 12.3 Phase 2 - Runtime semantics and evidence fabric

### Objectives

- Add behavior-aware detection to the isolated session.
- Create an evidence fabric suitable for SOC and analytics use.
- Keep models advisory until precision is proven.

### Deliverables

- CDP-based event capture in production.
- Rule engine for HTML smuggling, suspicious persistence, storage abuse, and form-risk behaviors.
- Trigger-based artifact pipeline.
- Search and analytics indices for detections and evidence references.
- Model-serving path for advisory phishing or JS triage.

### Exit criteria

- Curated malicious corpus coverage reaches agreed threshold.
- False-positive rate for inline rules is acceptable by tenant class.
- Advisory model outputs are tracked, explainable, and operationally useful.

## 12.4 Phase 3 - Acceleration track for rendering

### Objectives

- Develop a clean-room accelerated renderer behind a stable abstraction.
- Keep the work canary-only until legal and app-compatibility gates are cleared.

### Deliverables

- Internal renderer abstraction contract.
- Prototype accelerated viewer path.
- Transport path for non-pixel control or draw/update traffic.
- Accessibility and IME test matrix.
- Benchmark framework comparing pixel baseline vs accelerated path.

### Hard gates

- Written FTO sign-off for the selected design family.
- Clean-room evidence package complete.
- App-certification and accessibility gates passed.
- SRE sign-off that GA economics do not rely on this path.

### Exit criteria

- Acceleration path is an optional feature flag, not the default.
- Canary customers show measurable improvement with no unacceptable regressions.

## 12.5 Phase 4 - Endpoint co-processing and stronger app controls

### Objectives

- Reduce decision latency and add local enforcement where the endpoint can help.
- Improve controls around credential entry, print, and clipboard on managed endpoints.

### Deliverables

- Policy-bundle distribution to endpoint agent.
- Local risk-hint engine.
- QoE steering.
- Managed-device credential-entry watcher and step-up integration.
- OS-layer clipboard and print gates where supported.

### Exit criteria

- A measurable percentage of decisions benefit from local hints or steering.
- Endpoint-assisted controls reduce risky egress events without unacceptable user friction.

## 12.6 Phase 5 - Assured and confidential tiers

### Objectives

- Serve privileged, contractor, regulated, and non-human browsing principals with stronger assurance.

### Deliverables

- Dedicated assured tier with stricter controls and audit surface.
- Confidential VM path with attestation-gated secret release.
- BrowserPrincipal extension for agent sessions and explicit non-human scopes.
- Residency and key-management options for regulated deployments.

### Exit criteria

- Attestation negative tests are passed.
- Secret release is policy-bound and auditable.
- Regulated deployment pattern is documented and reviewed by compliance and legal.

## 12.7 Phase 6 - Long-tail productization and optimization

### Objectives

- Expand app coverage, customer analytics, forensics, and operating efficiency.

### Deliverables

- Rich analytics dashboards.
- More SaaS app profiles.
- Improved remote-extension program.
- Cost/capacity optimizations.
- Defensive publication or patent actions on approved novel work.

### Exit criteria

- Product has sustainable release, support, and evidence operations.
- Any acceleration path that remains is fully owned, benchmarked, and legally maintained.

\newpage

# 13. Workstreams by team

## 13.1 Platform and control-plane engineering

- Bootstrap, Session Authority, scheduler APIs, global control services, config distribution, entitlements, admin APIs.

## 13.2 Browser and runtime engineering

- Chromium image hardening, worker harness, rendering agents, app compatibility, release engineering, VM image train.

## 13.3 Media and transport engineering

- Media gateway, transport negotiation, bitrate policies, session QoE, migration experiments, relay strategy.

## 13.4 Security engineering

- Threat model, browser hardening, secrets flow, attestation integration, rule engine, extension curation, broker security.

## 13.5 Endpoint engineering

- Policy bundle, risk hints, QoE steering, OS-level local controls, enterprise browser integration.

## 13.6 Data and analytics

- Evidence fabric, search, artifact storage, sketches, customer analytics, model evaluation pipeline.

## 13.7 SRE and operations

- Regional deployments, admission control, capacity policy, observability, incident playbooks, rollback, canaries.

## 13.8 Legal and IP

- FTO reviews, open-source governance, invention disclosures, clean-room approvals, contract review for fallback providers.

\newpage

# 14. Verification and validation plan

## 14.1 Security validation

- Viewer CSP and isolation testing.
- Handoff replay and token misuse tests.
- Gateway abuse and rate-limit tests.
- Worker breakout and egress policy red-team tests.
- Broker bypass attempts.
- Attestation negative and secret-release tests.

## 14.2 Functional validation

- SaaS and IdP regression corpus.
- Internal-app access flows.
- Download/upload matrix.
- Clipboard and print matrix.
- Audio/video and canvas-heavy app profiles.

## 14.3 Performance validation

- Cold/warm start benchmarks.
- Transport establishment and fallback timings.
- Cross-region impairment tests.
- Gateway saturation and regional rebalance.
- Broker latency under load.

## 14.4 Detection validation

- HTML-smuggling corpus.[^mitre_html][^mitre_det]
- Runtime-assembled malicious JavaScript corpus.[^unit42_runtime]
- Phishing and brand impersonation corpus.
- Benign but complex SaaS scripts to control false positives.

## 14.5 Release validation

- Browser image ring promotion gates.
- Emergency patch rehearsal.
- Region-level rollback drills.
- Fallback-provider failover tests where permitted.

\newpage

# 15. Key risks and mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Direct viewer-to-worker topology resurfaces through shortcuts | Reintroduces network exposure and weakens operability | Make gateway mandatory in the production architecture and API contracts |
| Renderer acceleration becomes a hidden GA dependency | Legal and delivery risk | Keep pixel path first-class; acceleration behind abstraction and feature flag |
| Browser release engineering under-resourced | Security and app compatibility failures | Dedicated owner, release train, emergency patch SLA, app-certification gates |
| Endpoint co-processing over-promises DOM visibility | Design drift and false expectations | Define optional sensor models clearly; keep local hints useful without DOM |
| Evidence dedupe creates cross-tenant leakage | Privacy and trust issue | Tenant-scoped encryption and customer-visible references |
| Fallback provider violates residency or assurance constraints | Compliance risk | Tier- and tenant-aware fallback policy; disable for regulated tiers |
| Model-assisted detections create noisy inline blocks | Customer disruption | Rules first, models advisory first, explicit precision gates |
| Confidential tier planned on the wrong substrate | Delays and redesign | Separate standard microVM and confidential-VM runtime strategies early |

\newpage

# 16. Implementation recommendations and concrete next steps

## 16.1 First 90 days

1. Freeze architecture principles and legal gates.
2. Create Session Authority, gateway, and runtime abstraction contracts.
3. Implement JWE handoff and viewer hardening.
4. Narrow runtime matrix and define microVM target.
5. Define broker APIs and policy model.
6. Stand up browser release-engineering owner and app-certification harness.
7. Add full tracing and SLO dashboards.

## 16.2 First 180 days

1. Launch gateway-backed canary.
2. Put standard microVM tier behind tenant flag.
3. Deliver file broker MVP and clipboard broker MVP.
4. Define app-profile catalog for top SaaS and internal apps.
5. Land runtime semantic rules and artifact pipeline in canary.
6. Establish benchmark framework and customer-visible operator dashboards.

## 16.3 Before GA sign-off

1. Browser image release train is proven.
2. Fallback governance is explicit by tier and region.
3. Customer admin controls and reporting exist.
4. Security validation and red-team exercises are complete.
5. Product support runbooks, incident response, and SRE playbooks are complete.

\newpage

# 17. Normative decisions captured by this SDD

1. **Architecture:** media gateway in front of all production sessions.
2. **GA transport:** pixel RBI remains first-class.
3. **Advanced remoting:** optional and FTO-gated.
4. **Runtime tiers:** microVM standard; confidential VM for regulated workloads; container tier sunset from mainstream production.
5. **Identity model:** BrowserPrincipal supports human and agent sessions.
6. **SSO continuity:** supported-pattern matrix, not blanket cookie bridging promise.
7. **Data control:** file, clipboard, print, upload, download, and extension services are part of core architecture.
8. **Telemetry:** evidence fabric with tenant-scoped privacy controls.
9. **Release engineering:** mandatory function with signed image trains and rollback.
10. **IP posture:** clean-room process and invention disclosure for novel work.

\newpage

# 18. Public references informing this SDD

These references inform technology direction and risk framing. They do not authorize implementation of any proprietary method.

1. Cloudflare Browser Isolation documentation on Network Vector Rendering and Canvas Remoting.  
   https://developers.cloudflare.com/cloudflare-one/remote-browser-isolation/canvas-remoting/
2. Zscaler documentation on Turbo Mode and isolation experience modes.  
   https://help.zscaler.com/isolation/understanding-turbo-mode-isolation  
   https://help.zscaler.com/isolation/user-experience-modes-isolation
3. MDN documentation for WebTransport and WebTransport API.  
   https://developer.mozilla.org/en-US/docs/Web/API/WebTransport  
   https://developer.mozilla.org/en-US/docs/Web/API/WebTransport_API
4. Firecracker project documentation and FAQ.  
   https://firecracker-microvm.github.io/  
   https://github.com/firecracker-microvm/firecracker/blob/main/FAQ.md
5. Firecracker project discussion stating lack of AMD SEV support.  
   https://github.com/firecracker-microvm/firecracker/issues/2332
6. Cloud Hypervisor SEV-SNP documentation and project repository.  
   https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/amd_sev_snp.md  
   https://github.com/cloud-hypervisor/cloud-hypervisor
7. Confidential Containers attestation and policy documentation.  
   https://confidentialcontainers.org/docs/attestation/  
   https://confidentialcontainers.org/docs/attestation/policies/
8. Intel Trust Authority attestation overview and policy documentation.  
   https://docs.trustauthority.intel.com/main/articles/articles/ita/concept-attestation-overview.html  
   https://docs.trustauthority.intel.com/main/articles/articles/ita/concept-policies.html
9. MITRE ATT&CK technique and detection material for HTML Smuggling.  
   https://attack.mitre.org/techniques/T1027/006/  
   https://attack.mitre.org/detectionstrategies/DET0313/
10. Palo Alto Unit 42 write-up on real-time malicious JavaScript assembled through LLM interactions in the browser.  
    https://unit42.paloaltonetworks.com/real-time-malicious-javascript-through-llms/

\newpage

# Appendix A - Suggested initial technical decomposition

## A.1 Service list

- `bootstrap-api`
- `identity-service`
- `session-authority`
- `scheduler-api`
- `media-gateway`
- `worker-manager`
- `file-broker`
- `clipboard-broker`
- `print-broker`
- `semantic-probe`
- `artifact-router`
- `analytics-indexer`
- `browser-release-orchestrator`

## A.2 Suggested initial repositories or modules

- `control-plane/` - bootstrap, identity, session authority, scheduler, admin APIs.
- `gateway/` - media gateway and signaling.
- `worker-runtime/` - browser image, harness, render adapters, brokers.
- `endpoint/` - agent modules and policy bundle support.
- `evidence/` - collectors, artifact router, analytics ingestion.
- `release/` - browser image pipeline, app certification, signed manifests.
- `policy/` - app profiles, detection rules, broker policy schema.

## A.3 Internal interfaces to define first

1. Session Authority API.
2. Gateway-to-worker session contract.
3. Broker policy schema.
4. Evidence event schema.
5. BrowserPrincipal schema.
6. Runtime capability descriptor.
7. App-profile schema.

# Appendix B - Sample runtime capability descriptor

```json
{
  "runtime_class": "microvm-standard",
  "browser_channel": "stable",
  "transport": ["webrtc", "websocket"],
  "codecs": ["h264", "vp9"],
  "features": {
    "clipboard_in": true,
    "clipboard_out": false,
    "file_upload": true,
    "file_download": "brokered",
    "print": "remote_pdf_only",
    "extensions": "curated-only",
    "audio": true,
    "video": true,
    "safe_html": false,
    "accelerated_renderer": false,
    "attestation": false
  }
}
```

# Appendix C - Benchmark plan summary

Benchmark before committing any hard target for:

- Warm and cold session latency by tier.
- Bandwidth by page class and app profile.
- Gateway and broker latency.
- Worker density by runtime class.
- Transport fallback behavior under loss and blocking.
- Detection latency and precision.
- App-compatibility pass rates.

The benchmark plan exists to replace assumptions with evidence, not to justify architecture shortcuts.

[^webtransport]: MDN states the WebTransport API provides HTTP/3-based reliable streams and unreliable datagrams, and marks it as Baseline newly available in 2026. See https://developer.mozilla.org/en-US/docs/Web/API/WebTransport and https://developer.mozilla.org/en-US/docs/Web/API/WebTransport_API
[^firecracker]: Firecracker describes itself as KVM-backed microVM technology for secure, multi-tenant workloads with rate limiting and a small VMM footprint. See https://firecracker-microvm.github.io/
[^firecrackersev]: Public Firecracker project discussion states Firecracker does not currently support AMD SEV. See https://github.com/firecracker-microvm/firecracker/issues/2332
[^cloudhypervisor]: Cloud Hypervisor documents support work for AMD SEV-SNP and positions itself as a modern cloud VMM for KVM/MSHV. See https://github.com/cloud-hypervisor/cloud-hypervisor and https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/amd_sev_snp.md
[^coco]: Confidential Containers documents attestation, Trustee, and policy-bound secret release for confidential workloads. See https://confidentialcontainers.org/docs/attestation/ and https://confidentialcontainers.org/docs/attestation/policies/
[^intel_attest]: Intel Trust Authority documents remote attestation concepts, attestation tokens, and policy evaluation for attesters. See https://docs.trustauthority.intel.com/main/articles/articles/ita/concept-attestation-overview.html and https://docs.trustauthority.intel.com/main/articles/articles/ita/concept-policies.html
[^mitre_html]: MITRE ATT&CK documents HTML Smuggling as T1027.006. See https://attack.mitre.org/techniques/T1027/006/
[^mitre_det]: MITRE ATT&CK detection strategy DET0313 documents detection ideas for Blob plus dynamic file-drop HTML smuggling behavior. See https://attack.mitre.org/detectionstrategies/DET0313/
[^unit42_runtime]: Palo Alto Unit 42 published a 2026 write-up showing how a webpage can request malicious JavaScript snippets from trusted LLM services and assemble them in the browser at runtime. See https://unit42.paloaltonetworks.com/real-time-malicious-javascript-through-llms/
