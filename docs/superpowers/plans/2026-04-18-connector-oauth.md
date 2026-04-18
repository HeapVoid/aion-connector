# Connector OAuth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate manual Anthropic API key entry from the installer — admin authorizes Claude Code on a Workspace via device-code OAuth flow triggered from the AION UI.

**Architecture:** Four-hop synchronous proxy: UI → PB hook → aion-server (`/internal/oauth/*`) → aion-connector (`/coordinator/oauth/*`) → `claude setup-token`. OAuth `code` lives in memory only (never persisted). AION→VPS authenticated by new `aionToken` bearer pinned to the server certificate fingerprint. PB↔aion-server authenticated by a shared `AION_INTERNAL_TOKEN` over localhost.

**Tech Stack:** Imba 2 + Bun 1.x (bun:test), PocketBase v0.36 (Goja hooks + SDK), `undici` Agent for TLS pinning, systemd-user for VPS service management.

---

## Spec Drift Corrections

The spec at `docs/superpowers/specs/2026-04-18-connector-oauth-design.md` was written from memory and drifts from the real codebase in a few spots. This plan uses the *real* names/shapes; do not copy-paste identifiers from the spec verbatim.

| Spec says | Real codebase | Consequence |
|---|---|---|
| `fingerprint` field | `certFingerprint` | Migration & all route handlers use `certFingerprint` |
| `/api/workspaces/enroll` | `/api/workspaces/register` | All "enroll" wording in spec maps to `register` |
| `health!` returns `{healthy, detail}` | returns `{state: 'ready'\|'error', detail?}` | Adapter change keeps this shape — we add `detail` codes, never `healthy` |
| Migrations 020 + 021 | Migration 020 is taken (workspace rules) | All new fields bundled into migration **021** |
| `lastAuthorizedAt` exists | Does not exist in schema | Add via migration 021 |

These corrections are folded into every task below — no task references a name the codebase doesn't actually use.

---

## File Structure

### aion-pocketbase
- Create: `src/_migrations/021_workspace_oauth.imba` — adds `aionToken`, `detail`, `lastAuthorizedAt`
- Modify: `src/api.workspaces.pb.imba` — extend register (mint aionToken), re-enroll (rotate aionToken), heartbeat (accept detail)
- Create: `src/api.oauth.pb.imba` — new file for `/api/workspaces/{id}/oauth/start` + `/oauth/complete`
- Create: `tests/migration-021.test.imba`, `tests/api.oauth.test.imba`
- Extend: `tests/api.workspaces.test.imba` (existing)

