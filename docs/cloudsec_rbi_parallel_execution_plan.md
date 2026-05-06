# Cloudsec RBI Parallel Execution Plan

**Status:** Proposed implementation plan  
**Scope:** Dual-provider RBI program where Menlo remains the Cat-A provider and the
in-house RBI stack serves Cat-B traffic  
**Primary sources:** `cloudsec_rbi_master_plan.md`,
`cloudsec_rbi_product_architecture_execution_plan.md`,
`world-class-rbi-sdd.md`, `rbi-arch.md`,
`cloudsec_rbi_implementation_readiness_assessment.md`

## Executive Summary

Yes, we can plan implementation now, but only under the current dual-provider model:

- **Cat-A** remains on Menlo by design.
- **Cat-B** is the in-house RBI lane.
- The first implementable Cat-B slice is only **top-level browser `GET` or `HEAD`
  document navigation**.
- Unsupported Cat-B subflows continue to Menlo until parity exists.

This is not a broad rollout plan. It is a staged plan that starts with a narrow
Cat-B canary, then inserts the target control-plane and gateway architecture, then
adds VM-backed workers and brokered data controls.

## Program Principles

1. Do not widen Cat-B traffic before the control-plane contracts are frozen.
2. Do not skip the SWG or Zeus provider adapter.
3. Do not expose workers directly to viewers in the target architecture.
4. Do not claim broad Cat-B readiness before data-control and downstream parity exist.
5. Do not make runtime semantics, endpoint co-processing, or advanced rendering part of
   the Phase 0 or Phase 1 critical path.

## Execution Milestones

### M0 Program Freeze

Objective:

- Freeze the implementation shape before starting parallel coding.

Deliverables:

- confirmed Cat-A and Cat-B traffic model;
- confirmed first Cat-B slice;
- confirmed repo strategy;
- confirmed ownership map;
- confirmed provisional language and API choices.

Exit criteria:

- this document is accepted as the implementation plan baseline;
- blocking questions in `Clarifications Needed` are answered or explicitly accepted
  as provisional defaults.

### M1 Contract Freeze

Objective:

- Freeze the minimum set of contracts required for a dual-provider Cat-B canary.

Mandatory contracts:

1. provider-selection contract;
2. SWG or Zeus provider-adapter contract;
3. bootstrap contract;
4. fallback contract;
5. observability and phase-gate schema.

Exit criteria:

- contract owners are assigned;
- request and response shapes are documented;
- failure behavior is defined;
- unsupported Cat-B flows are pinned to Menlo.

### M2 Controlled Cat-B Canary

Objective:

- Run a narrow Cat-B in-house canary safely alongside Menlo.

Scope:

- top-level browser `GET` or `HEAD` only;
- deterministic Menlo fallback on bootstrap, establish, or unsupported-flow failure;
- no file, upload, download, user-input, `CONNECT`, or non-browser ownership.

Exit criteria:

- hard kill switch works;
- bootstrap, handoff, and establish-success dashboards are live;
- replay rejection and worker cleanup are verified;
- no direct customer-visible worker exposure exists beyond the accepted Phase 0
  transitional boundary.

### M3 Gateway-Backed Canary

Objective:

- Move canary sessions behind the target ingress pattern.

Deliverables:

- Session Authority;
- regional media gateway;
- gateway-to-worker bridge;
- regional admission and quota logic.

Exit criteria:

- all new Cat-B canary sessions terminate at the gateway;
- worker addresses are hidden from viewers;
- gateway quotas, QoE, and abuse metrics are live.

### M4 Broad Cat-B Beta

Objective:

- Make Cat-B operationally credible for a broader supported slice.

Deliverables:

- standard microVM or lightweight VM runtime;
- warm pools;
- first app-profile set;
- file broker MVP;
- clipboard broker MVP;
- downstream parity strategy implemented.

Exit criteria:

- Cat-B production path uses the standard VM-backed runtime;
- supported app profiles are documented and tested;
- brokered controls and downstream integration are live for the intended slice.

### M5 Broad Cat-B Production Readiness

Objective:

- Reach broad Cat-B readiness for the agreed supported traffic classes.

Deliverables:

- release train;
- runbooks;
- failover drills;
- support model;
- security validation and red-team evidence;
- tenant and region fallback governance.

Exit criteria:

- operational SLOs are met;
- fallback behavior is explicit by tier, app, and region;
- incident response, rollback, and release processes are proven.

## Parallel Agent Workstreams

### Agent 1: Policy Contract

Owner:

- Platform or control-plane team

Repo scope:

- `cloudsec-atlantis-policy-engine`
- `cloudsec-atlantis-flash-policy-engine`
- `cloudsec-atlantis-beaker-server`
- `cloudsec-atlantis-pe-lb`

First deliverables:

- provider-neutral decision schema;
- Cat-A or Cat-B lane field;
- canary percentage;
- hard kill switch;
- fallback permission and reason fields;
- tier, region, and feature-gate fields.

Dependencies:

- none before contract draft;
- blocks Agent 2 and the M1 freeze.

### Agent 2: SWG or Zeus Provider Adapter

Owner:

- Edge or SWG team

Repo scope:

- `cloudsec_Athena_zeus-nginx`
- `cloudsec_Athena_swg-proxy`
- `cloudsec_Athena_swg-nginx-proxy-https`

First deliverables:

- chosen insertion point;
- call to `POST /api/swg/sessions` or successor endpoint;
- redirect to `/swg/handoff` or successor flow;
- `GET` or `HEAD` Cat-B slice enforcement;
- deterministic fallback to Menlo.

Dependencies:

- provider-selection contract from Agent 1;
- bootstrap contract from Agent 3.

### Agent 3: Runtime Hardening

Owner:

- Browser or runtime team

Repo scope:

- `cloudsec_remote_browser`
- `browser_isolation`

First deliverables:

- opaque or JWE handoff;
- replay rejection tightening;
- viewer hardening;
- tracing and telemetry schema;
- narrowed canary runtime matrix.

Dependencies:

- minimal dependency on Agent 1 for bootstrap input fields;
- can proceed in parallel with Agent 2.

### Agent 4: Session Authority and Media Gateway

Owner:

- Media, transport, and platform team

Repo scope:

- new modules inside `cloudsec_remote_browser` or new adjacent repos if approved

First deliverables:

- `bootstrap -> Session Authority` contract;
- `Session Authority -> gateway` contract;
- `gateway -> worker` bridge contract;
- gateway skeleton;
- regional admission skeleton.

Dependencies:

- M1 contract freeze;
- can stub in parallel with Agents 2 and 3 once contract drafts exist.

### Agent 5: Deploy and VM Substrate

Owner:

- SRE and platform operations

Repo scope:

- `cloudsec_Athena_deploy-sig-eks`
- `cloudsec-atlantis-deploy-sig-eks`
- `browser_isolation`

First deliverables:

- provider config;
- secrets;
- health checks;
- rollout flags;
- fallback wiring;
- standard VM substrate pilot;
- warm-pool bootstrap.

Dependencies:

- provider adapter and bootstrap surfaces from Agents 2 and 3;
- VM choice decision from `Clarifications Needed`.

### Agent 6: Broker and Downstream Parity

Owner:

- Security or data-control team

Repo scope:

- `cloudsec_Athena_envoy-filter`
- `cloudsec_Athena_mps`
- `cloudsec_iproxy_mps`
- `cloudsec_remote_browser`

First deliverables:

- decision on `X-SIG-RBI-*` compatibility or replacement;
- file contract;
- clipboard contract;
- print contract;
- upload and download contract;
- phased parity plan.

Dependencies:

- not needed for M2;
- required before M4 broad Cat-B beta.

### Agent 7: Release and Validation

Owner:

- Browser runtime, QA, and SRE

Repo scope:

- `cloudsec_remote_browser`
- future `release/` and `policy/` modules if approved

First deliverables:

- browser release owner and process;
- app-profile certification corpus;
- fallback and failure test matrix;
- SLO dashboards;
- milestone evidence pack.

Dependencies:

- can start immediately and run throughout all milestones.

## Dependency Order

