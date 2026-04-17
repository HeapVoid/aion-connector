# Phase 1 — Workspace Registration + Coordinator Provisioning

**Status:** Design approved 2026-04-17. Ready for implementation plan.
**Scope:** First phase of a larger AION rework. Covers end-to-end lifecycle of a single Workspace on a single VPS, including its coordinator.

## 1. Context and Goals

AION is evolving into a platform where a **Project** owns one or more **Workspaces**. Each Workspace is a dedicated VPS running an `aion-connector` service plus a **Coordinator** — an AI coding agent (claude-code, qwen-code, codex, etc.) that the admin configures with a persona and skills. Future phases add per-workspace sub-agents, in-chat Stages, and a marketplace of third-party coordinators/agents.

This phase delivers the foundation: an admin can create a Workspace in the AION UI, run a one-line installer on a VPS, and end up with an online Workspace whose coordinator is provisioned, authorized, and reachable from AION.

### Non-goals (for this phase)

- Sub-agents (Phase 4), Stages (Phase 5), marketplace (Phase 6).
- Chat↔Workspace routing and @mentions (Phase 3).
- Coordinators other than `claude-code`. The adapter interface is designed to admit others, but only one adapter ships in Phase 1.
- NAT traversal / outbound-WS transport. See §11.

### Transition strategy

Greenfield. The current `aion-connector` config model (`aion.config.json` with `projects:{}` map, per-project tokens, plain HTTP on 7777) is being replaced entirely. No backward compatibility is required — existing installations can be wiped and re-enrolled under the new flow.

## 2. Architecture Overview

### 2.1 Entities

```
Project
  └── Workspace (1:N)
        ├── Coordinator (1:1, required)
        └── Agents (0:N, future — Phase 4)
```

A **Workspace** is a physical deployment: one VPS, one OS user, one `aion-connector` process, one Coordinator. Multiple Workspaces for the same Project or different Projects may coexist on a single VPS — each lives under its own OS user (`aion-<slug>`) with its own `$HOME`, its own connector, its own systemd unit, its own port.

### 2.2 Transport

**AION → Connector:** direct HTTPS over public IP. The connector exposes a TCP port (auto-selected at install time from the 7700–7799 range, overridable with `--port`) with a self-signed TLS certificate. AION pins the cert fingerprint (TOFU) at registration and verifies it on every call. Authorization is by `workspace_token` (long-lived bearer) sent in `Authorization: Bearer …`.

**Connector → AION:** plain HTTPS to the AION API (standard public TLS). Authorization same way.

**Rationale:** direct IP:port avoids per-VPS DNS and public TLS certificates. A shared wildcard cert and proxy layer aren't necessary because Stages (browser-facing UI served by the coordinator) will be proxied through AION's own domain in Phase 5 — that's how we avoid CORS and origin trust issues without DNS per VPS.

### 2.3 Prerequisites

The VPS must have:

- A public IPv4 address (dynamic OK — the connector re-reports it on heartbeat; behind NAT **not supported** in Phase 1).
- Outbound HTTPS to the AION API.
- Inbound TCP on one port in 7700–7799 (or the `--port` override) open at the firewall.
- `sudo` available to the installer (needed for user creation and systemd).
- systemd as init. Linux only.

If any prerequisite is unmet, the installer aborts early with a clear message and does **not** create partial state.

## 3. Components

### 3.1 `aion-connector` (on VPS)

Long-running service. Responsibilities:

- Heartbeat to AION (~30 s).
- Accept `/coordinator/update`, `/coordinator/oauth/start`, `/coordinator/oauth/complete`, `/coordinator/sync/*`, `/invoke` calls from AION over HTTPS.
- Own the Coordinator lifecycle via the adapter (start/stop/restart, health probes).
- Apply config changes (persona, skills, model, credentials) to the coordinator's filesystem and restart/reload it.
- Relay OAuth flows.

### 3.2 Coordinator adapter

A thin abstraction layer between the connector and the actual coordinator CLI. Phase 1 ships one adapter: `claude-code`. The interface:

