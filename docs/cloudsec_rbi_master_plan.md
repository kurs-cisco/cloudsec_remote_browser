# Cloudsec RBI Master Plan

**Status:** Proposed master document  
**Purpose:** Single source of truth for architecture direction, document authority,
phase ordering, and major gaps across the current RBI design set.

Current repo-state readiness against the existing SSE product is recorded in
`cloudsec_rbi_implementation_readiness_assessment.md`.
The executable implementation split and parallel-agent workstream plan are recorded in
`cloudsec_rbi_parallel_execution_plan.md`.

Operating-model assumption for this plan:

- Menlo remains an active RBI provider for **Cat-A** traffic.
- The in-house RBI stack serves as a second provider for **Cat-B** traffic.
- This plan does **not** assume Menlo replacement.
- Menlo also remains the fallback path for unsupported in-house traffic until
  the in-house provider reaches verified parity for the intended slice.

## Executive Decision

No single existing document is sufficient as the master plan without modification.

The strongest path is:

1. Use `world-class-rbi-sdd.md` as the **target-state architecture baseline**.
2. Use `cloudsec_rbi_product_architecture_execution_plan.md` as the **program and
   phase scaffold**.
3. Use `rbi-arch.md` as the **current-state technical baseline** and migration
   reality check.
4. Use `rbi-gen2-ssd.md` as the **Gen-2 differentiation and R&D direction**, not
   the mainline delivery plan.

If only one existing document had to be followed, the best base would be
`cloudsec_rbi_product_architecture_execution_plan.md`, but only after adding:

- a current-to-target migration appendix;
- explicit Phase 0 and Phase 1 interface contracts;
- measurable gates with owners;
- a clear role boundary versus `world-class-rbi-sdd.md` and `rbi-arch.md`.

Because that cleanup has not yet been done, this document becomes the master plan.

## Recommended Document Authority Model

| Document | Role going forward | Authority level |
| --- | --- | --- |
| `cloudsec_rbi_master_plan.md` | Master decision and delivery guide | Primary |
| `world-class-rbi-sdd.md` | Normative target-state architecture | Primary for end-state |
| `cloudsec_rbi_product_architecture_execution_plan.md` | Detailed program structure, phases, team workstreams, validation plan | Primary for execution details |
| `rbi-arch.md` | Current extracted-runtime design and migration baseline | Primary for present state |
| `rbi-gen2-ssd.md` | Differentiation roadmap and FTO-gated Gen-2 direction | Secondary |

Rule:

- If there is a conflict between current runtime behavior and target-state architecture,
  `rbi-arch.md` describes what exists now, while `world-class-rbi-sdd.md` and this
  master plan describe where the system must move.
- If there is a conflict between target-state architecture and a speculative future
  capability, the target-state architecture wins and the speculative item moves to the
  Gen-2 track.

## Comparative Assessment

### Overall Recommendation

The strongest architectural solution to follow is:

- **regional media gateway in front of workers;**
- **pixel-first GA;**
- **VM-backed production isolation;**
- **first-class file, clipboard, print, upload, and download brokers;**
- **runtime semantic threat engine after the GA-safe platform is stable;**
- **advanced rendering only as FTO-gated parallel R&D.**

This position is strongest in `world-class-rbi-sdd.md` and operationalized best in
`cloudsec_rbi_product_architecture_execution_plan.md`.

### Comparative Matrix

| Document | What it does best | Why it should not stand alone |
| --- | --- | --- |
| `rbi-arch.md` | Describes the extracted runtime accurately: SWG bootstrap, gateway WebRTC/SRTP relay, TURN, session lifecycle, disposability, and current gaps | It is current-state documentation rather than the final product/system architecture |
| `world-class-rbi-sdd.md` | Best target-state architecture: gateway-first, VM-backed workers, core brokers, evidence, app profiles, threat engine, phased safe GA | Not concrete enough as a build-spec; missing current-to-target migration detail, interface contracts, and some operational cutover detail |
| `cloudsec_rbi_product_architecture_execution_plan.md` | Best program document: phases, workstreams, validation plan, concrete next steps, risk framing | Overlaps too much with the SDD, creates authority drift, and is still weak on current-to-target migration contracts |
| `rbi-gen2-ssd.md` | Best technology-direction memo: language/runtime strategy, semantic engine direction, phased hot-path migration | Pushes hybrid/vector ideas too early, under-centers the media gateway, and is riskier than the mainline plan |

