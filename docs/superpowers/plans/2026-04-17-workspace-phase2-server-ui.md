# Workspace Phase 2 — Server-Side & UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the server-side `workspaces` collection + 6 HTTP endpoints + lifecycle cron in `aion-pocketbase`, plus the `/projects/:id/workspaces` admin page + full legacy clean-sweep in `aion-application`, so that an admin can provision a workspace from the UI and see it reach `online` state within 2 minutes.

**Architecture:** Three auth channels converge on pocketbase: UI uses JWT + project_member check, connector uses one-time `enrollment_token` for first contact, then `Bearer workspace_token` for steady-state. All tokens stored as SHA-256 hashes at rest. Lifecycle driven by a pocketbase cron flipping `online/degraded → offline` when `lastHeartbeatAt` is stale by >60s.

**Tech Stack:** Imba + Bimba compiled to JS (both repos); pocketbase hooks run in Goja (uses `$app`, `routerAdd`, `cronAdd`, `$security`); frontend uses pocketbase-imba SDK for realtime. Bun for test runner. Pure helper modules get TDD; route handlers get careful hand-implementation + acceptance-run.

**Spec:** `aion-connector/docs/superpowers/specs/2026-04-17-workspace-phase2-server-ui-design.md`

---

## Repo Layout Reminder

Three repos, sibling directories:
```
/Users/fedor/Projects/aion/aion-pocketbase/     # backend hooks (Imba → Goja)
/Users/fedor/Projects/aion/aion-application/    # SPA frontend (Imba + Bimba)
/Users/fedor/Projects/aion/aion-connector/      # VPS-side service (no changes, just source for install.sh)
```

## Test Strategy

Different surfaces get different test approaches because of the runtime split:

| Surface | Approach | Why |
|---|---|---|
| Pure utility modules (`token-utils.imba`) | Bun unit tests, TDD | No pocketbase globals — runs in normal JS runtime |
| Route handlers, cron | No automated tests; hand-implementation following existing `api.*.pb.imba` patterns + manual run in Task 22 | `$app`/`$security`/`cronAdd` only exist inside Goja; wiring up Goja-in-test is phase-N effort |
| Migration 019 | Manual run against a scratch pocketbase, verify collection schema | Same reason; pocketbase CLI inspection is the right tool here |
| Frontend components | Hand-implementation + visual check in `bun run dev` | aion-application has no test infra today; not adding in this phase |
| Whole system | Task 22: end-to-end acceptance run against a real VPS | Matches spec §1.3 |

## File Structure

### aion-pocketbase — new files
```
src/
  _migrations/019_workspace_model.imba   # drop legacy + create workspaces
  token-utils.imba                       # sha256, randomHex, hashEq (pure, testable)
  workspace-auth.imba                    # requireEnrollmentToken, requireWorkspaceToken
  api.workspaces.pb.imba                 # 6 HTTP endpoints
  cron.workspace-lifecycle.pb.imba       # stale-heartbeat → offline
tests/
  token-utils.test.imba                  # unit tests (Bun)
public/
  install.sh                             # static installer, copy of connector bin
```

### aion-pocketbase — modified
```
src/
  _migrations.imba                       # add 019 invocation
package.json                             # add test script + dev dep bun-test
```

### aion-pocketbase — deleted
```
src/api.servers.pb.imba
```

### aion-application — new files
```
src/
  pages/workspaces-page.imba
  components/workspaces/
    workspace-state-badge.imba
    workspace-list.imba
    workspace-detail.imba
    workspace-installer-view.imba
    workspace-create-modal.imba
```

### aion-application — modified
```
src/
  api.imba                               # add workspaces.*, remove servers/agents
  app.imba                               # add route, remove dead imports
  index.imba                             # remove dead imports
  components/right-panel.imba
  components/project-settings-popup.imba
  components/messages-list.imba
  components/canvas-panel.imba
  components/popups/*.imba               # conditional — audit in Task 21
```

### aion-application — deleted
```
src/components/server-settings-popup.imba
src/components/agent-console.imba
src/components/slash-commands.imba
```

---

## Part A: aion-pocketbase Backend

### Task 1: Token utilities (pure, TDD)

Pure sha256/randomHex helpers used by create + register + re-enroll endpoints. Testable in Bun because no `$app` access.

**Files:**
- Create: `aion-pocketbase/src/token-utils.imba`
- Create: `aion-pocketbase/tests/token-utils.test.imba`
- Modify: `aion-pocketbase/package.json` (add test deps + script)

**Context:** Pocketbase's `$security` has crypto helpers available inside Goja, but `token-utils.imba` should use standard Node/Bun crypto for testability. Goja polyfills `crypto.subtle`? No — use `crypto` (node-style). Bun supports the same. This gives us one module that runs in both Goja (via node-compat) and Bun (for tests).

Actually — Goja does NOT provide `crypto`. It provides `$security` (pocketbase-specific). So `token-utils.imba` must use `$security` for the Goja path.

Solution: `token-utils.imba` wraps `$security` when it's available (Goja), falls back to Node `crypto` when running in Bun tests. This is a two-line ternary.

- [ ] **Step 1: Add test script to package.json**

Edit `aion-pocketbase/package.json`, add to `scripts`:
```json
"test": "bunx bimba tests/ --outdir tests-dist --target node && bun test tests-dist"
```

Add to `devDependencies`:
```json
"@types/bun": "latest"
```

- [ ] **Step 2: Write the failing test**

Create `aion-pocketbase/tests/token-utils.test.imba`:
```imba
import {test, expect} from "bun:test"
import {randomHex, sha256Hex, hashEq} from "../src/token-utils.imba"

test "randomHex produces hex string of requested byte length", do
    const h = randomHex(32)
    expect(h).toMatch(/^[0-9a-f]{64}$/)

test "randomHex produces different values on repeated calls", do
    const a = randomHex(16)
    const b = randomHex(16)
    expect(a).not.toBe(b)

test "sha256Hex matches known vector for empty string", do
    expect(sha256Hex('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')

test "sha256Hex is deterministic", do
    expect(sha256Hex('hello')).toBe(sha256Hex('hello'))

test "hashEq true when token matches hash", do
    const token = 'a7b9c1d2e3f4'
    const hash = sha256Hex(token)
    expect(hashEq(token, hash)).toBe(true)

test "hashEq false when token does not match", do
    const hash = sha256Hex('secret')
    expect(hashEq('not-secret', hash)).toBe(false)

test "hashEq false when hash is null or empty", do
    expect(hashEq('anything', null)).toBe(false)
    expect(hashEq('anything', '')).toBe(false)
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run test`
Expected: FAIL with "Cannot find module '../src/token-utils.imba'" or similar.

- [ ] **Step 4: Implement token-utils**

