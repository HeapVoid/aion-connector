# Connector OAuth Design

**Status:** approved 2026-04-18

**Scope:** eliminate manual Anthropic API key entry from `install.sh`. Admin authorizes Claude Code on a Workspace via device-code OAuth flow, triggered from the AION UI. Covers transport, PB routes, aion-server worker, UI, installer changes, re-auth detection, and test strategy.

**Depends on:** `2026-04-17-workspace-registration-design.md` (§5 device-code OAuth flow, §9 TLS/fingerprint/token model). This doc operationalizes §5 and narrows §9 to concrete storage decisions.

**Relation to existing code:** ~60% infrastructure already present. `aion-connector/src/routes.imba` mounts `/coordinator/oauth/start` and `/coordinator/oauth/complete`. `claude-code-adapter.imba` implements `startAuth!` and `submitAuthCode!` via `claude setup-token`. `tls.imba` generates self-signed server cert and computes fingerprints (lowercase hex, 64 chars, no colons). `workspaces` schema has `authMode: select(['api_key','oauth'])` from migration 019.

---

## 1. Architecture

Four-hop admin-driven flow, no persistence of the OAuth `code` anywhere on AION side.

```
admin clicks "Authorize" in UI
  │
  ├─> AION UI: POST /api/workspaces/:id/oauth/start
  │     │
  │     ├─> PB hook (Goja): $http.send("http://127.0.0.1:8787/internal/oauth/start")
  │     │     │
  │     │     ├─> aion-server: pinned TLS fetch to https://{externalIp}:{port}/coordinator/oauth/start
  │     │     │     │
  │     │     │     ├─> connector: spawn `claude setup-token`, parse OAuth URL from stdout
  │     │     │     └─> returns {url}
  │     │     └─> returns {url}
  │     └─> returns 200 {url}
  │
  ├─> UI opens url in new tab; admin logs in at Anthropic; gets code
  │
  └─> admin pastes code into UI form
        │
        ├─> UI: POST /api/workspaces/:id/oauth/complete {code}
        │     │
        │     ├─> PB hook: $http.send("http://127.0.0.1:8787/internal/oauth/complete")
        │     │     │
        │     │     ├─> aion-server: pinned TLS fetch to connector /coordinator/oauth/complete
        │     │     │     │
        │     │     │     ├─> connector: write code to `claude setup-token` stdin
        │     │     │     └─> on exit 0: returns {status: "authorized"}
        │     │     └─> returns {status: "authorized"}
        │     └─> PB hook: updates workspace.lastAuthorizedAt, state=online, detail=""
        └─> returns 200 {status: "authorized"}
```

**Key invariant:** the OAuth `code` lives in memory of three processes (browser, PB Goja, aion-server) for ~2 seconds and never touches disk on the AION side. No queue table, no async job persistence.

---

## 2. Data model

### 2.1 `workspaces` collection — added fields

Migration `020_workspace_aion_token.imba`:

```imba
collection.field.text('aionToken', { max: 128 })
# Plaintext bearer for AION→VPS calls. Cannot be hashed because
# aion-server needs to send it. Threat model: if pb_data is
# compromised, full user/workspace data is already exposed;
# separate encryption of this field adds marginal protection.
```

Migration `021_workspace_detail.imba`:

```imba
collection.field.text('detail', { max: 64 })
# Free-form health detail from connector heartbeat.
# Known values: 'not_authorized', 'claude_missing', 'creds_corrupt'.
# Free-form (not select) so new codes land without migration.
```

Existing fields unchanged: `workspaceTokenHash`, `fingerprint`, `externalIp`, `port`, `state`, `lastHeartbeatAt`, `lastAuthorizedAt`, `authMode`.

### 2.2 What is stored where