## Major Cross-Document Conclusions

### 1. Gateway media relay is the production endpoint

`rbi-arch.md` accurately describes the current extracted runtime. The target-state
architecture should keep the viewer out of any default direct relationship with workers.

Master-plan decision:

- production sessions must terminate at a **regional media gateway**;
- workers remain private and non-addressable from the viewer;
- direct-connect WebRTC remains only as a rollback or development path.

### 2. VM-backed workers are the right strategic production boundary

The current runtime supports Docker, ECS, and host-agent modes. That is acceptable as a
transition state, not as the final mainstream boundary.

Master-plan decision:

- converge production standard browsing onto **microVM or lightweight VM-backed workers**;
- the container tier is **sunset from production** except where an explicitly approved,
  time-bounded exception exists (development, short-lived canary, or an emergency path);
  "lower-assurance internal use" is not a valid long-term justification;
- do not treat "container hardening" as a substitute for the final isolation model.

### 3. Pixel-first GA is the correct safe path

All three stronger documents converge on this, even when they use different language.

Master-plan decision:

- GA depends on a **high-quality pixel path**;
- advanced vector, clientless, safe-HTML, hybrid, or WebTransport-first rendering is
  not allowed to block GA;
- those paths remain optional parallel R&D after legal and platform gates.

### 4. Data controls are not add-ons

The architecture is incomplete if clipboard, download, upload, print, and extension
controls are not part of the session contract.

Master-plan decision:

- file and clipboard brokers are Phase 1 or Phase 2 deliverables, not "future nice to have";
- unsupported data paths remain on Menlo until cloudsec equivalents are real;
- no implicit local-device data egress features are enabled by default.

### 5. The runtime semantic threat engine is important, but not the first milestone

It is strategically important and a likely differentiator, but it should land only after
the GA-safe transport and isolation boundary are stable.

Master-plan decision:

- Phase 0 and Phase 1 focus on hardening, gateway, worker isolation, and core brokers;
- runtime semantics and evidence move in after the base platform is operationally credible.

### 6. The Gen-2 document is a later lane, not the current steering wheel

`rbi-gen2-ssd.md` is useful, but it mixes strong ideas with sequencing risk.

Master-plan decision:

- take from Gen-2 only the near-term pieces that strengthen the mainline:
  - FTO discipline;
  - selective Go/Rust hot-path migration;
  - semantic-event substrate;
  - evidence-fabric basics.
- defer these until later:
  - adaptive hybrid remoting;
  - safe-HTML mainline delivery;
  - WebTransport-first mainline transport;
  - agent principals;
  - confidential-compute scale-out.

## Gaps By Document

### `rbi-arch.md`

Strength:

- Best current-state explanation of how sessions, tokens, TURN, WebRTC, and disposal
  work today.

Gaps:

- direct viewer-to-worker topology is now documented as rollback, but older planning
  sections still need cleanup as the gateway-first implementation matures;
- signed handoff still carries metadata that target-state docs want to hide behind
  opaque/JWE-style tokens;
- current design is more runtime-focused than product/system-focused;
- broker call sites, VM tiering, app profiles, and evidence are described as gaps, not
  built architecture;
- no full multi-team phase plan.

Required role:

- keep as current-state baseline and migration source, not as future-state authority.

### `world-class-rbi-sdd.md`

Strength:

- Best target-state architecture and best set of strategic decisions.

Gaps:

- lacks explicit migration mapping from the extracted runtime;
- media gateway, admission, and broker APIs are conceptually strong but not yet
  specified tightly enough for implementation contracts;
