# Go Service Scaffolding

This directory holds the Go-native control-plane services for the in-house RBI
roadmap.

- `cmd/session-authority`: edge bootstrap and session-placement service entrypoint
- `cmd/media-gateway`: regional media gateway entrypoint
- `internal/contracts`: shared request and response contracts used between edge,
  Session Authority, gateway, and worker allocation layers

## Media Gateway

The media gateway now exposes concrete Wave 2 session-governance surfaces:

- `POST /v1/sessions`
  Registers a gateway-backed session, enforces admission rules, and returns the
  viewer and signaling URLs without exposing worker addresses.
- `GET /v1/sessions/:sessionId`
  Returns the registered request/response contract plus admission and signaling
  state for a specific session.
- `POST /v1/sessions/:sessionId/terminate`
  Marks the session terminated and closes active signaling sockets.
- `GET /v1/summary`
  Returns aggregate observability for gateway-backed sessions, including:
  - active session counts by tenant and worker;
  - signaling connection and relay counters;
  - explicit media-termination capability and per-session mode counts;
  - admission attempts, accepts, idempotent replays, rejects, and rejection
    reason codes;
  - current gateway quota configuration.

Admission control is configured with:

- `MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS`
- `MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_TENANT`
- `MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_WORKER`

`MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_WORKER` defaults to `1` when loaded from
environment so a worker cannot be admitted to multiple active sessions unless the
operator explicitly relaxes that guardrail.

## Production Media-Termination Default

The gateway contract now reports media termination capability explicitly on
`transport.mediaTermination` and in `/v1/summary.mediaTermination`.

Current production default is gateway-terminated WebRTC/SRTP:

- `mode`: `gateway-media-relay`
- `gatewayTerminatesSignaling`: `true`
- `gatewayTerminatesMedia`: `true`
- `mediaPlaneMode`: `gateway-webrtc-relay`
- `protocol`: `webrtc-srtp`

The rollback relay remains available through explicit configuration with
`MEDIA_GATEWAY_DEFAULT_RELAY_MODE=gateway-relay` and
`SESSION_AUTHORITY_RELAY_MODE=gateway-relay`. Direct or peer relay modes must stay
out of Cat-B.
