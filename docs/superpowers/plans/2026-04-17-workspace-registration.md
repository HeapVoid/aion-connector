# Phase 1 — Workspace Registration + Coordinator Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** VPS admin runs a one-line installer → `aion-connector` service comes up → registers with AION → provisions, configures, and authorizes a `claude-code` coordinator → workspace appears `online` in AION UI. Admin can later edit persona/skills in UI and see changes land on VPS.

**Architecture:** Rewrite of `aion-connector` as a single-workspace service. Split into focused imba modules (state, TLS, port, AION client, sync, adapter, server, heartbeat, connector, CLI). Self-signed TLS + TOFU fingerprint pinning for AION→connector. AION→connector auth via long-lived `workspace_token` (bearer). Claude-code is wrapped by an adapter that implements a stable interface, so other coordinators (qwen-code, codex) plug in later. Greenfield — the current `projects:{}` config model is deleted.

**Tech Stack:** Imba + Bun, bimba compiler. OpenSSL CLI for self-signed cert generation. systemd unit. Node's `https` module for the server. Global `fetch` for outbound. Shell-out to `npm`/`acpx`/`claude` from the claude-code adapter.

**Test Infrastructure:**
- Tests are `.imba` files in `tests/`, compiled by `bimba` to `tests-dist/` and run with `bun test tests-dist/`. Added in Task 0.
- **Mock AION** (`dev/mock-aion.imba`) implements the five AION API endpoints in-memory. Used by every integration test in Waves 3+. Added in Task 1.
- **TDD pragma:** unit tests for pure modules (state I/O, TLS fingerprint format, port picker, sync hash/conflict). Integration tests that actually spawn subprocesses for shell-out modules (openssl, installer bash script, adapter invoking claude CLI). Do **not** mock openssl, acpx, or the claude binary — the value of those tests is in catching real subprocess breakage.
- Tests against the real `claude` binary are gated by `env.CLAUDE_CODE_INSTALLED=1` and skipped otherwise. The stub adapter provides the rest of the coverage.

**Spec Reference:** `docs/superpowers/specs/2026-04-17-workspace-registration-design.md`

**Wave Structure:** The plan is organized into waves. Each wave ends with a working, committable state. Waves are intended to be executed in order; within a wave, tasks are sequential.

- Wave 0 — Cleanup + test setup
- Wave 1 — Mock AION
- Wave 2 — Pure modules (state, TLS, port, sync, adapter interface + StubAdapter)
- Wave 3 — AION client + server skeleton + heartbeat
- Wave 4 — CLI + `install` command + end-to-end registration (stub adapter)
- Wave 5 — Claude-code adapter
- Wave 6 — OAuth flow + two-way sync endpoints
- Wave 7 — Remaining CLI commands (status, logs, restart, stop, doctor, uninstall)
- Wave 8 — Installer bash + systemd unit + end-to-end smoke test

---

## File Structure

```
src/
  protocol.imba               # VERSION constant, shared type aliases
  utils.imba                  # log, error, exec, sha256Hex, ensureMode
  state.imba                  # workspace.json read/write, tls file paths
  tls.imba                    # self-signed cert gen (openssl), fingerprint
  port.imba                   # free port picker in 7700-7799
  aion-client.imba            # POST /api/workspaces/{register,:id/heartbeat,:id/cert-rotated}
  sync.imba                   # coordinator/ file layout, SHA-256 hashing, 409 conflict logic
  adapter.imba                # Adapter interface contract + StubAdapter + adapter registry
  claude-code-adapter.imba    # ClaudeCodeAdapter implementation
  server.imba                 # HTTPS server boot, TLS from state, bearer auth
  routes.imba                 # Route handlers (/coordinator/update, /oauth/*, /sync/*, /invoke stub)
  heartbeat.imba              # Heartbeat loop + lifecycle reporter
  connector.imba              # Orchestrator — wires adapter + server + heartbeat + state
  cli.imba                    # Subcommand dispatcher + command implementations

dev/
  mock-aion.imba              # In-memory mock AION for integration tests

bin/
  install.sh                  # Bash installer (run as sudo on VPS)
  aion-connector.service.tpl  # systemd unit template

tests/
  state.test.imba
  tls.test.imba
  port.test.imba
  sync.test.imba
  adapter-contract.test.imba
  aion-client.test.imba
  server.test.imba
  heartbeat.test.imba
  registration.test.imba
  claude-code-adapter.test.imba
  install.sh.test.imba
```

**Deleted** in Task 0.1 (Phase 3/4+ concerns): `src/agent.imba`, `src/files.imba`, `src/repos.imba`, `src/mcp-server.cjs`, `aion.config.example.json`.

---

# Wave 0 — Cleanup + Test Setup

## Task 0.1: Remove obsolete files

**Files:**
- Delete: `src/agent.imba`, `src/files.imba`, `src/repos.imba`, `src/mcp-server.cjs`, `aion.config.example.json`
- Modify: `src/cli.imba` (clear contents — rewritten in Wave 4)
- Modify: `src/connector.imba` (clear contents — rewritten in Wave 4)
- Modify: `src/server.imba` (clear contents — rewritten in Wave 3)

- [ ] **Step 1:** Delete the four files above:

```bash
rm src/agent.imba src/files.imba src/repos.imba src/mcp-server.cjs aion.config.example.json
```

- [ ] **Step 2:** Replace the three src files with a stub that fails the build loudly if imported, so accidental references surface fast:

For each of `src/cli.imba`, `src/connector.imba`, `src/server.imba`, overwrite with:

```imba
# Rewritten in Phase 1 — see docs/superpowers/plans/2026-04-17-workspace-registration.md
throw new Error("TODO: rewritten in Phase 1")
```

- [ ] **Step 3:** Verify the build fails for the right reason (module is expected to be imported and throw):

```bash
bun run build
```

Expected: success. The throw only runs when `cli.js` is executed, not at compile time.

- [ ] **Step 4:** Commit.

```bash
git add -A
git commit -m "chore: drop Phase 3/4+ code ahead of Phase 1 rewrite"
```

## Task 0.2: Bump protocol VERSION

**Files:**
- Modify: `src/protocol.imba`

- [ ] **Step 1:** Read current VERSION:

```bash
cat src/protocol.imba
```

- [ ] **Step 2:** Bump to 2. Overwrite `src/protocol.imba`:

```imba
# Protocol version for AION ↔ connector API.
# Phase 1 (workspace + coordinator) = 2. Bump on any wire-incompatible change.
export const VERSION = 2
```

- [ ] **Step 3:** Commit.

```bash
git add src/protocol.imba
git commit -m "feat(protocol): bump VERSION to 2 for Phase 1 wire contract"
```

## Task 0.3: Set up imba test runner

