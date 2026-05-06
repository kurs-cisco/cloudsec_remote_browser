# Wave 1/2 Ops Evidence Runbook

Date: 2026-04-25

Use this runbook to collect the minimum operational evidence for a Cat-B Wave
1/2 go/no-go review. It ties target deployment evidence to the live Media
Gateway `/v1/summary` surface and keeps Menlo fallback as the safe default when
any gate fails.

## Evidence Sources

Collect target-environment edge proof evidence against each canary
Zeus/nginx/runtime base URL. The proof must verify the Cat-B
`OriginTypeId = 64` bootstrap shape, send a signed bootstrap to the supplied
base URL, validate the opaque `/swg/handoff` redirect contract, check
malformed-token rejection, check bootstrap replay rejection, check valid handoff
plus handoff replay, and delete the proof session when the viewer cookie is
issued.

Capture live gateway summary from each canary region:

```bash
curl -sS "$MEDIA_GATEWAY_BASE_URL/v1/summary" | jq .
```

Record the command, timestamp, region, gateway id, tenant/profile, test target,
and whether the request was a fresh bootstrap, fallback drill, replay drill, or
cleanup drill.

## Required Signals

Wave 1 bootstrap and handoff:

| Signal | Source | Pass evidence |
| --- | --- | --- |
| Bootstrap success | Zeus/runtime logs plus browser redirect | Eligible `OriginTypeId = 64` top-level browser `GET` or `HEAD` document navigation receives a redirect to `/swg/handoff` with an opaque token. |
| Handoff success | Runtime structured log | `swg-handoff-issued` for the session, with `handoffTransport=opaque`. |
| Replay rejection | Runtime response/log | Reusing the same SWG handoff returns HTTP `409` with `Replayed SWG handoff`; bootstrap replay is rejected by the same replay store path. |
| Menlo fallback | Policy prefs and Zeus logs | Prefs include `rbi-provider-fallback-reason`; Zeus fallback logs include the concrete reason when bootstrap setup or redirect validation fails. |
| Worker cleanup | Runtime logs and worker backend | Session termination or worker disconnect leads to `worker disconnected` termination and the worker stop path runs for Docker, ECS, or host-agent launch mode. |

Wave 2 gateway summary:

| `/v1/summary` field | Pass evidence |
| --- | --- |
| `region`, `gatewayId` | Match the canary region and expected gateway. |
| `sessionsTotal`, `activeSessions`, `activeSessionsByTenant`, `activeSessionsByWorker` | Counts match the drill scope; no unexpected active worker remains after cleanup. |
| `signalSessions`, `viewerConnected`, `workerConnected` | Active drill shows expected viewer/worker connection state. |
| `pendingViewerSignals`, `pendingWorkerSignals` | Return to `0` after connection drain and cleanup. |
| `viewerConnectEvents`, `workerConnectEvents`, `viewerDisconnectEvents`, `workerDisconnectEvents` | Increment during connect/disconnect and cleanup drills. |
| `viewerHeartbeats`, `viewerSignalMessages`, `workerStateUpdates` | Show non-zero liveness for an active session. |
| `signalsToViewer`, `signalsToWorker` | Show signaling relay activity for the active session. |
| `transports` | Uses the expected canary transport bucket, for example `webtransport`, `webrtc`, or `websocket`. |
| `mediaTermination.defaultCapability.mode` | Must be `signaling-relay-only` for default sessions. Gated canaries may use `gateway-media-relay` only when explicitly enabled. |
| `mediaTermination.defaultCapability.gatewayTerminatesSignaling` | Must be `true`. |
| `mediaTermination.defaultCapability.gatewayTerminatesMedia` | Must be `false` for the default path. A `gateway-media-relay` canary session may report `true` for that session capability. |
| `mediaTermination.wave2AcceptanceComplete` | Must remain `false` for mixed/default traffic. It may be `true` only in a deliberately scoped test where every active session uses `gateway-media-relay`. |
| `mediaRelaySessions`, `mediaViewerConnected`, `mediaWorkerConnected` | Must match the gated media relay drill scope. They should be `0` for default signaling-only drills. |
| `mediaFramesToViewer`, `mediaFramesToWorker`, `mediaBytesToViewer`, `mediaBytesToWorker` | Must increase only during a `gateway-media-relay` drill and return to expected idle behavior after cleanup. |
| `admission.attempts`, `admission.accepted`, `admission.rejected`, `admission.idempotentReplays` | Match the drill counts. |
| `admission.rejectionsByReason` | Contains only expected rejection codes for the drill. |
| `admission.quotas` | Match configured `MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS`, `MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_TENANT`, and `MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_WORKER`. |