```
installCoordinator({program, version}) -> void       # idempotent; returns once ready-to-configure
configure({model, credentials, personaMd, skills}) -> void   # writes files into $HOME/coordinator/
start() / stop() / restart()
health() -> { state: 'ready' | 'starting' | 'error', detail? }
startAuth() -> { url }                               # returns null if program uses API key only
submitAuthCode({code}) -> { status: 'authorized' | 'error', error? }
writeSkills(skills)                                  # push direction; returns content hashes
readSkills() -> { persona: {hash, content}, skills: {name, hash, content}[] }  # pull direction
```

Each adapter maps these calls to the underlying CLI's commands, config paths, and auth ceremony. The file layout under `$HOME/coordinator/` is standardized across adapters so the connector's sync logic is adapter-agnostic.

### 3.3 AION server side

Not implemented in this repo, but this design locks in the API contract. In addition to existing Project/Chat APIs, AION gains:

- `POST /api/workspaces` — creates a Workspace record, returns `{workspace_id, enrollment_token, installer_snippet}`.
- `POST /api/workspaces/register` — called by the connector once with the enrollment token; returns `workspace_token`.
- `POST /api/workspaces/:id/heartbeat` — called every ~30 s.
- `POST /api/workspaces/:id/re-enroll` — UI action, issues a new `enrollment_token` bound to the existing `workspace_id`.
- `DELETE /api/workspaces/:id` — marks `decommissioned`.

## 4. Registration Flow

1. **Admin creates Workspace in AION UI**, choosing the coordinator config:
   - `program` (Phase 1: `claude-code`)
   - `model`
   - `persona` (markdown)
   - `skills` (list of named markdown files)
   - `auth_mode` (`api_key` or `oauth`)
   - if `api_key`: the key itself (stored encrypted in AION)
   AION generates `workspace_id` (UUID) and `enrollment_token` (one-time, 1h TTL). The UI displays the installer snippet — a `curl … | sudo bash` line carrying `--token <enrollment_token> --aion <url>` and the coordinator spec.

2. **Admin runs the installer on the VPS.** Installer, under sudo:
   - Verifies prerequisites (§2.3). Aborts cleanly on failure.
   - Creates OS user `aion-<slug>` with `$HOME=/home/aion-<slug>`.
   - Installs the connector binary and the coordinator CLI per-user.
   - Generates a self-signed TLS cert for the connector (cert + key at `$HOME/.config/aion-connector/tls/`, mode 600, owned by the OS user).
   - Picks a free port in 7700–7799 (or uses `--port`). Writes it to state.
   - Writes the coordinator spec to disk (persona, skills, config).
   - If `auth_mode=api_key`, writes credentials to `$HOME/coordinator/credentials.env` (600).
   - Writes the systemd unit and starts it.
   - If any step fails, rolls back what it created (see §8.2).

3. **Connector starts, registers.** Once the coordinator health check returns `ready` or `starting`, the connector calls `POST /api/workspaces/register` with:
   ```
   {
     enrollment_token,
     external_ip,
     port,
     cert_fingerprint,   // SHA-256 of DER cert, lowercase hex, 64 chars
     coordinator_status, // { state: ready|starting|error, program, version }
     connector_version
   }
   ```
   AION validates the enrollment token, stores the quadruple `(ip, port, fingerprint, workspace_token)`, invalidates the enrollment token, and returns `workspace_token`. The connector saves it to state.

4. **UI shows Workspace online.** If `auth_mode=oauth`, UI prompts the admin to authorize now (§5). Otherwise the Workspace is immediately usable.

5. **Heartbeat loop** begins (§6).

## 5. OAuth Flow (coordinators with subscription auth)

Used when the coordinator uses a login-based subscription (Claude Pro, ChatGPT Plus) rather than an API key. Two-step flow proxied through the connector; OAuth tokens never leave the VPS.

1. Admin clicks **Authorize** in UI.
2. AION → connector: `POST /coordinator/oauth/start`.
3. Connector calls `adapter.startAuth()`, captures the login URL from the adapter. Returns `{url}` to AION.
4. UI displays the URL and a code input field.
5. Admin opens URL in their own browser, logs in with the provider, receives an authorization code.
6. Admin pastes the code in UI. AION → connector: `POST /coordinator/oauth/complete` with `{code}`.
7. Connector calls `adapter.submitAuthCode({code})`. Adapter completes OAuth, writes provider tokens to its own private store (e.g., `~/.claude/credentials.json`). Connector replies `authorized`.