**Files:**
- Modify: `package.json`
- Create: `bunfig.toml` (if it doesn't already configure tests)
- Create: `tests/smoke.test.imba`

- [ ] **Step 1:** Add test scripts to `package.json`. Replace the `scripts` block with:

```json
"scripts": {
  "build": "bunx bimba src/cli.imba --outdir dist --target node --external node-pty --external ws",
  "build:tests": "bunx bimba tests --outdir tests-dist --target node --external node-pty --external ws",
  "test": "bun run build:tests && bun test tests-dist"
}
```

- [ ] **Step 2:** Write a smoke test to verify the pipeline works. Create `tests/smoke.test.imba`:

```imba
import {test, expect} from "bun:test"

test "test runner compiles and runs imba files", do
  expect(1 + 1).toBe(2)
```

- [ ] **Step 3:** Run it:

```bash
bun run test
```

Expected: `1 pass, 0 fail`.

- [ ] **Step 4:** Commit.

```bash
git add package.json tests/smoke.test.imba bunfig.toml 2>/dev/null; git add -A
git commit -m "chore(test): add imba test runner via bimba + bun test"
```

---

# Wave 1 — Mock AION

## Task 1.1: Scaffold mock-aion with register + heartbeat

**Files:**
- Create: `dev/mock-aion.imba`

- [ ] **Step 1:** Create `dev/mock-aion.imba`:

```imba
# In-memory mock AION server for integration tests.
# Implements the five endpoints: create, register, heartbeat, re-enroll, delete.
import {createServer} from 'http'
import {randomUUID, randomBytes} from 'crypto'

export class MockAion
  port = 0
  workspaces = new Map!        # workspace_id → record
  enrollments = new Map!       # enrollment_token → workspace_id
  workspaceTokens = new Map!   # workspace_token → workspace_id
  heartbeats = []              # recent heartbeats for assertions
  server = null

  def createWorkspace coordinatorConfig = {}
    const id = randomUUID!
    const enrollment = randomBytes(16).toString('hex')
    const now = Date.now!
    workspaces.set(id, {
      id
      state: 'provisioning'
      coordinator: coordinatorConfig
      ip: null
      port: null
      fingerprint: null
      createdAt: now
      updatedAt: now
    })
    enrollments.set(enrollment, id)
    return { workspace_id: id, enrollment_token: enrollment }

  def start
    server = createServer do(req, res) handle(req, res)
    return new Promise do(ok)
      server.listen 0, '127.0.0.1', do
        port = server.address!.port
        ok(port)

  def stop
    return unless server
    return new Promise do(ok) server.close do ok!

  def baseUrl
    "http://127.0.0.1:{port}"

  def handle req, res
    let body = ''
    req.on('data', do(c) body += c)
    req.on('end', do
      let payload = {}
      if body
        try payload = JSON.parse(body)
        catch
          return json(res, 400, { error: "invalid json" })
      try
        await route(req.method, req.url, payload, req.headers, res)
      catch e
        json(res, 500, { error: e.message })
    )

  def route method, url, payload, headers, res
    if method == 'POST' and url == '/api/workspaces/register'
      return handleRegister(payload, res)
    if method == 'POST' and url.match(/^\/api\/workspaces\/[^\/]+\/heartbeat$/)
      const id = url.split('/')[3]
      return handleHeartbeat(id, payload, headers, res)
    json(res, 404, { error: "not found" })

  def handleRegister payload, res
    const { enrollment_token, external_ip, port: connPort, cert_fingerprint, coordinator_status, connector_version } = payload
    const id = enrollments.get(enrollment_token)
    unless id
      return json(res, 401, { error: "invalid enrollment_token" })
    enrollments.delete(enrollment_token)
    const token = randomBytes(32).toString('hex')
    const ws = workspaces.get(id)
    ws.ip = external_ip
    ws.port = connPort
    ws.fingerprint = cert_fingerprint
    ws.connector_version = connector_version
    ws.coordinator_status = coordinator_status
    ws.workspace_token = token
    ws.state = coordinator_status..state == 'ready' ? 'online' : 'provisioning'
    ws.updatedAt = Date.now!
    workspaceTokens.set(token, id)
    json(res, 200, { workspace_id: id, workspace_token: token })

  def handleHeartbeat id, payload, headers, res
    const auth = headers['authorization'] or ''
    const token = auth.replace(/^Bearer /, '')
    const expected = workspaces.get(id)..workspace_token
    unless token and token == expected
      return json(res, 401, { error: "unauthorized" })
    const ws = workspaces.get(id)
    ws.ip = payload.external_ip or ws.ip
    ws.coordinator_status = payload.coordinator_status
    ws.lastHeartbeat = Date.now!
    ws.state = payload.coordinator_status..state == 'ready' ? 'online' : 'degraded'
    heartbeats.push({ id, at: ws.lastHeartbeat, payload })
    json(res, 200, { ok: true })

def json res, code, data
  res.writeHead(code, { 'content-type': 'application/json' })
  res.end(JSON.stringify(data))
```

- [ ] **Step 2:** Create `tests/mock-aion.test.imba` to verify it works:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {MockAion} from "../dev/mock-aion.imba"

let aion = null

beforeEach do
  aion = new MockAion!
  await aion.start!

afterEach do
  await aion.stop!

test "register with valid enrollment_token returns workspace_token", do
  const { workspace_id, enrollment_token } = aion.createWorkspace({ program: "claude-code" })
  const res = await fetch "{aion.baseUrl}/api/workspaces/register",
    method: 'POST'
    headers: { 'content-type': 'application/json' }
    body: JSON.stringify({
      enrollment_token
      external_ip: '203.0.113.42'
      port: 7700
      cert_fingerprint: '00'.repeat(32)
      coordinator_status: { state: 'ready', program: 'claude-code', version: '1.0' }
      connector_version: '0.4.0'
    })
  expect(res.status).toBe(200)
  const body = await res.json!
  expect(body.workspace_id).toBe(workspace_id)
  expect(typeof body.workspace_token).toBe('string')
  expect(body.workspace_token.length).toBeGreaterThan(32)

test "register with unknown enrollment_token returns 401", do
  const res = await fetch "{aion.baseUrl}/api/workspaces/register",
    method: 'POST'
    headers: { 'content-type': 'application/json' }
    body: JSON.stringify({ enrollment_token: 'bogus' })
  expect(res.status).toBe(401)

test "heartbeat with bearer token updates state", do
  const { workspace_id, enrollment_token } = aion.createWorkspace!
  const reg = await fetch "{aion.baseUrl}/api/workspaces/register",
    method: 'POST'
    headers: { 'content-type': 'application/json' }
    body: JSON.stringify({ enrollment_token, external_ip: '1.2.3.4', port: 7700, cert_fingerprint: '0'.repeat(64), coordinator_status: { state: 'ready' }, connector_version: '0.4.0' })
  const { workspace_token } = await reg.json!
  const hb = await fetch "{aion.baseUrl}/api/workspaces/{workspace_id}/heartbeat",
    method: 'POST'
    headers: { 'content-type': 'application/json', 'authorization': "Bearer {workspace_token}" }
    body: JSON.stringify({ external_ip: '1.2.3.4', coordinator_status: { state: 'ready' }, connector_version: '0.4.0', timestamp: Date.now! })
  expect(hb.status).toBe(200)
  expect(aion.heartbeats.length).toBe(1)
```

- [ ] **Step 3:** Run:

```bash
bun run test
```

Expected: 4 passing (3 new + 1 smoke).

- [ ] **Step 4:** Commit.

```bash
git add dev/mock-aion.imba tests/mock-aion.test.imba
git commit -m "test(mock-aion): add in-memory mock AION with register + heartbeat"
```

---

# Wave 2 — Pure Modules

## Task 2.1: `utils.imba` — log, error, exec, sha256Hex, ensureMode

**Files:**
- Modify: `src/utils.imba`

- [ ] **Step 1:** Overwrite `src/utils.imba`:

```imba
import {spawn} from 'child_process'
import {createHash} from 'crypto'
import {chmodSync} from 'fs'

export def log ...args
  console.log("[aion-connector]", ...args)

export def error ...args
  console.error("[aion-connector]", ...args)

# Spawn, collect stdout/stderr, return {stdout, stderr, exitCode}
export def exec args, opts = {}
  new Promise do(ok)
    const proc = spawn(args[0], args.slice(1), { ...opts, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    proc.stdout.on('data', do(chunk) stdout += chunk.toString!)
    proc.stderr.on('data', do(chunk) stderr += chunk.toString!)
    proc.on('close', do(code)
      ok({ stdout, stderr, exitCode: code })
    )

export def sha256Hex buf
  createHash('sha256').update(buf).digest('hex')

export def ensureMode path, mode
  chmodSync(path, mode)
```

- [ ] **Step 2:** Create `tests/utils.test.imba`:

```imba
import {test, expect} from "bun:test"
import {sha256Hex, exec} from "../src/utils.imba"

test "sha256Hex returns 64 lowercase hex chars", do
  const h = sha256Hex("hello")
  expect(h.length).toBe(64)
  expect(h).toMatch(/^[0-9a-f]+$/)
  expect(h).toBe("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

test "exec captures stdout and exitCode", do
  const r = await exec(["echo", "hi"])
  expect(r.exitCode).toBe(0)
  expect(r.stdout.trim!).toBe("hi")
```

- [ ] **Step 3:**

```bash
bun run test
```

Expected: passes.

- [ ] **Step 4:** Commit.

```bash
git add src/utils.imba tests/utils.test.imba
git commit -m "refactor(utils): add sha256Hex + ensureMode helpers"
```

## Task 2.2: `state.imba` — workspace state file I/O

**Files:**
- Create: `src/state.imba`
- Create: `tests/state.test.imba`

- [ ] **Step 1:** Create `src/state.imba`:

```imba
# Workspace state: workspace.json + tls/{cert,key}.pem under $HOME/.config/aion-connector/
import {existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync} from 'fs'
import {join, dirname} from 'path'
import {homedir} from 'os'

export def stateDir base = null
  const h = base or homedir!
  join(h, '.config', 'aion-connector')

export def statePath base = null
  join(stateDir(base), 'workspace.json')

export def tlsDir base = null
  join(stateDir(base), 'tls')

export def certPath base = null
  join(tlsDir(base), 'cert.pem')

export def keyPath base = null
  join(tlsDir(base), 'key.pem')

export def ensureDirs base = null
  const d = stateDir(base)
  mkdirSync(d, recursive: yes, mode: 0o700)
  const t = tlsDir(base)
  mkdirSync(t, recursive: yes, mode: 0o700)

export def readState base = null
  const p = statePath(base)
  return null unless existsSync(p)
  JSON.parse(readFileSync(p, 'utf8'))

export def writeState data, base = null
  ensureDirs(base)
  const p = statePath(base)
  writeFileSync(p, JSON.stringify(data, null, 2))
  chmodSync(p, 0o600)

export def mergeState patch, base = null
  const cur = readState(base) or {}
  const next = Object.assign({}, cur, patch)
  writeState(next, base)
  next
```

- [ ] **Step 2:** Create `tests/state.test.imba`:

```imba
import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, statSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {writeState, readState, mergeState, statePath, ensureDirs} from "../src/state.imba"

let base = null
beforeEach do
  base = mkdtempSync(join(tmpdir!, 'aion-state-'))

test "writeState/readState roundtrip", do
  writeState({ workspace_id: 'abc', port: 7700 }, base)
  const r = readState(base)
  expect(r.workspace_id).toBe('abc')
  expect(r.port).toBe(7700)

test "state file is mode 600", do
  writeState({ x: 1 }, base)
  const st = statSync(statePath(base))
  expect(st.mode & 0o777).toBe(0o600)

test "mergeState preserves existing keys", do
  writeState({ a: 1, b: 2 }, base)
  const r = mergeState({ b: 3, c: 4 }, base)
  expect(r).toEqual({ a: 1, b: 3, c: 4 })

test "readState returns null when missing", do
  expect(readState(base)).toBe(null)

test "ensureDirs creates stateDir mode 700", do
  ensureDirs(base)
  const st = statSync(join(base, '.config', 'aion-connector'))
  expect(st.mode & 0o777).toBe(0o700)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/state.imba tests/state.test.imba
git commit -m "feat(state): workspace.json read/write with 600/700 perms"
```

## Task 2.3: `tls.imba` — self-signed cert generation + fingerprint

**Files:**
- Create: `src/tls.imba`
- Create: `tests/tls.test.imba`

- [ ] **Step 1:** Create `src/tls.imba`. Uses `openssl` CLI — must be available on the VPS.

```imba
import {exec, sha256Hex} from './utils.imba'
import {writeFileSync, readFileSync, chmodSync, mkdirSync, existsSync} from 'fs'
import {dirname} from 'path'

# Generate a self-signed RSA 2048 cert valid 10 years for CN=aion-connector.
# Writes cert.pem and key.pem with mode 600. Returns SHA-256 fingerprint (lowercase hex, 64 chars).
export def generateSelfSigned certPath, keyPath
  mkdirSync(dirname(certPath), recursive: yes)
  const r = await exec [
    'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes'
    '-keyout', keyPath
    '-out', certPath
    '-days', '3650'
    '-subj', '/CN=aion-connector'
  ]
  if r.exitCode != 0
    throw new Error("openssl req failed: {r.stderr}")
  chmodSync(certPath, 0o600)
  chmodSync(keyPath, 0o600)
  await fingerprint(certPath)

# SHA-256 of DER form, lowercase hex, 64 chars. Matches what Node's tls peer cert reports.
export def fingerprint certPath
  const r = await exec(['openssl', 'x509', '-in', certPath, '-outform', 'DER'])
  if r.exitCode != 0
    throw new Error("openssl x509 DER failed: {r.stderr}")
  # openssl exec captures stdout as utf8 string; we need bytes. Re-read via pipe.
  # Fallback: compute fingerprint directly with openssl's -fingerprint switch for reliability.
  const f = await exec(['openssl', 'x509', '-in', certPath, '-noout', '-fingerprint', '-sha256'])
  if f.exitCode != 0
    throw new Error("openssl x509 -fingerprint failed: {f.stderr}")
  # Output: "sha256 Fingerprint=AA:BB:CC:..."
  const hex = f.stdout.split('=')[1]..trim!.replace(/:/g, '').toLowerCase!
  unless hex and hex.length == 64
    throw new Error("unexpected fingerprint output: {f.stdout}")
  hex

export def loadCertKey certPath, keyPath
  { cert: readFileSync(certPath), key: readFileSync(keyPath) }
```

- [ ] **Step 2:** Create `tests/tls.test.imba`:

```imba
import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, statSync, existsSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, fingerprint, loadCertKey} from "../src/tls.imba"

let dir = null
beforeEach do
  dir = mkdtempSync(join(tmpdir!, 'aion-tls-'))

test "generateSelfSigned creates cert+key with mode 600 and returns 64-hex fingerprint", do
  const cert = join(dir, 'cert.pem')
  const key = join(dir, 'key.pem')
  const fp = await generateSelfSigned(cert, key)
  expect(existsSync(cert)).toBe(true)
  expect(existsSync(key)).toBe(true)
  expect(statSync(cert).mode & 0o777).toBe(0o600)
  expect(statSync(key).mode & 0o777).toBe(0o600)
  expect(fp.length).toBe(64)
  expect(fp).toMatch(/^[0-9a-f]+$/)

test "fingerprint is deterministic for a given cert", do
  const cert = join(dir, 'cert.pem')
  const key = join(dir, 'key.pem')
  const fp1 = await generateSelfSigned(cert, key)
  const fp2 = await fingerprint(cert)
  expect(fp2).toBe(fp1)

test "loadCertKey returns buffers", do
  const cert = join(dir, 'cert.pem')
  const key = join(dir, 'key.pem')
  await generateSelfSigned(cert, key)
  const { cert: c, key: k } = loadCertKey(cert, key)
  expect(c.length).toBeGreaterThan(0)
  expect(k.length).toBeGreaterThan(0)
```

- [ ] **Step 3:** Run, expect pass. This requires `openssl` on PATH.

- [ ] **Step 4:** Commit.

```bash
git add src/tls.imba tests/tls.test.imba
git commit -m "feat(tls): self-signed cert generation + SHA-256 fingerprint"
```

## Task 2.4: `port.imba` — free-port picker

**Files:**
- Create: `src/port.imba`
- Create: `tests/port.test.imba`

- [ ] **Step 1:** Create `src/port.imba`:

```imba
import {createServer} from 'net'

export const DEFAULT_MIN = 7700
export const DEFAULT_MAX = 7799

# Tries each port in [min, max] until a bind succeeds. Returns chosen port.
# Throws if none are free.
export def pickFreePort min = DEFAULT_MIN, max = DEFAULT_MAX
  for p in [min..max]
    if await tryBind(p)
      return p
  throw new Error("no free port in {min}-{max}")

def tryBind p
  new Promise do(ok)
    const s = createServer!
    s.once('error', do ok(false))
    s.once('listening', do
      s.close do ok(true))
    s.listen(p, '0.0.0.0')
```

- [ ] **Step 2:** Create `tests/port.test.imba`:

```imba
import {test, expect} from "bun:test"
import {createServer} from 'net'
import {pickFreePort} from "../src/port.imba"

test "returns a port in the requested range", do
  const p = await pickFreePort(18000, 18010)
  expect(p).toBeGreaterThanOrEqual(18000)
  expect(p).toBeLessThanOrEqual(18010)

test "skips ports that are already bound", do
  const blocker = createServer!
  await new Promise do(ok) blocker.listen(18020, '0.0.0.0', ok)
  try
    const p = await pickFreePort(18020, 18022)
    expect(p).not.toBe(18020)
    expect(p).toBeLessThanOrEqual(18022)
  finally
    await new Promise do(ok) blocker.close(ok)

test "throws when no port is free", do
  # Bind every port in range [18030, 18031] then ask picker
  const a = createServer!
  const b = createServer!
  await new Promise do(ok) a.listen(18030, '0.0.0.0', ok)
  await new Promise do(ok) b.listen(18031, '0.0.0.0', ok)
  try
    let threw = no
    try await pickFreePort(18030, 18031)
    catch threw = yes
    expect(threw).toBe(true)
  finally
    await new Promise do(ok) a.close(ok)
    await new Promise do(ok) b.close(ok)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/port.imba tests/port.test.imba
git commit -m "feat(port): free-port picker in 7700-7799 range"
```

## Task 2.5: `sync.imba` — coordinator/ layout + hashing + conflict detection

**Files:**
- Create: `src/sync.imba`
- Create: `tests/sync.test.imba`

- [ ] **Step 1:** Create `src/sync.imba`:

```imba
# Two-way sync of coordinator/ files. Each file carries a SHA-256 content hash.
# On push from AION, a provided `expected_prev_hash` is matched against the current
# on-disk hash; mismatch → ConflictError. Caller maps this to HTTP 409.
import {readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, chmodSync, statSync} from 'fs'
import {join, dirname} from 'path'
import {sha256Hex} from './utils.imba'

export class ConflictError < Error
  def constructor path, actualHash
    super "sync conflict at {path}: on-disk hash is {actualHash}"
    self.path = path
    self.actualHash = actualHash

export def coordinatorDir home
  join(home, 'coordinator')

export def personaPath home
  join(coordinatorDir(home), 'persona.md')

export def skillsDir home
  join(coordinatorDir(home), 'skills')

export def skillPath home, name
  join(skillsDir(home), "{name}.md")

export def hashFile path
  return null unless existsSync(path)
  sha256Hex(readFileSync(path))

# Read file. Returns {content, hash} or null if missing.
export def readFile path
  return null unless existsSync(path)
  const content = readFileSync(path, 'utf8')
  { content, hash: sha256Hex(content) }

# Write file with conflict check. If expectedPrevHash is provided and does not match
# the current on-disk hash, throws ConflictError. If file doesn't exist, expectedPrevHash
# must be null (or omitted).
export def writeFile path, content, expectedPrevHash = undefined, mode = 0o600
  const actual = hashFile(path)
  if expectedPrevHash !== undefined and expectedPrevHash !== actual
    throw new ConflictError(path, actual)
  mkdirSync(dirname(path), recursive: yes)
  writeFileSync(path, content)
  chmodSync(path, mode)
  sha256Hex(content)

# List current skill files → [{ name, hash, content }].
export def listSkills home
  const d = skillsDir(home)
  return [] unless existsSync(d)
  readdirSync(d)
    .filter(do(f) f.endsWith('.md'))
    .map do(f)
      const name = f.slice(0, -3)
      const { content, hash } = readFile(join(d, f))
      { name, content, hash }

# Overwrite skills directory to exactly match `skills = [{name, content}]`.
# Returns [{name, hash}]. Expected-prev-hash conflict checks are per-skill in the caller.
export def writeSkills home, skills
  const d = skillsDir(home)
  mkdirSync(d, recursive: yes)
  # delete skills not in the new set
  const keep = new Set(skills.map do(s) "{s.name}.md")
  for f in readdirSync(d) when f.endsWith('.md') and !keep.has(f)
    require('fs').unlinkSync(join(d, f))
  # write each
  skills.map do(s)
    writeFile(skillPath(home, s.name), s.content, undefined, 0o600)
    { name: s.name, hash: sha256Hex(s.content) }
```

- [ ] **Step 2:** Create `tests/sync.test.imba`:

```imba
import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, writeFileSync, existsSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {readFile, writeFile, listSkills, writeSkills, personaPath, skillPath, skillsDir, ConflictError, hashFile} from "../src/sync.imba"
import {sha256Hex} from "../src/utils.imba"

let home = null
beforeEach do
  home = mkdtempSync(join(tmpdir!, 'aion-sync-'))

test "writeFile with no prev hash writes and returns hash", do
  const h = writeFile(personaPath(home), 'hello')
  expect(h).toBe(sha256Hex('hello'))
  expect(readFile(personaPath(home)).content).toBe('hello')

test "writeFile with matching prev hash overwrites", do
  writeFile(personaPath(home), 'v1')
  const prev = hashFile(personaPath(home))
  const next = writeFile(personaPath(home), 'v2', prev)
  expect(readFile(personaPath(home)).content).toBe('v2')
  expect(next).toBe(sha256Hex('v2'))

test "writeFile with wrong prev hash throws ConflictError", do
  writeFile(personaPath(home), 'v1')
  let thrown = null
  try
    writeFile(personaPath(home), 'v2', 'wronghash')
  catch e
    thrown = e
  expect(thrown instanceof ConflictError).toBe(true)
  expect(thrown.actualHash).toBe(sha256Hex('v1'))
  expect(readFile(personaPath(home)).content).toBe('v1')

test "listSkills returns names+hashes+content", do
  writeFile(skillPath(home, 'deploy'), 'body A')
  writeFile(skillPath(home, 'debug'), 'body B')
  const list = listSkills(home).sort do(a,b) a.name.localeCompare(b.name)
  expect(list.length).toBe(2)
  expect(list[0].name).toBe('debug')
  expect(list[0].hash).toBe(sha256Hex('body B'))

test "writeSkills replaces directory contents", do
  writeFile(skillPath(home, 'old'), 'x')
  writeSkills(home, [{ name: 'new', content: 'y' }])
  const list = listSkills(home)
  expect(list.length).toBe(1)
  expect(list[0].name).toBe('new')
  expect(existsSync(skillPath(home, 'old'))).toBe(false)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/sync.imba tests/sync.test.imba
git commit -m "feat(sync): coordinator/ file layout with SHA-256 + conflict detection"
```

## Task 2.6: `adapter.imba` — interface + StubAdapter + registry

**Files:**
- Create: `src/adapter.imba`
- Create: `tests/adapter-contract.test.imba`

- [ ] **Step 1:** Create `src/adapter.imba`:

```imba
# Adapter interface for coordinator CLIs. Phase 1 ships two:
#   - StubAdapter: always returns ready, no-ops everything. Used by integration tests.
#   - ClaudeCodeAdapter: wraps the real `claude` CLI. Added in Wave 5.
#
# Interface contract (every adapter implements):
#   installCoordinator({program, version}) -> Promise<void>
#     Idempotent. Ensures CLI is on PATH for the workspace OS user.
#   configure({model, credentials, persona, skills}) -> Promise<void>
#     Writes coordinator config files into $HOME/coordinator/.
#   start(), stop(), restart() -> Promise<void>
#     For daemon coordinators. No-op for per-invoke CLIs like claude-code.
#   health() -> Promise<{ state: 'ready'|'starting'|'error', detail? }>
#   startAuth() -> Promise<{url} | null>
#     null if program uses API key only.
#   submitAuthCode({code}) -> Promise<{status: 'authorized'|'error', error?}>
#   writeSkills({persona, skills}) -> Promise<{persona: hash, skills: [{name, hash}]}>
#   readSkills() -> Promise<{persona: {hash, content}, skills: [{name, hash, content}]}>

import {readFile, writeFile, listSkills, writeSkills as syncWriteSkills, personaPath, coordinatorDir} from './sync.imba'
import {mkdirSync} from 'fs'

export class StubAdapter
  home = null
  state = 'ready'
  configured = no

  def constructor home
    self.home = home
    mkdirSync(coordinatorDir(home), recursive: yes)

  def installCoordinator opts
    return

  def configure opts
    configured = yes
    if opts.persona?
      writeFile(personaPath(home), opts.persona)
    if opts.skills?
      syncWriteSkills(home, opts.skills)

  def start
    state = 'ready'

  def stop
    state = 'error'

  def restart
    state = 'ready'

  def health
    { state }

  def startAuth
    null  # API-key mode only

  def submitAuthCode opts
    { status: 'error', error: 'stub adapter does not authenticate' }

  def writeSkills opts
    const personaHash = writeFile(personaPath(home), opts.persona)
    const skillHashes = syncWriteSkills(home, opts.skills or [])
    { persona: personaHash, skills: skillHashes }

  def readSkills
    const p = readFile(personaPath(home))
    const s = listSkills(home)
    { persona: p, skills: s }

const registry = { stub: StubAdapter }

export def registerAdapter name, cls
  registry[name] = cls

export def makeAdapter program, home
  const cls = registry[program]
  unless cls
    throw new Error("no adapter registered for program '{program}'")
  new cls(home)
```

- [ ] **Step 2:** Create `tests/adapter-contract.test.imba`. This test runs against any adapter that claims to implement the contract.

```imba
import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {StubAdapter, makeAdapter} from "../src/adapter.imba"

let home = null
beforeEach do
  home = mkdtempSync(join(tmpdir!, 'aion-adapter-'))

test "StubAdapter starts in ready state", do
  const a = new StubAdapter(home)
  const h = await a.health!
  expect(h.state).toBe('ready')

test "StubAdapter configure writes persona + skills", do
  const a = new StubAdapter(home)
  await a.configure({ persona: 'be helpful', skills: [{ name: 'k1', content: 'c1' }] })
  const out = await a.readSkills!
  expect(out.persona.content).toBe('be helpful')
  expect(out.skills.length).toBe(1)
  expect(out.skills[0].name).toBe('k1')

test "writeSkills returns persona + per-skill hashes", do
  const a = new StubAdapter(home)
  const r = await a.writeSkills({ persona: 'p', skills: [{ name: 's', content: 'body' }] })
  expect(typeof r.persona).toBe('string')
  expect(r.skills.length).toBe(1)
  expect(r.skills[0].name).toBe('s')

test "StubAdapter startAuth returns null (api-key only)", do
  const a = new StubAdapter(home)
  expect(await a.startAuth!).toBe(null)

test "makeAdapter('stub') returns a StubAdapter", do
  const a = makeAdapter('stub', home)
  expect(a instanceof StubAdapter).toBe(true)

test "makeAdapter of unknown program throws", do
  let threw = no
  try makeAdapter('bogus', home)
  catch threw = yes
  expect(threw).toBe(true)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/adapter.imba tests/adapter-contract.test.imba
git commit -m "feat(adapter): interface + StubAdapter for integration tests"
```

---

# Wave 3 — AION Client + Server + Heartbeat

## Task 3.1: `aion-client.imba` — register + heartbeat + cert-rotated

**Files:**
- Create: `src/aion-client.imba`
- Create: `tests/aion-client.test.imba`

- [ ] **Step 1:** Create `src/aion-client.imba`:

```imba
import {VERSION} from './protocol.imba'

export class AionClient
  baseUrl = null
  workspaceToken = null

  def constructor baseUrl, workspaceToken = null
    self.baseUrl = baseUrl.replace(/\/$/, '')
    self.workspaceToken = workspaceToken

  def setWorkspaceToken t
    self.workspaceToken = t

  def register { enrollment_token, external_ip, port, cert_fingerprint, coordinator_status, connector_version }
    const res = await fetch "{baseUrl}/api/workspaces/register",
      method: 'POST'
      headers: { 'content-type': 'application/json' }
      body: JSON.stringify({ enrollment_token, external_ip, port, cert_fingerprint, coordinator_status, connector_version, v: VERSION })
    const body = await res.json!
    if !res.ok
      throw new Error("register failed: {res.status} {body..error or ''}")
    body  # { workspace_id, workspace_token }

  def heartbeat workspaceId, { external_ip, coordinator_status, connector_version }
    const res = await fetch "{baseUrl}/api/workspaces/{workspaceId}/heartbeat",
      method: 'POST'
      headers: { 'content-type': 'application/json', 'authorization': "Bearer {workspaceToken}" }
      body: JSON.stringify({ external_ip, coordinator_status, connector_version, timestamp: Date.now!, v: VERSION })
    if !res.ok
      const b = await res.json!.catch do({})
      throw new Error("heartbeat failed: {res.status} {b..error or ''}")
    res.json!

  def certRotated workspaceId, newFingerprint
    const res = await fetch "{baseUrl}/api/workspaces/{workspaceId}/cert-rotated",
      method: 'POST'
      headers: { 'content-type': 'application/json', 'authorization': "Bearer {workspaceToken}" }
      body: JSON.stringify({ cert_fingerprint: newFingerprint, v: VERSION })
    res.ok
```

- [ ] **Step 2:** Create `tests/aion-client.test.imba` using MockAion:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"

let aion = null
beforeEach do
  aion = new MockAion!
  await aion.start!
afterEach do
  await aion.stop!

test "register returns workspace_id + workspace_token", do
  const { workspace_id, enrollment_token } = aion.createWorkspace!
  const cli = new AionClient(aion.baseUrl)
  const r = await cli.register({
    enrollment_token, external_ip: '1.2.3.4', port: 7700
    cert_fingerprint: '0'.repeat(64)
    coordinator_status: { state: 'ready', program: 'stub', version: '1' }
    connector_version: '0.4.0'
  })
  expect(r.workspace_id).toBe(workspace_id)
  expect(typeof r.workspace_token).toBe('string')

test "register with bad token throws", do
  const cli = new AionClient(aion.baseUrl)
  let threw = no
  try
    await cli.register({
      enrollment_token: 'bogus', external_ip: '1.2.3.4', port: 7700
      cert_fingerprint: '0'.repeat(64)
      coordinator_status: { state: 'ready' }
      connector_version: '0.4.0'
    })
  catch
    threw = yes
  expect(threw).toBe(true)

test "heartbeat requires workspace_token", do
  const { workspace_id, enrollment_token } = aion.createWorkspace!
  const cli = new AionClient(aion.baseUrl)
  const reg = await cli.register({
    enrollment_token, external_ip: '1.2.3.4', port: 7700
    cert_fingerprint: '0'.repeat(64)
    coordinator_status: { state: 'ready' }
    connector_version: '0.4.0'
  })
  cli.setWorkspaceToken(reg.workspace_token)
  await cli.heartbeat(workspace_id, {
    external_ip: '1.2.3.4'
    coordinator_status: { state: 'ready' }
    connector_version: '0.4.0'
  })
  expect(aion.heartbeats.length).toBe(1)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/aion-client.imba tests/aion-client.test.imba
git commit -m "feat(aion-client): register + heartbeat + cert-rotated HTTPS client"
```

## Task 3.2: `server.imba` — HTTPS server + bearer auth + ping

**Files:**
- Create: `src/server.imba` (overwrite the stub)
- Create: `tests/server.test.imba`

- [ ] **Step 1:** Overwrite `src/server.imba`:

```imba
import {createServer} from 'https'
import {VERSION} from './protocol.imba'
import {log, error} from './utils.imba'

# Minimal HTTPS server with bearer-token auth.
# Route handlers are plugged in by Connector via registerRoute(method, path, handler).
# Server itself only owns: TLS boot, body parse, auth, error shape, logging.
export class Server
  host = '0.0.0.0'
  port = 0
  cert = null
  key = null
  workspaceToken = null
  routes = []      # [{method, test(url)→params|null, handler(params,body)→Promise<{status,body}>}]
  srv = null

  def constructor { port, cert, key, workspaceToken, host = '0.0.0.0' }
    self.port = port
    self.cert = cert
    self.key = key
    self.workspaceToken = workspaceToken
    self.host = host

  # Register a route. `path` supports ":param" segments.
  def route method, path, handler
    const parts = path.split('/').filter(Boolean)
    const test = do(url)
      const u = url.split('?')[0].split('/').filter(Boolean)
      return null if u.length != parts.length
      const params = {}
      for seg, i in parts
        if seg[0] == ':'
          params[seg.slice(1)] = u[i]
        elif seg != u[i]
          return null
      params
    routes.push({ method, test, handler, path })

  def start
    srv = createServer { cert, key }, do(req, res) await handle(req, res)
    return new Promise do(ok) srv.listen(port, host, do ok!)
    log "https listening on {host}:{port}"

  def stop
    return unless srv
    new Promise do(ok) srv.close do ok!

  def handle req, res
    try
      # auth
      const auth = req.headers['authorization'] or ''
      const tok = auth.replace(/^Bearer /, '')
      unless tok and tok == workspaceToken
        return respond(res, 403, { error: 'unauthorized' })

      # body
      let body = null
      if req.method == 'POST'
        let raw = ''
        await new Promise do(ok)
          req.on('data', do(c) raw += c)
          req.on('end', ok)
        if raw
          try body = JSON.parse(raw)
          catch
            return respond(res, 400, { error: 'invalid json' })
        if body..v and body.v > VERSION
          return respond(res, 400, { error: 'version', min: body.v })

      # built-in ping
      if req.method == 'POST' and (req.url == '/ping' or req.url == '/')
        return respond(res, 200, { ok: yes, v: VERSION })

      # dispatch
      for r in routes when r.method == req.method
        const params = r.test(req.url)
        if params
          const r2 = await r.handler(params, body, req)
          return respond(res, r2.status or 200, r2.body or { ok: yes })
      respond(res, 404, { error: 'not found' })
    catch e
      error "route error: {e.message}"
      respond(res, 500, { error: 'internal' })

def respond res, code, data
  res.writeHead(code, { 'content-type': 'application/json' })
  res.end(JSON.stringify(data))
```

- [ ] **Step 2:** Create `tests/server.test.imba`. Because the client must pin the self-signed cert, the test uses Node's `https` agent with `rejectUnauthorized: false` (test-only — real AION pins fingerprint explicitly).

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {Agent} from 'https'

let server = null
let port = 0
let token = 'test-token-abc'
let agent = null
beforeEach do
  const dir = mkdtempSync(join(tmpdir!, 'aion-srv-'))
  const certPath = join(dir, 'cert.pem')
  const keyPath = join(dir, 'key.pem')
  await generateSelfSigned(certPath, keyPath)
  const { cert, key } = loadCertKey(certPath, keyPath)
  server = new Server({ port: 0, cert, key, workspaceToken: token })
  # let the OS pick a port
  server.port = 19100 + Math.floor(Math.random! * 200)
  await server.start!
  port = server.port
  agent = new Agent({ rejectUnauthorized: false })

afterEach do
  await server.stop!

def postJson path, body, authToken = token
  fetch "https://127.0.0.1:{port}{path}",
    method: 'POST'
    headers: { 'content-type': 'application/json', 'authorization': "Bearer {authToken}" }
    body: body ? JSON.stringify(body) : null
    tls: { rejectUnauthorized: false }

test "ping returns ok with VERSION", do
  const res = await postJson('/ping', {})
  expect(res.status).toBe(200)
  const body = await res.json!
  expect(body.ok).toBe(true)
  expect(body.v).toBeGreaterThan(0)

test "wrong bearer token returns 403", do
  const res = await postJson('/ping', {}, 'wrong')
  expect(res.status).toBe(403)

test "registered route receives params and body", do
  let seen = null
  server.route 'POST', '/foo/:id', do(params, body)
    seen = { params, body }
    { status: 200, body: { ok: yes, id: params.id } }
  const res = await postJson('/foo/abc123', { hello: 'world' })
  expect(res.status).toBe(200)
  expect(seen.params.id).toBe('abc123')
  expect(seen.body.hello).toBe('world')

test "unknown route returns 404", do
  const res = await postJson('/nope', {})
  expect(res.status).toBe(404)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/server.imba tests/server.test.imba
git commit -m "feat(server): HTTPS server with bearer auth and route dispatcher"
```

## Task 3.3: `heartbeat.imba` — periodic heartbeat loop

**Files:**
- Create: `src/heartbeat.imba`
- Create: `tests/heartbeat.test.imba`

- [ ] **Step 1:** Create `src/heartbeat.imba`:

```imba
import {log, error} from './utils.imba'

# Fires heartbeat() every intervalMs. `collect()` returns the payload.
export class Heartbeat
  interval = 30000
  timer = null
  aionClient = null
  workspaceId = null
  collect = null  # function returning {external_ip, coordinator_status, connector_version}

  def constructor { aionClient, workspaceId, collect, intervalMs = 30000 }
    self.aionClient = aionClient
    self.workspaceId = workspaceId
    self.collect = collect
    self.interval = intervalMs

  def start
    tick!        # fire immediately
    timer = setInterval(&, interval) do tick!

  def stop
    if timer
      clearInterval(timer)
      timer = null

  def tick
    try
      const payload = await collect!
      await aionClient.heartbeat(workspaceId, payload)
    catch e
      error "heartbeat failed: {e.message}"
```

- [ ] **Step 2:** Create `tests/heartbeat.test.imba`:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"
import {Heartbeat} from "../src/heartbeat.imba"

let aion = null
beforeEach do
  aion = new MockAion!
  await aion.start!
afterEach do
  await aion.stop!

def register!
  const { workspace_id, enrollment_token } = aion.createWorkspace!
  const cli = new AionClient(aion.baseUrl)
  const { workspace_token } = await cli.register({
    enrollment_token, external_ip: '1.2.3.4', port: 7700
    cert_fingerprint: '0'.repeat(64)
    coordinator_status: { state: 'ready' }
    connector_version: '0.4.0'
  })
  cli.setWorkspaceToken(workspace_token)
  { cli, workspace_id }

test "heartbeat fires immediately and then on interval", do
  const { cli, workspace_id } = await register!
  let calls = 0
  const hb = new Heartbeat({
    aionClient: cli, workspaceId: workspace_id, intervalMs: 50
    collect: do
      calls++
      { external_ip: '1.2.3.4', coordinator_status: { state: 'ready' }, connector_version: '0.4.0' }
  })
  hb.start!
  await new Promise do(ok) setTimeout(ok, 180)
  hb.stop!
  # expect at least 3 calls (t=0, t=50, t=100, t=150)
  expect(calls).toBeGreaterThanOrEqual(3)
  expect(aion.heartbeats.length).toBe(calls)

test "heartbeat swallows network errors", do
  await aion.stop!  # server down
  const cli = new AionClient("http://127.0.0.1:1")  # bogus
  cli.setWorkspaceToken('x')
  const hb = new Heartbeat({
    aionClient: cli, workspaceId: 'x', intervalMs: 50
    collect: do { external_ip: '1.2.3.4', coordinator_status: { state: 'ready' }, connector_version: '0.4.0' }
  })
  hb.start!
  await new Promise do(ok) setTimeout(ok, 120)
  hb.stop!
  # test passes if no unhandled rejection
  # restart aion for afterEach cleanup
  aion = new MockAion!
  await aion.start!
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/heartbeat.imba tests/heartbeat.test.imba
git commit -m "feat(heartbeat): periodic heartbeat loop with error tolerance"
```

---

# Wave 4 — CLI + Registration End-to-End

## Task 4.1: `connector.imba` — orchestrator wiring

**Files:**
- Create: `src/connector.imba` (overwrite the stub)

- [ ] **Step 1:** Overwrite `src/connector.imba`:

```imba
# Orchestrator. Owns:
#   - state (workspace.json)
#   - adapter (chosen by program name)
#   - https server
#   - aion client
#   - heartbeat loop
# Wire routes here; route handlers are in src/routes.imba.
import {readState, writeState, mergeState, certPath, keyPath} from './state.imba'
import {generateSelfSigned, loadCertKey, fingerprint} from './tls.imba'
import {pickFreePort} from './port.imba'
import {AionClient} from './aion-client.imba'
import {Server} from './server.imba'
import {Heartbeat} from './heartbeat.imba'
import {makeAdapter} from './adapter.imba'
import {registerRoutes} from './routes.imba'
import {log} from './utils.imba'
import {readFileSync} from 'fs'
import {join, dirname} from 'path'
import {fileURLToPath} from 'url'

const __dir = dirname(fileURLToPath(import.meta.url))
const pkg = JSON.parse(readFileSync(join(__dir, '..', 'package.json'), 'utf8'))
export const CONNECTOR_VERSION = pkg.version

export class Connector
  state = null
  adapter = null
  server = null
  aionClient = null
  heartbeat = null
  externalIp = null

  def constructor state
    self.state = state

  def start
    # TLS
    const { cert, key } = loadCertKey(certPath!, keyPath!)
    # Adapter
    adapter = makeAdapter(state.coordinator.program, process.env.HOME or require('os').homedir!)
    # Detect external IP
    externalIp = await detectIp!
    # AION client
    aionClient = new AionClient(state.aion_url, state.workspace_token)
    # HTTPS server
    server = new Server({ port: state.port, cert, key, workspaceToken: state.workspace_token })
    registerRoutes(server, self)
    await server.start!
    log "server up on :{state.port}"
    # Heartbeat
    heartbeat = new Heartbeat({
      aionClient, workspaceId: state.workspace_id
      intervalMs: 30000
      collect: do collectHeartbeat!
    })
    heartbeat.start!
    log "heartbeat started"

  def stop
    heartbeat..stop!
    await server..stop!
    await adapter..stop!

  def collectHeartbeat
    const h = await adapter.health!
    { external_ip: externalIp, coordinator_status: { state: h.state, detail: h.detail, program: state.coordinator.program, version: state.coordinator.version }, connector_version: CONNECTOR_VERSION }

# Detect external IP by asking AION-exposed helper or a stun-like service.
# Phase 1 strategy: pass it in from the installer on initial register, then re-fetch
# from the AION record on each heartbeat (AION echoes back what it saw). For now,
# read it from env AION_EXTERNAL_IP (set by installer) or fall back to a best-guess.
def detectIp
  if process.env.AION_EXTERNAL_IP
    return process.env.AION_EXTERNAL_IP
  # Fallback: ask ifconfig.me
  try
    const res = await fetch('https://ifconfig.me/ip')
    if res.ok
      const txt = (await res.text!).trim!
      return txt if txt
  catch
    ;
  '0.0.0.0'
```

- [ ] **Step 2:** Don't run tests yet — `routes.imba` doesn't exist. Write the stub to make the build happy:

Create `src/routes.imba`:

```imba
# Route handlers mounted on the HTTPS server. Filled in Wave 6.
export def registerRoutes server, connector
  # /invoke stub — returns 501 until Phase 3 delivers chat routing.
  server.route 'POST', '/invoke', do
    { status: 501, body: { error: 'invoke not implemented in Phase 1' } }
```

- [ ] **Step 3:** Build check:

```bash
bun run build
```

Expected: success.

- [ ] **Step 4:** Commit.

```bash
git add src/connector.imba src/routes.imba
git commit -m "feat(connector): orchestrator wiring + /invoke stub"
```

## Task 4.2: `cli.imba` — subcommand dispatcher + `install` command

The `install` subcommand is invoked by the bash installer, not by the admin directly. It:
1. Reads `--token`, `--aion`, `--port`, `--workspace-id` (optional re-enroll), `--program`, `--model`, `--auth-mode`, `--persona` (path), `--skills-json` (path), `--external-ip` args.
2. Picks a port, generates a TLS cert.
3. Asks adapter to install+configure+start the coordinator.
4. Calls AION `register`, gets `workspace_token`.
5. Writes `workspace.json` with everything.
6. Prints `READY workspace_id=... port=... fingerprint=...` to stdout so the installer can log it.

**Files:**
- Create: `src/cli.imba` (overwrite the stub)

- [ ] **Step 1:** Overwrite `src/cli.imba`:

```imba
import {readFileSync, existsSync} from 'fs'
import {log, error} from './utils.imba'
import {ensureDirs, writeState, mergeState, readState, certPath, keyPath, stateDir} from './state.imba'
import {generateSelfSigned} from './tls.imba'
import {pickFreePort} from './port.imba'
import {AionClient} from './aion-client.imba'
import {makeAdapter} from './adapter.imba'
import {Connector, CONNECTOR_VERSION} from './connector.imba'

const sub = process.argv[2]

def parseFlags argv
  const out = {}
  let i = 0
  while i < argv.length
    const a = argv[i]
    if a.startsWith('--')
      const key = a.slice(2)
      const val = argv[i+1] and !argv[i+1].startsWith('--') ? argv[i+1] : 'true'
      out[key] = val
      i += val == 'true' ? 1 : 2
    else
      i++
  out

def usage
  console.error "Usage: aion-connector <command> [flags]"
  console.error ""
  console.error "Commands:"
  console.error "  run                 Start the connector service (used by systemd)"
  console.error "  install --token X --aion URL --program P --model M --auth-mode api_key|oauth"
  console.error "                      [--workspace-id ID] [--port N] [--persona FILE] [--skills-json FILE]"
  console.error "                      [--api-key VALUE] [--external-ip IP]"
  console.error "                      Enroll this host as a workspace. Called by installer."
  console.error "  status | logs | restart | stop | doctor | uninstall"
  process.exit(2)

switch sub
  when 'run' then await cmdRun!
  when 'install' then await cmdInstall(parseFlags(process.argv.slice(3)))
  else usage!

def cmdRun
  const state = readState!
  unless state
    error "no workspace state found — run `aion-connector install` first"
    process.exit(1)
  const c = new Connector(state)
  await c.start!
  const shutdown = do
    log "shutting down..."
    await c.stop!
    process.exit(0)
  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)

def cmdInstall f
  const required = ['token', 'aion', 'program', 'model', 'auth-mode']
  for k in required when !f[k]
    error "--{k} is required"
    process.exit(2)
  ensureDirs!
  log "generating TLS cert..."
  const fp = await generateSelfSigned(certPath!, keyPath!)
  const port = f.port ? parseInt(f.port) : await pickFreePort!
  log "chose port {port}, fingerprint {fp}"

  const persona = f.persona and existsSync(f.persona) ? readFileSync(f.persona, 'utf8') : ''
  const skills = f['skills-json'] and existsSync(f['skills-json']) ? JSON.parse(readFileSync(f['skills-json'], 'utf8')) : []

  log "configuring coordinator ({f.program}, {f.model})..."
  const adapter = makeAdapter(f.program, process.env.HOME or require('os').homedir!)
  await adapter.installCoordinator({ program: f.program })
  await adapter.configure({
    model: f.model
    credentials: f['auth-mode'] == 'api_key' ? { api_key: f['api-key'] or '' } : null
    persona
    skills
  })
  await adapter.start!
  const health = await adapter.health!

  log "registering with AION..."
  const cli = new AionClient(f.aion)
  const reg = await cli.register({
    enrollment_token: f.token
    external_ip: f['external-ip'] or process.env.AION_EXTERNAL_IP or '0.0.0.0'
    port
    cert_fingerprint: fp
    coordinator_status: { state: health.state, program: f.program, version: f.model }
    connector_version: CONNECTOR_VERSION
  })

  writeState({
    workspace_id: reg.workspace_id
    workspace_token: reg.workspace_token
    aion_url: f.aion
    port
    cert_fingerprint: fp
    coordinator: {
      program: f.program
      model: f.model
      auth_mode: f['auth-mode']
    }
  })
  console.log "READY workspace_id={reg.workspace_id} port={port} fingerprint={fp}"
```

- [ ] **Step 2:** Create `tests/registration.test.imba` — full round-trip via CLI's cmdInstall-equivalent flow using StubAdapter:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync, readFileSync, existsSync} from 'fs'
import {tmpdir, homedir} from 'os'
import {join} from 'path'
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"
import {generateSelfSigned} from "../src/tls.imba"
import {writeState, readState, certPath, keyPath, ensureDirs} from "../src/state.imba"
import {makeAdapter} from "../src/adapter.imba"
import {pickFreePort} from "../src/port.imba"

let aion = null
let sandbox = null
let oldHome = null

beforeEach do
  aion = new MockAion!
  await aion.start!
  sandbox = mkdtempSync(join(tmpdir!, 'aion-home-'))
  oldHome = process.env.HOME
  process.env.HOME = sandbox

afterEach do
  process.env.HOME = oldHome
  await aion.stop!

test "end-to-end registration with stub adapter", do
  const { workspace_id, enrollment_token } = aion.createWorkspace({ program: 'stub' })
  ensureDirs!
  const fp = await generateSelfSigned(certPath!, keyPath!)
  const port = await pickFreePort(18100, 18199)
  const adapter = makeAdapter('stub', sandbox)
  await adapter.installCoordinator({ program: 'stub' })
  await adapter.configure({ persona: 'p', skills: [], model: 'm', credentials: null })
  await adapter.start!
  const cli = new AionClient(aion.baseUrl)
  const reg = await cli.register({
    enrollment_token, external_ip: '1.2.3.4', port
    cert_fingerprint: fp
    coordinator_status: { state: 'ready', program: 'stub', version: '1' }
    connector_version: '0.4.0'
  })
  expect(reg.workspace_id).toBe(workspace_id)
  writeState({
    workspace_id: reg.workspace_id, workspace_token: reg.workspace_token
    aion_url: aion.baseUrl, port, cert_fingerprint: fp
    coordinator: { program: 'stub', model: 'm', auth_mode: 'api_key' }
  })
  const st = readState!
  expect(st.workspace_id).toBe(workspace_id)
  # AION sees it as online
  const wsRec = aion.workspaces.get(workspace_id)
  expect(wsRec.state).toBe('online')
  expect(wsRec.port).toBe(port)
  expect(wsRec.fingerprint).toBe(fp)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/cli.imba tests/registration.test.imba
git commit -m "feat(cli): install command + end-to-end registration test"
```

## Task 4.3: `run` command — connector lifecycle test

**Files:**
- Create: `tests/run.test.imba`

- [ ] **Step 1:** This test starts the Connector directly (not via CLI shell-out) with a pre-populated state and verifies it registers heartbeats.

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {MockAion} from "../dev/mock-aion.imba"
import {AionClient} from "../src/aion-client.imba"
import {generateSelfSigned} from "../src/tls.imba"
import {writeState, certPath, keyPath, ensureDirs} from "../src/state.imba"
import {Connector} from "../src/connector.imba"
import {pickFreePort} from "../src/port.imba"

let aion = null
let sandbox = null
let oldHome = null

beforeEach do
  aion = new MockAion!
  await aion.start!
  sandbox = mkdtempSync(join(tmpdir!, 'aion-run-'))
  oldHome = process.env.HOME
  process.env.HOME = sandbox
  process.env.AION_EXTERNAL_IP = '1.2.3.4'

afterEach do
  process.env.HOME = oldHome
  delete process.env.AION_EXTERNAL_IP
  await aion.stop!

test "Connector.start sends a heartbeat within 2s", do
  const { workspace_id, enrollment_token } = aion.createWorkspace!
  ensureDirs!
  const fp = await generateSelfSigned(certPath!, keyPath!)
  const port = await pickFreePort(18200, 18299)
  const cli = new AionClient(aion.baseUrl)
  const reg = await cli.register({
    enrollment_token, external_ip: '1.2.3.4', port
    cert_fingerprint: fp, coordinator_status: { state: 'ready', program: 'stub' }
    connector_version: '0.4.0'
  })
  writeState({
    workspace_id: reg.workspace_id, workspace_token: reg.workspace_token
    aion_url: aion.baseUrl, port, cert_fingerprint: fp
    coordinator: { program: 'stub', model: 'm', auth_mode: 'api_key' }
  })
  const state = (require('../src/state.imba')).readState!
  const c = new Connector(state)
  await c.start!
  await new Promise do(ok) setTimeout(ok, 100)
  expect(aion.heartbeats.length).toBeGreaterThanOrEqual(1)
  await c.stop!
```

- [ ] **Step 2:** Run, expect pass.

- [ ] **Step 3:** Commit.

```bash
git add tests/run.test.imba
git commit -m "test(connector): Connector.start fires heartbeat end-to-end"
```

---

# Wave 5 — Claude-code Adapter

All tests in this wave are gated by `CLAUDE_CODE_INSTALLED=1` in env, unless noted. Reason: CI without the claude CLI can still pass the rest.

## Task 5.1: ClaudeCodeAdapter skeleton — install + configure + health

**Files:**
- Create: `src/claude-code-adapter.imba`
- Modify: `src/adapter.imba` (register the adapter)

- [ ] **Step 1:** Create `src/claude-code-adapter.imba`:

```imba
import {exec, log} from './utils.imba'
import {writeFile, writeSkills as syncWriteSkills, readFile, listSkills, personaPath, skillsDir, coordinatorDir} from './sync.imba'
import {mkdirSync, writeFileSync, chmodSync, existsSync} from 'fs'
import {join} from 'path'

# Wraps the real `claude` CLI. claude-code is invoked per-turn via acpx, not as a daemon —
# so start/stop/restart are mostly no-ops; health() just probes the binary.
export class ClaudeCodeAdapter
  home = null
  installed = no
  authorized = no
  authProc = null

  def constructor home
    self.home = home
    mkdirSync(coordinatorDir(home), recursive: yes)

  # Idempotent: install @anthropic-ai/claude-code into the user's npm prefix, or verify present.
  def installCoordinator { program, version = 'latest' }
    const which = await exec(['which', 'claude'])
    if which.exitCode == 0
      installed = yes
      return
    log "installing @anthropic-ai/claude-code@{version}..."
    const inst = await exec(['npm', 'install', '-g', "@anthropic-ai/claude-code@{version}"])
    if inst.exitCode != 0
      throw new Error("npm install failed: {inst.stderr}")
    installed = yes

  def configure { model, credentials, persona, skills }
    if persona?
      writeFile(personaPath(home), persona)
    if skills?
      syncWriteSkills(home, skills)
    if credentials?.api_key
      const envPath = join(coordinatorDir(home), 'credentials.env')
      writeFileSync(envPath, "ANTHROPIC_API_KEY={credentials.api_key}\n")
      chmodSync(envPath, 0o600)
    const cfg = { program: 'claude-code', model }
    writeFileSync(join(coordinatorDir(home), 'config.json'), JSON.stringify(cfg, null, 2))

  def start
    return  # no daemon

  def stop
    return

  def restart
    return

  def health
    unless installed
      const which = await exec(['which', 'claude'])
      installed = which.exitCode == 0
    unless installed
      return { state: 'error', detail: 'claude binary not found' }
    { state: 'ready' }

  def startAuth
    # filled in Task 5.2
    throw new Error("startAuth not implemented yet")

  def submitAuthCode opts
    throw new Error("submitAuthCode not implemented yet")

  def writeSkills { persona, skills }
    const { sha256Hex } = require('./utils.imba')
    const personaHash = writeFile(personaPath(home), persona)
    const skillHashes = syncWriteSkills(home, skills or [])
    { persona: personaHash, skills: skillHashes }

  def readSkills
    const p = readFile(personaPath(home))
    { persona: p, skills: listSkills(home) }
```

- [ ] **Step 2:** Register in `src/adapter.imba`. Modify the `registry` initializer:

Before:
```imba
const registry = { stub: StubAdapter }
```

After:
```imba
import {ClaudeCodeAdapter} from './claude-code-adapter.imba'
const registry = { stub: StubAdapter, 'claude-code': ClaudeCodeAdapter }
```

- [ ] **Step 3:** Create `tests/claude-code-adapter.test.imba`:

```imba
import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, existsSync, readFileSync, statSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {ClaudeCodeAdapter} from "../src/claude-code-adapter.imba"
import {personaPath, skillPath} from "../src/sync.imba"

const SKIP = process.env.CLAUDE_CODE_INSTALLED != '1'

let home = null
beforeEach do
  home = mkdtempSync(join(tmpdir!, 'aion-cc-'))

test "configure writes persona.md + skills/*", (SKIP ? test.skip : test.todo), do
  const a = new ClaudeCodeAdapter(home)
  await a.configure({ persona: 'be terse', skills: [{ name: 'deploy', content: 'steps' }], model: 'sonnet-4.6', credentials: { api_key: 'sk-xxx' } })
  expect(readFileSync(personaPath(home), 'utf8')).toBe('be terse')
  expect(readFileSync(skillPath(home, 'deploy'), 'utf8')).toBe('steps')
  const envPath = join(home, 'coordinator', 'credentials.env')
  expect(existsSync(envPath)).toBe(true)
  expect(statSync(envPath).mode & 0o777).toBe(0o600)
  expect(readFileSync(envPath, 'utf8')).toContain('sk-xxx')

test "health returns ready when binary is present", (SKIP ? test.skip : test), do
  const a = new ClaudeCodeAdapter(home)
  await a.installCoordinator({ program: 'claude-code' })
  const h = await a.health!
  expect(h.state).toBe('ready')
```

Note: the `configure` test is `test.skip` by default and should be flipped to `test` unconditionally (it doesn't actually need claude installed). Fix it in the final version — leaving skip here only because the full suite in Task 5.2 exercises it with real binary.

Actually make it unconditional — configure is pure file I/O:

Replace the `configure` test's guard with plain `test`:
```imba
test "configure writes persona.md + skills/*", do
  ...
```

- [ ] **Step 4:** Run, expect configure test pass, health test skip on CI.

```bash
bun run test
```

- [ ] **Step 5:** Commit.

```bash
git add src/claude-code-adapter.imba src/adapter.imba tests/claude-code-adapter.test.imba
git commit -m "feat(adapter): claude-code adapter — install, configure, health"
```

## Task 5.2: ClaudeCodeAdapter — startAuth + submitAuthCode

The `claude setup-token` flow prints an auth URL to stdout and reads an auth code from stdin. We spawn it, capture stdout until the URL appears, keep the process alive, then on `submitAuthCode` write the code to its stdin and wait for exit.

**Files:**
- Modify: `src/claude-code-adapter.imba`

- [ ] **Step 1:** Replace `startAuth` and `submitAuthCode` methods in `src/claude-code-adapter.imba`:

```imba
  def startAuth
    const {spawn} = require('child_process')
    const env = Object.assign({}, process.env, { HOME: home })
    authProc = spawn('claude', ['setup-token'], { stdio: ['pipe', 'pipe', 'pipe'], env })
    let stdout = ''
    return new Promise do(ok, ko)
      let resolved = no
      const urlRegex = /(https?:\/\/\S+)/
      authProc.stdout.on 'data', do(chunk)
        stdout += chunk.toString!
        const m = stdout.match(urlRegex)
        if m and !resolved
          resolved = yes
          ok({ url: m[1] })
      authProc.on 'exit', do(code)
        unless resolved
          resolved = yes
          ko(new Error("claude setup-token exited {code} before URL appeared"))

  def submitAuthCode { code }
    unless authProc
      return { status: 'error', error: 'no auth in progress — call startAuth first' }
    authProc.stdin.write("{code}\n")
    authProc.stdin.end!
    return new Promise do(ok)
      authProc.on 'exit', do(ec)
        authProc = null
        if ec == 0
          authorized = yes
          ok({ status: 'authorized' })
        else
          ok({ status: 'error', error: "claude setup-token exited {ec}" })
```

- [ ] **Step 2:** Add a test (skipped on CI without claude installed). Append to `tests/claude-code-adapter.test.imba`:

```imba
test "startAuth surfaces an auth URL", (SKIP ? test.skip : test), 20000, do
  const a = new ClaudeCodeAdapter(home)
  const r = await a.startAuth!
  expect(r.url).toMatch(/^https?:/)
  # kill the spawned process since we won't supply a code
  a.authProc..kill!
```

- [ ] **Step 3:** Run — on local dev with `CLAUDE_CODE_INSTALLED=1`, test runs; on CI, skipped.

```bash
bun run test
```

- [ ] **Step 4:** Commit.

```bash
git add src/claude-code-adapter.imba tests/claude-code-adapter.test.imba
git commit -m "feat(adapter): claude-code startAuth/submitAuthCode via spawn"
```

---

# Wave 6 — Server Routes: OAuth + Sync

## Task 6.1: `/coordinator/oauth/start` + `/coordinator/oauth/complete`

**Files:**
- Modify: `src/routes.imba`
- Create: `tests/routes.oauth.test.imba`

- [ ] **Step 1:** Add routes in `src/routes.imba`:

```imba
export def registerRoutes server, connector
  server.route 'POST', '/invoke', do
    { status: 501, body: { error: 'invoke not implemented in Phase 1' } }

  server.route 'POST', '/coordinator/oauth/start', do
    try
      const r = await connector.adapter.startAuth!
      if r == null
        return { status: 400, body: { error: 'adapter is api-key only' } }
      { status: 200, body: { url: r.url } }
    catch e
      { status: 500, body: { error: e.message } }

  server.route 'POST', '/coordinator/oauth/complete', do(params, body)
    unless body?.code
      return { status: 400, body: { error: 'code required' } }
    const r = await connector.adapter.submitAuthCode({ code: body.code })
    { status: r.status == 'authorized' ? 200 : 400, body: r }

  # Fills in Task 6.2, 6.3
```

- [ ] **Step 2:** Create `tests/routes.oauth.test.imba`. Uses StubAdapter but replaces `startAuth`/`submitAuthCode` with probes:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"

let server = null
let port = 0
const token = 'tok'

beforeEach do
  const dir = mkdtempSync(join(tmpdir!, 'aion-routes-'))
  const certP = join(dir, 'cert.pem')
  const keyP = join(dir, 'key.pem')
  await generateSelfSigned(certP, keyP)
  const { cert, key } = loadCertKey(certP, keyP)
  port = 19400 + Math.floor(Math.random! * 200)
  server = new Server({ port, cert, key, workspaceToken: token })
  const adapter = new StubAdapter(dir)
  adapter.startAuth = do { url: 'https://provider.example/oauth?session=abc' }
  adapter.submitAuthCode = do(o) o.code == 'good' ? { status: 'authorized' } : { status: 'error', error: 'bad code' }
  registerRoutes(server, { adapter })
  await server.start!

afterEach do
  await server.stop!

def post path, body
  fetch "https://127.0.0.1:{port}{path}",
    method: 'POST'
    headers: { 'content-type': 'application/json', 'authorization': "Bearer {token}" }
    body: JSON.stringify(body or {})
    tls: { rejectUnauthorized: false }

test "/coordinator/oauth/start returns url", do
  const res = await post('/coordinator/oauth/start', {})
  expect(res.status).toBe(200)
  const b = await res.json!
  expect(b.url).toBe('https://provider.example/oauth?session=abc')

test "/coordinator/oauth/complete with good code", do
  const res = await post('/coordinator/oauth/complete', { code: 'good' })
  expect(res.status).toBe(200)
  const b = await res.json!
  expect(b.status).toBe('authorized')

test "/coordinator/oauth/complete with bad code returns 400", do
  const res = await post('/coordinator/oauth/complete', { code: 'bad' })
  expect(res.status).toBe(400)
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/routes.imba tests/routes.oauth.test.imba
git commit -m "feat(routes): /coordinator/oauth/start + complete"
```

## Task 6.2: `/coordinator/sync/persona` + `/coordinator/sync/skills`

Two endpoints per direction (GET for pull, POST for push), plus a POST for replacing the whole skills set.

**Files:**
- Modify: `src/routes.imba`
- Create: `tests/routes.sync.test.imba`

- [ ] **Step 1:** Append to `src/routes.imba`, inside `registerRoutes`:

```imba
  server.route 'POST', '/coordinator/sync/persona', do(params, body)
    unless body?.content?
      return { status: 400, body: { error: 'content required' } }
    try
      const out = await connector.adapter.writeSkills({ persona: body.content, skills: (await connector.adapter.readSkills!).skills.map do(s) { name: s.name, content: s.content } })
      { status: 200, body: { persona: out.persona } }
    catch e
      if e.constructor..name == 'ConflictError'
        return { status: 409, body: { error: 'conflict', actualHash: e.actualHash } }
      { status: 500, body: { error: e.message } }

  server.route 'POST', '/coordinator/sync/read', do
    const r = await connector.adapter.readSkills!
    { status: 200, body: r }

  server.route 'POST', '/coordinator/sync/skills', do(params, body)
    unless Array.isArray(body?.skills)
      return { status: 400, body: { error: 'skills array required' } }
    try
      const curr = await connector.adapter.readSkills!
      const out = await connector.adapter.writeSkills({ persona: curr.persona?.content or '', skills: body.skills })
      { status: 200, body: { skills: out.skills } }
    catch e
      if e.constructor..name == 'ConflictError'
        return { status: 409, body: { error: 'conflict', actualHash: e.actualHash } }
      { status: 500, body: { error: e.message } }
```

Note: conflict handling here is simplified because the StubAdapter/ClaudeCodeAdapter `writeSkills` currently doesn't accept `expected_prev_hash`. Task 6.3 extends the adapter contract to plumb that through properly; for now these routes push-overwrite.

- [ ] **Step 2:** Create `tests/routes.sync.test.imba`:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"

let server = null
let port = 0
let home = null
const token = 'tok'

beforeEach do
  home = mkdtempSync(join(tmpdir!, 'aion-sync-home-'))
  const certP = join(home, 'cert.pem')
  const keyP = join(home, 'key.pem')
  await generateSelfSigned(certP, keyP)
  const { cert, key } = loadCertKey(certP, keyP)
  port = 19600 + Math.floor(Math.random! * 200)
  server = new Server({ port, cert, key, workspaceToken: token })
  const adapter = new StubAdapter(home)
  await adapter.configure({ persona: 'v1', skills: [{ name: 'a', content: 'x' }], model: 'm', credentials: null })
  registerRoutes(server, { adapter })
  await server.start!

afterEach do
  await server.stop!

def post path, body
  fetch "https://127.0.0.1:{port}{path}",
    method: 'POST'
    headers: { 'content-type': 'application/json', 'authorization': "Bearer {token}" }
    body: JSON.stringify(body or {})
    tls: { rejectUnauthorized: false }

test "sync/read returns persona + skills", do
  const res = await post('/coordinator/sync/read', {})
  expect(res.status).toBe(200)
  const b = await res.json!
  expect(b.persona.content).toBe('v1')
  expect(b.skills.length).toBe(1)
  expect(b.skills[0].name).toBe('a')

test "sync/persona overwrites persona", do
  const res = await post('/coordinator/sync/persona', { content: 'v2' })
  expect(res.status).toBe(200)
  const read = await (await post('/coordinator/sync/read', {})).json!
  expect(read.persona.content).toBe('v2')

test "sync/skills replaces skills", do
  const res = await post('/coordinator/sync/skills', { skills: [{ name: 'b', content: 'y' }] })
  expect(res.status).toBe(200)
  const read = await (await post('/coordinator/sync/read', {})).json!
  expect(read.skills.length).toBe(1)
  expect(read.skills[0].name).toBe('b')
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/routes.imba tests/routes.sync.test.imba
git commit -m "feat(routes): two-way sync for persona + skills"
```

## Task 6.3: Conflict detection via `expected_prev_hash`

Extends adapter contract so write paths accept and enforce `expected_prev_hash`. Route returns HTTP 409 on mismatch.

**Files:**
- Modify: `src/adapter.imba` (StubAdapter.writeSkills)
- Modify: `src/claude-code-adapter.imba` (writeSkills)
- Modify: `src/sync.imba` (writeSkills helper already accepts per-file hash — use it)
- Modify: `src/routes.imba`
- Create: `tests/routes.sync-conflict.test.imba`

- [ ] **Step 1:** Update `src/sync.imba` — replace `writeSkills` to accept and propagate per-file expected hashes:

```imba
# Overwrite skills. `skills` = [{name, content, expected_prev_hash?}].
# Throws ConflictError on first mismatch. Returns [{name, hash}].
export def writeSkills home, skills
  const d = skillsDir(home)
  mkdirSync(d, recursive: yes)
  const keep = new Set(skills.map do(s) "{s.name}.md")
  for f in readdirSync(d) when f.endsWith('.md') and !keep.has(f)
    require('fs').unlinkSync(join(d, f))
  skills.map do(s)
    writeFile(skillPath(home, s.name), s.content, s.expected_prev_hash, 0o600)
    { name: s.name, hash: sha256Hex(s.content) }
```

Add import of `sha256Hex` at top of sync.imba:

```imba
import {sha256Hex} from './utils.imba'
```

- [ ] **Step 2:** Update StubAdapter and ClaudeCodeAdapter — both already pass arbitrary skills through to `writeSkills`; the new `expected_prev_hash` field rides along. Change their `writeSkills(opts)` to also accept `opts.expected_persona_hash` for the persona file. In `src/adapter.imba` replace StubAdapter.writeSkills:

```imba
  def writeSkills opts
    const personaHash = writeFile(personaPath(home), opts.persona, opts.expected_persona_hash)
    const skillHashes = syncWriteSkills(home, opts.skills or [])
    { persona: personaHash, skills: skillHashes }
```

Mirror change in ClaudeCodeAdapter.

- [ ] **Step 3:** Update route handlers to plumb hashes through. Replace the `/coordinator/sync/persona` handler:

```imba
  server.route 'POST', '/coordinator/sync/persona', do(params, body)
    unless body?.content?
      return { status: 400, body: { error: 'content required' } }
    try
      const curr = await connector.adapter.readSkills!
      const out = await connector.adapter.writeSkills({
        persona: body.content
        expected_persona_hash: body.expected_prev_hash
        skills: curr.skills.map do(s) { name: s.name, content: s.content }
      })
      { status: 200, body: { persona: out.persona } }
    catch e
      if e.constructor..name == 'ConflictError'
        return { status: 409, body: { error: 'conflict', actualHash: e.actualHash } }
      { status: 500, body: { error: e.message } }
```

Update `/coordinator/sync/skills` similarly to forward per-skill `expected_prev_hash`:

```imba
  server.route 'POST', '/coordinator/sync/skills', do(params, body)
    unless Array.isArray(body?.skills)
      return { status: 400, body: { error: 'skills array required' } }
    try
      const curr = await connector.adapter.readSkills!
      const out = await connector.adapter.writeSkills({
        persona: curr.persona?.content or ''
        skills: body.skills  # each entry may carry {name, content, expected_prev_hash}
      })
      { status: 200, body: { skills: out.skills } }
    catch e
      if e.constructor..name == 'ConflictError'
        return { status: 409, body: { error: 'conflict', actualHash: e.actualHash } }
      { status: 500, body: { error: e.message } }
```

- [ ] **Step 4:** Create `tests/routes.sync-conflict.test.imba`:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync, readFileSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"
import {personaPath} from "../src/sync.imba"
import {sha256Hex} from "../src/utils.imba"

let server = null
let port = 0
let home = null
const token = 'tok'

beforeEach do
  home = mkdtempSync(join(tmpdir!, 'aion-conf-home-'))
  const certP = join(home, 'cert.pem')
  const keyP = join(home, 'key.pem')
  await generateSelfSigned(certP, keyP)
  const { cert, key } = loadCertKey(certP, keyP)
  port = 19800 + Math.floor(Math.random! * 200)
  server = new Server({ port, cert, key, workspaceToken: token })
  const adapter = new StubAdapter(home)
  await adapter.configure({ persona: 'v1', skills: [], model: 'm', credentials: null })
  registerRoutes(server, { adapter })
  await server.start!

afterEach do
  await server.stop!

def post path, body
  fetch "https://127.0.0.1:{port}{path}",
    method: 'POST'
    headers: { 'content-type': 'application/json', 'authorization': "Bearer {token}" }
    body: JSON.stringify(body or {})
    tls: { rejectUnauthorized: false }

test "sync/persona returns 409 on stale expected_prev_hash", do
  const res = await post('/coordinator/sync/persona', { content: 'v2', expected_prev_hash: sha256Hex('stale') })
  expect(res.status).toBe(409)
  const b = await res.json!
  expect(b.actualHash).toBe(sha256Hex('v1'))
  # file on disk unchanged
  expect(readFileSync(personaPath(home), 'utf8')).toBe('v1')

test "sync/persona with current hash succeeds", do
  const correct = sha256Hex('v1')
  const res = await post('/coordinator/sync/persona', { content: 'v2', expected_prev_hash: correct })
  expect(res.status).toBe(200)
  expect(readFileSync(personaPath(home), 'utf8')).toBe('v2')
```

- [ ] **Step 5:** Run, expect pass.

- [ ] **Step 6:** Commit.

```bash
git add src/sync.imba src/adapter.imba src/claude-code-adapter.imba src/routes.imba tests/routes.sync-conflict.test.imba
git commit -m "feat(sync): enforce expected_prev_hash — return 409 on conflict"
```

## Task 6.4: `/coordinator/update` — config change trigger

This handles model / skills / persona changes pushed from AION in a single call. It unwraps the payload and routes each field to the adapter.

**Files:**
- Modify: `src/routes.imba`
- Create: `tests/routes.update.test.imba`

- [ ] **Step 1:** Append to `registerRoutes` in `src/routes.imba`:

```imba
  server.route 'POST', '/coordinator/update', do(params, body)
    body = body or {}
    try
      # Reconfigure: forward to adapter.configure
      if body.model or body.persona? or body.skills? or body.credentials?
        const curr = await connector.adapter.readSkills!
        await connector.adapter.configure({
          model: body.model
          persona: body.persona? ? body.persona : curr.persona?.content or ''
          skills: body.skills? ? body.skills : curr.skills.map do(s) { name: s.name, content: s.content }
          credentials: body.credentials
        })
        await connector.adapter.restart!
      { status: 200, body: { status: 'updated' } }
    catch e
      { status: 500, body: { status: 'error', error: e.message } }
```

- [ ] **Step 2:** Create `tests/routes.update.test.imba`:

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync, readFileSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"
import {personaPath} from "../src/sync.imba"

let server = null
let port = 0
let home = null
const token = 'tok'

beforeEach do
  home = mkdtempSync(join(tmpdir!, 'aion-up-'))
  const certP = join(home, 'cert.pem')
  const keyP = join(home, 'key.pem')
  await generateSelfSigned(certP, keyP)
  const { cert, key } = loadCertKey(certP, keyP)
  port = 19900 + Math.floor(Math.random! * 100)
  server = new Server({ port, cert, key, workspaceToken: token })
  const adapter = new StubAdapter(home)
  await adapter.configure({ persona: 'v1', skills: [], model: 'm1', credentials: null })
  registerRoutes(server, { adapter })
  await server.start!

afterEach do
  await server.stop!

test "update applies new persona via configure", do
  const res = await fetch "https://127.0.0.1:{port}/coordinator/update",
    method: 'POST'
    headers: { 'content-type': 'application/json', 'authorization': "Bearer {token}" }
    body: JSON.stringify({ persona: 'v2' })
    tls: { rejectUnauthorized: false }
  expect(res.status).toBe(200)
  expect(readFileSync(personaPath(home), 'utf8')).toBe('v2')
```

- [ ] **Step 3:** Run, expect pass.

- [ ] **Step 4:** Commit.

```bash
git add src/routes.imba tests/routes.update.test.imba
git commit -m "feat(routes): /coordinator/update — push new config to adapter"
```

---

# Wave 7 — Remaining CLI Commands

## Task 7.1: `status`, `logs`, `restart`, `stop`

**Files:**
- Modify: `src/cli.imba`

- [ ] **Step 1:** Add subcommands after `cmdInstall` in `src/cli.imba`:

```imba
import {exec} from './utils.imba'

switch sub
  when 'run' then await cmdRun!
  when 'install' then await cmdInstall(parseFlags(process.argv.slice(3)))
  when 'status' then await cmdStatus!
  when 'logs' then await cmdLogs(parseFlags(process.argv.slice(3)))
  when 'restart' then await cmdRestart(parseFlags(process.argv.slice(3)))
  when 'stop' then await cmdStop!
  when 'doctor' then await cmdDoctor!
  when 'uninstall' then await cmdUninstall!
  else usage!

def cmdStatus
  const st = readState!
  unless st
    console.error "no workspace state"
    process.exit(1)
  console.log "workspace_id: {st.workspace_id}"
  console.log "aion_url:     {st.aion_url}"
  console.log "port:         {st.port}"
  console.log "coordinator:  {st.coordinator.program} ({st.coordinator.model})"
  console.log "fingerprint:  {st.cert_fingerprint}"
  # Also show systemd unit status for the current user.
  const unit = "aion-connector.service"
  const s = await exec(['systemctl', '--user', 'is-active', unit])
  console.log "unit active:  {s.stdout.trim! or s.stderr.trim!}"

def cmdLogs flags
  const args = ['journalctl', '--user', '-u', 'aion-connector.service', '-n', flags.n or '100', '-f']
  const {spawn} = require('child_process')
  const p = spawn(args[0], args.slice(1), { stdio: 'inherit' })
  p.on('close', do(code) process.exit(code))

def cmdRestart flags
  const unit = flags.coordinator ? null : 'aion-connector.service'
  if flags.coordinator
    # trigger a local restart via SIGHUP; connector's run process catches it
    process.kill(await pidOfRun!, 'SIGHUP')
    return
  const r = await exec(['systemctl', '--user', 'restart', unit])
  process.exit(r.exitCode)

def cmdStop
  const r = await exec(['systemctl', '--user', 'stop', 'aion-connector.service'])
  process.exit(r.exitCode)

def pidOfRun
  const r = await exec(['systemctl', '--user', 'show', 'aion-connector.service', '--property=MainPID', '--value'])
  parseInt(r.stdout.trim!) or 0
```

Add missing imports at top: `import {readState} from './state.imba'`.

- [ ] **Step 2:** Add `SIGHUP` handling in `cmdRun` in `src/cli.imba` so `restart --coordinator` triggers `adapter.restart()`:

Inside `cmdRun`, after registering SIGTERM/SIGINT handlers, add:

```imba
  process.on('SIGHUP', do
    log "SIGHUP — restarting coordinator"
    c.adapter..restart!
  )
```

- [ ] **Step 3:** Create `tests/cli.status.test.imba` (just the status output — other commands need systemd and are covered by Wave 8 smoke test):

```imba
import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {exec} from "../src/utils.imba"
import {writeState} from "../src/state.imba"

let oldHome = null
let sandbox = null
beforeEach do
  sandbox = mkdtempSync(join(tmpdir!, 'aion-cli-'))
  oldHome = process.env.HOME
  process.env.HOME = sandbox
  writeState({
    workspace_id: 'abc-123'
    workspace_token: 'x'
    aion_url: 'https://aion.test'
    port: 7777
    cert_fingerprint: 'f'.repeat(64)
    coordinator: { program: 'stub', model: 'm', auth_mode: 'api_key' }
  })

afterEach do
  process.env.HOME = oldHome

test "status prints workspace_id + port", do
  # Run via the compiled dist/cli.js with `status` subcommand.
  # Rebuild first.
  const build = await exec(['bun', 'run', 'build'])
  if build.exitCode != 0
    throw new Error("build failed: {build.stderr}")
  const r = await exec(['node', 'dist/cli.js', 'status'], env: process.env)
  expect(r.stdout).toContain('abc-123')
  expect(r.stdout).toContain('7777')
```

- [ ] **Step 4:** Run, expect pass.

- [ ] **Step 5:** Commit.

```bash
git add src/cli.imba tests/cli.status.test.imba
git commit -m "feat(cli): status, logs, restart, stop commands"
```

## Task 7.2: `doctor`

**Files:**
- Modify: `src/cli.imba`

- [ ] **Step 1:** Add `cmdDoctor`:

```imba
def cmdDoctor
  const st = readState!
  if !st
    console.error "FAIL: no workspace state"
    process.exit(1)
  let ok = yes
  # AION reachability
  try
    const res = await fetch "{st.aion_url}/api/workspaces/{st.workspace_id}/heartbeat",
      method: 'POST'
      headers: { 'content-type': 'application/json', 'authorization': "Bearer {st.workspace_token}" }
      body: JSON.stringify({ external_ip: process.env.AION_EXTERNAL_IP or '0.0.0.0', coordinator_status: { state: 'starting' }, connector_version: require('./connector.imba').CONNECTOR_VERSION, timestamp: Date.now! })
    console.log "aion reach:    {res.status == 200 ? 'OK' : 'FAIL ' + res.status}"
    ok = ok and res.status == 200
  catch e
    console.log "aion reach:    FAIL ({e.message})"
    ok = no
  # Cert
  const { fingerprint } = require('./tls.imba')
  try
    const fp = await fingerprint(certPath!)
    const match = fp == st.cert_fingerprint
    console.log "tls cert:      {match ? 'OK' : 'FAIL (pin mismatch)'}"
    ok = ok and match
  catch e
    console.log "tls cert:      FAIL ({e.message})"
    ok = no
  # Adapter health
  try
    const adapter = makeAdapter(st.coordinator.program, process.env.HOME)
    const h = await adapter.health!
    console.log "coordinator:   {h.state == 'ready' ? 'OK' : 'FAIL ' + (h.detail or h.state)}"
    ok = ok and h.state == 'ready'
  catch e
    console.log "coordinator:   FAIL ({e.message})"
    ok = no
  process.exit(ok ? 0 : 1)
```

Add imports: `import {certPath} from './state.imba'`.

- [ ] **Step 2:** No automated test (requires real systemd + live AION). Manual verification covered by Wave 8 smoke test.

- [ ] **Step 3:** Commit.

```bash
git add src/cli.imba
git commit -m "feat(cli): doctor — reach AION, verify cert, probe adapter"
```

## Task 7.3: `uninstall`

**Files:**
- Modify: `src/cli.imba`

- [ ] **Step 1:** Add `cmdUninstall`:

```imba
def cmdUninstall
  const st = readState!
  # Notify AION (best effort)
  if st
    try
      await fetch "{st.aion_url}/api/workspaces/{st.workspace_id}",
        method: 'DELETE'
        headers: { 'authorization': "Bearer {st.workspace_token}" }
    catch
      console.error "warning: could not notify AION — proceeding anyway"
  # Stop + disable systemd unit
  await exec(['systemctl', '--user', 'stop', 'aion-connector.service'])
  await exec(['systemctl', '--user', 'disable', 'aion-connector.service'])
  # Delete unit file
  const unit = join(process.env.HOME or '', '.config/systemd/user/aion-connector.service')
  try require('fs').unlinkSync(unit)
  catch
    ;
  # Wipe state
  const {rmSync} = require('fs')
  rmSync(stateDir!, recursive: yes, force: yes)
  rmSync(join(process.env.HOME or '', 'coordinator'), recursive: yes, force: yes)
  console.log "uninstalled — re-run installer with --workspace-id to re-enroll"
```

Add imports: `import {stateDir} from './state.imba'`, `import {join} from 'path'`.

- [ ] **Step 2:** Commit.

```bash
git add src/cli.imba
git commit -m "feat(cli): uninstall — notify AION, tear down unit, wipe state"
```

---

# Wave 8 — Installer + systemd + End-to-End Smoke Test

## Task 8.1: systemd unit template

**Files:**
- Create: `bin/aion-connector.service.tpl`

- [ ] **Step 1:** Create `bin/aion-connector.service.tpl`:

```ini
[Unit]
Description=AION Connector (workspace {{WORKSPACE_SLUG}})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/aion-connector run
Restart=on-failure
RestartSec=5
Environment=HOME={{USER_HOME}}
Environment=AION_EXTERNAL_IP={{EXTERNAL_IP}}

[Install]
WantedBy=default.target
```

- [ ] **Step 2:** Commit.

```bash
git add bin/aion-connector.service.tpl
git commit -m "feat(systemd): unit template"
```

## Task 8.2: Bash installer — preflight + user creation + cert + systemd

**Files:**
- Create: `bin/install.sh`

- [ ] **Step 1:** Create `bin/install.sh`. It runs as root (via sudo) and provisions everything:

```bash
#!/usr/bin/env bash
set -euo pipefail

# aion-connector installer.
# Usage: curl .../install.sh | sudo bash -s -- --token X --aion URL --program claude-code \
#          --model sonnet-4.6 --auth-mode api_key [--api-key K] [--workspace-id ID] \
#          [--port N] [--persona-file F] [--skills-json-file F]

LOG=/tmp/aion-connector-install-$$.log
exec > >(tee -a "$LOG") 2>&1
echo "== aion-connector installer, log: $LOG =="

TOKEN=""; AION=""; PROGRAM=""; MODEL=""; AUTH_MODE=""; API_KEY=""
WORKSPACE_ID=""; PORT=""; PERSONA_FILE=""; SKILLS_JSON_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)            TOKEN="$2"; shift 2 ;;
    --aion)             AION="$2"; shift 2 ;;
    --program)          PROGRAM="$2"; shift 2 ;;
    --model)            MODEL="$2"; shift 2 ;;
    --auth-mode)        AUTH_MODE="$2"; shift 2 ;;
    --api-key)          API_KEY="$2"; shift 2 ;;
    --workspace-id)     WORKSPACE_ID="$2"; shift 2 ;;
    --port)             PORT="$2"; shift 2 ;;
    --persona-file)     PERSONA_FILE="$2"; shift 2 ;;
    --skills-json-file) SKILLS_JSON_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

for v in TOKEN AION PROGRAM MODEL AUTH_MODE; do
  [ -n "${!v}" ] || { echo "missing --${v,,}"; exit 2; }
done

# --- preflight ---
echo "-- preflight --"
command -v openssl >/dev/null || { echo "openssl required"; exit 1; }
command -v systemctl >/dev/null || { echo "systemd required"; exit 1; }
command -v node >/dev/null || { echo "node required"; exit 1; }
command -v npm >/dev/null || { echo "npm required"; exit 1; }

# --- user ---
SLUG="${WORKSPACE_ID:-$(openssl rand -hex 3)}"
USER="aion-$SLUG"
USER_HOME="/home/$USER"
echo "-- provisioning user $USER --"
if ! id "$USER" >/dev/null 2>&1; then
  useradd -m -d "$USER_HOME" -s /bin/bash "$USER"
fi

# Rollback helper
rollback() {
  echo "!! install failed — rolling back"
  systemctl --user -M "$USER@" stop aion-connector.service 2>/dev/null || true
  systemctl --user -M "$USER@" disable aion-connector.service 2>/dev/null || true
  userdel -r "$USER" 2>/dev/null || true
  exit 1
}
trap rollback ERR

# --- detect external IP ---
EXTERNAL_IP="$(curl -fsS https://ifconfig.me/ip || echo '0.0.0.0')"

# --- install connector bin into /usr/local/bin ---
# Assumes installer is extracted next to a dist/cli.js + package.json tarball.
# For manual bring-up during development, the user can skip and `npm install -g` ahead of time.
echo "-- installing aion-connector binary --"
if [ ! -x /usr/local/bin/aion-connector ]; then
  npm install -g aion-connector
fi

# --- prep coordinator files ---
PERSONA_PATH=""
if [ -n "$PERSONA_FILE" ] && [ -f "$PERSONA_FILE" ]; then
  PERSONA_PATH="$USER_HOME/.install-persona.md"
  cp "$PERSONA_FILE" "$PERSONA_PATH"
  chown "$USER:$USER" "$PERSONA_PATH"
fi
SKILLS_PATH=""
if [ -n "$SKILLS_JSON_FILE" ] && [ -f "$SKILLS_JSON_FILE" ]; then
  SKILLS_PATH="$USER_HOME/.install-skills.json"
  cp "$SKILLS_JSON_FILE" "$SKILLS_PATH"
  chown "$USER:$USER" "$SKILLS_PATH"
fi

# --- enable user linger so systemd --user starts at boot ---
loginctl enable-linger "$USER"

# --- run install subcommand as the user ---
echo "-- registering workspace --"
INSTALL_ARGS=(--token "$TOKEN" --aion "$AION" --program "$PROGRAM" --model "$MODEL" --auth-mode "$AUTH_MODE" --external-ip "$EXTERNAL_IP")
[ -n "$API_KEY" ]       && INSTALL_ARGS+=(--api-key "$API_KEY")
[ -n "$WORKSPACE_ID" ]  && INSTALL_ARGS+=(--workspace-id "$WORKSPACE_ID")
[ -n "$PORT" ]          && INSTALL_ARGS+=(--port "$PORT")
[ -n "$PERSONA_PATH" ]  && INSTALL_ARGS+=(--persona "$PERSONA_PATH")
[ -n "$SKILLS_PATH" ]   && INSTALL_ARGS+=(--skills-json "$SKILLS_PATH")

sudo -u "$USER" -H env AION_EXTERNAL_IP="$EXTERNAL_IP" /usr/local/bin/aion-connector install "${INSTALL_ARGS[@]}"

# --- systemd unit ---
echo "-- installing systemd user unit --"
UNIT_DIR="$USER_HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
chown -R "$USER:$USER" "$USER_HOME/.config"
# Render template
TPL="$(dirname "$0")/aion-connector.service.tpl"
[ -f "$TPL" ] || TPL="/usr/local/share/aion-connector/aion-connector.service.tpl"
sed -e "s|{{WORKSPACE_SLUG}}|$SLUG|g" \
    -e "s|{{USER_HOME}}|$USER_HOME|g" \
    -e "s|{{EXTERNAL_IP}}|$EXTERNAL_IP|g" \
    "$TPL" > "$UNIT_DIR/aion-connector.service"
chown "$USER:$USER" "$UNIT_DIR/aion-connector.service"

sudo -u "$USER" -H XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user daemon-reload
sudo -u "$USER" -H XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user enable --now aion-connector.service

# cleanup temp files
rm -f "$PERSONA_PATH" "$SKILLS_PATH" 2>/dev/null || true

echo "== done. log: $LOG =="
trap - ERR
```

Mark executable:
```bash
chmod +x bin/install.sh
```

- [ ] **Step 2:** Commit.

```bash
git add bin/install.sh
git commit -m "feat(installer): bash installer with preflight + rollback + systemd"
```

## Task 8.3: End-to-end smoke test

Not a bun test — a scripted walkthrough to run manually on a fresh Ubuntu VM (or local Docker). Documenting exact steps in a `docs/` script so the executor (and future you) can verify Phase 1 acceptance.

**Files:**
- Create: `docs/superpowers/smoke-tests/2026-04-17-workspace-registration.md`

- [ ] **Step 1:** Create the file:

```markdown
# Phase 1 Smoke Test — Workspace Registration + Coordinator Provisioning

## Prereqs
- Ubuntu 22.04 test VM with public IP, port 7700-7799 open, `sudo` available.
- AION staging instance with the Phase 1 API deployed.

## Steps

1. **Create workspace in AION UI**, choose claude-code + API-key mode, paste your Anthropic key.
   Copy the installer snippet.

2. **On the VM, run the snippet.** It should:
   - Create user `aion-<slug>`
   - Install claude-code globally
   - Generate TLS cert
   - Register with AION
   - Start systemd user service
   - Print `done. log: /tmp/aion-connector-install-<pid>.log`

3. **Verify from AION UI:** Workspace goes `online` within 2 minutes.

4. **Check from VM shell:**
   ```bash
   sudo -u aion-<slug> -H aion-connector status
   # expect: workspace_id, port, coordinator: claude-code (sonnet-4.6), unit active: active
   sudo -u aion-<slug> -H aion-connector doctor
   # expect: all OK, exit 0
   ```

5. **Edit persona in AION UI**, click save.
   On VM: `cat /home/aion-<slug>/coordinator/persona.md` → reflects new content.

6. **Stop the connector:**
   ```bash
   sudo -u aion-<slug> -H aion-connector stop
   ```
   AION UI → workspace transitions to `offline` within 90 s.

7. **Restart:**
   ```bash
   sudo -u aion-<slug> -H systemctl --user start aion-connector.service
   ```
   AION UI → back to `online` within ~30 s.

8. **Re-enroll** (simulate crashed VPS recovered on new box):
   - In AION UI, click "Re-enroll" on the workspace. New enrollment token.
   - On VM, `sudo -u aion-<slug> -H aion-connector uninstall`
   - Run installer snippet again with `--workspace-id <same>`.
   - AION UI → same workspace_id, fresh fingerprint, back online.

9. **OAuth path** (if coordinator supports it):
   - Create another workspace with auth_mode=oauth.
   - Run installer; workspace shows `provisioning → online, coordinator needs auth`.
   - Click Authorize, follow URL, paste code.
   - UI → coordinator ready.

10. **Uninstall cleanup:**
    ```bash
    sudo -u aion-<slug> -H aion-connector uninstall
    ```
    - AION UI: workspace `decommissioned`.
    - `id aion-<slug>` → no such user.
    - `/home/aion-<slug>` → gone.
```

- [ ] **Step 2:** Commit.

```bash
git add docs/superpowers/smoke-tests/2026-04-17-workspace-registration.md
git commit -m "docs: Phase 1 end-to-end smoke test runbook"
```

## Task 8.4: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** Read current README:

```bash
cat README.md
```

- [ ] **Step 2:** Replace its contents with:

```markdown
# aion-connector

Per-workspace service that runs on a VPS, hosts an AI coordinator (claude-code, …), and is driven by AION.

## Install

On an Ubuntu VPS with sudo:

```bash
curl -fsSL <AION_URL>/install.sh | sudo bash -s -- \
  --token <ENROLLMENT_TOKEN> --aion <AION_URL> \
  --program claude-code --model sonnet-4.6 \
  --auth-mode api_key --api-key <ANTHROPIC_KEY>
```

## Commands

```
aion-connector status     # workspace id, port, coordinator state, unit status
aion-connector logs       # journalctl --user -u aion-connector -f
aion-connector restart    # restart whole connector
aion-connector restart --coordinator   # restart only the coordinator
aion-connector stop
aion-connector doctor     # diagnose AION reachability, cert, coordinator
aion-connector uninstall  # notify AION, tear down unit + user
```

## Development

```bash
bun run build          # compile src → dist
bun run test           # run full test suite
CLAUDE_CODE_INSTALLED=1 bun run test  # also run real-claude integration tests
```

## Design

See `docs/superpowers/specs/2026-04-17-workspace-registration-design.md`.
```

- [ ] **Step 3:** Commit.

```bash
git add README.md
git commit -m "docs: rewrite README for Phase 1 interface"
```

---

# Final Self-Review

After all waves complete, run:

```bash
bun run test
```

All tests should pass (real-claude tests skipped unless `CLAUDE_CODE_INSTALLED=1`). Then walk through the smoke test at least once on a test VPS before declaring Phase 1 done.

Acceptance criteria recap (from spec §12):

1. ✅ Install via one-line snippet → workspace online within 2 min — Wave 8 smoke step 2-3.
2. ✅ OAuth path works — Wave 6 OAuth routes + Wave 5 adapter + smoke step 9.
3. ✅ Edit persona/skills in UI applies to VPS — Wave 6 sync routes + smoke step 5.
4. ✅ Killing connector → offline within 90 s — Wave 3 heartbeat + mock-AION state transitions + smoke step 6.
5. ✅ Uninstall cleans up — Task 7.3 + smoke step 10.
6. ✅ Doctor reports green / pinpoints — Task 7.2 + smoke step 4.
7. ✅ Re-enroll with same workspace_id preserves state — CLI install accepts `--workspace-id` + smoke step 8.