Expected gateway admission rejection reason codes include:

- `active-sessions-quota-exceeded`
- `tenant-active-sessions-quota-exceeded`
- `worker-active-sessions-quota-exceeded`
- `session-id-conflict`
- `gateway-region-mismatch`
- `gateway-id-mismatch`
- `worker-assignment-mismatch`
- `unsupported-relay-mode`
- `assignment-session-id-mismatch`
- `direct-worker-public-endpoint`
- `session-id-required`
- `tenant-id-required`
- `viewer-token-required`
- `worker-token-required`
- `invalid-target-url`

Expected Zeus bootstrap fallback reasons currently include:

- `setup_failed`
- `prepare_failed`
- `subrequest_create_failed`

Also record policy-provided `rbi-provider-fallback-reason` values, for example
tenant canary holdback, kill-switch, or operator-defined rollout reasons. These
values are policy data, not gateway admission reason codes.

## Evidence Template

```text
Review:
Date/time:
Operator:
Tenant/profile:
Region:
Gateway ID:
Target URL:
Traffic class:
Validation method:
Validation result:
Summary command:
Summary snapshot path or paste:

Wave 1:
Bootstrap result:
Handoff result:
Replay rejection result:
Fallback drill reason:
Worker cleanup result:

Wave 2:
Admission attempts/accepted/rejected/idempotentReplays:
Admission rejectionsByReason:
Active sessions by tenant:
Active sessions by worker:
Pending viewer/worker signals after cleanup:
Worker connect/disconnect events:
Transport counts:
Media termination mode:
Gateway terminates signaling:
Gateway terminates media:
Wave 2 acceptance complete:

Decision:
Go / No-go:
Owner for follow-up:
Expiry for this evidence:
```

## Go/No-Go Gates

Go for a narrow Wave 1 Cat-B canary only when:

- Target proof evidence is complete and attached.
- Eligible Cat-B `GET`/`HEAD` document traffic reaches `/swg/handoff`.
- Non-eligible traffic and bootstrap failures deterministically fall back to
  Menlo with a recorded fallback reason.
- Handoff replay is rejected with HTTP `409`.
- Worker cleanup leaves no unexpected active worker/session in runtime state or
  `/v1/summary.activeSessionsByWorker`.

Go for Wave 2 gateway-backed canary only when:

- `/v1/summary` is reachable for every canary region.
- Admission counters and rejection reasons match the drill plan.
- Pending viewer/worker signals return to zero after cleanup.
- Worker connect/disconnect events prove cleanup behavior.
- Worker addresses are not present in browser-facing viewer or signaling URLs.
- Default sessions explicitly acknowledge `mediaTermination.wave2AcceptanceComplete=false`.
- Gated `gateway-media-relay` drills explicitly record `mediaRelaySessions`,
  frame counters, byte counters, and whether all active sessions used the media
  relay path.

No-go if any of the following are true:

- Target proof evidence is missing or fails.
- Fallback occurs without a concrete reason.
- Replay succeeds or returns a non-409 result for the same SWG handoff.
- Cleanup leaves an orphan worker, active session, or persistent pending signal.
- `/v1/summary.admission.rejectionsByReason` contains an unexpected reason.
- The dashboard or evidence packet implies gateway-terminated media is complete
  for default traffic while `gatewayTerminatesMedia=false`.