Re-authorization on token expiry: UI re-triggers the same flow. The connector is stateless about OAuth — only the adapter's private store holds tokens.

## 6. Heartbeat and Lifecycle

### 6.1 Heartbeat payload

Every ~30 s the connector POSTs to AION:

```
{
  workspace_token,
  external_ip,          // re-reported; AION updates record if changed
  coordinator_status,   // { state, detail?, version }
  connector_version,
  timestamp
}
```

**Fingerprint is not sent on heartbeat.** TLS pinning on every AION→connector call already detects a changed cert. When the connector rotates its cert intentionally (rare; Phase 1 has no automation for this), it sends a one-shot `POST /api/workspaces/:id/cert-rotated` with the new fingerprint signed by the current `workspace_token`.

### 6.2 Lifecycle states

| State | Meaning |
|---|---|
| `provisioning` | `enrollment_token` issued, not yet registered. Enters this state when the Workspace is created in AION. |
| `online` | Heartbeat fresh (< 60 s), coordinator `ready`. |
| `degraded` | Heartbeat fresh, coordinator `error` (crashed, auth expired, adapter error). |
| `offline` | No heartbeat for > 60 s (2× interval). |
| `decommissioned` | Admin deleted. Chat history retained in AION; connector/OS user removed from VPS. |

Offline threshold: 60 s. Heartbeat interval: 30 s. `degraded` is triggered by either a coordinator health-check failure or a crash-loop detection (adapter process exiting 3 times within 60 s — the connector stops auto-restarting and reports `degraded` until the admin intervenes via `restart` or config change).

## 7. Two-way Sync

Coordinator config lives on the VPS under a standardized layout:

```
$HOME/
  .config/aion-connector/
    workspace.json       # workspace_id, workspace_token, port, cert_fingerprint
    tls/                 # cert.pem, key.pem (600)
  coordinator/
    persona.md
    skills/
      <skill_name>.md ...
    credentials.env      # API key mode only, 600
    config.json          # program, model
```

### 7.1 Sync directions

| Field | Source of truth | AION → Connector | Connector → AION |
|---|---|---|---|
| `persona.md` | VPS | push on save | pull before open-for-edit |
| `skills/*` | VPS | push on save | pull before open-for-edit |
| coordinator memory files (if the coordinator writes its own) | VPS | push (only if admin edits in UI) | pull for view/edit |
| API key | AION (encrypted) | push | never |
| OAuth tokens | VPS (adapter private store) | OAuth flow | never |
| `program`, `model` | AION | push (may trigger coordinator reinstall) | — |

### 7.2 Versioning and conflicts

Every synced file carries a SHA-256 content hash. On pull, AION stores both content and hash. On save, AION sends `{content, expected_prev_hash}` — the connector rejects with HTTP 409 if the file on disk now has a different hash (coordinator modified it since pull). UI then presents the admin with two options in Phase 1: **overwrite** (last-write-wins) or **cancel** (re-fetch, re-edit). A 3-way merge option is deferred to Phase 3.

## 8. CLI

Admin-facing commands, all run as the workspace OS user (installer puts a sudo wrapper on `PATH` so `sudo aion-connector …` works):

| Command | Purpose |
|---|---|
| `aion-connector install --token X --aion URL [--workspace-id ID] [--port N]` | Installer-internal; not for direct use. |
| `aion-connector status` | `workspace_id`, AION URL, port, last heartbeat, coordinator state. |
| `aion-connector logs [--coordinator\|--connector]` | Tail logs. |
| `aion-connector restart [--coordinator]` | Restart connector or only the coordinator. |
| `aion-connector stop` | Stop systemd unit. |
| `aion-connector doctor` | Diagnostics: AION reachability, TLS cert, coordinator health, adapter auth, versions. |
| `aion-connector uninstall` | Notify AION → remove systemd unit, state files, OS user and `$HOME`. AION marks Workspace `decommissioned`. |

### 8.1 Identity and change handling