Create `aion-pocketbase/src/token-utils.imba`:
```imba
# ============================================================
# token-utils.imba — Token generation and hashing
# ============================================================
# Pure helpers used by workspace create/register/re-enroll.
# Uses pocketbase's $security when running inside Goja, falls
# back to Node crypto for Bun test runs.
# ============================================================

const hasGoja = typeof $security !== 'undefined'
const nodeCrypto = hasGoja ? null : require('crypto')

export def randomHex nBytes
    if hasGoja
        # $security.randomString returns arbitrary chars; build hex from bytes.
        # $security has randomStringWithAlphabet — use hex alphabet.
        return $security.randomStringWithAlphabet(nBytes * 2, '0123456789abcdef')
    return nodeCrypto.randomBytes(nBytes).toString('hex')

export def sha256Hex input
    if hasGoja
        return $security.hs256(input, '').toString!.toLowerCase! if false
        # pocketbase $security.hs256 is HMAC-SHA256, not plain sha256.
        # Use pure JS sha256 inline for portability. Goja supports it.
        return _sha256(input)
    return nodeCrypto.createHash('sha256').update(input).digest('hex')

export def hashEq token, hash
    return false unless token and hash
    return sha256Hex(token) === hash

# --- pure JS sha256, for Goja path ---
# Copied minimal implementation (runs in both Goja and Bun).
# If Goja has TextEncoder + DataView + bitwise ops — it does — this works.
def _sha256 str
    const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    const k = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
    # Encode as UTF-8 bytes
    const bytes = []
    for ch in str.split('')
        const code = ch.charCodeAt(0)
        if code < 0x80
            bytes.push(code)
        elif code < 0x800
            bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
        else
            bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
    const bitLen = bytes.length * 8
    bytes.push(0x80)
    while (bytes.length % 64) !== 56
        bytes.push(0)
    # Append length as 64-bit big-endian
    for i in [7, 6, 5, 4, 3, 2, 1, 0]
        bytes.push((bitLen >>> (i * 8)) & 0xff)
    # Process 512-bit chunks
    let ii = 0
    while ii < bytes.length
        const w = []
        for j in [0 .. 15]
            w.push((bytes[ii + j*4] << 24) | (bytes[ii + j*4 + 1] << 16) | (bytes[ii + j*4 + 2] << 8) | bytes[ii + j*4 + 3])
        for j in [16 .. 63]
            const s0 = _rotr(w[j-15], 7) ^ _rotr(w[j-15], 18) ^ (w[j-15] >>> 3)
            const s1 = _rotr(w[j-2], 17) ^ _rotr(w[j-2], 19) ^ (w[j-2] >>> 10)
            w.push((w[j-16] + s0 + w[j-7] + s1) | 0)
        let [a, b, c, d, e, f, g, hh] = h
        for j in [0 .. 63]
            const S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            const ch2 = (e & f) ^ (~e & g)
            const t1 = (hh + S1 + ch2 + k[j] + w[j]) | 0
            const S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            const mj = (a & b) ^ (a & c) ^ (b & c)
            const t2 = (S0 + mj) | 0
            hh = g ; g = f ; f = e ; e = (d + t1) | 0 ; d = c ; c = b ; b = a ; a = (t1 + t2) | 0
        h[0] = (h[0] + a) | 0 ; h[1] = (h[1] + b) | 0 ; h[2] = (h[2] + c) | 0 ; h[3] = (h[3] + d) | 0
        h[4] = (h[4] + e) | 0 ; h[5] = (h[5] + f) | 0 ; h[6] = (h[6] + g) | 0 ; h[7] = (h[7] + hh) | 0
        ii = ii + 64
    return h.map(do(v) (v >>> 0).toString(16).padStart(8, '0')).join('')

def _rotr x, n
    return ((x >>> n) | (x << (32 - n))) >>> 0
```

Note: this inline sha256 is deliberately portable (pure ints, no TypedArray). It's ~60 lines but removes the Goja-vs-Node branching headache. If Goja later ships a `crypto.subtle`-style API, replace `_sha256` with a one-liner.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run test`
Expected: 7/7 PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/token-utils.imba tests/token-utils.test.imba package.json
git commit -m "feat(token-utils): sha256 + randomHex for workspace tokens"
```

---

### Task 2: Migration 019 — drop legacy + create workspaces

Drops `agent_sessions`, `agents`, `servers`. Creates `workspaces` with all fields + indexes + closed rules (null on all built-in list/view/create/update/delete).

**Files:**
- Create: `aion-pocketbase/src/_migrations/019_workspace_model.imba`
- Modify: `aion-pocketbase/src/_migrations.imba` (add invocation)

**Context:** Existing migrations use a shared helper (`collection.ensure`) that doesn't expose indexes or null rules. We construct the `workspaces` Collection directly for explicit control. Drops use `$app.findCollectionByNameOrId` + `$app.delete`.

- [ ] **Step 1: Write migration 019**

Create `aion-pocketbase/src/_migrations/019_workspace_model.imba`:
```imba
# ============================================================
# 019_workspace_model.imba — Phase 2 clean sweep
# ============================================================
# Drops legacy agent_sessions / agents / servers collections.
# Creates workspaces as the single source of truth for remote
# coordinator instances.
# ============================================================

def migrate app
    # --- drop legacy collections, if present ---
    for name in ['agent_sessions', 'agents', 'servers']
        try
            const col = app.findCollectionByNameOrId(name)
            app.delete(col) if col
        catch e
            # collection may not exist on fresh installs — that's fine
            continue

    # --- create workspaces ---
    const col = new Collection({
        type: 'base'
        name: 'workspaces'
        # all built-in rules nil → only superuser or custom endpoints
        listRule: null
        viewRule: null
        createRule: null
        updateRule: null
        deleteRule: null
    })

    # resolve relation collection ids
    const projectsCol = app.findCollectionByNameOrId('projects')
    const usersCol = app.findCollectionByNameOrId('users')

    # @ts-expect-error — pocketbase FieldsList ext at runtime
    col.fields = [
        new RelationField({ name: 'projectId', required: yes, collectionId: projectsCol.id, cascadeDelete: yes, maxSelect: 1 })
        new TextField({ name: 'name', required: yes, max: 80 })
        new TextField({ name: 'slug', required: yes, min: 3, max: 40, pattern: '^[a-z0-9-]+$' })
        new RelationField({ name: 'createdBy', required: yes, collectionId: usersCol.id, maxSelect: 1 })
        new SelectField({ name: 'state', required: yes, values: ['provisioning', 'online', 'offline', 'degraded', 'decommissioned'], maxSelect: 1 })
        new DateField({ name: 'lastHeartbeatAt' })
        new TextField({ name: 'externalIp' })
        new NumberField({ name: 'port' })
        new TextField({ name: 'certFingerprint' })
        new TextField({ name: 'enrollmentTokenHash' })
        new DateField({ name: 'enrollmentTokenExpiresAt' })
        new TextField({ name: 'workspaceTokenHash' })
        new TextField({ name: 'connectorVersion' })
        new SelectField({ name: 'program', required: yes, values: ['claude-code'], maxSelect: 1 })
        new TextField({ name: 'model', required: yes })
        new SelectField({ name: 'authMode', required: yes, values: ['api_key', 'oauth'], maxSelect: 1 })
    ]

    col.indexes = [
        "CREATE INDEX idx_workspaces_project ON workspaces (projectId)"
        "CREATE UNIQUE INDEX idx_workspaces_slug ON workspaces (slug)"
        "CREATE INDEX idx_workspaces_state_hb ON workspaces (state, lastHeartbeatAt)"
    ]

    app.save(col)

module.exports = { migrate }
```

- [ ] **Step 2: Register migration in orchestrator**

Edit `aion-pocketbase/src/_migrations.imba`, append after the `018_servers_display_url` block (before `module.exports`):
```imba
    # 019 — Workspace model: drop legacy agents/servers, create workspaces
    if !migration.run(app, '019_workspace_model')
        const { migrate } = require("{__hooks}/_migrations/019_workspace_model.js")
        migrate(app)
        migration.mark(app, '019_workspace_model')
        app.logger!.info("Migration 019_workspace_model applied")
```

- [ ] **Step 3: Compile and manually verify schema**

Run:
```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
bun run mac:compile
```
Expected: `public/_migrations/019_workspace_model.js` and updated `public/_migrations.js` exist with no errors.

Then boot pocketbase locally (following the repo's CLAUDE.md instructions) against a scratch DB and verify:
```bash
# In pocketbase admin UI or via API
curl -s "http://localhost:8090/api/collections" | jq '.items[] | .name' | grep -E '^"(workspaces|agents|servers|agent_sessions)"$'
```
Expected: only `"workspaces"` appears; the three legacy names are absent.

- [ ] **Step 4: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/_migrations/019_workspace_model.imba src/_migrations.imba
git commit -m "feat(migration): 019 — drop legacy agents/servers, create workspaces"
```

---

### Task 3: Workspace auth middleware

Two helpers used by endpoints 4.3, 4.4, 4.6 (§4 of spec).

**Files:**
- Create: `aion-pocketbase/src/workspace-auth.imba`

**Context:** Existing hooks use `require("{__hooks}/utils.js")` to import helpers. Follow the same pattern.

- [ ] **Step 1: Write workspace-auth**