- does not tell teams exactly how to replace existing `server.js`, WebSocket relay,
  `worker.py`, Redis, or TURN topology;
- some capacity and rollout assumptions remain conceptual rather than implementation-gated.

Required role:

- keep as normative target-state architecture baseline.

### `cloudsec_rbi_product_architecture_execution_plan.md`

Strength:

- Best program structure and best concrete multi-phase execution framing.

Gaps:

- overlaps too heavily with the SDD and creates duplicate authority;
- lacks explicit current-to-target cutover plan;
- names interfaces without fully defining initial normative schemas;
- some phase exits are qualitative rather than measurable;
- still too broad to drive repo-level implementation without a nearer-term migration plan.

Required role:

- keep as detailed execution-plan source, but subordinate it to the master plan and
  target-state architecture.

### `rbi-gen2-ssd.md`

Strength:

- Best articulation of future hot-path runtime evolution and Gen-2 ambitions.

Gaps:

- does not make the regional media gateway the clear mandatory production default;
- keeps containers too central for too long in commodity production;
- moves advanced remoting too far forward;
- internal language/runtime ownership is not fully consistent;
- underplays app-compatibility/app-profile work.

Required role:

- keep as Gen-2 and differentiation lane only.

## Normative Decisions Captured By This Master Plan

1. Production viewer ingress must terminate at a **regional media gateway**.
2. Production mainstream browsing isolation must converge to **VM-backed workers**.
3. GA must be **pixel-first**.
4. Advanced rendering is **optional, FTO-gated, and not on the GA critical path**.
5. File, clipboard, upload, download, print, and extension controls are **core RBI services**.
6. Runtime semantics and evidence are required for differentiation, but not before the
   GA-safe transport and isolation boundary are stable.
7. `rbi-arch.md` is the **current-state truth**, not the future-state architecture.
8. Menlo remains a **first-class RBI provider for Cat-A traffic** and the
   **fallback and scope boundary** for unsupported Cat-B traffic until parity
   exists and is verified.
9. Every production phase must have measurable gates, explicit interfaces, and a
   fallback posture.
10. IP/FTO guardrails are gating design inputs, not post-hoc legal review.

### Dual-provider operating model

This master plan assumes a dual-provider RBI product model:

- **Cat-A** traffic continues on Menlo by design.
- **Cat-B** traffic is eligible for the in-house RBI provider.
- Unsupported Cat-B subflows still fall back to Menlo until product parity is
  intentionally built and verified.

The missing implementation piece is not the existence of Menlo. The missing piece is
the provider-selection contract and the SWG or Zeus adapter that can reliably map
`ISOLATE` decisions into the correct provider lane.

### FTO-sensitive feature families (binding)

The following workstreams are blocked behind counsel-led FTO review and must not
enter the GA critical path. This list is authoritative here; see
`cloudsec_rbi_product_architecture_execution_plan.md` §3.2 for the full treatment.

- Draw-command remoting and compositor/display-list transport.
- DOM-diff streaming or clientless DOM reconstruction.
- Hybrid remoting that switches between semantic and raster transports based on
  compositor or layout internals.
- Session replay or browsing-forensics features that capture semantically rich
  user/session state beyond ordinary security logging.
- Browser-origin bridging mechanisms that replicate local-origin cookie continuity
  for remote sessions.
- Advanced remote extension models that execute privileged logic in or adjacent to
  isolated page contexts.

### Phase numbering map (authoritative)

The other documents use different phase numberings. When teams cite phases, use
this master-plan numbering and map across as follows.

| Master plan | Execution plan | Gen-2 SDD | Scope |
| --- | --- | --- | --- |
| Phase 0 | Phase 0 | Phase 0 | Current runtime hardening, legal/threat-model gates |
| Phase 1 | Phase 0 (gateway) → Phase 1 (GA core) | — | Media gateway + Session Authority insertion |
| Phase 2 | Phase 1 (GA core) | Phase 1 (microVM) | VM-backed standard tier + core brokers |
| Phase 3 | Phase 2 | Phase 2 | Runtime semantic detection + evidence |
| Phase 4a (hot-path migration) | Phase 3 (acceleration) + runtime eng | Phases 3–4 | Go/Rust hot-path, endpoint co-processing |
| Phase 4b (assured → confidential) | Phases 5–6 | Phase 5 | Assured/confidential tiers, attestation, agent principals |