| Data | Location | Form |
|---|---|---|
| `workspaceToken` (VPS→AION bearer) | VPS: `/etc/aion-connector/workspace-token` (600 root); PB: `workspaceTokenHash` only | plaintext on VPS, sha256 on AION |
| `aionToken` (AION→VPS bearer) | VPS: `/etc/aion-connector/aion-token` (600 root); PB: `aionToken` field | plaintext on both sides |
| OAuth `code` (transient) | never persisted | in-memory only |
| Anthropic OAuth tokens | VPS: `~/.claude/credentials.json` (adapter private) | plaintext, adapter domain |
| VPS server cert fingerprint | PB: `fingerprint` field | lowercase hex, 64 chars |
| AION→PB shared secret | `pb_data/.env` + aion-server env: `AION_INTERNAL_TOKEN` | plaintext env |

### 2.3 Explicitly NOT encrypting at rest

- `aionToken` — argued in Section 1 of brainstorm: scope is single-VPS access, compromise-equivalent to full DB read
- OAuth `code` — never persists, encryption moot
- Anthropic OAuth tokens — adapter-owned on VPS, never touches AION

Spec §9 line 242 ("API keys: encrypted at rest in AION") remains in force **for Anthropic API keys** when `--auth-mode api_key` path is wired end-to-end. That's a separate deliverable.

---

## 3. PB routes

### 3.1 New routes

`POST /api/workspaces/:id/oauth/start` — admin-auth'd. Forwards to aion-server `/internal/oauth/start` via `$http.send` (localhost). Returns connector's `{url}` verbatim.

`POST /api/workspaces/:id/oauth/complete` — admin-auth'd. Forwards to aion-server `/internal/oauth/complete` with `{code}` in body. On success:

```imba
rec.set('lastAuthorizedAt', new Date!.toISOString!)
rec.set('state', 'online')
rec.set('detail', '')
$app.save(rec)
```

Returns `{status: "authorized"}` verbatim. On connector error: does NOT modify workspace record; returns error status from aion-server.

### 3.2 Updated handler: heartbeat

`POST /api/workspaces/:id/heartbeat` — accept new optional `detail` field in body:

```imba
rec.set('state', body.state)
rec.set('lastHeartbeatAt', new Date!.toISOString!)
rec.set('detail', body.detail or '')
$app.save(rec)
```

Cron `cron.workspace-lifecycle.pb.imba` — unchanged. Flip-to-offline logic on stale heartbeat is orthogonal to `detail`.

### 3.3 Updated handler: enrollment

`POST /api/workspaces/enroll` — in addition to generating `workspaceToken`:

```imba
const aionToken = randomHex(32)
rec.set('aionToken', aionToken)
# ... existing workspaceToken handling ...
return e.json(201, {
    workspace_id: rec.id
    workspace_token: workspaceToken
    aion_token: aionToken
})
```

Accept `authMode` in request body, store verbatim; validate against `['api_key', 'oauth']`.

### 3.4 PB ↔ aion-server auth

Shared secret `AION_INTERNAL_TOKEN` (64 hex chars) in both `pb_data/.env` and aion-server env. PB sends `X-Internal-Token` header on every `$http.send` to `127.0.0.1:8787/internal/*`. aion-server rejects 401 on mismatch. aion-server listens on `127.0.0.1` only (not `0.0.0.0`).

Rotation: regenerate both envs + restart both services. Installer generates at first AION deploy and writes both envs.

---

## 4. aion-server module

New file `aion-server/src/connector.imba`. Mounts `/internal/oauth/start` and `/internal/oauth/complete` routes on existing `Bun.serve` router. Follows the module pattern of `src/push.imba`.

### 4.1 TLS pinning

```imba
import { Agent } from 'undici'
import { createHash } from 'node:crypto'

def pinnedAgent serverFp
    new Agent({
        connect: {
            rejectUnauthorized: false   # pin by fp, not CA chain
            checkServerIdentity: do(host, cert)
                const got = createHash('sha256').update(cert.raw).digest('hex')
                return new Error("fp mismatch") if got !== serverFp
                return undefined
        }
    })
```

