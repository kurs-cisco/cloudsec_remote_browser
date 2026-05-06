# Extraction Manifest

Source repo: `browser_isolation`

Target folder: `cloudsec_remote_browser`

## Copied Runtime Components

- `shared/swg-handoff.js`: SWG bootstrap and handoff canonicalization, signing, verification, and query/header extraction.
- `shared/target-url.js`: HTTP/HTTPS target URL normalization.
- `shared/viewport.js`: viewer-to-worker viewport computation.
- `app/token.js`: signed token primitive.
- `app/session-token.js`: viewer and worker session-token verification.
- `app/turn-credentials.js`: TURN REST HMAC credential generation.
- `app/session-store.js`: memory and Redis session state.
- `app/signal-bus.js`: memory and Redis signaling fanout.
- `app/worker-runtime.js`: worker launch adapter for Docker, ECS, and host-agent.
- `viewer/index.html`, `viewer/viewer.js`, `viewer/viewer.css`: pixel-stream viewer.
- `worker/*`: Chromium worker runtime, worker image, and TURN diagnostics.
- `deploy/chromium-seccomp.json`: Chromium worker seccomp profile.
- Relevant unit tests for signing, target URL normalization, token, TURN credentials, viewport, and session lifecycle.

## Rewritten Components

- `app/config.js`: reduced to SWG/runtime settings; removed admin/local-auth/extension defaults and default production secrets.
- `app/server.js`: reduced to SWG bootstrap, handoff, viewer/session APIs, signaling, health, and lifecycle GC.
- `Dockerfile`: control-plane-only image; does not copy admin or install Docker CLI.
- `package.json`: reduced scripts and dependencies.

## Excluded Components

- `extension/`
- `admin/`
- `services/swg-sim/`
- `experimental/hybrid-dom/`
- `viewer/launch.*`
- `viewer/hybrid.*`
- `infra/aws/`
- local-lab/simple-cloud/aws-single-vm compose stacks
- generated artifacts, `.playwright-cli`, `.npm-cache`, and `node_modules`
- any cloudsec policy-engine policy decision logic

## Remaining Coupling

The copied viewer and worker runtimes still contain disabled legacy branches from the
source package because they are interwoven with the WebRTC capture and reconnect loops.
In this extraction:

- the server does not expose `/launch`;
- the server does not expose hybrid viewer assets;
- `authMode` accepts only `swg`;
- `HYBRID_DOM_BRIDGE_ENABLED` is forced off in config.

Future cleanup can remove the dormant viewer hybrid/restart branches and worker hybrid
DOM methods after WebRTC-only regression coverage is available.

`app/worker-runtime.js` still supports Docker, ECS, and host-agent. Cloudsec should
replace or narrow this with the production scheduler adapter chosen for deployment.