- `workspace_id` is stable across reinstalls. Stored in `workspace.json`.
- IP/port changes: connector detects at each heartbeat and reports; AION updates record. Token unchanged.
- Cert fingerprint change: AION rejects (pin mismatch); UI prompts admin to confirm a new pin. Manual re-pin only.
- Re-enroll (reinstall on a crashed VPS): UI button issues a new `enrollment_token` tied to the existing `workspace_id`. Installer run with `--workspace-id <existing>` reuses the record, refreshes IP/port/cert/`workspace_token`. Chat history and coordinator config preserved server-side.

### 8.2 Installer recovery

Installer writes a step log to `/tmp/aion-connector-install-<pid>.log`. On failure it rolls back in reverse order: stops/disables systemd unit, deletes unit file, removes `$HOME`, removes the OS user, invalidates the enrollment token via AION (best-effort; if unreachable the token simply expires). Installer always exits non-zero with the failure reason and path to the full log.

## 9. Security Model

- **Workspace token** is a random 256-bit token, stored in `workspace.json` (mode 600, owned by the OS user). Rotatable via UI — AION issues new token, pushes to connector over the existing channel, connector updates state, replies OK, AION invalidates old.
- **Enrollment token** is one-time, 1 h TTL, bound to `workspace_id`. Invalidated on first successful register call.
- **TLS:** self-signed cert per Workspace. Fingerprint (SHA-256 of DER, lowercase hex, 64 chars) pinned by AION at registration. AION verifies fingerprint on every call; mismatch → refuse.
- **Isolation:** each Workspace runs as its own unprivileged OS user. Files are 600, owned by that user. The connector does **not** run as root.
- **Credentials:**
  - API keys: encrypted at rest in AION, pushed over TLS, written to `credentials.env` (600) by the connector. Never read back to AION.
  - OAuth tokens: only ever in the adapter's private store on the VPS. Proxied 2-step flow so the AION server never sees them.

## 10. Open Design Details (resolved)

- **Port selection:** installer picks the first free TCP port in 7700–7799 via an OS bind test. `--port N` overrides. Port is persisted in `workspace.json` and reported at register.
- **Cert rotation:** not automated in Phase 1. Manual re-pin only, via UI confirmation.
- **Degraded triggers:** (a) coordinator health probe returns `error`; (b) crash-loop detector (≥3 exits in 60 s) — connector stops auto-restarting and reports `degraded` in the next heartbeat.
- **Merge strategy:** Phase 1 implements overwrite + cancel only. 3-way merge is a Phase 3 deliverable.
- **Sudo wrapper:** installer writes `/usr/local/bin/aion-connector` that `sudo -u aion-<slug>`-runs the per-user binary. `aion-connector-<slug>` is available directly when targeting a specific Workspace on a multi-tenant host.

## 11. Strategic Notes (non-goals worth recording)

- **Outbound-WS transport.** NAT'd VPS and egress-only networks will need the connector to open a persistent WebSocket to AION and receive calls in-band. The adapter and sync layer are designed so this is a drop-in transport change later — API surface doesn't depend on inbound.
- **Multi-adapter support.** The interface in §3.2 is meant to admit `qwen-code`, `codex`, and others without breaking `claude-code`. Phase 2 introduces the second adapter to validate the abstraction.
- **Stages via AION-domain proxy.** When Phase 5 lands, stage iframes will be served at `https://aion.tld/w/<workspace_id>/stage/<stage_id>/…` and proxied to the connector. This avoids per-VPS DNS and resolves CORS cleanly.

## 12. Acceptance Criteria

Phase 1 is done when:

1. Admin can create a Workspace in the AION UI with a `claude-code` coordinator (API-key mode or OAuth), run the installer on a fresh VPS, and see the Workspace go `online` in the UI within 2 minutes.
2. For OAuth coordinators, the authorize flow completes successfully and the coordinator's health returns `ready`.
3. Admin can edit persona/skills in the UI; changes apply on the VPS within seconds; the coordinator picks them up on next restart or hot-reload.
4. Killing the connector process on the VPS causes the Workspace to go `offline` within 90 s.
5. `aion-connector uninstall` removes the OS user, `$HOME`, and systemd unit, and the Workspace appears as `decommissioned` in AION.
6. `aion-connector doctor` reports green on a healthy install and pinpoints the failing component on a broken one.
7. Running the installer a second time with the same `--workspace-id` (after a clean uninstall or a crashed VPS) successfully re-enrolls without losing server-side state.