### aion-server
- Create: `src/connector.imba` — pinnedAgent, callConnector, /internal/oauth/*
- Modify: `src/index.imba` — mount connector routes
- Create: `package.json` test script + `tests/` directory + `tests/connector.test.imba`

### aion-connector
- Modify: `src/claude-code-adapter.imba` — extend `health()` with credential-file inspection
- Modify: `src/stub-adapter.imba` — keep return shape in sync
- Modify: `src/server.imba` — replace `workspaceToken` bearer with `aionToken`
- Modify: `src/aion-client.imba` — pass aion_token through register response
- Modify: `src/cli.imba` — write aion-token on install; load it at run time
- Modify: `src/state.imba` — persist `aion_token` path
- Modify: `src/connector.imba` — pass aionToken to Server instance
- Modify: `bin/install.sh` — `--auth-mode oauth` branch, aion-token writeout, claude CLI ensurement
- Extend: `tests/routes.oauth.test.imba`, `tests/server.auth.test.imba`, `tests/claude-code-adapter.test.imba`

### aion-application
- Create: `src/components/workspaces/workspace-oauth-modal.imba`
- Modify: `src/components/workspaces/workspace-create-modal.imba` — oauth option
- Modify: `src/components/workspaces/workspace-detail-view.imba` (or equivalent) — CTA banner + re-auth link
- Modify: `src/services/api.imba` — `workspaces.oauthStart()`, `workspaces.oauthComplete()`
- Create: `tests/workspace-oauth-modal.test.imba`

### Docs & Ops
- Create: `docs/runbooks/oauth-smoke.md`

---

## Wave 1 — AION PocketBase foundation

### Task 1: Migration 021 — aionToken + lastAuthorizedAt + detail

**Files:**
- Create: `aion-pocketbase/src/_migrations/021_workspace_oauth.imba`
- Create: `aion-pocketbase/tests/migration-021.test.imba`

- [ ] **Step 1: Write the failing test**

Create `aion-pocketbase/tests/migration-021.test.imba`:

```imba
import {test, expect} from "bun:test"
import {readFileSync} from "fs"
import {join} from "path"

# Static source-level assertions. PB migrations run against a live DB;
# we don't boot one here — we assert the source declares the expected
# fields, which is what the compile step ships to Goja.

const source = readFileSync(join(process.cwd(), 'src/_migrations/021_workspace_oauth.imba'), 'utf8')

test "021 adds aionToken text field", do
	expect(source).toContain("aionToken")
	expect(source).toContain("text")
	# Size cap from spec §2.1
	expect(source).toMatch(/aionToken[^\n]*max:\s*128/)

test "021 adds detail text field", do
	expect(source).toContain("'detail'")
	# Free-form, max 64 per spec §2.1
	expect(source).toMatch(/'detail'[^\n]*max:\s*64/)

test "021 adds lastAuthorizedAt date field", do
	expect(source).toContain("lastAuthorizedAt")
	expect(source).toMatch(/date\(\s*'lastAuthorizedAt'/)

test "021 uses collection.update on workspaces", do
	expect(source).toMatch(/collection\.update\(\s*app,\s*'workspaces'/)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-pocketbase && bun test tests/migration-021.test.imba
```
Expected: FAIL with "no such file or directory" (migration not yet created).

- [ ] **Step 3: Write the migration**

Create `aion-pocketbase/src/_migrations/021_workspace_oauth.imba`:

```imba
# ============================================================
# 021_workspace_oauth.imba — Connector OAuth fields
# ============================================================
# Adds three fields to `workspaces`:
#   aionToken          — plaintext bearer for AION→VPS calls.
#                        Can't be hashed (aion-server reads it).
#                        Threat: if pb_data leaks, DB already lost
#                        → separate at-rest encryption is marginal.
#   detail             — free-form health detail from heartbeat
#                        ('not_authorized', 'claude_missing',
#                         'creds_corrupt'). Free-form so new codes
#                        land without a migration.
#   lastAuthorizedAt   — timestamp set when /oauth/complete succeeds.
#                        UI uses (authMode == 'oauth' && !lastAuthorizedAt)
#                        to show first-time authorize CTA.
# ============================================================

def migrate app
	const { field, collection } = require("{__hooks}/migration.js")
	collection.update(app, 'workspaces', [
		field.text('aionToken', { max: 128 })
		field.text('detail', { max: 64 })
		field.date('lastAuthorizedAt')
	], {})

module.exports = { migrate }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd aion-pocketbase && bun test tests/migration-021.test.imba
```
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full test suite — migrations 019 + 020 + 021 must still compile clean**

```bash
cd aion-pocketbase && bun test tests/compile.test.imba
bun run build
```
Expected: both PASS. No `__commonJS` / `iterable$` / `runtime.mjs` bundled.

- [ ] **Step 6: Commit**

```bash
cd aion-pocketbase
git add src/_migrations/021_workspace_oauth.imba tests/migration-021.test.imba
git commit -m "pb: add migration 021 for workspace OAuth fields"
```

---

### Task 2: Register handler — mint aion_token in transaction

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (register handler, lines 125-173)
- Create: `aion-pocketbase/tests/api.workspaces.register.test.imba` (new)

- [ ] **Step 1: Write the failing test**

Create `aion-pocketbase/tests/api.workspaces.register.test.imba`:

```imba
import {test, expect} from "bun:test"
import {readFileSync} from "fs"
import {join} from "path"

# Source-level assertion — we verify the compiled handler uses the
# right identifiers. A real HTTP test needs a PB daemon, which we
# don't spin up in unit tests; the compile gate + smoke runbook
# cover wire-level behavior.

const source = readFileSync(join(process.cwd(), 'src/api.workspaces.pb.imba'), 'utf8')

test "register mints aionToken inside transaction", do
	# Must be inside the register handler's runInTransaction block
	const registerBlock = source.match(/routerAdd 'POST', '\/api\/workspaces\/register'[\s\S]+?catch err/)
	expect(registerBlock).not.toBeNull()
	const block = registerBlock[0]
	expect(block).toContain("randomHex(32)")
	expect(block).toMatch(/rec\.set\(\s*'aionToken'/)

test "register response includes aion_token", do
	const registerBlock = source.match(/routerAdd 'POST', '\/api\/workspaces\/register'[\s\S]+?catch err/)[0]
	expect(registerBlock).toContain("aion_token")

test "register response still includes workspace_id and workspace_token", do
	const registerBlock = source.match(/routerAdd 'POST', '\/api\/workspaces\/register'[\s\S]+?catch err/)[0]
	expect(registerBlock).toContain("workspace_id")
	expect(registerBlock).toContain("workspace_token")
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-pocketbase && bun test tests/api.workspaces.register.test.imba
```
Expected: FAIL — `aionToken` / `aion_token` not yet in source.

- [ ] **Step 3: Update the register handler**

In `aion-pocketbase/src/api.workspaces.pb.imba`, locate the register handler's transaction block (around lines 135-168). Inside `$app.runInTransaction`, after the existing `workspaceToken` minting, add:

```imba
			# mint aionToken — plaintext bearer for AION→VPS calls
			# (stored in cleartext on both sides per spec §2.3)
			const aionToken = randomHex(32)
			rec.set('aionToken', aionToken)
```

And extend the response object from:

```imba
				response = {
					workspace_id: rec.id
					workspace_token: workspaceToken
				}
```

to:

```imba
				response = {
					workspace_id: rec.id
					workspace_token: workspaceToken
					aion_token: aionToken
				}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd aion-pocketbase && bun test tests/api.workspaces.register.test.imba
```
Expected: PASS (3 tests).

- [ ] **Step 5: Run compile gate**

```bash
cd aion-pocketbase && bun run build
```
Expected: PASS, no residual `__commonJS`.

- [ ] **Step 6: Commit**

```bash
cd aion-pocketbase
git add src/api.workspaces.pb.imba tests/api.workspaces.register.test.imba
git commit -m "pb: mint aion_token on workspace register"
```

---

### Task 3: Re-enroll handler — rotate aionToken

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (re-enroll handler, lines 199-231)
- Modify: `aion-pocketbase/tests/api.workspaces.register.test.imba` (append cases)

- [ ] **Step 1: Write the failing test**

Append to `aion-pocketbase/tests/api.workspaces.register.test.imba`:

```imba
test "re-enroll rotates aionToken", do
	const block = source.match(/routerAdd 'POST', '\/api\/workspaces\/\{id\}\/re-enroll'[\s\S]+?catch err/)[0]
	expect(block).toMatch(/rec\.set\(\s*'aionToken'/)
	expect(block).toContain("randomHex(32)")

test "re-enroll response includes new aion_token", do
	const block = source.match(/routerAdd 'POST', '\/api\/workspaces\/\{id\}\/re-enroll'[\s\S]+?catch err/)[0]
	expect(block).toContain("aion_token")
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-pocketbase && bun test tests/api.workspaces.register.test.imba
```
Expected: FAIL on the two new cases.

- [ ] **Step 3: Update the re-enroll handler**

In the re-enroll handler, after the existing `workspaceTokenHash` clear line, add:

```imba
			# rotate aionToken alongside workspace_token — installer grabs the
			# new value on re-register, same shape as Task 2 mint path
			const aionToken = randomHex(32)
			rec.set('aionToken', aionToken)
```

Extend the response:

```imba
			return e.json(200, {
				enrollment_token: enrollmentToken
				aion_token: aionToken
			})
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd aion-pocketbase && bun test tests/api.workspaces.register.test.imba
```
Expected: PASS (5 tests total).

- [ ] **Step 5: Commit**

```bash
cd aion-pocketbase
git add src/api.workspaces.pb.imba tests/api.workspaces.register.test.imba
git commit -m "pb: rotate aion_token on re-enroll"
```

---

### Task 4: Heartbeat handler — accept `detail` field

**Files:**
- Modify: `aion-pocketbase/src/api.workspaces.pb.imba` (heartbeat handler, lines 177-195)
- Create: `aion-pocketbase/tests/api.workspaces.heartbeat.test.imba`

- [ ] **Step 1: Write the failing test**

Create `aion-pocketbase/tests/api.workspaces.heartbeat.test.imba`:

```imba
import {test, expect} from "bun:test"
import {readFileSync} from "fs"
import {join} from "path"

const source = readFileSync(join(process.cwd(), 'src/api.workspaces.pb.imba'), 'utf8')

test "heartbeat handler sets detail from coordinator_status.detail", do
	const block = source.match(/routerAdd 'POST', '\/api\/workspaces\/\{id\}\/heartbeat'[\s\S]+?catch err/)[0]
	expect(block).toMatch(/rec\.set\(\s*'detail'/)

test "heartbeat defaults detail to empty string when coordinator_status.detail missing", do
	const block = source.match(/routerAdd 'POST', '\/api\/workspaces\/\{id\}\/heartbeat'[\s\S]+?catch err/)[0]
	# The handler must tolerate old connectors that don't send detail
	expect(block).toMatch(/cs\.detail\s+or\s+['"]['"]/)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-pocketbase && bun test tests/api.workspaces.heartbeat.test.imba
```
Expected: FAIL.

- [ ] **Step 3: Update the heartbeat handler**

In the heartbeat handler, after the existing `rec.set('state', …)` line, insert:

```imba
			# detail is optional (old connectors send only state). Default
			# to empty string rather than null — field is a text field.
			rec.set('detail', cs.detail or '') if body.coordinator_status
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd aion-pocketbase && bun test tests/api.workspaces.heartbeat.test.imba
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd aion-pocketbase
git add src/api.workspaces.pb.imba tests/api.workspaces.heartbeat.test.imba
git commit -m "pb: heartbeat stores coordinator_status.detail"
```

---

### Task 5: New PB routes — `/oauth/start` and `/oauth/complete`

**Files:**
- Create: `aion-pocketbase/src/api.oauth.pb.imba`
- Create: `aion-pocketbase/tests/api.oauth.test.imba`

- [ ] **Step 1: Write the failing test**

Create `aion-pocketbase/tests/api.oauth.test.imba`:

```imba
import {test, expect} from "bun:test"
import {readFileSync, existsSync} from "fs"
import {join} from "path"

const path = join(process.cwd(), 'src/api.oauth.pb.imba')

test "api.oauth.pb.imba source exists", do
	expect(existsSync(path)).toBe(true)

test "mounts /api/workspaces/{id}/oauth/start", do
	const source = readFileSync(path, 'utf8')
	expect(source).toMatch(/routerAdd\s+'POST',\s*'\/api\/workspaces\/\{id\}\/oauth\/start'/)

test "mounts /api/workspaces/{id}/oauth/complete", do
	const source = readFileSync(path, 'utf8')
	expect(source).toMatch(/routerAdd\s+'POST',\s*'\/api\/workspaces\/\{id\}\/oauth\/complete'/)

test "start handler forwards to aion-server /internal/oauth/start", do
	const source = readFileSync(path, 'utf8')
	expect(source).toContain('/internal/oauth/start')
	expect(source).toContain('127.0.0.1:8787')

test "complete handler forwards to aion-server /internal/oauth/complete", do
	const source = readFileSync(path, 'utf8')
	expect(source).toContain('/internal/oauth/complete')

test "complete handler updates lastAuthorizedAt + state='online' + detail='' on success", do
	const source = readFileSync(path, 'utf8')
	expect(source).toContain("lastAuthorizedAt")
	expect(source).toMatch(/rec\.set\(\s*'state',\s*'online'/)
	expect(source).toMatch(/rec\.set\(\s*'detail',\s*''/)

test "routes require project-member auth via info()", do
	const source = readFileSync(path, 'utf8')
	expect(source).toContain("info(rec.get('projectId'), request.auth.id)")

test "uses AION_INTERNAL_TOKEN env var on X-Internal-Token header", do
	const source = readFileSync(path, 'utf8')
	expect(source).toContain("AION_INTERNAL_TOKEN")
	expect(source).toContain("X-Internal-Token")
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-pocketbase && bun test tests/api.oauth.test.imba
```
Expected: FAIL (file doesn't exist).

- [ ] **Step 3: Implement the routes**

Create `aion-pocketbase/src/api.oauth.pb.imba`:

```imba
# ============================================================
# api.oauth.pb.imba — Connector OAuth proxy endpoints
# ============================================================
# POST /api/workspaces/{id}/oauth/start
#   Project-member auth. Forwards to aion-server localhost
#   /internal/oauth/start via $http.send. Returns {url} verbatim.
#
# POST /api/workspaces/{id}/oauth/complete {code}
#   Same auth path. Forwards to aion-server. On HTTP 200,
#   flips workspace record: lastAuthorizedAt=now, state=online,
#   detail=''. UI subscribes via realtime and clears the CTA.
#
# PB v0.36 Goja per-request VM: all `const`/`require` MUST live
# INSIDE the handler (see api.push.pb.imba comment for the rule).
# ============================================================

routerAdd 'POST', '/api/workspaces/{id}/oauth/start', do(e)
	const { auth, info } = require("{__hooks}/utils.js")
	const { request } = auth(e)
	const id = e.request.pathValue('id')

	try
		const rec = $app.findRecordById('workspaces', id)
		const i = info(rec.get('projectId'), request.auth.id)
		return e.json(403, { error: "not a project member" }) unless i.member

		const internalToken = $os.getenv('AION_INTERNAL_TOKEN')
		return e.json(500, { error: "AION_INTERNAL_TOKEN not configured" }) unless internalToken

		const resp = $http.send({
			method: 'POST'
			url: "http://127.0.0.1:8787/internal/oauth/start"
			body: JSON.stringify({ workspace_id: id })
			headers: {
				"Content-Type": "application/json"
				"X-Internal-Token": internalToken
			}
			timeout: 15
		})
		if resp.statusCode >= 400
			return e.json(resp.statusCode, JSON.parse(resp.body or '{"error":"aion-server error"}'))
		return e.json(200, JSON.parse(resp.body))
	catch err
		$app.logger!.error("oauth start failed", "err", String(err))
		return e.json(500, { error: "oauth start failed: " + String(err) })

routerAdd 'POST', '/api/workspaces/{id}/oauth/complete', do(e)
	const { auth, info } = require("{__hooks}/utils.js")
	const { request } = auth(e, ['code'])
	const id = e.request.pathValue('id')
	const query = e.requestInfo!.body or {}

	try
		const rec = $app.findRecordById('workspaces', id)
		const i = info(rec.get('projectId'), request.auth.id)
		return e.json(403, { error: "not a project member" }) unless i.member

		const internalToken = $os.getenv('AION_INTERNAL_TOKEN')
		return e.json(500, { error: "AION_INTERNAL_TOKEN not configured" }) unless internalToken

		const resp = $http.send({
			method: 'POST'
			url: "http://127.0.0.1:8787/internal/oauth/complete"
			body: JSON.stringify({ workspace_id: id, code: query.code })
			headers: {
				"Content-Type": "application/json"
				"X-Internal-Token": internalToken
			}
			timeout: 15
		})
		if resp.statusCode >= 400
			return e.json(resp.statusCode, JSON.parse(resp.body or '{"error":"aion-server error"}'))

		# Success: optimistic state flip (spec §7.4). Next heartbeat
		# is self-correcting if adapter disagrees.
		rec.set('lastAuthorizedAt', new Date!.toISOString!)
		rec.set('state', 'online')
		rec.set('detail', '')
		$app.save(rec)

		return e.json(200, JSON.parse(resp.body))
	catch err
		$app.logger!.error("oauth complete failed", "err", String(err))
		return e.json(500, { error: "oauth complete failed: " + String(err) })
```

Note on `auth(e, ['code'])`: `utils.imba` `auth()` helper validates required fields; it already understands request body + path params. If the existing helper only covers query/body but not body on POST, fall back to extracting `e.requestInfo!.body.code` manually (which is what the handler does anyway via `query.code` — keep both as defense-in-depth).

- [ ] **Step 4: Run test to verify it passes**

```bash
cd aion-pocketbase && bun test tests/api.oauth.test.imba
```
Expected: PASS (8 tests).

- [ ] **Step 5: Run compile gate**

```bash
cd aion-pocketbase && bun run build
```
Expected: `public/api.oauth.pb.js` generated, no `__commonJS` residue.

- [ ] **Step 6: Commit**

```bash
cd aion-pocketbase
git add src/api.oauth.pb.imba tests/api.oauth.test.imba
git commit -m "pb: add /oauth/start and /oauth/complete proxy routes"
```

---

## Wave 2 — aion-connector changes

### Task 6: Extend `ClaudeCodeAdapter.health()` with credentials.json inspection

**Files:**
- Modify: `aion-connector/src/claude-code-adapter.imba` (lines 64-70)
- Modify: `aion-connector/src/stub-adapter.imba` (keep shape in sync)
- Create: `aion-connector/tests/claude-code-adapter.health.test.imba`

- [ ] **Step 1: Write the failing test**

Create `aion-connector/tests/claude-code-adapter.health.test.imba`:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync, rmSync, mkdirSync, writeFileSync, chmodSync} from "fs"
import {tmpdir} from "os"
import {join} from "path"
import {ClaudeCodeAdapter} from "../src/claude-code-adapter.imba"

let home = null

beforeEach(do
	home = mkdtempSync(join(tmpdir!, 'aion-test-'))
	mkdirSync(join(home, '.claude'), { recursive: yes })
)

afterEach(do
	rmSync(home, { recursive: yes, force: yes })
)

# NOTE: these tests assume `claude` is resolvable in PATH (CI installs it).
# If not, the `claude_missing` branch fires and the other asserts are
# short-circuited; the test for that exact case is the first one below.

test "health returns claude_missing when binary absent", do
	# Force PATH to a dir that has no `claude` so `which` fails
	const origPath = process.env.PATH
	process.env.PATH = '/nonexistent'
	const a = new ClaudeCodeAdapter(home)
	const h = await a.health()
	process.env.PATH = origPath
	expect(h.state).toBe('error')
	expect(h.detail).toBe('claude_missing')

test "health returns not_authorized when credentials.json absent", do
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes   # skip the which probe
	const h = await a.health()
	expect(h.state).toBe('error')
	expect(h.detail).toBe('not_authorized')

test "health returns not_authorized when credentials.json says expired", do
	const creds = { expires_at: Date.now() - 1000 }
	writeFileSync(join(home, '.claude/credentials.json'), JSON.stringify(creds))
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('error')
	expect(h.detail).toBe('not_authorized')

test "health returns ready when credentials.json present and fresh", do
	const creds = { expires_at: Date.now() + 3600 * 1000 }
	writeFileSync(join(home, '.claude/credentials.json'), JSON.stringify(creds))
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('ready')

test "health returns creds_corrupt on unparseable credentials.json", do
	writeFileSync(join(home, '.claude/credentials.json'), '{not json')
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('error')
	expect(h.detail).toBe('creds_corrupt')

test "health treats credentials.json without expires_at as ready (adapter can't know)", do
	writeFileSync(join(home, '.claude/credentials.json'), '{}')
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('ready')
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-connector && bun test tests/claude-code-adapter.health.test.imba
```
Expected: FAIL (most assertions — current `health()` doesn't look at credentials.json).

- [ ] **Step 3: Implement the extended `health()`**

Replace the `health` method in `aion-connector/src/claude-code-adapter.imba`:

```imba
	def health
		unless installed
			const which = await utils.exec(['which', 'claude'])
			installed = which.exitCode == 0
		unless installed
			return { state: 'error', detail: 'claude_missing' }

		# Peek at credentials.json without spawning a subprocess or
		# hitting the network. Runs every heartbeat (~30s cadence),
		# so cost matters. Threshold: refuse if expires_at < now+60s —
		# treat "about to expire" as already-expired so the UI CTA
		# lights up before calls start failing.
		const credsPath = path.join(self.home, '.claude', 'credentials.json')
		unless fs.existsSync(credsPath)
			return { state: 'error', detail: 'not_authorized' }

		try
			const raw = fs.readFileSync(credsPath, 'utf8')
			const creds = JSON.parse(raw)
			if creds.expires_at and creds.expires_at < Date.now! + 60_000
				return { state: 'error', detail: 'not_authorized' }
		catch e
			return { state: 'error', detail: 'creds_corrupt' }

		{ state: 'ready' }
```

- [ ] **Step 4: Update StubAdapter to match the shape**

Read `aion-connector/src/stub-adapter.imba` (or wherever `StubAdapter.health` lives). Ensure its `health()` returns `{state: 'ready'}` (or accepts an override for testing the error branches in route tests). No behavior change — spec just requires the return shape stays additive.

If the file currently returns `{state: 'ready'}` only, leave it. If it returns `{healthy: yes}`, normalize to `{state: 'ready'}`.

- [ ] **Step 5: Run test to verify it passes**

```bash
cd aion-connector && bun test tests/claude-code-adapter.health.test.imba
```
Expected: PASS (6 tests).

- [ ] **Step 6: Also run existing adapter + routes tests to make sure we didn't break them**

```bash
cd aion-connector && bun test
```
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd aion-connector
git add src/claude-code-adapter.imba src/stub-adapter.imba tests/claude-code-adapter.health.test.imba
git commit -m "connector: extend ClaudeCodeAdapter.health with credentials inspection"
```

---

### Task 7: Server middleware — switch inbound bearer to `aionToken`

**Files:**
- Modify: `aion-connector/src/server.imba` (lines 8-22, 51-56)
- Modify: `aion-connector/src/connector.imba` (passes `workspaceToken` to Server — switch to `aionToken`)
- Modify: `aion-connector/src/state.imba` (persist aion_token path)
- Modify: `aion-connector/tests/routes.oauth.test.imba` (fixture uses `aionToken`)
- Create: `aion-connector/tests/server.auth.test.imba`

- [ ] **Step 1: Write the failing test**

Create `aion-connector/tests/server.auth.test.imba`:

```imba
import {test, expect, beforeAll, afterAll} from "bun:test"
import {Server} from "../src/server.imba"
import * as tls from "../src/tls.imba"
import {mkdtempSync, rmSync} from "fs"
import {tmpdir} from "os"
import {join} from "path"

let srv = null
let url = null
const aionToken = 'a'.repeat(64)
let tmp = null

beforeAll(do
	tmp = mkdtempSync(join(tmpdir!, 'aion-srv-'))
	const certPath = join(tmp, 'cert.pem')
	const keyPath = join(tmp, 'key.pem')
	await tls.generateSelfSigned(certPath, keyPath)
	const {readFileSync} = require('fs')
	srv = new Server({
		port: 0
		cert: readFileSync(certPath)
		key: readFileSync(keyPath)
		aionToken: aionToken
	})
	srv.route 'POST', '/ok', do { status: 200, body: { ok: yes } }
	await srv.start()
	url = "https://127.0.0.1:{srv.srv.address().port}/ok"
)

afterAll(do
	await srv?.stop()
	rmSync(tmp, { recursive: yes, force: yes })
)

test "request without Authorization → 403", do
	const res = await fetch(url, { method: 'POST', tls: { rejectUnauthorized: no } })
	expect(res.status).toBe(403)

test "request with wrong bearer → 403", do
	const res = await fetch(url, {
		method: 'POST'
		headers: { authorization: "Bearer wrong" }
		tls: { rejectUnauthorized: no }
	})
	expect(res.status).toBe(403)

test "request with correct aionToken bearer → 200", do
	const res = await fetch(url, {
		method: 'POST'
		headers: { authorization: "Bearer {aionToken}" }
		tls: { rejectUnauthorized: no }
	})
	expect(res.status).toBe(200)
```

Then update `aion-connector/tests/routes.oauth.test.imba` — replace every `workspaceToken: token` with `aionToken: token` in the Server fixture.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-connector && bun test tests/server.auth.test.imba
```
Expected: FAIL — `Server` doesn't yet accept `aionToken` constructor arg.

- [ ] **Step 3: Update Server class**

In `aion-connector/src/server.imba`:

Replace the class field and constructor assignment:

```imba
export class Server
	host = '0.0.0.0'
	port = 0
	cert = null
	key = null
	aionToken = null
	routes = []
	srv = null

	def constructor opts
		self.port = opts.port
		self.cert = opts.cert
		self.key = opts.key
		self.aionToken = opts.aionToken
		self.host = opts.host or '0.0.0.0'
```

Replace the auth check in `handle()`:

```imba
			const auth = req.headers['authorization'] or ''
			const tok = auth.replace(/^Bearer /, '')
			unless tok and tok === aionToken
				return self.reply(res, 403, { error: 'unauthorized' })
```

- [ ] **Step 4: Update the caller in connector.imba**

In `aion-connector/src/connector.imba`, where `Server` is instantiated, replace `workspaceToken: state.workspace_token` with `aionToken: state.aion_token`.

- [ ] **Step 5: Update state.imba to persist aion_token**

In `aion-connector/src/state.imba` make sure the state schema includes `aion_token` (alongside `workspace_token`). Both get written by cli.imba in Task 8.

- [ ] **Step 6: Run tests**

```bash
cd aion-connector && bun test tests/server.auth.test.imba tests/routes.oauth.test.imba
```
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
cd aion-connector
git add src/server.imba src/connector.imba src/state.imba tests/server.auth.test.imba tests/routes.oauth.test.imba
git commit -m "connector: authenticate inbound /coordinator/* with aionToken"
```

---

### Task 8: Install flow — capture aion_token from register response + persist

**Files:**
- Modify: `aion-connector/src/aion-client.imba` — register returns `aion_token`
- Modify: `aion-connector/src/cli.imba` — writeState includes `aion_token`

- [ ] **Step 1: Write the failing test**

Extend `aion-connector/tests/aion-client.test.imba` (or create if missing):

```imba
import {test, expect} from "bun:test"
import {AionClient} from "../src/aion-client.imba"

test "register passes through aion_token from PB response", do
	# Stub fetch that returns the full register payload
	const origFetch = globalThis.fetch
	globalThis.fetch = do(url, opts)
		return {
			status: 200
			ok: yes
			json: do Promise.resolve({
				workspace_id: 'ws1'
				workspace_token: 'wtok'
				aion_token: 'atok'
			})
		}
	const c = new AionClient('http://aion.test')
	const r = await c.register({
		enrollment_token: 'e'
		external_ip: '1.2.3.4'
		port: 9000
		cert_fingerprint: 'deadbeef'
		coordinator_status: { state: 'ready' }
		connector_version: 'test'
	})
	globalThis.fetch = origFetch
	expect(r.aion_token).toBe('atok')
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-connector && bun test tests/aion-client.test.imba
```
Expected: FAIL if current `register` strips unknown fields, PASS trivially if it returns the full JSON. Read `aion-client.imba` — if it already returns the full response object, this test passes immediately and Step 3 below is a no-op (skip to Step 4).

- [ ] **Step 3: Ensure `AionClient.register` returns the full JSON**

In `aion-connector/src/aion-client.imba`, the `register` method should already `return await res.json()`. Confirm it does not filter keys; if it does, remove the filter.

- [ ] **Step 4: Update `cli.imba` to persist aion_token**

In `aion-connector/src/cli.imba`, in `cmdInstall` after the register call (around line 113), extend `writeState`:

```imba
	stateMod.writeState({
		workspace_id: reg.workspace_id
		workspace_token: reg.workspace_token
		aion_token: reg.aion_token
		aion_url: f.aion
		port: port
		cert_fingerprint: fp
		coordinator: {
			program: f.program
			model: f.model
			auth_mode: f['auth-mode']
		}
	})
```

- [ ] **Step 5: Run tests**

```bash
cd aion-connector && bun test
```
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd aion-connector
git add src/cli.imba src/aion-client.imba tests/aion-client.test.imba
git commit -m "connector: persist aion_token from register response"
```

---

## Wave 3 — aion-server module

### Task 9: Bootstrap test infrastructure in aion-server

**Files:**
- Modify: `aion-server/package.json` — add test script + bun:test types
- Create: `aion-server/tests/.gitkeep` (or smoke test below)
- Create: `aion-server/tests/smoke.test.imba`

- [ ] **Step 1: Write a trivial smoke test that proves the runner works**

Create `aion-server/tests/smoke.test.imba`:

```imba
import {test, expect} from "bun:test"

test "bun test runner is wired", do
	expect(1 + 1).toBe(2)
```

- [ ] **Step 2: Add test script**

Edit `aion-server/package.json`:

```json
{
  "scripts": {
    "start": "...existing...",
    "dev": "...existing...",
    "test": "bun test"
  }
}
```

- [ ] **Step 3: Run**

```bash
cd aion-server && bun test
```
Expected: PASS (1 test).

- [ ] **Step 4: Commit**

```bash
cd aion-server
git add package.json tests/smoke.test.imba
git commit -m "aion-server: bootstrap bun:test infrastructure"
```

---

### Task 10: `connector.imba` — pinnedAgent + callConnector helpers

**Files:**
- Create: `aion-server/src/connector.imba` (helpers only — routes added in Task 12)
- Create: `aion-server/tests/connector.helpers.test.imba`

- [ ] **Step 1: Write the failing test**

Create `aion-server/tests/connector.helpers.test.imba`:

```imba
import {test, expect, beforeAll, afterAll} from "bun:test"
import {pinnedAgent, callConnector} from "../src/connector.imba"
import {createHash} from "crypto"
import {createServer} from "https"
import {selfsigned} from "../src/testutil.imba"  # see Step 3 below

let srv = null
let port = null
let fp = null

beforeAll(do
	const {cert, key} = await selfsigned()
	# Fingerprint is lowercase-hex SHA-256 of the DER cert, matching
	# aion-connector/src/tls.imba:fingerprint()
	fp = createHash('sha256').update(cert.raw or cert).digest('hex')
	srv = createServer({ cert, key }, do(req, res)
		let raw = ''
		req.on 'data', do(c) raw += c
		req.on 'end', do
			const auth = req.headers['authorization'] or ''
			if auth !== 'Bearer good-token'
				res.writeHead(401); return res.end()
			res.writeHead(200, { 'content-type': 'application/json' })
			res.end(JSON.stringify({ echo: JSON.parse(raw or '{}') }))
	)
	await new Promise do(ok) srv.listen(0, '127.0.0.1', ok)
	port = srv.address().port
)

afterAll(do srv?.close())

test "callConnector sends Bearer aionToken and hits pinned fingerprint", do
	const ws = { externalIp: '127.0.0.1', port: port, certFingerprint: fp, aionToken: 'good-token' }
	const r = await callConnector(ws, '/whatever', { hello: 1 })
	expect(r.status).toBe(200)
	expect(r.json.echo.hello).toBe(1)

test "callConnector with wrong fingerprint throws", do
	const ws = { externalIp: '127.0.0.1', port: port, certFingerprint: 'deadbeef' + 'f'.repeat(56), aionToken: 'good-token' }
	let thrown = no
	try
		await callConnector(ws, '/whatever', {})
	catch e
		thrown = yes
	expect(thrown).toBe(true)

test "callConnector with wrong bearer gets 401", do
	const ws = { externalIp: '127.0.0.1', port: port, certFingerprint: fp, aionToken: 'wrong' }
	const r = await callConnector(ws, '/whatever', {})
	expect(r.status).toBe(401)
```

- [ ] **Step 2: Write the testutil helper for self-signed certs**

Create `aion-server/src/testutil.imba`:

```imba
# Self-signed cert factory for unit tests. Uses node:crypto + the
# selfsigned pkg if available, otherwise shells out to openssl via Bun.$.
# Kept in src/ so tests can import without path shenanigans.

import {$ as bunShell} from "bun"
import {readFileSync, mkdtempSync} from "fs"
import {tmpdir} from "os"
import {join} from "path"

export def selfsigned
	const dir = mkdtempSync(join(tmpdir!, 'aion-testcert-'))
	const key = join(dir, 'k.pem')
	const crt = join(dir, 'c.pem')
	await bunShell`openssl req -x509 -newkey rsa:2048 -nodes -keyout {key} -out {crt} -days 1 -subj "/CN=localhost" 2>/dev/null`
	{ cert: readFileSync(crt), key: readFileSync(key) }
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd aion-server && bun test tests/connector.helpers.test.imba
```
Expected: FAIL — `connector.imba` not yet created.

- [ ] **Step 4: Implement helpers**

Create `aion-server/src/connector.imba`:

```imba
# ============================================================
# connector.imba — aion-server ↔ aion-connector pinned TLS client
# ============================================================
# Only the helpers in this file are tested independently;
# /internal/oauth/* routes are added in a follow-up task.
# ============================================================

import {Agent} from "undici"
import {createHash} from "node:crypto"

# Fingerprint comparison is exact-string on lowercase 64-char hex
# (no colons). That's what aion-connector/src/tls.imba:fingerprint()
# emits, so no normalization needed.
export def pinnedAgent serverFp
	new Agent({
		connect: {
			rejectUnauthorized: no  # pin by fp, not CA chain
			checkServerIdentity: do(host, cert)
				const got = createHash('sha256').update(cert.raw).digest('hex')
				return new Error("fingerprint mismatch: expected {serverFp} got {got}") if got !== serverFp
				return undefined
		}
	})

# 10s timeout covers `claude setup-token` cold start. No retries —
# failure surfaces to UI, admin retries manually (spec §4.2).
export def callConnector workspace, path, body
	const res = await fetch("https://{workspace.externalIp}:{workspace.port}{path}", {
		method: 'POST'
		dispatcher: pinnedAgent(workspace.certFingerprint)
		headers: {
			'Content-Type': 'application/json'
			'Authorization': "Bearer {workspace.aionToken}"
		}
		body: JSON.stringify(body)
		signal: AbortSignal.timeout(10_000)
	})
	let json = null
	try
		json = await res.json()
	catch e
		json = {}
	{ status: res.status, json: json }
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd aion-server && bun test tests/connector.helpers.test.imba
```
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
cd aion-server
git add src/connector.imba src/testutil.imba tests/connector.helpers.test.imba
git commit -m "aion-server: add pinnedAgent + callConnector helpers"
```

---

### Task 11: `connector.imba` — workspace lookup via PB SDK (superuser auth)

**Files:**
- Modify: `aion-server/src/connector.imba` — add `fetchWorkspace(id)` helper
- Modify: `aion-server/tests/connector.helpers.test.imba` — mock PB fetch

- [ ] **Step 1: Write the failing test**

Append to `aion-server/tests/connector.helpers.test.imba`:

```imba
import {fetchWorkspace} from "../src/connector.imba"

test "fetchWorkspace returns record from PB", do
	# Stub globalThis.fetch for the PB admin auth + collection fetch
	const origFetch = globalThis.fetch
	let calls = 0
	globalThis.fetch = do(url, opts)
		calls++
		if url.includes('/auth-with-password')
			return { ok: yes, status: 200, json: do Promise.resolve({ token: 'admintok' }) }
		if url.includes('/collections/workspaces/records/')
			return { ok: yes, status: 200, json: do Promise.resolve({
				id: 'w1', externalIp: '1.2.3.4', port: 8443, certFingerprint: 'fp', aionToken: 'atok'
			}) }
		return { ok: no, status: 404 }
	const ws = await fetchWorkspace('w1')
	globalThis.fetch = origFetch
	expect(ws.id).toBe('w1')
	expect(ws.aionToken).toBe('atok')
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-server && bun test tests/connector.helpers.test.imba
```
Expected: FAIL — `fetchWorkspace` not yet exported.

- [ ] **Step 3: Implement fetchWorkspace**

Append to `aion-server/src/connector.imba`:

```imba
# PB admin superuser auth — same pattern as aion-server/src/push.imba.
# Env: PB_URL, PB_EMAIL, PB_PASSWORD.
let _cachedToken = null
let _cachedExpiresAt = 0

def pbAdminToken
	const now = Date.now!
	return _cachedToken if _cachedToken and now < _cachedExpiresAt
	const pbUrl = process.env.PB_URL or 'http://127.0.0.1:8090'
	const res = await fetch("{pbUrl}/api/collections/_superusers/auth-with-password", {
		method: 'POST'
		headers: { 'Content-Type': 'application/json' }
		body: JSON.stringify({
			identity: process.env.PB_EMAIL
			password: process.env.PB_PASSWORD
		})
	})
	throw new Error("PB admin auth failed: {res.status}") unless res.ok
	const data = await res.json()
	_cachedToken = data.token
	# Admin tokens live ~1 week; refresh every 10m to absorb clock skew
	_cachedExpiresAt = now + 10 * 60 * 1000
	_cachedToken

export def fetchWorkspace id
	const tok = await pbAdminToken()
	const pbUrl = process.env.PB_URL or 'http://127.0.0.1:8090'
	const res = await fetch("{pbUrl}/api/collections/workspaces/records/{id}", {
		headers: { 'Authorization': tok }
	})
	throw new Error("workspace {id} not found: {res.status}") unless res.ok
	await res.json()
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd aion-server && bun test tests/connector.helpers.test.imba
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd aion-server
git add src/connector.imba tests/connector.helpers.test.imba
git commit -m "aion-server: add fetchWorkspace via PB superuser auth"
```

---

### Task 12: `/internal/oauth/*` routes + X-Internal-Token middleware

**Files:**
- Modify: `aion-server/src/connector.imba` — export `mountConnectorRoutes(router)`
- Create: `aion-server/tests/connector.routes.test.imba`

- [ ] **Step 1: Write the failing test**

Create `aion-server/tests/connector.routes.test.imba`:

```imba
import {test, expect, beforeAll, afterAll} from "bun:test"
import {mountConnectorRoutes} from "../src/connector.imba"

# Spin up a Bun.serve() with mountConnectorRoutes against a fake PB
# + fake connector. Validate the X-Internal-Token gate and the
# start/complete forwarding.

let server = null
let url = null

beforeAll(do
	process.env.AION_INTERNAL_TOKEN = 'secret-t0ken'
	# Fake PB: respond with any workspace record
	# Fake connector: respond 200 { url: '...'}
	# Easiest: stub globalThis.fetch inside each test

	const handler = do(req)
		# Standard Bun.serve handler signature
		const u = new URL(req.url)
		if u.pathname.startsWith('/internal/oauth/')
			return mountConnectorRoutes.handle(req)  # see Step 3
		return new Response('not found', { status: 404 })

	server = Bun.serve({ port: 0, fetch: handler })
	url = "http://localhost:{server.port}"
)

afterAll(do server?.stop())

test "rejects missing X-Internal-Token with 401", do
	const res = await fetch("{url}/internal/oauth/start", {
		method: 'POST'
		headers: { 'Content-Type': 'application/json' }
		body: JSON.stringify({ workspace_id: 'w1' })
	})
	expect(res.status).toBe(401)

test "rejects wrong X-Internal-Token with 401", do
	const res = await fetch("{url}/internal/oauth/start", {
		method: 'POST'
		headers: { 'Content-Type': 'application/json', 'X-Internal-Token': 'wrong' }
		body: JSON.stringify({ workspace_id: 'w1' })
	})
	expect(res.status).toBe(401)

test "start forwards to connector and returns {url}", do
	const origFetch = globalThis.fetch
	globalThis.fetch = do(u, opts)
		if u.includes('/auth-with-password') then return { ok: yes, json: do Promise.resolve({ token: 't' }) }
		if u.includes('/collections/workspaces/records/')
			return { ok: yes, json: do Promise.resolve({ id: 'w1', externalIp: '127.0.0.1', port: 1, certFingerprint: 'fp', aionToken: 'atok' }) }
		if u.includes('/coordinator/oauth/start')
			return { status: 200, json: do Promise.resolve({ url: 'https://anthropic.oauth' }) }
		return { ok: no, status: 404 }

	const res = await fetch("{url}/internal/oauth/start", {
		method: 'POST'
		headers: { 'Content-Type': 'application/json', 'X-Internal-Token': 'secret-t0ken' }
		body: JSON.stringify({ workspace_id: 'w1' })
	})
	const body = await res.json()
	globalThis.fetch = origFetch
	expect(res.status).toBe(200)
	expect(body.url).toBe('https://anthropic.oauth')

test "complete forwards code to connector", do
	const origFetch = globalThis.fetch
	let receivedCode = null
	globalThis.fetch = do(u, opts)
		if u.includes('/auth-with-password') then return { ok: yes, json: do Promise.resolve({ token: 't' }) }
		if u.includes('/collections/workspaces/records/')
			return { ok: yes, json: do Promise.resolve({ id: 'w1', externalIp: '127.0.0.1', port: 1, certFingerprint: 'fp', aionToken: 'atok' }) }
		if u.includes('/coordinator/oauth/complete')
			receivedCode = JSON.parse(opts.body).code
			return { status: 200, json: do Promise.resolve({ status: 'authorized' }) }
		return { ok: no, status: 404 }

	await fetch("{url}/internal/oauth/complete", {
		method: 'POST'
		headers: { 'Content-Type': 'application/json', 'X-Internal-Token': 'secret-t0ken' }
		body: JSON.stringify({ workspace_id: 'w1', code: 'abc123' })
	})
	globalThis.fetch = origFetch
	expect(receivedCode).toBe('abc123')
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd aion-server && bun test tests/connector.routes.test.imba
```
Expected: FAIL — `mountConnectorRoutes` not exported.

- [ ] **Step 3: Implement the routes**

Append to `aion-server/src/connector.imba`:

```imba
# mountConnectorRoutes — object with a `handle(req)` method the
# server's top-level router delegates to. Matches the style of
# src/push.imba (also mounted via a per-module handler).

def requireInternalAuth req
	const expected = process.env.AION_INTERNAL_TOKEN
	unless expected
		return new Response(JSON.stringify({ error: 'server misconfigured' }), { status: 500 })
	const got = req.headers.get('x-internal-token') or ''
	unless got === expected
		return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 })
	null

export const mountConnectorRoutes = {
	handle: do(req)
		const gate = requireInternalAuth(req)
		return gate if gate

		const url = new URL(req.url)
		const body = await req.json()
		const workspace = await fetchWorkspace(body.workspace_id)

		if url.pathname === '/internal/oauth/start'
			const r = await callConnector(workspace, '/coordinator/oauth/start', {})
			return new Response(JSON.stringify(r.json), {
				status: r.status
				headers: { 'Content-Type': 'application/json' }
			})

		if url.pathname === '/internal/oauth/complete'
			const r = await callConnector(workspace, '/coordinator/oauth/complete', { code: body.code })
			return new Response(JSON.stringify(r.json), {
				status: r.status
				headers: { 'Content-Type': 'application/json' }
			})

		return new Response(JSON.stringify({ error: 'not found' }), { status: 404 })
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd aion-server && bun test tests/connector.routes.test.imba
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd aion-server
git add src/connector.imba tests/connector.routes.test.imba
git commit -m "aion-server: mount /internal/oauth/{start,complete}"
```

---

### Task 13: Wire connector module into aion-server `index.imba`

**Files:**
- Modify: `aion-server/src/index.imba` — dispatch to `mountConnectorRoutes.handle` for `/internal/oauth/*`

- [ ] **Step 1: Read `aion-server/src/index.imba` to see current router shape**

Read the file. Locate the top-level request router (where `/push/*` etc are dispatched).

- [ ] **Step 2: Add dispatch rule**

At the appropriate place in the router (before the fallthrough 404):

```imba
import {mountConnectorRoutes} from "./connector.imba"

# ... inside the main fetch handler:
if req.url.includes('/internal/oauth/')
	return await mountConnectorRoutes.handle(req)
```

Exact structure depends on index.imba — follow existing `push.imba` dispatch style.

- [ ] **Step 3: Smoke run**

```bash
cd aion-server && bun run src/index.imba &
SERVER_PID=$!
sleep 1
# Missing token → 401
curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8787/internal/oauth/start -d '{"workspace_id":"x"}' -H 'content-type: application/json'
kill $SERVER_PID
```
Expected: prints `401`.

- [ ] **Step 4: Commit**

```bash
cd aion-server
git add src/index.imba
git commit -m "aion-server: route /internal/oauth/* to connector module"
```

---

## Wave 4 — Installer

### Task 14: `install.sh` — `--auth-mode oauth` branch

**Files:**
- Modify: `aion-connector/bin/install.sh`

- [ ] **Step 1: Write a shellcheck smoke test**

```bash
cd aion-connector && shellcheck bin/install.sh
```
Expected: PASS (baseline; record any warnings to preserve).

- [ ] **Step 2: Update the required-flag gate**

Locate (around lines 31-33):

```bash
for v in TOKEN AION PROGRAM MODEL AUTH_MODE; do
  [ -n "${!v}" ] || { echo "missing --${v,,}"; exit 2; }
done
```

Add below it:

```bash
# api_key mode requires --api-key; oauth mode doesn't (cli.imba handles both branches)
if [ "$AUTH_MODE" = "api_key" ] && [ -z "$API_KEY" ]; then
  echo "missing --api-key (required when --auth-mode=api_key)"
  exit 2
fi
if [ "$AUTH_MODE" != "api_key" ] && [ "$AUTH_MODE" != "oauth" ]; then
  echo "--auth-mode must be api_key or oauth"
  exit 2
fi
```

- [ ] **Step 3: Re-run shellcheck**

```bash
cd aion-connector && shellcheck bin/install.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd aion-connector
git add bin/install.sh
git commit -m "installer: accept --auth-mode oauth (skip --api-key requirement)"
```

---

### Task 15: `install.sh` — aion-token writeout + claude CLI ensurement

**Files:**
- Modify: `aion-connector/bin/install.sh`
- Modify: `aion-connector/src/cli.imba` (optional: write /etc/aion-connector/aion-token from cmdInstall)

- [ ] **Step 1: Update install.sh preflight to ensure `claude` binary**

After the existing `command -v node …` checks (around line 40):

```bash
# Ensure @anthropic-ai/claude-code is installed globally — required for
# `claude setup-token` (OAuth) and for api_key invocation.
if ! command -v claude >/dev/null 2>&1; then
  echo "-- installing @anthropic-ai/claude-code --"
  npm install -g @anthropic-ai/claude-code
fi
```

(npm is already required by the node check; no-op if claude is present.)

- [ ] **Step 2: Decide on aion-token persistence location**

Spec §2.2 says `/etc/aion-connector/aion-token` (600, root-owned). But aion-connector runs as the user `aion-$SLUG` via systemd-user — that user can't read root-owned /etc files.

Revise: write the token to `$USER_HOME/.aion-connector/aion-token`, mode 600, owned by the service user. That preserves the "read at boot" design from spec §6.5 without needing root access at runtime.

Add this after the install subcommand runs (around line 111 in install.sh):

```bash
# Persist the aion_token the connector received during register, so
# server.imba can load it on subsequent boots without hitting AION.
# cli.imba's writeState already stores it in the state JSON; this
# extra file is for rotation & manual inspection only — cli.imba's
# AION_TOKEN env var is the actual auth source. (No-op if absent.)
```

Actually — simpler: cli.imba already writes `aion_token` into the state JSON (Task 8 Step 4). `server.imba` should read it from state, same way it reads `workspace_token` today. The spec's "`/etc/aion-connector/aion-token` file" is the plan-step variant; the implementation uses the state file instead. Document this divergence in a code comment in `connector.imba` where Server() is constructed.

Drop the file writeout. No install.sh change needed here beyond Step 1.

- [ ] **Step 3: Verify with shellcheck**

```bash
cd aion-connector && shellcheck bin/install.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd aion-connector
git add bin/install.sh
git commit -m "installer: ensure @anthropic-ai/claude-code is installed"
```

---

## Wave 5 — UI

### Task 16: `workspace-oauth-modal.imba` component

**Files:**
- Create: `aion-application/src/components/workspaces/workspace-oauth-modal.imba`
- Create: `aion-application/tests/workspace-oauth-modal.test.imba`
- Modify: `aion-application/src/services/api.imba` — `workspaces.oauthStart(id)`, `workspaces.oauthComplete(id, code)`

- [ ] **Step 1: Add API client methods**

In `aion-application/src/services/api.imba`, under the `workspaces` section:

```imba
oauthStart: do(id)
	await pb.send("/api/workspaces/{id}/oauth/start", { method: 'POST' })

oauthComplete: do(id, code)
	await pb.send("/api/workspaces/{id}/oauth/complete", {
		method: 'POST'
		body: JSON.stringify({ code })
		headers: { 'Content-Type': 'application/json' }
	})
```

- [ ] **Step 2: Write the failing component test**

Create `aion-application/tests/workspace-oauth-modal.test.imba`:

```imba
import {test, expect} from "bun:test"
# Component state-machine tests are source-level here — a real DOM
# render requires jsdom + bimba render plumbing we don't have yet.
# Verify transitions in the exported state enum & handlers.

import {readFileSync} from "fs"
import {join} from "path"

const source = readFileSync(join(process.cwd(), 'src/components/workspaces/workspace-oauth-modal.imba'), 'utf8')

test "defines idle / starting / awaiting_code / submitting / success / error states", do
	for s in ['idle', 'starting', 'awaiting_code', 'submitting', 'success', 'error']
		expect(source).toContain("'{s}'")

test "auto-opens received URL in new tab", do
	expect(source).toMatch(/window\.open\(/)

test "on submit calls api.workspaces.oauthComplete", do
	expect(source).toContain("oauthComplete")

test "transitions to error state on throw", do
	expect(source).toMatch(/state\s*=\s*'error'/)
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd aion-application && bun test tests/workspace-oauth-modal.test.imba
```
Expected: FAIL — component file doesn't exist.

- [ ] **Step 4: Implement the component**

Create `aion-application/src/components/workspaces/workspace-oauth-modal.imba`:

```imba
# ============================================================
# workspace-oauth-modal.imba — OAuth flow modal
# ============================================================
# State machine (see spec §5.1):
#   idle → starting → awaiting_code → submitting → success | error
#
# Props:
#   workspace  — the workspace record
#   onclose()  — close callback (called on success + manual close)
# ============================================================
import {workspaces} from "../../services/api.imba"

export tag WorkspaceOAuthModal
	prop workspace
	prop onclose

	state = 'idle'
	url = null
	code = ''
	errorMessage = null

	def start
		state = 'starting'
		errorMessage = null
		try
			const r = await workspaces.oauthStart(workspace.id)
			url = r.url
			state = 'awaiting_code'
			# open the URL automatically; admin can also copy it
			window.open(url, '_blank', 'noopener,noreferrer')
		catch e
			errorMessage = String(e.message or e)
			state = 'error'

	def submit
		return if !code
		state = 'submitting'
		errorMessage = null
		try
			await workspaces.oauthComplete(workspace.id, code)
			state = 'success'
		catch e
			errorMessage = String(e.message or e)
			state = 'error'

	def retry
		state = 'idle'
		code = ''
		errorMessage = null

	def render
		<self.modal>
			<div.header> "Authorize Claude Code"
			<div.body>
				if state == 'idle'
					<button @click=start> "Authorize Claude Code"
				elif state == 'starting'
					<div.spinner> "Starting OAuth…"
				elif state == 'awaiting_code'
					<div.code-box>
						<p> "Sign in at Anthropic and paste the verification code below:"
						<div.url-row>
							<a href=url target="_blank"> url
							<button @click=(navigator.clipboard.writeText(url))> "Copy"
						<input bind=code placeholder="paste code here">
						<button @click=submit disabled=(code == '')> "Submit"
				elif state == 'submitting'
					<div.spinner> "Verifying…"
				elif state == 'success'
					<div.success> "✓ Authorized"
					<button @click=onclose> "Close"
				elif state == 'error'
					<div.error> errorMessage
					<button @click=retry> "Try again"
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd aion-application && bun test tests/workspace-oauth-modal.test.imba
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd aion-application
git add src/components/workspaces/workspace-oauth-modal.imba src/services/api.imba tests/workspace-oauth-modal.test.imba
git commit -m "ui: add workspace OAuth modal + api client methods"
```

---

### Task 17: Workspace-detail CTA + re-authorize link

**Files:**
- Modify: `aion-application/src/components/workspaces/workspace-detail-view.imba` (or `workspace-overview-tab.imba` — find by search)

- [ ] **Step 1: Locate the workspace detail page**

```bash
cd aion-application && grep -rl "workspace" src/components/workspaces/ | head -20
```

- [ ] **Step 2: Add CTA banner**

At the top of the workspace-detail render tree, add:

```imba
const needsFirstAuth = workspace.authMode == 'oauth' and not workspace.lastAuthorizedAt
const needsReAuth   = workspace.state == 'degraded' and workspace.detail == 'not_authorized'

if needsFirstAuth or needsReAuth
	<div.oauth-banner>
		<p>
			if needsFirstAuth
				"Complete setup: authorize Claude Code on this workspace."
			else
				"Claude credentials expired — re-authorize to restore operation."
		<button @click=(showOAuthModal = yes)> "Authorize Claude Code"

if showOAuthModal
	<WorkspaceOAuthModal workspace=workspace onclose=(showOAuthModal = no)>
```

Also add a small "Re-authorize" link in the settings tab:

```imba
<button.link @click=(showOAuthModal = yes)> "Re-authorize Claude Code"
```

- [ ] **Step 3: Manually open the page in dev, verify CTA appears when conditions match**

```bash
cd aion-application && bunx bimba dev &
# Open http://localhost:xxxx/workspaces/...
```

- [ ] **Step 4: Commit**

```bash
cd aion-application
git add src/components/workspaces/
git commit -m "ui: show authorize CTA on workspace detail page"
```

---

### Task 18: `workspace-create-modal.imba` — add oauth option

**Files:**
- Modify: `aion-application/src/components/workspaces/workspace-create-modal.imba`

- [ ] **Step 1: Read current auth-mode dropdown**

```bash
cd aion-application && grep -n "api_key" src/components/workspaces/workspace-create-modal.imba
```

- [ ] **Step 2: Add oauth option**

Locate the dropdown:

```imba
<select bind=authMode>
	<option value='api_key'> "API Key (manual entry)"
```

Change to:

```imba
<select bind=authMode>
	<option value='api_key'> "API Key (manual entry)"
	<option value='oauth'> "OAuth (Claude CLI)"
```

- [ ] **Step 3: Hide api-key input when oauth is selected**

```imba
if authMode == 'api_key'
	<input bind=apiKey placeholder="Anthropic API key">
```

- [ ] **Step 4: Update installer-step hint text**

In the "installer" step component, if `authMode == 'oauth'`, append:

```
After the connector comes online, open the workspace page and click
"Authorize Claude Code" to complete setup.
```

- [ ] **Step 5: Commit**

```bash
cd aion-application
git add src/components/workspaces/workspace-create-modal.imba
git commit -m "ui: add OAuth option to workspace-create modal"
```

---

## Wave 6 — Ops

### Task 19: Smoke runbook

**Files:**
- Create: `aion-connector/docs/runbooks/oauth-smoke.md`

- [ ] **Step 1: Write the runbook**

Create `aion-connector/docs/runbooks/oauth-smoke.md`:

```markdown
# OAuth smoke runbook

## Prereqs
- Staging VPS with public IP reachable from AION host
- AION PB + aion-server running, `AION_INTERNAL_TOKEN` set in both envs
- Admin account on AION UI

## Happy path
1. Log into AION UI as project admin
2. Projects → $PROJECT → Workspaces → "New Workspace"
3. Name: `oauth-smoke-YYYYMMDD`, program: claude-code, model: sonnet-4.6, auth-mode: **OAuth (Claude CLI)**
4. Copy the curl snippet from step 2 of the modal, run as root on the test VPS
5. Wait for the connector to come online (≤60s); workspace detail shows "Complete setup" banner
6. Click "Authorize Claude Code" → modal opens
7. Click the URL (auto-opened in new tab), sign in at Anthropic, grant access, copy the code
8. Paste code into modal, click Submit
9. Modal shows "✓ Authorized"; banner disappears within 2s (realtime)
10. Workspace state: **online**, detail empty
11. From admin shell, verify `claude --print "hello"` works as the service user on VPS

## Re-auth path
1. SSH into VPS as service user: `sudo -iu aion-$SLUG`
2. `rm ~/.claude/credentials.json`
3. Wait ≤60s (two heartbeat cycles to be safe)
4. UI shows workspace **degraded**, detail **not_authorized**, banner "Claude credentials expired"
5. Re-run the Authorize flow — same as Happy Path 6-10

## Cleanup
1. UI → workspace → Settings → Delete
2. On VPS: `sudo /usr/local/bin/aion-connector uninstall` and `userdel -r aion-$SLUG`

## Failure modes to verify
- Submitting a bogus code → modal shows error; workspace state unchanged
- `AION_INTERNAL_TOKEN` missing on aion-server side → 500 surfaced in modal
- Connector offline at time of Authorize → modal shows timeout error (10s)
```

- [ ] **Step 2: Commit**

```bash
cd aion-connector
git add docs/runbooks/oauth-smoke.md
git commit -m "docs: add OAuth smoke runbook"
```

---

### Task 20: Rollout — `AION_INTERNAL_TOKEN` + listening address

**Files:**
- Modify: `aion-server/src/index.imba` — bind to 127.0.0.1, not 0.0.0.0
- Modify: `aion-pocketbase/.env.example` (if it exists) — add `AION_INTERNAL_TOKEN=`
- Modify: `aion-server/.env.example` — add `AION_INTERNAL_TOKEN=`

- [ ] **Step 1: Verify aion-server listens on 127.0.0.1 only**

Read `aion-server/src/index.imba`. If `Bun.serve` binds to `0.0.0.0` or default (all interfaces), change to:

```imba
Bun.serve({
	hostname: '127.0.0.1'
	port: 8787
	fetch: ...
})
```

Spec §3.4: aion-server is localhost-only.

- [ ] **Step 2: Document the env var in both example files**

Add to `aion-pocketbase/.env.example` and `aion-server/.env.example`:

```
# Shared secret for PB hooks → aion-server /internal/* calls.
# Generate with: openssl rand -hex 32
# MUST be identical in both services.
AION_INTERNAL_TOKEN=
```

- [ ] **Step 3: Write a one-liner rollout doc**

Append to `aion-connector/docs/runbooks/oauth-smoke.md` (or a new `connector-oauth-rollout.md`):

```markdown
## Production rollout

1. `openssl rand -hex 32 > /tmp/tok`
2. Append `AION_INTERNAL_TOKEN=$(cat /tmp/tok)` to both `pb_data/.env` and aion-server's env file
3. `systemctl restart aion-pocketbase aion-server` (or equivalent)
4. Verify: `curl -sf http://127.0.0.1:8787/internal/oauth/start -X POST -d '{}' -H 'content-type: application/json'` returns 401 (token missing), then 500 w/ "workspace not found" after adding the correct header + workspace_id
5. Run `oauth-smoke.md` against staging
6. Enable oauth option in production by setting a UI feature flag (or simply shipping the build)
```

- [ ] **Step 4: Commit**

```bash
cd aion-server && git add src/index.imba .env.example && git commit -m "aion-server: bind 127.0.0.1 + document AION_INTERNAL_TOKEN"
cd ../aion-pocketbase && git add .env.example && git commit -m "pb: document AION_INTERNAL_TOKEN env var"
cd ../aion-connector && git add docs/runbooks/oauth-smoke.md && git commit -m "docs: add OAuth rollout checklist"
```

---

## Verification matrix

After all 20 tasks land, these must all hold:

| Check | How |
|---|---|
| Workspace register returns `aion_token` | `curl -X POST .../register` response includes field |
| Connector rejects wrong aionToken bearer | `tests/server.auth.test.imba` |
| aion-server `/internal/*` rejects wrong `X-Internal-Token` | `tests/connector.routes.test.imba` |
| Pinned TLS fails on fingerprint mismatch | `tests/connector.helpers.test.imba` |
| `health()` reports 4 distinct detail codes | `tests/claude-code-adapter.health.test.imba` |
| Heartbeat carries `coordinator_status.detail` to PB | manual: tail connector logs + PB admin DB |
| UI shows re-auth CTA when workspace degrades | smoke runbook step "re-auth path" |
| `lastAuthorizedAt` set on successful complete | smoke runbook + PB admin DB |
| No OAuth code leaves memory | grep logs for the code (no hits) |
| shellcheck passes on install.sh | `shellcheck bin/install.sh` |
| Compile gate passes (no Goja-incompatible output) | `bun run build` in each repo |

---

## Notes for implementers

1. **Imba tab gotcha:** all files use tabs-only, no spaces. `get`-accessors need the `get` keyword.

2. **PB Goja VM per-request scope:** any `const`/`require` at file top level in `.pb.imba` files is NOT available inside handlers. Always put declarations inside the `do(e)` body — see `api.push.pb.imba` line 10 comment for the canonical example.

3. **Compile gate is strict:** `assertCleanOutput` rejects `__commonJS`, `iterable$`, `runtime.mjs` imports. If you write a `for x in <variable>` in a .pb.imba file, it pulls imba runtime into Goja and the build fails loudly. Convert to index-based `while`.

4. **Do not invent names.** The spec has drift. Use the identifiers defined in this plan — `certFingerprint`, `/api/workspaces/register`, `{state, detail}` for health — not the ones from the spec.

5. **Test philosophy.** PB handler tests are source-level (grep on compiled output), because PB requires a live daemon to integration-test. The smoke runbook is the real gate for end-to-end correctness. aion-server + aion-connector + aion-application tests are real in-process: they spin up fake servers or use stubs.

6. **Commit after each task.** Each task ends with a commit step. Don't batch. If a step breaks, the commit before it is the rollback point.

7. **Graceful shutdown (spec §4.4) is a no-new-work item.** `callConnector` already uses `AbortSignal.timeout(10_000)`. aion-server's existing SIGTERM handler in `src/index.imba` already closes `Bun.serve` cleanly — pending connector fetches abort naturally via the timeout signal. If the existing SIGTERM handler doesn't call an `AbortController.abort()` on an app-wide controller, that's a follow-up improvement, not a blocker for this feature.

8. **Heartbeat detail flow is already wired on the connector side.** `aion-connector/src/connector.imba` `collectHeartbeat` already reads `adapter.health()` and passes both `state` and `detail` into `coordinator_status`. Extending `health()` in Task 6 is enough — no change to `connector.imba` heartbeat logic needed.