## Recommended Phased Plan

### Phase 0: Current Runtime Production Hardening

Objective:

- Make the extracted runtime safe enough for controlled canary while preserving the
  current pixel/WebRTC architecture.

Required work:

- tighten SWG bootstrap and handoff security;
- move to opaque or JWE-style handoff;
- enforce relay-only or well-bounded ICE posture for production;
- harden Redis, TURN, viewer headers, and replay controls;
- narrow worker launch matrix;
- add deterministic Cat-B provider selection and Menlo fallback;
- add measurable session, TURN, and signaling telemetry;
- formalize threat model and FTO gate.

Exit criteria:

- controlled canary is safe and observable;
- unsupported Cat-B flows deterministically fall back to Menlo;
- session cleanup, replay protection, and worker containment meet agreed baseline.

### Phase 1: Gateway And Session Authority Insertion

Objective:

- replace the direct public worker-facing session topology with the target production
  ingress pattern.

Required work:

- introduce regional media gateway;
- define Session Authority and regional admission contracts;
- define bootstrap-to-gateway handoff contract;
- hide worker topology from viewers;
- preserve pixel-first path through the gateway;
- specify current-to-target cutover for viewer signaling and worker bridging.

Exit criteria:

- all new canary sessions use gateway ingress;
- no worker addresses are exposed to viewers;
- gateway metrics, quotas, and abuse controls are live.

### Phase 2: VM-Backed Standard Tier And Core Data Brokers

Objective:

- make the isolation boundary production-credible.

Required work:

- introduce microVM or equivalent lightweight VM standard tier;
- move worker egress through controlled path;
- block metadata and internal network access;
- build file broker MVP;
- build clipboard broker MVP;
- add app-profile catalog for top SaaS and internal apps;
- add warm-pool and regional admission logic.

Exit criteria:

- standard production browsing runs on VM-backed workers;
- file and clipboard policies are real product surfaces;
- app compatibility for top supported apps is documented and tested.

### Phase 3: Runtime Semantic Detection And Evidence

Objective:

- add security differentiation after the core platform is stable.

Required work:

- CDP-based semantic-event pipeline;
- rule-based runtime detections;
- trigger-based artifact capture;
- evidence-fabric baseline;
- customer/operator-facing diagnostics and audit path.

Exit criteria:

- curated threat corpus is detected with acceptable false-positive rates;
- artifacts and telemetry support investigations without over-collection.

### Phase 4: Gen-2 Differentiation Track

Split into two distinct lanes under one phase header. They have different risk
profiles, different skill sets, and different gates; do not fund them as one
budget line.

#### Phase 4a — Hot-path and endpoint runtime evolution (near-term, low legal risk)

Objective:

- reduce worker density cost and decision latency using runtime and endpoint work
  that does not depend on FTO-sensitive rendering.

Allowed work:

- Go or Rust hot-path migration where a benchmark justifies it;
- endpoint co-processing expansion (risk hints, QoE steering, managed-device
  credential-entry and clipboard/print gates);
- transport capability negotiation work (WebTransport as an added option, not
  as a replacement for WebRTC pixel).

Gate:

- benchmark-backed density or latency gain before any migration is declared
  default;
- no regression in SLOs, app-certification, or accessibility.

#### Phase 4b — Assured, confidential, and FTO-gated rendering (later, higher policy load)

Objective:

- open the assured and confidential tiers and, separately, explore FTO-cleared
  rendering acceleration.

Allowed work:

- assured tier on dedicated pools;
- confidential VM pilots with attestation-gated secret release (not on
  Firecracker — see VM strategy note in §Immediate Next 90 Days);
