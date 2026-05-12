# SWG Integration Contract

## Bootstrap

```http
POST /api/swg/sessions
Content-Type: application/json
X-Cisco-Signature: <hmac-sha256>
X-Cisco-Timestamp: <epoch-ms>
X-Cisco-Transaction-Id: <swg-transaction-id>
X-MSIP-Tenant-UUID: <tenant-id>
X-MSIP-Profile-Id: <rbi-profile-id>
X-MSIP-Policy: <policy-id-or-policy-name>
X-Upstream-Host: <original-upstream-host>
X-Upstream-Scheme: http|https
X-Upstream-Port: <port>
```

Body:

```json
{
  "targetUrl": "https://example.com/",
  "viewport": {
    "width": 1920,
    "height": 1080,
    "deviceScaleFactor": 1
  },
  "client": {
    "browser": "cloudsec-swg",
    "source": "zeus"
  }
}
```

`X-Upstream-*` headers are sent explicitly by SWG for auditability. The runtime can derive
them from `targetUrl` when absent, but cloudsec integration should not rely on derivation.

Canonical string:

```text
method:POST
targetUrl:<targetUrl>
timestamp:<X-Cisco-Timestamp>
transactionId:<X-Cisco-Transaction-Id>
tenantId:<X-MSIP-Tenant-UUID>
profileId:<X-MSIP-Profile-Id>
policy:<X-MSIP-Policy>
upstreamHost:<X-Upstream-Host>
upstreamScheme:<X-Upstream-Scheme>
upstreamPort:<X-Upstream-Port>
```

Signature:

```text
hex(hmac_sha256(SWG_SHARED_SECRET, canonical_string))
```

## Golden HMAC Test Vectors

These vectors use a public dummy key and are safe to commit. They are the
release-gate contract for any SWG/Zeus bootstrap signer or verifier. Any change
to canonical field order, newline placement, key decoding, or HMAC algorithm
must update this document and the authoritative unit test
`test/swg-handoff.test.js`.

Public test secret, base64-encoded 32-byte key material:

```text
AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=
```

Bootstrap v1 canonical string:

```text
method:POST
targetUrl:https://wikipedia.org/wiki/RBI?source=swg
timestamp:1778572800123
transactionId:txn-golden-0001
tenantId:tenant-golden-11111111-2222-3333-4444-555555555555
profileId:default_rbi_profile
policy:isolate-wikipedia
upstreamHost:wikipedia.org
upstreamScheme:https
upstreamPort:443
```

Expected bootstrap v1 HMAC-SHA256 hex:

```text
a962e520be8e33c27222d6f2c10a6c37eb0ee6012aa36bea6ebf27302f903cc4
```

Bootstrap v2 canonical string:

```text
method:POST
contractVersion:v2
requestKind:https-decrypted-document
originalMethod:GET
targetUrl:https://wikipedia.org/wiki/RBI?source=swg
timestamp:1778572800123
transactionId:txn-golden-0001
tenantId:tenant-golden-11111111-2222-3333-4444-555555555555
profileId:default_rbi_profile
policy:isolate-wikipedia
provider:in_house
providerCategory:cat-b
fallbackProvider:fail_closed
fallbackReason:
upstreamHost:wikipedia.org
upstreamScheme:https
upstreamPort:443
```

Expected bootstrap v2 HMAC-SHA256 hex:

```text
18ccfaf692f6a02c0572ecb1f3caaa4f43a4abcd68ba3e335efb7ee34a029187
```

Legacy signed handoff canonical string:

```text
method:GET
sessionId:sess_golden_0001
targetUrl:https://wikipedia.org/wiki/RBI?source=swg
timestamp:1778572800123
transactionId:txn-golden-0001
tenantId:tenant-golden-11111111-2222-3333-4444-555555555555
profileId:default_rbi_profile
policy:isolate-wikipedia
upstreamHost:wikipedia.org
upstreamScheme:https
upstreamPort:443
```

Expected legacy signed handoff HMAC-SHA256 hex:

```text
17d55b2e66fd226adc78ad563e45c8ad6c5d2b196b5422668b3d744dcc34e7ea
```

Release gate:

- `npm run test:unit` in `cloudsec_remote_browser` must pass before changing
  the SWG contract or signer.
- Consumer repos that implement the bootstrap signer must carry an equivalent
  golden-vector test using the values above.
- Consumer release evidence must link the consumer test result to this contract
  and must not rely only on live round-trip handoff success.

Response:

```json
{
  "sessionId": "sess_...",
  "state": "allocating",
  "viewerUrl": "https://remote-browser.example.com/swg/handoff?token=<opaque-handoff-token>",
  "handoffUrl": "https://remote-browser.example.com/swg/handoff?token=<opaque-handoff-token>",
  "viewerEntryMode": "swg-handoff",
  "signalingUrl": "wss://remote-browser.example.com/ws",
  "viewerCookie": {
    "name": "rbi_viewer_sess_...",
    "path": "/",
    "httpOnly": true,
    "sameSite": "Lax",
    "secure": true
  },
  "swgContext": {
    "transactionId": "...",
    "tenantId": "...",
    "profileId": "...",
    "policy": "...",
    "upstreamHost": "...",
    "upstreamScheme": "https",
    "upstreamPort": "443"
  }
}
```

For SWG sessions, `viewerUrl` and `handoffUrl` intentionally point to the opaque handoff
URL, not directly to `/viewer`.

## Handoff

SWG redirects the browser to `handoffUrl`. By default the handoff URL carries a single
opaque `token` query parameter. The token is AEAD-wrapped with the shared SWG secret and
contains the session ID, target URL, transaction, tenant, profile, policy, and upstream
metadata. `GET /swg/handoff` still accepts the legacy signed cleartext query during
migration, but new handoff URLs are opaque by default.

`GET /swg/handoff` validates:

- session exists
- session was created by SWG bootstrap
- timestamp is fresh
- target/session/SWG context match stored session context
- opaque token decrypts successfully or legacy HMAC signature is valid
- handoff has not been replayed

On success it sets the first-party viewer cookie and redirects to:

```text
/viewer?sessionId=<sessionId>
```

## Replay And Freshness

- Bootstrap replay key: `bootstrap:<transactionId>`
- Handoff replay key: `handoff:<sessionId>:<transactionId>:<timestamp>`
- Default local timestamp tolerance: 5 minutes
- Default nonlocal timestamp tolerance: 90 seconds
- Default replay TTL: 10 minutes

Use Redis for replay protection in multi-instance deployments.

## Required SWG-Side Adapter

Cloudsec SWG/Zeus needs an adapter that:

- Runs only after final action `ISOLATE`.
- Applies traffic gating for the selected provider.
- Builds `targetUrl` from the original browser navigation.
- Maps policy context to tenant/profile/policy fields.
- Adds transaction and upstream context.
- Signs the bootstrap request.
- Calls `POST /api/swg/sessions`.
- Redirects the browser to returned `handoffUrl`.
- Falls back to Menlo during canary on missing config, timeout, 4xx/5xx, or malformed response.

## Target-Environment Proof Evidence

Prove the Zeus/nginx/runtime contract against each supplied target base URL
without local mock infrastructure. Required inputs are:

- `RBI_TARGET_BASE_URL`: target Zeus/nginx/runtime base URL.
- `SWG_SHARED_SECRET`: target SWG bootstrap signing secret.
- `WAVE1_PROOF_TARGET_URL`: browser navigation URL used for the proof.
- Expected bootstrap response shape: direct runtime JSON or Zeus/nginx redirect.
- Expected Menlo fallback prefix for bad-signature and replay drills.

The proof must sign the bootstrap with `OriginTypeId = 64`, validate the opaque
handoff token, rejects a malformed handoff token, verifies bootstrap replay,
follows the valid handoff, verifies handoff replay, and deletes the proof
session when the viewer cookie is issued.