`serverFp` format: lowercase hex, 64 chars, no colons — matches `aion-connector/src/tls.imba:fingerprint()` output. No uppercase conversion or colon-stripping needed.

No mTLS, no client cert. Outbound AION→VPS auth is bearer-only via `aionToken`.

### 4.2 Outbound call helper

```imba
def callConnector workspace, path, body
    const res = await fetch("https://{workspace.externalIp}:{workspace.port}{path}", {
        method: 'POST'
        dispatcher: pinnedAgent(workspace.fingerprint)
        headers: {
            'Content-Type': 'application/json'
            'Authorization': "Bearer {workspace.aionToken}"
        }
        body: JSON.stringify(body)
        signal: AbortSignal.timeout(10_000)
    })
    return { status: res.status, json: await res.json! }
```

10s timeout covers `claude setup-token` cold start. No retries — failure surfaces to UI, admin retries manually.

### 4.3 Route handlers

`/internal/oauth/start`:
1. Verify `X-Internal-Token` header; 401 on mismatch
2. Look up workspace by `workspaceId` via PB REST as superuser — reuses existing `_superusers.authWithPassword(PB_EMAIL, PB_PASSWORD)` pattern from `aion-server/src/push.imba`. Fetches `externalIp`, `port`, `fingerprint`, `aionToken`.
3. `callConnector(workspace, '/coordinator/oauth/start', {})`
4. Return status + JSON verbatim

`/internal/oauth/complete`:
1. Verify `X-Internal-Token`
2. Look up workspace (same pattern as above)
3. `callConnector(workspace, '/coordinator/oauth/complete', {code: body.code})`
4. Return status + JSON verbatim

aion-server **only reads** workspace records — never writes. State mutation on OAuth success happens in the PB hook that called us (see §3.1), eliminating cross-service write coordination.

### 4.4 Graceful shutdown

SIGTERM handler closes pending connector calls (via AbortController). In-flight admin requests get 503. Follow existing pattern in `aion-server/src/index.imba`.

---

## 5. UI

### 5.1 New component: `workspace-oauth-modal.imba`

State machine:

| State | Display | Transition |
|---|---|---|
| `idle` | "Authorize Claude Code" button | click → `starting` |
| `starting` | spinner "Starting OAuth…" | POST `/oauth/start` → `awaiting_code` on 200, → `error` on 4xx/5xx |
| `awaiting_code` | `{url}` copyable + "Open in new tab" auto-opens it + input `[code]` + "Submit" | submit → `submitting` |
| `submitting` | spinner "Verifying…" | POST `/oauth/complete` → `success` on 200, → `error` on error |
| `success` | "✓ Authorized" + "Close" | close → modal dismisses |
| `error` | error message + "Try again" | click → `idle` |

Opens only on explicit user click. No auto-open after create-workspace.

### 5.2 CTA on workspace detail page

Banner above tabs, shown when:
- `authMode === 'oauth'` AND `lastAuthorizedAt === null` — first-time authorization prompt
- `state === 'degraded'` AND `detail === 'not_authorized'` — re-auth prompt

Click opens `workspace-oauth-modal`.

Plus small "Re-authorize" link in workspace settings tab — always available, even when healthy, for proactive rotation.

### 5.3 Updates to `workspace-create-modal.imba`

- Add `<option value='oauth'>OAuth (Claude CLI)</option>` to authMode dropdown
- Hide api-key input when `oauth` selected
- Installer-step text appends: *"After the connector comes online, open the workspace page and click Authorize Claude Code to complete setup."*
- No auto-redirect to OAuth modal

### 5.4 State propagation

Workspace record subscribed via `pb.collection('workspaces').subscribe(id, ...)` (existing). Any mutation from `/oauth/complete` or heartbeat → realtime push → UI rerenders → CTA appears/disappears automatically.

### 5.5 Explicitly not building