Create `aion-pocketbase/src/workspace-auth.imba`:
```imba
# ============================================================
# workspace-auth.imba — enrollment_token + workspace_token checks
# ============================================================
# requireEnrollmentToken:
#   verifies { workspace_id, enrollment_token } in request body,
#   checks sha256(token) == enrollmentTokenHash AND expiresAt > now.
#   Returns the pocketbase record.
# requireWorkspaceToken:
#   verifies Bearer token in Authorization header against
#   workspaceTokenHash of the :id path param.
# ============================================================

const { hashEq } = require("{__hooks}/token-utils.js")

export def requireEnrollmentToken e, body
    const wid = body.workspace_id
    const token = body.enrollment_token
    throw new BadRequestError("workspace_id required") unless wid
    throw new BadRequestError("enrollment_token required") unless token
    let rec = null
    try
        rec = $app.findRecordById('workspaces', wid)
    catch err
        throw new NotFoundError("workspace not found")
    const hash = rec.get('enrollmentTokenHash') or ''
    throw new UnauthorizedError("enrollment token already consumed") unless hash
    const exp = rec.get('enrollmentTokenExpiresAt')
    const now = new Date!
    if !exp or new Date(exp) < now
        throw new UnauthorizedError("enrollment token expired")
    throw new UnauthorizedError("enrollment token invalid") unless hashEq(token, hash)
    return rec

export def requireWorkspaceToken e, id
    const header = e.request.header.get('Authorization') or ''
    const m = header.match(/^Bearer\s+(.+)$/)
    throw new UnauthorizedError("missing bearer token") unless m
    const token = m[1]
    let rec = null
    try
        rec = $app.findRecordById('workspaces', id)
    catch err
        throw new NotFoundError("workspace not found")
    const hash = rec.get('workspaceTokenHash') or ''
    throw new UnauthorizedError("workspace token invalid") unless hashEq(token, hash)
    return rec

module.exports = { requireEnrollmentToken, requireWorkspaceToken }
```

- [ ] **Step 2: Compile and verify**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: `public/workspace-auth.js` exists, no compile errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/workspace-auth.imba
git commit -m "feat(auth): enrollment_token + workspace_token middleware"
```

---

### Task 4: Endpoint `POST /api/workspaces` (create)

**Files:**
- Create: `aion-pocketbase/src/api.workspaces.pb.imba` (first endpoint)

**Context:** Follow the pattern in `api.servers.pb.imba`: `routerAdd`, import `auth`/`info` from utils. `auth(e, ['field'])` throws if field missing. `info(projectId, userId).member` is the admin-access check.

- [ ] **Step 1: Write endpoint**

Create `aion-pocketbase/src/api.workspaces.pb.imba`:
```imba
# ============================================================
# api.workspaces.pb.imba — Workspace lifecycle HTTP endpoints
# ============================================================
# All six Phase 2 endpoints live here:
#   POST   /api/workspaces                  (UI: create)
#   GET    /api/workspaces/:id/installer    (UI: snippet template)
#   POST   /api/workspaces/register         (connector: first contact)
#   POST   /api/workspaces/:id/heartbeat    (connector: keepalive)
#   POST   /api/workspaces/:id/re-enroll    (UI: force new token)
#   DELETE /api/workspaces/:id              (UI or connector)
# ============================================================

# --- POST /api/workspaces — create ---

routerAdd 'POST', '/api/workspaces', do(e)
    const { auth, info } = require("{__hooks}/utils.js")
    const { randomHex, sha256Hex } = require("{__hooks}/token-utils.js")
    const { request, query } = auth(e, ['projectId', 'name', 'program', 'model', 'authMode'])

    try
        const i = info(query.projectId, request.auth.id)
        return e.json(403, { error: "not a project member" }) unless i.member

        # generate slug with retry on collision
        const baseSlug = String(query.name).toLowerCase!.replace(/[^a-z0-9-]+/g, '-').slice(0, 32).replace(/(^-+|-+$)/g, '')
        let slug = null
        for attempt in [0 .. 5]
            const candidate = "{baseSlug}-{randomHex(2)}"
            const hits = $app.findRecordsByFilter('workspaces', "slug='{candidate}'", '', 1, 0) or []
            if hits.length == 0
                slug = candidate
                break
        return e.json(500, { error: "could not allocate unique slug" }) unless slug

        const enrollmentToken = randomHex(32)
        const enrollmentHash = sha256Hex(enrollmentToken)
        const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString!

        const col = $app.findCollectionByNameOrId('workspaces')
        const rec = new Record(col)
        rec.set('projectId', query.projectId)
        rec.set('name', query.name)
        rec.set('slug', slug)
        rec.set('createdBy', request.auth.id)
        rec.set('state', 'provisioning')
        rec.set('enrollmentTokenHash', enrollmentHash)
        rec.set('enrollmentTokenExpiresAt', expiresAt)
        rec.set('program', query.program)
        rec.set('model', query.model)
        rec.set('authMode', query.authMode)
        $app.save(rec)

        return e.json(201, {
            workspace: {
                id: rec.id
                projectId: rec.get('projectId')
                name: rec.get('name')
                slug: rec.get('slug')
                state: rec.get('state')
                program: rec.get('program')
                model: rec.get('model')
                authMode: rec.get('authMode')
                enrollmentTokenExpiresAt: rec.get('enrollmentTokenExpiresAt')
            }
            enrollment_token: enrollmentToken
        })
    catch err
        return e.json(500, { error: "create workspace failed: " + String(err) })
```

- [ ] **Step 2: Register hook in compile pipeline**

No action needed — `compile.imba` recursively processes `./src`, so `api.workspaces.pb.imba` is picked up automatically. Confirm by running compile:
```bash
cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile
```
Expected: `public/api.workspaces.pb.js` exists.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/api.workspaces.pb.imba
git commit -m "feat(api): POST /api/workspaces — create workspace record"
```

---

### Task 5: Endpoint `GET /api/workspaces/:id/installer`

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (append)

**Context:** Returns a small JSON template, NOT ready-made bash. UI assembles the final command client-side with the `enrollment_token` it's holding in memory from the create response. Server enforces TTL + unconsumed-token check.

- [ ] **Step 1: Append installer endpoint**

Append to `aion-pocketbase/src/api.workspaces.pb.imba`:
```imba
# --- GET /api/workspaces/:id/installer — template fields ---

routerAdd 'GET', '/api/workspaces/{id}/installer', do(e)
    const { auth, info } = require("{__hooks}/utils.js")
    const { request } = auth(e)
    const id = e.request.pathValue('id')

    try
        const rec = $app.findRecordById('workspaces', id)
        const i = info(rec.get('projectId'), request.auth.id)
        return e.json(403, { error: "not a project member" }) unless i.member

        const hash = rec.get('enrollmentTokenHash') or ''
        const exp = rec.get('enrollmentTokenExpiresAt')
        return e.json(410, { error: "enrollment token expired or consumed — press Re-enroll" }) unless hash
        if !exp or new Date(exp) < new Date!
            return e.json(410, { error: "enrollment token expired — press Re-enroll" })

        # base_url comes from a settings record; use request host as fallback.
        let baseUrl = ''
        try
            const s = $app.findFirstRecordByData('settings', 'key', 'aion_base_url')
            baseUrl = s.get('value') or ''
        catch err
            baseUrl = ''
        if !baseUrl
            const host = e.request.host
            const proto = e.request.tls ? 'https' : 'http'
            baseUrl = "{proto}://{host}"

        return e.json(200, {
            base_url: baseUrl
            workspace_id: rec.id
            workspace_slug: rec.get('slug')
            program: rec.get('program')
            model: rec.get('model')
            auth_mode: rec.get('authMode')
        })
    catch err
        return e.json(404, { error: "workspace not found" })
```

Note: `settings` is an existing collection from migration 017. If `aion_base_url` key exists, use it; otherwise fall back to the request's host. This gives ops a way to override the domain baked into installer snippets.

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/api.workspaces.pb.imba
git commit -m "feat(api): GET /api/workspaces/:id/installer — template for UI snippet"
```

---

### Task 6: Endpoint `POST /api/workspaces/register`

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (append)

**Context:** Connector's first contact. Verifies `enrollment_token`, atomically: consumes token, writes transport fields, generates `workspace_token`, flips to `online`, writes `lastHeartbeatAt`. Returns raw workspace_token ONCE.

- [ ] **Step 1: Append register endpoint**

Append to `aion-pocketbase/src/api.workspaces.pb.imba`:
```imba
# --- POST /api/workspaces/register — connector first contact ---

