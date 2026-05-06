# Cloudsec Remote Browser

`cloudsec_remote_browser` is the SWG-facing runtime extracted from `browser_isolation`.
It intentionally does not include policy management, browser extension routing, local SWG
simulator policy/admin UI, or cloudsec policy-engine logic. SWG and policy-engine remain
the systems of record for isolate decisions.

## Included Runtime

- `POST /api/swg/sessions`: signed SWG bootstrap that creates a remote browser session.
- `GET /swg/handoff`: opaque first-party handoff that sets the viewer cookie.
- `GET /viewer`, `/viewer.js`, `/viewer.css`, `/shared/viewport.js`: viewer shell and client code.
- `GET /api/sessions/:sessionId`: viewer-authenticated session state.
- `POST /api/sessions/:sessionId/refresh`: viewer-authenticated worker/session refresh.
- `DELETE /api/sessions/:sessionId`: viewer-authenticated session termination.
- `/ws`: viewer signaling.
- `/ws/worker`: worker signaling.
- Worker runtime, worker image, TURN credential generation, Redis-backed session/signaling state.

## Explicitly Not Included

- Browser extension.
- Policy management or SWG simulator policy UI.
- Admin UI and admin APIs.
- Direct public launch page.
- Hybrid DOM experiment UI.
- Menlo file/DLP/FTC parity flows.
- Cloudsec policy-engine RBI action computation, AIC parsing, or package downgrade logic.

## Integration Model

1. Cloudsec policy-engine and SWG decide final action `ISOLATE`.
2. SWG selects `browser_isolation` or `cloudsec_remote_browser` as the provider for an eligible traffic slice.
3. SWG signs and sends `POST /api/swg/sessions`.
4. `cloudsec_remote_browser` creates a remote browser worker session and returns an opaque `handoffUrl`.
5. SWG redirects the browser to `handoffUrl`.
6. `/swg/handoff` validates the opaque token, still accepts the legacy signed query for compatibility, sets the first-party viewer cookie, and redirects to `/viewer`.

In the current intended product model, Menlo can remain the active provider for
Cat-A traffic while `cloudsec_remote_browser` serves Cat-B traffic.

The recommended first traffic slice remains canaried top-level browser `GET` or `HEAD`
document navigations. File view, download, upload, user-input, DLP, FTC, local AV,
non-browser, and `CONNECT` flows should remain on the existing Menlo path until parity
is designed and implemented.

## Runtime Requirements

- Node.js 22 for the control plane.
- Redis in multi-instance deployments.
- TURN/coturn with REST HMAC credentials.
- A worker launch mode: `docker`, `ecs`, or `host-agent`.
- Worker image built from `worker/Dockerfile`.

## Runtime Operation

This package no longer exposes npm helper scripts for proofs, validation, or
image builds. Run the Node control plane directly when developing locally:

```bash
node app/server.js
```

Build images directly with Docker:

```bash
docker build -t cloudsec-remote-browser-control-plane .
docker build -t cloudsec-remote-browser-worker ./worker
```

Use the Bash deployment wrappers under `scripts/` for Terraform environment
management. Target-environment proof evidence should be collected from the
deployed SWG, gateway, runtime, and worker logs/runbooks.

See `.env.example`, `docs/SWG_INTEGRATION_CONTRACT.md`, `docs/rbi-arch.md`,
`docs/cloudsec_rbi_master_plan.md`, and
`docs/cloudsec_rbi_implementation_readiness_assessment.md`, and
`docs/cloudsec_rbi_parallel_execution_plan.md` for the SWG contract, current runtime
architecture, master delivery direction, SSE integration readiness, and execution plan.