1. Freeze Cat-B scope and repo strategy.
2. Freeze provider-selection contract.
3. Freeze bootstrap and provider-adapter contract.
4. Freeze fallback contract.
5. Launch M2 narrow Cat-B canary.
6. Freeze Session Authority and gateway contracts.
7. Insert gateway and regional admission.
8. Choose and deploy standard VM-backed runtime.
9. Add brokered controls and downstream parity.
10. Widen Cat-B only after M4 criteria are met.

## Recommended Default Technical Split

These are proposed defaults to reduce decision churn. If you disagree, answer the
questions in `Clarifications Needed`.

### Language split

- `Node.js + TypeScript` for bootstrap, admin, and tenant-facing control APIs.
- `Go` for Session Authority, gateway control services, scheduler APIs, and
  telemetry fan-in.
- `Rust` only for later worker harness or hot-path components where benchmark data
  justifies it.
- `Python` only for model experimentation and offline analysis, not for new
  production control-plane services.

### API split

- `REST/JSON` for the SWG-facing bootstrap surface in Phase 0.
- `gRPC/protobuf` for new internal contracts after Session Authority and gateway are introduced.

### Transport split

- `WebRTC` remains the first-class Cat-B pixel path.
- `WebSocket/HTTPS` remains fallback.
- `WebTransport` stays additive and out of the Phase 0 critical path.

### Runtime split

- keep container-backed runtime only for the narrow canary;
- choose one standard VM-backed production path for M4;
- do not carry Docker, ECS, and host-agent as equal long-term production modes.

## Repo Strategy

Two viable options exist.

### Option A: Land Phase 0 and Phase 1 in existing repos

Pros:

- least organizational churn;
- faster path to M2;
- works with the current SSE repo structure.

Cons:

- architectural seams stay diffuse;
- later service extraction is harder.

### Option B: Start carving out target modules early

Suggested module boundaries:

- `control-plane/`
- `gateway/`
- `worker-runtime/`
- `policy/`
- `release/`
- `evidence/`

Pros:

- cleaner ownership;
- clearer long-term service boundaries.

Cons:

- more upfront movement;
- slower near-term canary path.

Recommendation:

- use **Option A** for M2;
- revisit module carve-out before M3 or M4.

## Phase 0 Success Metrics

Minimum dashboards:

- bootstrap success rate;
- handoff success rate;
- session establish success rate;
- replay rejection correctness;
- worker cleanup success;
- deterministic fallback correctness;
- p95 time to first visual response;
- TURN relay ratio;
- session termination reason distribution.

## Clarifications Needed

Please answer these before we begin implementation.

1. Should Phase 0 be locked to Cat-B top-level browser `GET` or `HEAD` only?
2. Which front-door component should own the provider adapter: Zeus, SWG proxy, or another service?
3. For Phase 0, should we preserve `POST /api/swg/sessions` plus `/swg/handoff`, or jump to a new `/v2/rbi/sessions` surface?
4. Do you approve the proposed language split: Node or TypeScript for bootstrap, Go for new control services, Rust only later, Python only for research?
5. What internal contract style is standard for new services: REST, gRPC, or mixed?
6. What approved crypto stack should be used for mTLS, JWT, JWE, and key management?
7. What media-gateway strategy should we assume: extend the current stack or adopt a specific framework?
8. What standard production substrate should we plan for: Firecracker-class microVM, Cloud Hypervisor, managed lightweight VM, or another approved option?
9. What canonical deploy target should we assume for new services: EKS, ECS, or both?
10. Do downstream consumers require temporary `X-SIG-RBI-*` compatibility, or can we define a new provider-neutral contract?
11. Do you want Phase 0 and Phase 1 to land in existing repos only, or should we create new target modules or repos early?
12. Which tenant cohort and app-profile set should be the first Cat-B certification target?

## Recommended Immediate Next Step

Answer the twelve clarification questions, then freeze M0 and M1 and start Agents 1,
2, 3, and 7 in parallel. Agent 4 can start contract stubs once M1 drafts are in
review. Agents 5 and 6 should begin once the adapter and contract shapes are stable.