routerAdd 'POST', '/api/workspaces/register', do(e)
    const { randomHex, sha256Hex } = require("{__hooks}/token-utils.js")
    const { requireEnrollmentToken } = require("{__hooks}/workspace-auth.js")
    const body = e.requestInfo!.body or {}

    try
        const rec = requireEnrollmentToken(e, body)

        # consume enrollment token
        rec.set('enrollmentTokenHash', '')
        rec.set('enrollmentTokenExpiresAt', null)

        # store transport fields reported by connector
        rec.set('externalIp', body.external_ip or '')
        rec.set('port', body.port)
        rec.set('certFingerprint', body.cert_fingerprint or '')
        rec.set('connectorVersion', body.connector_version or '')

        # mint workspace token
        const workspaceToken = randomHex(32)
        rec.set('workspaceTokenHash', sha256Hex(workspaceToken))

        # mark online + fresh heartbeat
        const cs = body.coordinator_status or {}
        rec.set('state', cs.state == 'ready' ? 'online' : 'degraded')
        rec.set('lastHeartbeatAt', new Date!.toISOString!)

        $app.save(rec)

        return e.json(200, {
            workspace_id: rec.id
            workspace_token: workspaceToken
        })
    catch err
        const msg = err.message or String(err)
        const code = err.status or 400
        return e.json(code, { error: msg })
```

Note on error handling: `requireEnrollmentToken` throws `BadRequestError`, `NotFoundError`, `UnauthorizedError` — pocketbase's `e.json` needs explicit status. We inspect `err.status` (set by pocketbase error classes). If absent, default 400.

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/api.workspaces.pb.imba
git commit -m "feat(api): POST /api/workspaces/register — connector enrollment"
```

---

### Task 7: Endpoint `POST /api/workspaces/:id/heartbeat`

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (append)

- [ ] **Step 1: Append heartbeat endpoint**

Append to `aion-pocketbase/src/api.workspaces.pb.imba`:
```imba
# --- POST /api/workspaces/:id/heartbeat — connector keepalive ---

routerAdd 'POST', '/api/workspaces/{id}/heartbeat', do(e)
    const { requireWorkspaceToken } = require("{__hooks}/workspace-auth.js")
    const id = e.request.pathValue('id')
    const body = e.requestInfo!.body or {}

    try
        const rec = requireWorkspaceToken(e, id)
        rec.set('lastHeartbeatAt', new Date!.toISOString!)
        const cs = body.coordinator_status or {}
        rec.set('state', cs.state == 'ready' ? 'online' : 'degraded')
        rec.set('externalIp', body.external_ip) if body.external_ip
        rec.set('connectorVersion', body.connector_version) if body.connector_version
        $app.save(rec)
        return e.json(200, {})
    catch err
        const msg = err.message or String(err)
        const code = err.status or 401
        return e.json(code, { error: msg })
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/api.workspaces.pb.imba
git commit -m "feat(api): POST /api/workspaces/:id/heartbeat — connector keepalive"
```

---

### Task 8: Endpoint `POST /api/workspaces/:id/re-enroll`

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (append)

**Context:** UI-only in MVP. Generates new enrollment_token, invalidates old workspace_token, flips state to `provisioning`. Leaves transport fields alone so UI can still show "this is the VPS that needs reinstall".

- [ ] **Step 1: Append re-enroll endpoint**

Append to `aion-pocketbase/src/api.workspaces.pb.imba`:
```imba
# --- POST /api/workspaces/:id/re-enroll — UI force new enrollment ---

routerAdd 'POST', '/api/workspaces/{id}/re-enroll', do(e)
    const { auth, info } = require("{__hooks}/utils.js")
    const { randomHex, sha256Hex } = require("{__hooks}/token-utils.js")
    const { request } = auth(e)
    const id = e.request.pathValue('id')

    try
        const rec = $app.findRecordById('workspaces', id)
        const i = info(rec.get('projectId'), request.auth.id)
        return e.json(403, { error: "not a project member" }) unless i.member

        const enrollmentToken = randomHex(32)
        rec.set('enrollmentTokenHash', sha256Hex(enrollmentToken))
        rec.set('enrollmentTokenExpiresAt', new Date(Date.now() + 15 * 60 * 1000).toISOString!)
        rec.set('workspaceTokenHash', '')
        rec.set('state', 'provisioning')
        # intentionally do NOT clear externalIp/port/certFingerprint — UI still shows
        # admin "this is the VPS you need to reinstall on"
        $app.save(rec)

        return e.json(200, { enrollment_token: enrollmentToken })
    catch err
        return e.json(404, { error: "workspace not found: " + String(err) })
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/api.workspaces.pb.imba
git commit -m "feat(api): POST /api/workspaces/:id/re-enroll — UI-initiated reset"
```

---

### Task 9: Endpoint `DELETE /api/workspaces/:id` (dual auth)

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (append)

**Context:** Accepts either pocketbase JWT (UI flow — verifies project member) or workspace_token bearer (connector uninstall). Try JWT path first; on failure, try bearer path.

- [ ] **Step 1: Append delete endpoint**

Append to `aion-pocketbase/src/api.workspaces.pb.imba`:
```imba
# --- DELETE /api/workspaces/:id — UI or connector ---

routerAdd 'DELETE', '/api/workspaces/{id}', do(e)
    const { info } = require("{__hooks}/utils.js")
    const { requireWorkspaceToken } = require("{__hooks}/workspace-auth.js")
    const id = e.request.pathValue('id')

    # Try to resolve caller identity: JWT (UI) or bearer (connector).
    let rec = null
    let authorized = no

    # Path A: pocketbase JWT
    try
        const reqInfo = e.requestInfo!
        if reqInfo.auth
            rec = $app.findRecordById('workspaces', id)
            const i = info(rec.get('projectId'), reqInfo.auth.id)
            authorized = i.member
    catch err
        authorized = no

    # Path B: workspace_token
    unless authorized
        try
            rec = requireWorkspaceToken(e, id)
            authorized = yes
        catch err
            authorized = no

    return e.json(401, { error: "unauthorized" }) unless authorized and rec

    try
        $app.delete(rec)
        return e.json(200, { ok: yes })
    catch err
        return e.json(500, { error: "delete failed: " + String(err) })
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/api.workspaces.pb.imba
git commit -m "feat(api): DELETE /api/workspaces/:id — dual-auth (UI or connector)"
```

---

### Task 10: Cron `workspace-lifecycle`

**Files:**
- Create: `aion-pocketbase/src/cron.workspace-lifecycle.pb.imba`

**Context:** Pocketbase uses `cronAdd(id, expr, handler)`. Robfig/cron v3 supports `@every 30s`. If that fails at runtime, fall back to `* * * * *` (every minute) and widen the staleness threshold to 90s (60s + one-minute scheduling jitter).

- [ ] **Step 1: Write cron**

Create `aion-pocketbase/src/cron.workspace-lifecycle.pb.imba`:
```imba
# ============================================================
# cron.workspace-lifecycle.pb.imba — stale-heartbeat sweeper
# ============================================================
# Every 30s: any workspace in (online, degraded) whose last
# heartbeat is older than 60s gets flipped to offline.
# ============================================================

cronAdd('workspace-lifecycle', '@every 30s', do
    try
        const threshold = new Date(Date.now() - 60_000).toISOString!
        const filter = "(state = 'online' || state = 'degraded') && lastHeartbeatAt < {:t}"
        const records = $app.findRecordsByFilter(
            'workspaces'
            filter
            '-lastHeartbeatAt'
            100
            0
            { t: threshold }
        ) or []
        for rec in records
            rec.set('state', 'offline')
            $app.save(rec)
    catch err
        $app.logger!.error("workspace-lifecycle cron failed: " + String(err))
)
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: `public/cron.workspace-lifecycle.pb.js` exists.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/cron.workspace-lifecycle.pb.imba
git commit -m "feat(cron): workspace-lifecycle — flip stale online/degraded → offline"
```

---

### Task 11: Static `install.sh` in `pb_public/`

**Files:**
- Create: `aion-pocketbase/public/install.sh` (copy from connector)