- BrowserPrincipal extension for non-human agent sessions;
- vector remoting / safe-HTML / hybrid renderer prototypes **only** behind
  written FTO sign-off and a stable Render Abstraction Layer contract.

Gate:

- written FTO sign-off for each FTO-sensitive design family before code freeze;
- none of these items may become GA-critical until FTO, product, and
  operational gates pass.

## Current-To-Target Migration Priorities

This is the key gap missing from the current document set.

### What survives from the current extracted runtime

- SWG contract concepts;
- session model;
- token model;
- TURN credential model;
- viewer shell concepts;
- worker session isolation concepts;
- current canary fallback logic.

### What must change first

- direct viewer-to-worker rollback/development path must stay out of production default;
- visible signed handoff metadata;
- container-centric mainstream runtime;
- ad hoc worker-runtime multiplicity;
- missing live gateway and regional admission-control evidence.

### What can be deferred

- hybrid or vector remoting;
- confidential-compute scale-out;
- agent principals;
- long-tail analytics and advanced evidence layers.

## Immediate Next 90 Days

1. Freeze the document authority model in this master plan.
2. Add a migration appendix to `cloudsec_rbi_product_architecture_execution_plan.md`
   or reference this one as authoritative.
3. Define three initial normative contracts (stub schemas live in
   `cloudsec_rbi_product_architecture_execution_plan.md` Appendix A — service list,
   Appendix B — runtime capability descriptor, Appendix C — benchmark plan; extend,
   don't re-author):
   - bootstrap to Session Authority;
   - Session Authority to media gateway;
   - media gateway to worker bridge.
4. Finalize Phase 0 measurable gates:
   - session-establishment success;
   - worker cleanup success;
   - relay ratio;
   - provider fallback correctness;
   - replay rejection correctness.
5. Decide the production VM strategy. The standard commercial tier and the
   confidential tier must be decided **separately**; they do not share a
   substrate today:
   - Standard commercial tier: Firecracker-class microVM, Cloud Hypervisor, or
     a cloud-managed lightweight VM.
   - Confidential tier: Cloud Hypervisor (SEV-SNP), Kata / Confidential
     Containers, or a managed confidential VM. **Firecracker must not be
     planned for the confidential tier** — it does not currently support
     AMD SEV. See `cloudsec_rbi_product_architecture_execution_plan.md` §6.7
     and its public-reference list for the substrate rationale.
6. Lock the first supported traffic slice:
   - Cat-B top-level browser `GET` or `HEAD` document navigations only.
7. Lock the unsupported traffic slice to Menlo:
   - file flows;
   - upload and download flows until brokers are ready;
   - non-browser and `CONNECT` flows;
   - any unsupported app profile.

## Master-Plan Recommendation

Follow this stack of authority:

1. **Use this file as the master plan.**
2. **Use `world-class-rbi-sdd.md` as the target-state architecture source.**
3. **Use `cloudsec_rbi_product_architecture_execution_plan.md` as the detailed phase
   and program source.**
4. **Use `rbi-arch.md` as the current-state technical baseline.**
5. **Use `rbi-gen2-ssd.md` only for later-stage differentiation.**

### External references

This master plan is intentionally light on citations. The supporting external
references (Cloudflare Browser Isolation / Canvas Remoting, Zscaler Turbo Mode,
MDN WebTransport, Firecracker / Cloud Hypervisor / Confidential Containers /
Intel Trust Authority, MITRE ATT&CK T1027.006 HTML Smuggling, Palo Alto Unit 42
real-time malicious JavaScript via LLMs) live in
`cloudsec_rbi_product_architecture_execution_plan.md` §18. Cite from there when
the master plan's decisions need external backing.

### Direction

This resolves the current ambiguity and gives the program one coherent direction:

- harden the current runtime;
- insert the media gateway and Session Authority;
- move to VM-backed mainstream isolation;
- add core data brokers and app compatibility;
- then add semantic detection and differentiated rendering.
