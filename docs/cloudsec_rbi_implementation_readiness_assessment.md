# Cloudsec RBI Implementation Readiness Assessment

**Status:** Assessed against the current workspace on 2026-04-24  
**Question:** Is the current in-house RBI plan implementation-ready for an existing SSE
product that already ships Menlo-backed RBI, with Menlo retained for Cat-A traffic
and the in-house provider serving Cat-B traffic?

## Executive Verdict

Not yet. The current plan is **directionally strong** but **not implementation-ready**
for broad Cat-B production as a second RBI provider alongside Menlo.

The current workspace supports only a narrower claim:

- the in-house RBI runtime is real enough for a bounded Phase 0 canary;
- the existing SSE product is still wired around Menlo-specific contracts, routes,
  file semantics, and downstream enforcement;
- the only plausible near-term Cat-B slice is **top-level browser `GET` or `HEAD`
  document navigation**, with deterministic fallback to Menlo;
- file view, upload, download, user-input, DLP, FTC, MPS, local AV, non-browser,
  and `CONNECT` flows are **not ready** to move off Menlo.

Treat the current state as **plan-ready for staged dual-provider integration**, not
**implementation-ready for broad Cat-B production**.

## Assumed Operating Model

- **Cat-A** traffic continues to Menlo by design.
- **Cat-B** traffic is routed to the in-house RBI provider when the control plane
  selects that lane.
- Unsupported Cat-B subflows fall back to Menlo until parity is intentionally built.

This means the right question is not "Can we replace Menlo?" The right question is
"Can SSE support a clean dual-provider RBI split with correct category routing,
fallback, and downstream semantics?" Today, the answer is still not fully yes.

## Assessment Scope

Parallel domain reviews were run across the RBI-relevant repos in this workspace.

| Domain | Repos assessed |
| --- | --- |
| Current and target in-house RBI | `cloudsec_remote_browser`, `browser_isolation` |
| Policy and control plane | `cloudsec-atlantis-policy-engine`, `cloudsec-atlantis-flash-policy-engine`, `cloudsec-atlantis-beaker-server`, `cloudsec-atlantis-deploy-sig-eks`, `cloudsec-atlantis-pe-lb` |
| Front door and proxy enforcement | `cloudsec_Athena_zeus-nginx`, `cloudsec_Athena_swg-nginx-proxy-https`, `cloudsec_Athena_swg-proxy`, `cloudsec_Athena_envoy-filter` |
| Data control and downstream scan path | `cloudsec_Athena_mps`, `cloudsec_iproxy_mps`, `cloudsec_Athena_deploy-sig-eks` |

## Readiness Scorecard

| Area | Status | Assessment |
| --- | --- | --- |
| Runtime-only in-house RBI service | Partial | `cloudsec_remote_browser` can create signed sessions and handoff users into a remote browser runtime, but it is intentionally not the policy product and does not provide Menlo parity for downstream data-control flows |
| SSE front door integration | Not ready | Existing Zeus and SWG repos do not implement the bootstrap and handoff contract used by the in-house runtime |
| Policy engine contract | Not ready | Current policy outputs remain Menlo-shaped and do not carry provider-neutral routing, canary, or fallback state |
| Deployment and secret wiring | Not ready | Current deploy defaults still point to Menlo hosts and Menlo-named secrets |
| File, DLP, FTC, AV, and MPS parity | Not ready | Current downstream components depend on `X-SIG-RBI-*` semantics and Menlo-style file routing; the in-house runtime explicitly does not provide that parity yet |
| Target-state gateway and Session Authority | Not ready | They are architectural requirements in the plan, not implemented services in the current runtime |
| VM-backed production isolation tier | Not ready | The current runtime is still container and task oriented, while the plan requires VM-backed mainstream isolation |
| Narrow Cat-B canary | Feasible after bounded integration work | A top-level browser `GET` or `HEAD` document slice is implementable after new adapter, config, telemetry, and fallback work |

## Highest-Severity Blockers

### 1. No SSE provider adapter exists for the in-house bootstrap and handoff model

The in-house contract expects SWG to call `POST /api/swg/sessions`, receive a
`handoffUrl`, and redirect the browser into `/swg/handoff`.

That model is documented in:

- `cloudsec_remote_browser/docs/SWG_INTEGRATION_CONTRACT.md`
- `cloudsec_remote_browser/docs/rbi-arch.md`
- `cloudsec_remote_browser/docs/cloudsec_rbi_master_plan.md`

But the current front door does something else:

- Zeus still chooses an RBI upstream inline in
  `cloudsec_Athena_zeus-nginx/exe-nginx/modules/zeus/ngx_http_zeus.c:1976`
- the custom-tenant path still behaves like an inline upstream target in
  `cloudsec_Athena_zeus-nginx/exe-nginx/modules/zeus/ngx_http_zeus.c:4049`
- repo searches across `cloudsec_Athena_zeus-nginx`, `cloudsec_Athena_swg-proxy`,
  `cloudsec_Athena_swg-nginx-proxy-https`, and `cloudsec_Athena_envoy-filter`
  found no existing `/api/swg/sessions`, `/swg/handoff`, `handoffUrl`, or
  `viewerEntryMode` wiring

This is the main dual-provider product-integration blocker.

### 2. Policy-engine outputs are still Menlo-specific, not provider-neutral

The policy side still emits the current Menlo-oriented isolate model:

- only one external isolate setting exists in
  `cloudsec-atlantis-policy-engine/internal/pkg/settings/settings.go:90`
- proxy header generation is explicitly tied to Menlo control domains in
  `cloudsec-atlantis-policy-engine/pkg/rbi/advanced_isolation_control.go:668`
- Menlo-specific URL and control-domain handling still exists in
  `cloudsec-atlantis-policy-engine/internal/pkg/api/prefsapi/prefsapi.go`
  and `cloudsec-atlantis-policy-engine/pkg/query/query.go`

What is missing today:

- Cat-A or Cat-B category-to-provider mapping
- provider selection
- provider canary state
- provider kill switch
- fallback permission and reason model
- explicit profile and upstream contract for the in-house provider

Without that contract, the in-house runtime cannot be treated as a first-class Cat-B
RBI provider inside SSE.

### 3. Deploy and runtime wiring is still pointed at Menlo

Current deployment defaults remain Menlo-backed:

- `cloudsec_Athena_deploy-sig-eks/swg-nginx-proxy-https/helmchart/helmvalues/swg-nginx-proxy-https-consul-values.yaml:19`
- `cloudsec_Athena_deploy-sig-eks/swg-nginx-proxy-https/helmchart/helmvalues/swg-nginx-proxy-https-consul-values.yaml:25`
- `cloudsec_Athena_swg-nginx-proxy-https/static_resources/opt/nginx/conf/consul_values.py:156`
- `cloudsec_Athena_swg-nginx-proxy-https/static_resources/service/aws-secret-syncer/config-sse.json:21`

This means the current SSE deploy path still assumes:

- Menlo RBI upstreams
- Menlo-oriented secret names
- Menlo health and runtime assumptions

The provider-side infrastructure for the in-house RBI exists separately in
`browser_isolation`, but it is not wired into the SSE deployment repos.

### 4. File, DLP, FTC, AV, and MPS parity is not available

This is the largest parity gap after bootstrap.

Current downstream systems consume RBI-specific metadata:

- `cloudsec_Athena_mps/mps-model/src/main/java/net/scansafe/headers/SigHeader.java:54`
- `cloudsec_iproxy_mps/mps-scanner/src/main/java/net/scansafe/proxylets/business/MpsIdentity.java:551`
- `cloudsec_Athena_envoy-filter/src/common/header_extractor.cc:152`
- `cloudsec_Athena_envoy-filter/src/request_body_dlp/request_body_dlp.cc:543`
- `cloudsec_Athena_envoy-filter/src/response_body_scan/response_body_scan.cc:914`

The in-house runtime explicitly says this parity is not included yet:

- upload brokering is not included
- download brokering is not included
- Safe-PDF and original-file semantics are not included
- DLP and FTC verdict propagation is not included
- local AV passthrough is not included
- `X-SIG-RBI-File-*` equivalent metadata is not included

See `cloudsec_remote_browser/docs/NOT_INCLUDED.md:26`.

This is why the current in-house route can only target a narrow Cat-B browsing slice.

### 5. The target topology in the plan does not match the current runtime

The execution plan requires:

- opaque or JWE handoff
- Session Authority allocation
- regional media gateway ingress
- no direct viewer exposure to workers
- VM-backed standard runtime

See:

- `cloudsec_remote_browser/docs/cloudsec_rbi_product_architecture_execution_plan.md:325`
- `cloudsec_remote_browser/docs/cloudsec_rbi_product_architecture_execution_plan.md:339`
- `cloudsec_remote_browser/docs/cloudsec_rbi_product_architecture_execution_plan.md:363`
- `cloudsec_remote_browser/docs/cloudsec_rbi_product_architecture_execution_plan.md:397`

The current runtime still behaves as a transitional Gen-1 service:

- signed handoff URLs still carry visible metadata in
  `browser_isolation/app/server.js:1317`
- viewer and worker signaling still terminate in the control plane over `/ws` and
  `/ws/worker`
- the active session model is still `SessionStore + SignalBus + WorkerRuntime`

The current runtime is useful, but it is not yet the target production shape.

### 6. The plan itself still contains missing delivery contracts

The master plan already admits that current-to-target migration and early-phase
contracts still need to be finalized:

- `cloudsec_remote_browser/docs/cloudsec_rbi_master_plan.md:24`
- `cloudsec_remote_browser/docs/cloudsec_rbi_master_plan.md:205`
- `cloudsec_remote_browser/docs/cloudsec_rbi_master_plan.md:452`

The execution plan also lists the first-90-day items as future work, not completed
implementation:

- Session Authority
- media gateway
- JWE handoff
- runtime abstraction
- microVM-backed production tier
- broker APIs

See `cloudsec_remote_browser/docs/cloudsec_rbi_product_architecture_execution_plan.md:1144`.

## What Is Real And Reusable Today

The assessment is not saying there is no in-house RBI implementation. It is saying
the existing implementation is not yet integrated into the dual-provider SSE product
boundary.

What is already real:

- `cloudsec_remote_browser` has signed SWG bootstrap, first-party handoff, viewer,
  session lifecycle, worker launchers, and Redis/TURN-backed signaling
- `browser_isolation` already contains deployable AWS control-plane pieces such as
  ALB, Redis, TURN-secret injection, and ECS worker/runtime wiring
- the runtime is sufficient to support a bounded provider experiment once the SSE
  adapter exists

What is not yet real inside the SSE product:

- Cat-A or Cat-B policy and routing contract
- SWG or Zeus bootstrap adapter
- provider canary and kill switch integrated in product control surfaces
- file and DLP parity
- gateway and Session Authority production topology
- VM-backed mainstream isolation

## What Can Be Implemented Now

The only implementation slice that is close enough to pursue immediately is:

- Cat-B top-level browser `GET` or `HEAD` document navigations only

That slice must include:

- explicit provider canary
- deterministic fallback to Menlo on bootstrap or session-establishment failure
- unsupported-flow lockout
- clear production telemetry
- no attempt to own file or non-browser flows

The following traffic should remain on Menlo until parity exists:

- all Cat-A traffic by design
- file view
- upload
- download
- user-input and brokered file actions
- DLP and FTC-sensitive payload paths
- local AV-dependent flows
- `CONNECT`
- non-browser traffic
- unsupported app profiles

## Minimum Work Before Calling This Cat-B Implementation-Ready

### Minimum work for a bounded Phase 0 canary

1. Add Cat-A or Cat-B provider selection, canary percentage, and hard kill switch to
   policy and SWG.
2. Build the Zeus or SWG adapter that calls `POST /api/swg/sessions` and redirects to
   `/swg/handoff`.
3. Add deploy-time provider config, bootstrap secret, timeout policy, health checks,
   and Menlo fallback wiring.
4. Lock the supported traffic slice to top-level browser `GET` or `HEAD` only.
5. Add observability for bootstrap success, handoff success, session establishment,
   fallback correctness, worker cleanup, and replay rejection.
6. Enforce explicit unsupported-flow fallback to Menlo.

### Minimum work for broader in-house Cat-B product readiness

1. Define and implement the SSE provider-adapter contract.
2. Define and implement the bootstrap-to-Session Authority contract.
3. Define and implement the Session Authority-to-gateway and worker-assignment contract.
4. Move viewer ingress behind the regional media gateway.
5. Decide and implement the VM-backed standard runtime tier.
6. Build brokered upload, download, clipboard, and print paths.
7. Provide downstream parity for `X-SIG-RBI-*` style metadata or replace those
   dependencies with a new agreed contract.
8. Integrate DLP, FTC, AV, MPS, and Envoy semantics for in-house provider flows.
9. Certify app-profile coverage for the first supported SaaS and internal apps.

Until that set exists, the program should not claim broad Cat-B production readiness.

## Final Recommendation

Proceed with the current plan only under this framing:

- the architecture direction is strong;
- the current codebase is **not** implementation-ready for broad Cat-B production;
- the near-term deliverable is a **controlled additive provider canary**, not a
  provider cutover;
- Menlo remains the Cat-A provider and the fallback or scope boundary until bootstrap
  integration, data-control parity, gateway insertion, and VM-backed isolation are
  all real and verified.

In short: **strong plan, partial runtime, low-to-medium dual-provider readiness**.