- Polling status from UI after modal close — realtime handles it
- Auto-retry on `error` state — admin explicitly re-clicks
- Expiry countdown display — Anthropic doesn't expose expiry to UI ahead of time

---

## 6. Installer changes

### 6.1 New CLI mode

```bash
curl ... | sudo bash -s -- \
    --token <enrollment_token> \
    --aion <aion_url> \
    --auth-mode oauth
```

Existing `--auth-mode api_key [--api-key K]` branch unchanged.

`--aion-token` is NOT a flag — it's returned in the enrollment response.

### 6.2 Enrollment handshake

Installer POSTs to `/api/workspaces/enroll` with `authMode: 'oauth'` in body. Receives:

```json
{
    "workspace_id": "uuid",
    "workspace_token": "<plaintext>",
    "aion_token": "<plaintext>"
}
```

### 6.3 File writeouts

Always (both auth modes):

```bash
install -m 600 -o connector -g connector \
    <(echo "$workspace_token") \
    /etc/aion-connector/workspace-token

install -m 600 -o connector -g connector \
    <(echo "$aion_token") \
    /etc/aion-connector/aion-token
```

Only for `api_key` mode: create `/etc/aion-connector/credentials.env` with `ANTHROPIC_API_KEY=...`.

### 6.4 claude CLI dependency

Installer always ensures `claude` is in PATH:

```bash
if ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code
fi
```

No-op if already installed (npm upgrades to latest, fine).

### 6.5 Connector boot

In `aion-connector/src/server.imba`:

```imba
import { readFileSync } from 'node:fs'

const AION_TOKEN = readFileSync('/etc/aion-connector/aion-token', 'utf-8').trim!

def requireAionAuth req
    const header = req.headers.get('authorization') or ''
    const bearer = header.startsWith('Bearer ') ? header.slice(7) : ''
    return new Response('', {status: 401}) if bearer !== AION_TOKEN
    return null
```

Applied to all `/coordinator/*` routes. Token loaded once at process start; rotation requires restart.

### 6.6 Backfill for existing workspaces

Not automated in this spec. Existing workspaces (none in prod yet as of 2026-04-18) require re-enrollment via future endpoint `/api/workspaces/:id/rotate-tokens` — out of scope here, documented in runbook.

---

## 7. Re-auth detection & automation

### 7.1 Connector `health!` reads credentials.json

Extend `ClaudeCodeAdapter.health!` in `aion-connector/src/claude-code-adapter.imba`:

```imba
def health
    try
        await which('claude')
    catch
        return { healthy: false, detail: 'claude_missing' }
    
    const credsPath = join(homedir!, '.claude/credentials.json')
    unless await exists(credsPath)
        return { healthy: false, detail: 'not_authorized' }
    
    try
        const creds = JSON.parse(await readFile(credsPath, 'utf-8'))
        if creds.expires_at and creds.expires_at < Date.now! + 60_000
            return { healthy: false, detail: 'not_authorized' }
    catch
        return { healthy: false, detail: 'creds_corrupt' }
    
    return { healthy: true }
```

No subprocess spawn, no network call. Cheap enough to run every heartbeat (30s cadence).

`ApiKeyAdapter.health!` (or `api_key` branch) reads `credentials.env`, checks `ANTHROPIC_API_KEY` present. No expiry tracking.

**Adapter interface contract change:** `health!` return type goes from current `{healthy: bool}` to `{healthy: bool, detail?: string}`. `StubAdapter` must be updated to match; existing callers of `health!` that only destructure `healthy` continue to work (detail is additive).

### 7.2 Heartbeat payload

Connector sends to `POST /api/workspaces/:id/heartbeat`:

```json
{
    "state": "online" | "degraded",
    "detail": null | "not_authorized" | "claude_missing" | "creds_corrupt"
}
```

If `health!.healthy === false` → `state: 'degraded'` + detail string. If `true` → `state: 'online'` + `detail: null`.

### 7.3 AION heartbeat handler

