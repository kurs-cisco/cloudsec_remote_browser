# CloudSec RBI Backlog

## Stabilize KURS Dev RBI Runtime And 502 Debuggability

Status: RBI runtime changes deployed to KURS dev; SWG/PE bootstrap metadata gap remains

Priority: immediate for KURS dev reliability

### Context

Live inspection on 2026-05-06 showed the RBI control plane and target groups healthy.
The runtime is back on the normal rolling Deployment path with two runtime endpoints,
two session-authority endpoints, two media-gateway endpoints, and two warm-pool worker
pods. The remaining KURS `502 Bad Gateway` symptom is currently before RBI session
creation: PE returns an isolate verdict for origin-type `1` traffic, but does not return
RBI tenant/profile bootstrap metadata, so SWG falls through to the legacy upstream path
instead of issuing an RBI handoff.

### Stability Risks

- Persist the hotpatch runtime image through the normal deployment path; do not leave the
  `runtime` Service permanently pinned to the ad hoc `runtime-hotpatch` selector.
- Add at least two runtime backends before keeping hotpatch routing in place, or restore
  a normal rolling Deployment so one readiness flap does not remove all runtime endpoints.
- Fix session lifecycle cleanup: viewer unload or media disconnect must terminate or reap
  idle session workers and media-gateway state.
- Reset or recycle warm-pool workers after assignment so stale session capture state cannot
  contaminate the pool.
- Add live 502 correlation: SWG transaction id, RBI session id, ALB target response code,
  runtime request id, gateway session id, and worker pod id should be joinable.
- Enable/retain ALB access logs or equivalent target-response telemetry for RBI ingress.
- Increase control-plane HA: avoid single replicas for runtime/session-authority/media
  gateway in dev proof flows that are used for interactive testing.
- Review node capacity: the control node was near CPU request saturation, and worker
  capacity was concentrated on one Spot node.
- Review bootstrap NLB resilience: cross-zone was disabled while the active runtime target
  was in a single AZ.
- Confirm KURS PAC routes `dev-rbi.cubex.vyom.umbrella-engineering.com` and
  `*.cubex.vyom.umbrella-engineering.com` as `DIRECT` to avoid recursive SWG/RBI loops.

### Acceptance Criteria

- Triggering isolate traffic from the KURS Windows test host produces either a working RBI
  session or a correlated failure bundle with SWG transaction id and RBI session id.
- No stale session worker remains after viewer unload beyond the configured idle grace.
- Warm-pool workers return to a clean idle state after each assignment or are recycled.
- Runtime service has at least two healthy endpoints, or hotpatch routing is removed.
- Direct public RBI probes and proxied SWG browser flows are both covered in live proof.

### Implementation Notes

- Viewer unload and gateway/media disconnect now persist `viewerDisconnectedAt` and
  `viewerDisconnectReason` in the session store, so idle termination survives runtime
  restarts and pod replacement.
- Runtime now runs a periodic idle-session reaper plus an optional Kubernetes session-worker
  orphan reaper. The KURS dev defaults enable the orphan reaper and keep the grace window
  short for interactive test stability.
- Warm-pool workers can recycle after one assignment with `POOL_RECYCLE_AFTER_SESSION=1`,
  which is enabled in the shared worker config for the dev stack.
- The Terraform dev config now targets two control-plane replicas, and the ingress module
  exposes ALB access-log and bootstrap NLB cross-zone settings for deployment persistence.
- Live KURS verification on 2026-05-06 showed `/api/health` on the RBI public endpoint
  healthy with Redis-only backends, all RBI control deployments at `2/2`, and no stale
  session workers remaining after cleanup.
- Live KURS 502 correlation for `www.google.com` and `www.wikipedia.org` showed
  `RuleAction=4`, `PE-Action=4`, `OriginType=1`, and `RBITenantID=-`/`RBISettingID=-`
  on the PE lookup, followed by a contextless `502` to the legacy Menlo upstream
  `57.140.195.4:4000`. No RBI session id is created for that failure mode.

## Fix SWG/PE Origin-Type 1 RBI Bootstrap Metadata

Status: implemented locally in PE/Zeus, pending live PE and SWG image rollout

Priority: immediate for KURS dev RBI handoff

### Context

KURS dev isolate traffic for Google and Wikipedia is matching policy correctly, but
origin-type `1` responses from the live policy-engine path are missing the RBI bootstrap
tenant/profile metadata needed by SWG to call `/x-opendns-rbi-bootstrap/` and redirect the
browser to the in-house RBI handoff. The live SWG pod is still on
`swg-nginx-proxy-https:prod_r2348`, so local Zeus bootstrap compatibility changes are not
active in the running pod.

### Required Work

- Promote the current policy-engine RBI provider-selection change into
  `policy-engine-dev-kurs`, or set the dev-only `RBI_E2E_FORCE_CATB_PROVIDER_FOR_ISOLATE`
  path for that KURS PE deployment until provider-scoped RBI settings are naturally
  available.
- Promote the Zeus `/x-opendns-rbi-bootstrap/` Cat-B compatibility change into a new
  `swg-nginx-proxy-https` image and deploy it to `swg-nginx-proxy-https-dev-kurs`.
- Keep the compatibility guarded to origin-type `1`/`64` isolate decisions and in-house
  Cat-B routing. Do not broaden policy matching or treat non-isolate traffic as RBI.
- Verify KURS logs show PE lookup lines with non-empty `RBITenantID` and `RBISettingID`,
  followed by a `303` RBI handoff, not a contextless `502` to `57.140.195.4:4000`.

### Acceptance Criteria

- `https://www.google.com/` and `https://www.wikipedia.org/` through the KURS proxy return
  RBI `303 See Other` handoff responses for isolate policy, not SWG `502`.
- SWG logs include one transaction id from PE lookup through bootstrap and handoff.
- The handoff creates exactly one RBI session and assigns a warm-pool worker.
- The PE/Zeus regression tests cover origin-type `1` with missing provider metadata and
  prove bootstrap only runs when tenant/profile bootstrap headers are present.

## Replace Dev SWG Egress Proxy Shim With Real SWG Proxy Integration

Status: backlog

Priority: high before production RBI rollout

### Context

The development EKS environment currently includes `deploy/eks/dev-swg-egress-proxy.yaml`
to provide the in-cluster service name expected by RBI workers:

```text
swg-proxy.cloudsec-swg.svc.cluster.local:3128
```

This shim unblocks worker Chromium navigation during RBI development and live proof runs,
but it is not a production SWG proxy or policy-enforcement component.

### Required Work

- Deploy the real SWG proxy into the RBI/SWG runtime environment with the same stable
  service contract, or update worker configuration to point at the production SWG egress
  endpoint.
- Ensure worker egress always flows through the real SWG policy path, including identity,
  tenant, profile, policy, logging, and PE decision context.
- Preserve explicit deny behavior for metadata, Kubernetes API, Redis, VPC/internal CIDRs,
  link-local addresses, and cluster-local service names.
- Remove or gate `deploy/eks/dev-swg-egress-proxy.yaml` so it cannot be used as the
  production egress path.
- Update the EKS/Kata egress proof to validate the real proxy path instead of the dev shim.

### Acceptance Criteria

- RBI worker Chromium can browse public HTTPS only through the real SWG proxy.
- Direct worker public HTTPS without proxy fails.
- Direct metadata, Kubernetes API, Redis, VPC/internal CIDRs, and `8.8.8.8:53` fail.
- Proxied metadata/internal destinations receive a SWG deny response.
- SWG logs contain the expected tenant/profile/policy context for worker egress.
- The dev shim is absent from production overlays and cannot satisfy production proof checks.