**Context:** Pocketbase serves static files from `pb_public/`. The path in this repo is `public/` (which gets rsynced to `pb_hooks/` — but wait, that's hooks, not static files). Need to confirm. Actually looking at `mac:deploy`: `rsync ./public/ → aion:/home/pocketbase/pb_hooks/`. So `public/` in this repo = `pb_hooks/` on the server. That's hooks, not static content.

For static files, pocketbase uses `pb_public/` by convention. We need to add a separate deployment path for static files, OR serve them from a hook route. Simpler: serve from a route, reading from a file that ships with hooks.

Decision: `install.sh` lives in `aion-pocketbase/public/install.sh` (next to hooks), and we serve it via a `routerAdd 'GET', '/install.sh'` hook that reads the file with `fs.readFileSync`. Pocketbase hooks support Node-style `fs`? Actually Goja doesn't ship `fs` — pocketbase exposes `$os` and `$filesystem`. Simpler still: hardcode the script content as a string in the hook.

Actually pocketbase's `pb_public/` serving works if the directory exists. Let me check the CLAUDE.md of aion-pocketbase.

We'll ship `install.sh` as a static string served via a route. The script content is the exact byte-for-byte copy of `aion-connector/bin/install.sh`.

- [ ] **Step 1: Create installer-serving hook**

Create `aion-pocketbase/src/api.installer.pb.imba`:
```imba
# ============================================================
# api.installer.pb.imba — Serves /install.sh
# ============================================================
# The script body is inlined because pb_public/ is not configured
# in this deployment; we serve directly from a route.
# Source of truth: aion-connector/bin/install.sh — keep in sync
# at release time (see aion-pocketbase/README.md).
# ============================================================

const INSTALL_SH = '''<PASTE FULL CONTENTS OF aion-connector/bin/install.sh HERE>'''

routerAdd 'GET', '/install.sh', do(e)
    e.response.header.set('Content-Type', 'text/plain; charset=utf-8')
    e.response.header.set('Cache-Control', 'no-cache')
    return e.string(200, INSTALL_SH)
```

Copy the full text of `aion-connector/bin/install.sh` (from Task context) into the `INSTALL_SH` triple-quoted literal. Imba triple-quoted strings preserve newlines verbatim.

- [ ] **Step 2: Add release note to README**

Create or append to `aion-pocketbase/README.md`:
```markdown
## Release sync: install.sh

`src/api.installer.pb.imba` embeds `aion-connector/bin/install.sh` as a string
literal. When `bin/install.sh` changes in the connector repo, copy-paste the
updated body into the `INSTALL_SH` constant and re-run `bun run mac:compile`.
Mismatch = admin runs a stale installer.
```

- [ ] **Step 3: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && bun run mac:compile`
Expected: `public/api.installer.pb.js` exists.

- [ ] **Step 4: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add src/api.installer.pb.imba README.md
git commit -m "feat(installer): serve /install.sh from embedded connector script"
```

---

### Task 12: Delete `api.servers.pb.imba`

**Files:**
- Delete: `aion-pocketbase/src/api.servers.pb.imba`

**Context:** Collections `servers`/`agents`/`agent_sessions` are gone (Task 2). The frontend will stop calling these endpoints in Part B. Leave `api.agents.pb.imba` untouched for this task — we'll handle it in a final backend cleanup pass if it references removed collections.

- [ ] **Step 1: Check what api.agents.pb.imba references**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && grep -l "findCollectionByNameOrId.'agents'\|findCollectionByNameOrId.'agent_sessions'" src/*.imba`
Expected: lists `api.agents.pb.imba` and possibly others.

- [ ] **Step 2: Delete api.servers.pb.imba and api.agents.pb.imba**

These are dead — their collections are dropped. Remove them:
```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
rm src/api.servers.pb.imba
rm src/api.agents.pb.imba
```

Also check `src/channel.imba` — it's imported by `api.servers.pb.imba` only. Confirm:
```bash
grep -l "channel.js\|channel.imba" src/
```
If only the deleted files reference it, remove `src/channel.imba` too.

- [ ] **Step 3: Re-compile to catch broken imports**

Run: `cd /Users/fedor/Projects/aion/aion-pocketbase && rm -rf public .cache && bun run mac:compile`
Expected: no errors. If any surviving hook still references removed modules, the compile will surface it.

- [ ] **Step 4: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-pocketbase
git add -A src/
git commit -m "chore: remove legacy api.servers, api.agents, channel hooks"
```

---

## Part B: aion-application Frontend

### Task 13: Extend `src/api.imba` with workspaces

**Files:**
- Modify: `aion-application/src/api.imba` (add workspaces methods)

**Context:** The existing `api.imba` is the thin HTTP wrapper for the SPA. Add a `workspaces` namespace mirroring the six endpoints. Don't remove legacy methods in this task — Task 20 handles the strip to keep the backend/frontend changes reviewable in isolation.

- [ ] **Step 1: Read current api.imba structure to mirror conventions**

Run: `cat /Users/fedor/Projects/aion/aion-application/src/api.imba | head -80`
Expected: understand the existing `fetch`/`get`/`post` helpers.

- [ ] **Step 2: Add workspaces namespace**

Append to `aion-application/src/api.imba` (after existing exports, before `module.exports` or the final export block — follow the file's existing pattern):
```imba
# --- workspaces ---

export const workspaces =
    list: do(projectId)
        # UI reads via pocketbase SDK realtime, but for one-shot fetches:
        await pb.collection('workspaces').getFullList({ filter: "projectId='{projectId}'", sort: '-created' })

    create: do(projectId, name, program, model, authMode)
        await postJson('/api/workspaces', { projectId, name, program, model, authMode })

    installer: do(id)
        await getJson("/api/workspaces/{id}/installer")

    reEnroll: do(id)
        await postJson("/api/workspaces/{id}/re-enroll", {})

    remove: do(id)
        await fetchRaw("/api/workspaces/{id}", { method: 'DELETE' })
```

Assumes `postJson`, `getJson`, `fetchRaw`, `pb` are already defined in `api.imba` (standard pattern for this codebase). If any helper name differs, match the file's actual convention.

- [ ] **Step 3: Compile to verify**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/api.imba
git commit -m "feat(api): add workspaces.* client methods"
```

---

### Task 14: Component `workspace-state-badge`

**Files:**
- Create: `aion-application/src/components/workspaces/workspace-state-badge.imba`

**Context:** Small presentational tag that renders a colored pill given a state string. Used by both list and detail views.

- [ ] **Step 1: Create component**

Create `aion-application/src/components/workspaces/workspace-state-badge.imba`:
```imba
# ============================================================
# workspace-state-badge — colored state pill
# ============================================================

const COLORS =
    provisioning: '#8e8e93'   # gray
    online:       '#34c759'   # green
    degraded:     '#ff9500'   # amber
    offline:      '#ff3b30'   # red
    decommissioned: '#555'

export tag WorkspaceStateBadge
    prop state\string = 'provisioning'

    css.root
        display: inline-block
        padding: 2px 8px
        border-radius: 10px
        font-size: 11px
        line-height: 1.4
        font-weight: 600
        color: white

    def render
        <self.root[background: COLORS[state] or COLORS.provisioning]>
            {state}
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/components/workspaces/workspace-state-badge.imba
git commit -m "feat(workspaces): state-badge pill component"
```

---

### Task 15: Component `workspace-list`

**Files:**
- Create: `aion-application/src/components/workspaces/workspace-list.imba`

**Context:** Left-column table. Emits `select` event on row click. Receives `workspaces` array and `selectedId` from parent.

- [ ] **Step 1: Create component**

Create `aion-application/src/components/workspaces/workspace-list.imba`:
```imba
# ============================================================
# workspace-list — sidebar table of workspaces
# ============================================================

import {WorkspaceStateBadge} from './workspace-state-badge.imba'

export tag WorkspaceList
    prop workspaces\any[] = []
    prop selectedId\string = ''

    css.root
        display: flex
        flex-direction: column
        width: 260px
        border-right: 1px solid #333
        overflow-y: auto
    css.row
        padding: 10px 12px
        border-bottom: 1px solid #222
        cursor: pointer
        display: flex
        justify-content: space-between
        align-items: center
        gap: 8px
        &:hover background: #1c1c1e
        &.selected background: #2c2c2e
    css.empty
        padding: 16px
        color: #8e8e93
        font-size: 13px

    def onRowClick ws
        emit('select', ws)

    def render
        <self.root>
            if workspaces.length == 0
                <div.empty> "No workspaces yet."
            else
                for ws in workspaces
                    <div.row[.selected = ws.id == selectedId] @click=onRowClick(ws)>
                        <span> ws.name
                        <WorkspaceStateBadge state=ws.state>
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/components/workspaces/workspace-list.imba
git commit -m "feat(workspaces): list sidebar component"
```

---

### Task 16: Component `workspace-installer-view`

**Files:**
- Create: `aion-application/src/components/workspaces/workspace-installer-view.imba`

**Context:** Renders the bash snippet with client-side interpolation of `enrollment_token` (held in parent state), `api_key` (also in parent state, pass-through — never sent to pb), plus template fields from `GET /installer`. Shows a copy button.

- [ ] **Step 1: Create component**

Create `aion-application/src/components/workspaces/workspace-installer-view.imba`:
```imba
# ============================================================
# workspace-installer-view — bash snippet + copy button
# ============================================================
# Receives: template (base_url, workspace_id, program, model, auth_mode)
#           enrollmentToken — raw, held in parent state only
#           apiKey — user-typed, pass-through to VPS only
# ============================================================

export tag WorkspaceInstallerView
    prop template\any
    prop enrollmentToken\string = ''
    prop apiKey\string = ''
    prop expiresAt\string = ''

    css.root
        display: flex
        flex-direction: column
        gap: 12px
    css.block
        background: #111
        border: 1px solid #333
        border-radius: 6px
        padding: 12px
        font-family: ui-monospace, monospace
        font-size: 12px
        white-space: pre-wrap
        word-break: break-all
    css.row
        display: flex
        gap: 8px
        align-items: center
        justify-content: space-between
    css.warn
        font-size: 12px
        color: #ff9500

    get snippet
        return '' unless template
        const parts = [
            "curl -fsSL {template.base_url}/install.sh | sudo bash -s -- \\"
            "    --token {enrollmentToken} \\"
            "    --aion {template.base_url} \\"
            "    --workspace-id {template.workspace_id} \\"
            "    --program {template.program} \\"
            "    --model {template.model} \\"
            "    --auth-mode {template.auth_mode}"
        ]
        if template.auth_mode == 'api_key' and apiKey
            parts[parts.length - 1] = parts[parts.length - 1] + ' \\'
            parts.push("    --api-key {apiKey}")
        return parts.join('\n')

    def copy
        try
            await navigator.clipboard.writeText(snippet)
            # optional: emit('copied')

    def render
        <self.root>
            <.row>
                <.warn> "Expires at {expiresAt or 'unknown'}. If lost, press Re-enroll."
                <button @click=copy> "Copy"
            <.block> snippet
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/components/workspaces/workspace-installer-view.imba
git commit -m "feat(workspaces): installer-view component with client-side snippet"
```

---

### Task 17: Component `workspace-create-modal`

**Files:**
- Create: `aion-application/src/components/workspaces/workspace-create-modal.imba`

**Context:** Two-step modal. Step 1: form (name, program, model, authMode, apiKey). Step 2: installer-view shown after successful create. Also used in "re-enroll" flow — same step 2, but step 1 only collects apiKey (pocketbase doesn't remember it).

- [ ] **Step 1: Create component**

Create `aion-application/src/components/workspaces/workspace-create-modal.imba`:
```imba
# ============================================================
# workspace-create-modal — two-step create/re-enroll flow
# ============================================================
# mode: 'create' | 'reenroll'
# projectId: required for create
# workspace: required for reenroll (record with id, name, program, model, authMode)
# ============================================================

import {workspaces} from '../../api.imba'
import {WorkspaceInstallerView} from './workspace-installer-view.imba'

export tag WorkspaceCreateModal
    prop mode\string = 'create'
    prop projectId\string = ''
    prop workspace\any = null

    step\string = 'form'
    name\string = ''
    program\string = 'claude-code'
    model\string = 'sonnet-4.6'
    authMode\string = 'api_key'
    apiKey\string = ''
    error\string = ''
    busy\bool = no

    enrollmentToken\string = ''
    template\any = null
    expiresAt\string = ''

    def mount
        if mode == 'reenroll' and workspace
            name = workspace.name
            program = workspace.program
            model = workspace.model
            authMode = workspace.authMode

    def submit
        return if busy
        if authMode == 'api_key' and !apiKey
            error = "API key required"
            return
        busy = yes
        error = ''
        try
            if mode == 'create'
                const res = await workspaces.create(projectId, name, program, model, authMode)
                enrollmentToken = res.enrollment_token
                expiresAt = res.workspace.enrollmentTokenExpiresAt
                # fetch template
                template = await workspaces.installer(res.workspace.id)
            else
                const res = await workspaces.reEnroll(workspace.id)
                enrollmentToken = res.enrollment_token
                template = await workspaces.installer(workspace.id)
                expiresAt = template.enrollmentTokenExpiresAt or ''
            step = 'installer'
        catch err
            error = err.message or String(err)
        busy = no

    def close
        emit('close')

    def render
        <self>
            <.backdrop @click=close>
            <.dialog>
                if step == 'form'
                    <h2> (mode == 'reenroll' ? "Re-enroll workspace" : "Create workspace")
                    if mode != 'reenroll'
                        <label> "Name" <input[value]=name @input.set(name, e.target.value)>
                    <label> "Program"
                    <select[value]=program>
                        <option value='claude-code'> "claude-code"
                    <label> "Model" <input[value]=model @input.set(model, e.target.value)>
                    <label> "Auth mode"
                    <select[value]=authMode>
                        <option value='api_key'> "API key"
                        # <option value='oauth' disabled> "OAuth (phase 3)"
                    if authMode == 'api_key'
                        <label> "API key" <input type='password' [value]=apiKey @input.set(apiKey, e.target.value)>
                    if error then <.error> error
                    <.actions>
                        <button @click=close> "Cancel"
                        <button.primary @click=submit disabled=busy> (busy ? "..." : (mode == 'reenroll' ? "Re-enroll" : "Create"))
                elif step == 'installer'
                    <h2> (mode == 'reenroll' ? "Reinstall on VPS" : "Run on VPS")
                    <WorkspaceInstallerView template=template enrollmentToken=enrollmentToken apiKey=apiKey expiresAt=expiresAt>
                    <.actions>
                        <button.primary @click=close> "Done"
```

Note: Imba's template syntax for `<input @input.set(name, e.target.value)>` is the repo's existing convention — confirm by grepping one of the existing components.

- [ ] **Step 2: Confirm input-binding syntax**

Run: `cd /Users/fedor/Projects/aion/aion-application && grep -l "@input" src/components/*.imba | head -1 | xargs cat | grep -A2 -B2 "@input"`
Expected: see the pattern, adjust create-modal code above if different.

- [ ] **Step 3: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/components/workspaces/workspace-create-modal.imba
git commit -m "feat(workspaces): create/re-enroll modal with two-step flow"
```

---

### Task 18: Component `workspace-detail`

**Files:**
- Create: `aion-application/src/components/workspaces/workspace-detail.imba`

**Context:** Right panel showing full workspace fields + re-enroll and delete buttons.

- [ ] **Step 1: Create component**

Create `aion-application/src/components/workspaces/workspace-detail.imba`:
```imba
# ============================================================
# workspace-detail — right-panel detail view
# ============================================================

import {workspaces} from '../../api.imba'
import {WorkspaceStateBadge} from './workspace-state-badge.imba'

export tag WorkspaceDetail
    prop workspace\any = null

    css.root
        flex: 1
        padding: 20px
        overflow-y: auto
    css.field
        display: grid
        grid-template-columns: 140px 1fr
        padding: 6px 0
        border-bottom: 1px solid #222
    css.label
        color: #8e8e93
        font-size: 13px
    css.value
        font-family: ui-monospace, monospace
        font-size: 13px
        word-break: break-all
    css.actions
        margin-top: 24px
        display: flex
        gap: 12px
    css.empty
        color: #8e8e93
        padding: 24px
        text-align: center

    get hbAge
        return '—' unless workspace?.lastHeartbeatAt
        const ms = Date.now() - new Date(workspace.lastHeartbeatAt).getTime()
        return "{Math.floor(ms / 1000)}s ago"

    def reEnroll
        emit('re-enroll', workspace)

    def remove
        return unless confirm("Delete workspace '{workspace.name}'? This is permanent.")
        try
            await workspaces.remove(workspace.id)
            emit('deleted', workspace)
        catch err
            alert("Delete failed: {err.message or err}")

    def render
        <self.root>
            if !workspace
                <.empty> "Select a workspace from the list."
            else
                <h2> workspace.name
                <.field><.label> "State" <.value><WorkspaceStateBadge state=workspace.state>
                <.field><.label> "External IP" <.value> (workspace.externalIp or '—')
                <.field><.label> "Port" <.value> (workspace.port or '—')
                <.field><.label> "Fingerprint" <.value> (workspace.certFingerprint or '—')
                <.field><.label> "Last heartbeat" <.value> hbAge
                <.field><.label> "Program" <.value> "{workspace.program} {workspace.model}"
                <.field><.label> "Connector" <.value> (workspace.connectorVersion or '—')
                <.field><.label> "Slug" <.value> workspace.slug
                <.actions>
                    <button @click=reEnroll> "Re-enroll"
                    <button.danger @click=remove> "Delete"
```

- [ ] **Step 2: Compile**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/components/workspaces/workspace-detail.imba
git commit -m "feat(workspaces): detail view with re-enroll and delete"
```

---

### Task 19: Page `workspaces-page` + routing

**Files:**
- Create: `aion-application/src/pages/workspaces-page.imba`
- Modify: `aion-application/src/app.imba` (add route)

**Context:** Container page. Holds list + detail + modal state. Subscribes to pocketbase realtime on `workspaces` collection.

- [ ] **Step 1: Create page**

Create `aion-application/src/pages/workspaces-page.imba`:
```imba
# ============================================================
# workspaces-page — /projects/:id/workspaces
# ============================================================

import {pb, workspaces as wsApi} from '../api.imba'
import {WorkspaceList} from '../components/workspaces/workspace-list.imba'
import {WorkspaceDetail} from '../components/workspaces/workspace-detail.imba'
import {WorkspaceCreateModal} from '../components/workspaces/workspace-create-modal.imba'

export tag WorkspacesPage
    prop projectId\string

    items\any[] = []
    selected\any = null
    modalMode\string = ''        # '' | 'create' | 'reenroll'
    modalWorkspace\any = null
    loading\bool = yes
    error\string = ''
    unsub\any = null

    css.root
        display: flex
        flex-direction: column
        height: 100%
    css.header
        display: flex
        justify-content: space-between
        align-items: center
        padding: 16px 20px
        border-bottom: 1px solid #333
    css.body
        flex: 1
        display: flex
        min-height: 0

    def mount
        await load
        await subscribe

    def unmount
        unsub! if unsub

    def load
        try
            items = await wsApi.list(projectId)
            loading = no
        catch err
            error = err.message or String(err)
            loading = no

    def subscribe
        unsub = await pb.collection('workspaces').subscribe('*', do(e)
            if e.record.projectId !== projectId
                return
            if e.action == 'create'
                items = [e.record, ...items]
            elif e.action == 'update'
                items = items.map do(w) w.id == e.record.id ? e.record : w
                if selected?.id == e.record.id
                    selected = e.record
            elif e.action == 'delete'
                items = items.filter do(w) w.id != e.record.id
                if selected?.id == e.record.id
                    selected = null
            imba.commit!
        )

    def openCreate
        modalMode = 'create'
        modalWorkspace = null

    def onSelect ws
        selected = ws

    def onReEnroll ws
        modalMode = 'reenroll'
        modalWorkspace = ws

    def onDeleted ws
        # realtime will also remove it; safe to be idempotent
        items = items.filter do(w) w.id != ws.id
        selected = null if selected?.id == ws.id

    def closeModal
        modalMode = ''
        modalWorkspace = null

    def render
        <self.root>
            <.header>
                <h1> "Workspaces"
                <button.primary @click=openCreate> "+ Create"
            <.body>
                <WorkspaceList workspaces=items selectedId=(selected?.id or '') @select=onSelect(e.detail)>
                <WorkspaceDetail workspace=selected @re-enroll=onReEnroll(e.detail) @deleted=onDeleted(e.detail)>
            if modalMode
                <WorkspaceCreateModal mode=modalMode projectId=projectId workspace=modalWorkspace @close=closeModal>
```

- [ ] **Step 2: Add route to app.imba**

Edit `aion-application/src/app.imba` — add the import and route handler. Look at how existing routes are wired (search for a similar page entry), then follow that convention. The key addition:
```imba
import {WorkspacesPage} from './pages/workspaces-page.imba'

# inside the router/rendering block:
if path.match(/^\/projects\/([^/]+)\/workspaces$/)
    const m = path.match(/^\/projects\/([^/]+)\/workspaces$/)
    <WorkspacesPage projectId=m[1]>
```

Exact integration depends on the existing routing style — match it.

- [ ] **Step 3: Compile and smoke-test in dev**

Run:
```bash
cd /Users/fedor/Projects/aion/aion-application
bun run dev
```
Navigate to `http://localhost:4242/projects/<any-id>/workspaces`.
Expected: page renders with "No workspaces yet." and "+ Create" button. Click cycles through the modal steps (create will 404 until backend is deployed, but the UI should not crash).

- [ ] **Step 4: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/pages/workspaces-page.imba src/app.imba
git commit -m "feat(workspaces): page container + /projects/:id/workspaces route"
```

---

### Task 20: Strip legacy methods from `api.imba`

**Files:**
- Modify: `aion-application/src/api.imba`

- [ ] **Step 1: Identify legacy blocks**

Run:
```bash
cd /Users/fedor/Projects/aion/aion-application
grep -n "^export const \(servers\|agents\|agentSessions\)\|servers\.\|agents\.\|agent_sessions" src/api.imba
```
Expected: lists legacy export blocks and any internal references.

- [ ] **Step 2: Delete legacy exports**

Edit `aion-application/src/api.imba` — remove the entire `servers`, `agents`, `agentSessions` export blocks. Do not delete helpers (`pb`, `postJson`, `getJson`, `fetchRaw`) — those stay.

- [ ] **Step 3: Compile to surface consumers**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle 2>&1 | tee /tmp/aion-bundle.log`
Expected: compile errors in files that still import `servers` / `agents` / `agentSessions` from `api.imba`. These are the files Task 21 will fix.

- [ ] **Step 4: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add src/api.imba
git commit -m "chore(api): remove legacy servers/agents/agentSessions exports"
```

---

### Task 21: Delete legacy components + clean references

**Files:**
- Delete: `aion-application/src/components/server-settings-popup.imba`
- Delete: `aion-application/src/components/agent-console.imba`
- Delete: `aion-application/src/components/slash-commands.imba`
- Modify: `aion-application/src/components/right-panel.imba`
- Modify: `aion-application/src/components/project-settings-popup.imba`
- Modify: `aion-application/src/components/messages-list.imba`
- Modify: `aion-application/src/components/canvas-panel.imba`
- Modify: `aion-application/src/components/popups/terminal.imba`, `editor.imba`, `shared.imba`, `markdown.imba` (audit each)
- Modify: `aion-application/src/index.imba`
- Modify: `aion-application/src/app.imba`

**Context:** This is mechanical. Use the compile errors from Task 20 Step 3 as the authoritative list of files that need edits. Strip each reference carefully — preserve surrounding logic.

- [ ] **Step 1: Delete the three legacy component files**

```bash
cd /Users/fedor/Projects/aion/aion-application
rm src/components/server-settings-popup.imba
rm src/components/agent-console.imba
rm src/components/slash-commands.imba
```

- [ ] **Step 2: Recompile to get fresh error list**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle 2>&1 | tee /tmp/aion-bundle.log`
Save the error list — each line points to a file + import to fix.

- [ ] **Step 3: Walk each error and remove the import/reference**

For each file reported, open it and:
1. Remove the broken `import {...} from './components/server-settings-popup.imba'` (or similar).
2. Find where the imported tag/function is used; remove that usage.
3. If a whole block becomes dead (e.g., the `if false` branch left over), remove it too.

Specifically check:
- `src/components/right-panel.imba` — remove `<ServerSettingsPopup>`, `<SlashCommands>`, any agent-related sidebar sections. Add a link/button to `/projects/:id/workspaces` (project navigation).
- `src/components/project-settings-popup.imba` — remove agents/servers tab and its content. Add a button "Workspaces →" that navigates to the new page.
- `src/components/messages-list.imba` — remove the branch that renders `agent_sessions` message types.
- `src/components/canvas-panel.imba` — remove agent-branch rendering.
- `src/components/popups/{terminal,editor,shared,markdown}.imba` — for each, grep for agent/server/slashCommand references; remove if present, leave file alone otherwise.
- `src/index.imba`, `src/app.imba` — remove dead imports.

- [ ] **Step 4: Final grep check**

Run:
```bash
cd /Users/fedor/Projects/aion/aion-application
grep -rn "agent_sessions\|slashCommand\|agentMemory\|ServerSettingsPopup\|AgentConsole\|SlashCommands" src/
```
Expected: zero matches.

- [ ] **Step 5: Final compile check**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run bundle`
Expected: zero errors.

- [ ] **Step 6: Smoke-test in dev**

Run: `cd /Users/fedor/Projects/aion/aion-application && bun run dev`
Open the SPA, navigate through projects / chats / right-panel / settings. Nothing about "agents" or "servers" should appear. Navigate to `/projects/<id>/workspaces` — the new page loads.

- [ ] **Step 7: Commit**

```bash
cd /Users/fedor/Projects/aion/aion-application
git add -A src/
git commit -m "chore(ui): remove legacy server/agent/slash-command components and references"
```

---

## Part C: End-to-End Acceptance

### Task 22: Acceptance criteria run

**Files:** none — this is a verification pass.

**Context:** All implementation is done. Run through spec §1.3 acceptance criteria end-to-end against a real deployment. Any criterion that fails becomes a follow-up task, not a show-stopper — log it.

Prereqs:
- pocketbase deployed with this plan's changes (migration 019 applied, new hooks compiled + rsynced to `pb_hooks/`)
- aion-application bundled + served (or deployed)
- a clean VPS accessible with passwordless sudo, node+npm installed
- the `install.sh` at `https://<aion-host>/install.sh` resolves (test with curl)

- [ ] **Step 1: Admin creates workspace from UI**

1. Open `/projects/<existing-project-id>/workspaces` in the browser.
2. Click "+ Create". Fill: name="smoke-test", program=claude-code, model=sonnet-4.6, authMode=api_key, apiKey=<real sk-ant-...>.
3. Click "Create".

Expected: modal switches to installer-view. Snippet shows correct `--token`, `--aion`, `--workspace-id`, `--api-key` values. List in background has new row with state `provisioning`.

- [ ] **Step 2: Admin runs installer on VPS**

1. Copy snippet, SSH into clean VPS.
2. Paste + run.

Expected: installer completes. Systemd unit `aion-connector.service` is active. `aion-connector status` (as per-workspace user) shows `unit active: active`.

- [ ] **Step 3: Observe provisioning → online in UI**

Expected: within ≤2 minutes (one heartbeat cycle plus register latency), UI list and detail both show `online`. Realtime update, no page refresh needed.

- [ ] **Step 4: Simulate VPS loss**

On the VPS: `systemctl --user stop aion-connector.service` (as the per-workspace user, with `XDG_RUNTIME_DIR` set).

Expected: within ≤90 seconds, UI state flips `online → offline`.

- [ ] **Step 5: Re-enroll**

In UI detail view, click "Re-enroll" → confirm → fill apiKey again → get new snippet.
SSH back into VPS: `sudo aion-connector uninstall` as the per-workspace user, then paste the new installer snippet.

Expected: state cycles back `provisioning → online`.

- [ ] **Step 6: Delete**

Click "Delete" in UI → confirm.

Expected: record disappears from list. Optionally verify VPS connector is orphaned (next heartbeat returns 404; connector self-stops).

- [ ] **Step 7: Legacy audit**

Run (in both repos):
```bash
cd /Users/fedor/Projects/aion/aion-pocketbase && grep -rn "agent_sessions\|api\.servers\|api\.agents" src/ public/
cd /Users/fedor/Projects/aion/aion-application && grep -rn "agent_sessions\|slashCommand\|agentMemory\|api\.servers\|api\.agents" src/
```
Expected: zero matches in both.

> **Interpretation (2026-04-17):** Matches confined to `aion-pocketbase/public/_migrations/**` are expected and acceptable — migration history must continue to reference collections it originally created/dropped. What must be zero is any reference in live hook/api code (`src/`, `public/*.pb.js`, `public/workspace-auth.js`). Audit result: aion-application clean (0 matches); aion-pocketbase live code clean (0 matches); `_migrations/**` matches present by design.

- [ ] **Step 8: Mark plan complete**

Commit a final plan-complete marker if desired, or simply declare done. No code change needed.

---

> **Phase 2 status (2026-04-18):** Code-complete. All 21 implementation tasks (1-21) shipped; Task 22 Step 7 (legacy audit) verified zero live-code hits; Steps 1-6 (live VPS acceptance) deferred to the deployment operator — they require a clean VPS, a real Anthropic API key, and human observation of the UI + systemd state transitions. A final cross-repo code review was run over the full Phase 2 commit range (aion-pocketbase `69e3fc6..aa45a19`, aion-application `2387aa4..934d494`) and returned one blocker, now fixed in aion-application `d02e549` (`db.collection` → `db.pb.collection` on the workspaces realtime subscribe path). Four non-blocking follow-ups (I1 required-field flags in migration 019, I2 global-vs-project slug uniqueness, I3 repo-wide `pbQuote()` retrofit, I4 client-side filter hardening) are tracked separately for the next cycle.

---

## Self-Review (plan author)

### Spec coverage

| Spec section | Task(s) |
|---|---|
| §1.1 migration 019 | Task 2 |
| §1.1 six endpoints | Tasks 4–9 |
| §1.1 cron | Task 10 |
| §1.1 install.sh static | Task 11 |
| §1.1 delete api.servers | Task 12 |
| §1.1 /workspaces page | Tasks 14–19 |
| §1.1 realtime subscription | Task 19 (`subscribe`) |
| §1.1 clean-sweep legacy UI | Tasks 20–21 |
| §1.3 acceptance all 8 points | Task 22 |
| §2 three auth channels | Tasks 3, 4, 6, 7, 8, 9 |
| §3 data model | Task 2 |
| §4 each endpoint behavior | Tasks 4–9 |
| §5 UI flows + clean-sweep | Tasks 13–21 |
| §6 cron filter/threshold | Task 10 |
| §7 installer delivery | Tasks 11, 16 |
| §8 migration strategy | Task 2 |
| §9 security (hashing, null rules, no api_key storage) | Tasks 1, 2, 4, 6 |

### Placeholder scan

No TBD / "TODO later" / "add validation" patterns. Task 11 Step 1 says "`<PASTE FULL CONTENTS OF aion-connector/bin/install.sh HERE>`" — that's an explicit instruction with a named source file, not a placeholder.

Task 21 Step 3 references "per-file audit" for popups — this is intentional because the popup files were never read in the spec work; the audit is small and mechanical, and the compile-error list from Task 20 is the concrete input.

### Type consistency

- `enrollmentTokenHash` / `workspaceTokenHash` names consistent across Tasks 2, 3, 4, 6, 8.
- `randomHex(32)` / `sha256Hex` / `hashEq` names match between Task 1 (definitions) and Tasks 4, 6, 8 (callers).
- `requireEnrollmentToken(e, body)` signature matches between Task 3 (definition) and Task 6 (caller).
- `requireWorkspaceToken(e, id)` signature matches between Task 3 and Tasks 7, 9.
- `workspaces.create / installer / reEnroll / remove / list` API names consistent between Task 13 (definitions) and Tasks 17, 18, 19 (callers).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-17-workspace-phase2-server-ui.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, spec-compliance + code-quality review between tasks, fast iteration. Good fit: the plan has 22 independent tasks with clean boundaries.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

Which approach?