See §3.2 — writes `detail` field verbatim.

### 7.4 Optimistic UI update on successful complete

PB hook on `/oauth/complete` success sets `state='online'`, `detail=''`, `lastAuthorizedAt=now` immediately (see §3.1) — doesn't wait for next heartbeat. Realtime push → UI removes CTA instantly. Self-correcting if next heartbeat disagrees (unlikely).

### 7.5 Idle-workspace detection

Covered by heartbeat cycle: even when no user interacts, every 30s connector checks `health!` → AION gets notified within ~60s of expiry. No separate watchdog needed.

### 7.6 Explicitly not building

- Pre-expiry warning state
- Auto-re-auth (impossible with device-code flow)
- Email/push notifications on `detail` change — future work

---

## 8. Test strategy

### 8.1 aion-connector unit tests (`bun:test`)

- `tests/claude-code-adapter.test.imba`: `health!` return values for each credentials.json state (missing / expired / fresh / corrupt / claude-missing)
- `tests/server-auth.test.imba`: `requireAionAuth` against missing/wrong/correct bearer
- `tests/oauth-routes.test.imba`: smoke that `/coordinator/oauth/*` mount and delegate to adapter (stub adapter)

### 8.2 aion-server unit tests

- `tests/connector.test.imba`:
  - `pinnedAgent.checkServerIdentity` matching/mismatching fp
  - `callConnector` sends correct Authorization bearer
  - `callConnector` aborts on 10s timeout
  - `/internal/oauth/*` rejects missing/wrong `X-Internal-Token`
  - `/internal/oauth/*` forwards to connector (local self-signed Bun.serve fixture on random port, fp computed inline)

### 8.3 aion-pocketbase unit tests

- `tests/oauth-routes.test.imba`:
  - `/oauth/start` requires admin auth; mocks `$http.send`
  - `/oauth/complete` updates `lastAuthorizedAt` + `state=online` on success
  - `/oauth/complete` does NOT update record on connector error
- `tests/enrollment.test.imba` (extend existing): verify `aion_token` in response and `aionToken` stored on record
- Migrations 020 and 021 pass existing `tests/compile.test.imba` invariants

### 8.4 Installer tests

- `shellcheck install.sh` (no new framework)
- Manual verification: run against test-VPS, verify writeouts

### 8.5 UI tests (bun:test + jsdom)

- `workspace-oauth-modal.test.imba`: state machine transitions
- Workspace detail CTA: show/hide logic for the three known states

### 8.6 Manual smoke runbook

Committed alongside spec as `docs/runbooks/oauth-smoke.md`:

1. Create workspace with `authMode=oauth` via UI
2. Run installer on test-VPS
3. Click Authorize, complete OAuth at Anthropic, paste code
4. Verify workspace goes online + Claude command works
5. Delete `~/.claude/credentials.json`, wait 60s
6. Verify UI shows degraded + `not_authorized` + CTA
7. Re-authorize, verify recovery
8. Delete workspace, cleanup VPS

### 8.7 Explicitly not automating

- Real Anthropic OAuth round-trip (requires interactive login)
- Real TLS handshake in integration tests (unit-tested at fingerprint level)
- Long-term expiry detection (tests assert only the `< now + 60s` arithmetic)
- Cross-browser visual regression (narrow matrix, eyeball at smoke)

---

## 9. Rollout checklist

1. Land migrations 020 + 021
2. Land PB routes + heartbeat extension (can ship without UI — dormant)
3. Land aion-server `connector.imba` + internal routes
4. Land aion-connector adapter `health!` extension + server bearer middleware
5. Land installer `--auth-mode oauth` branch
6. Land UI modal + CTA + create-form changes
7. Generate `AION_INTERNAL_TOKEN` in prod, write to both envs, restart PB + aion-server
8. Run `oauth-smoke.md` runbook against staging VPS
9. Enable `oauth` option in production `workspace-create-modal`
