# Phase 2 — Workspace Server-Side & UI (MVP) Design

**Status:** draft
**Depends on:** Phase 1 (`2026-04-17-workspace-registration-design.md`)
**Date:** 2026-04-17

## 1. Goal & Scope

Close the loop on workspace provisioning: an admin creates a workspace in the UI, copies the installer snippet, runs it on a fresh VPS, and within ≤2 minutes sees the workspace transition to `online` in the UI. Nothing more in this phase.

Phase 1 defined the connector and the client side of the contract. It also specified the server endpoints as a contract only — no server implementation, no UI. This phase implements that server contract in `aion-pocketbase` and the admin UI in `aion-application`, and removes the legacy `servers`/`agents`/`agent_sessions` model entirely.

### 1.1 In Scope

- **aion-pocketbase**
  - Migration `019_workspace_model.imba`: drop legacy collections `agents`, `agent_sessions`, `servers`; create `workspaces`.
  - Six HTTP endpoints in `api.workspaces.pb.imba` (create, installer, register, heartbeat, re-enroll, delete).
  - Cron `workspace-lifecycle` in `cron.workspace-lifecycle.pb.imba` — runs every 30s, flips stale `online`/`degraded` → `offline`.
  - Static `pb_public/install.sh` (byte-for-byte copy of `aion-connector/bin/install.sh`).
  - Delete legacy backend file `api.servers.pb.imba`.
- **aion-application**
  - New page `/projects/:id/workspaces` with list, detail, create modal, re-enroll, delete, installer-snippet view.
  - Realtime subscription on `workspaces` collection.
  - Clean-sweep removal of all legacy UI: `server-settings-popup.imba`, `agent-console.imba`, `slash-commands.imba`, and all references in other files.
- **aion-connector** — no changes (Phase 1 already implements the client side).

### 1.2 Out of Scope (Future Phases — Roadmap)

Catalogued to avoid forgetting:

| Phase | Topic | What it adds |
|---|---|---|
| 3 | Coordinator sync | Persona/skills/OAuth stored in pocketbase, pushed to connector via heartbeat response. |
| 4 | Chat ↔ workspace routing | `chats.workspaceId`, message tunneling through connector's TLS channel. |
| 5 | Sub-agents | Reintroduce "agent" as a workspace sub-entity spawned by coordinator. |
| 6 | Stages | Workflow orchestration of agents inside a workspace. |
| 7 | Marketplace | Public personas/skills. |
| 8 | Multi-adapter | `gemini-cli`, `codex` alongside `claude-code`. |
| 9 | Outbound-WS transport | Fallback for VPS behind NAT without public IP. |

### 1.3 Acceptance Criteria

1. Admin creates a workspace from the UI in project P.
2. UI shows installer snippet with an embedded `enrollment_token` valid for 15 minutes.
3. Admin runs snippet on a clean VPS: `curl ... | sudo bash -s -- ...`.
4. Within 2 minutes, UI state transitions `provisioning → online` (via pocketbase realtime).
5. Admin shuts the VPS off; within ≤90 seconds UI shows `online → offline`.
6. Admin presses "Re-enroll", receives a new snippet, reinstalls on a fresh VPS; state returns to `online`.
7. Admin presses "Delete"; record disappears from UI (realtime), `DELETE /api/workspaces/:id` returned 200.
8. No legacy references to `agents`, `agent_sessions`, `servers`, `slashCommand`, or `agentMemory` remain in `aion-application/src/`.

## 2. Architecture

Three repositories, each gets a focused change set:

```
┌─────────────────────┐        ┌──────────────────────┐        ┌──────────────────┐
│  aion-application   │        │   aion-pocketbase    │        │  aion-connector  │
│   (SPA, Imba)       │  ────▶ │  (hooks, Imba→JS)    │ ◀────▶ │  (VPS, Imba)     │
│                     │        │                      │        │                  │
│  /workspaces page   │        │  workspaces coll.    │        │  (done in P1)    │
│  installer modal    │        │  6 HTTP endpoints    │        │                  │
│  re-enroll button   │        │  lifecycle cron 30s  │        │                  │
└─────────────────────┘        │  static install.sh   │        └──────────────────┘
                               └──────────────────────┘
       ▲                                   ▲                            ▲
       │ pocketbase JWT                    │ enrollment_token /         │ mTLS + fp pin
       │ (admin UI)                        │ workspace_token bearer     │ (runtime, phase 4)
       └───────────────────────────────────┘ (connector control plane)  │
```

Three auth channels, each with its own middleware:
1. **UI → pocketbase:** pocketbase JWT + `requireProjectMember(projectId)`.
2. **Connector → pocketbase (first contact):** one-time `enrollment_token`, hashed at rest, TTL 15 min, consumed on use.
3. **Connector → pocketbase (steady state):** `Bearer workspace_token`, hashed at rest, verified by `sha256(bearer) == workspaceTokenHash`.

`DELETE /api/workspaces/:id` accepts either JWT or workspace_token.

## 3. Data Model

### 3.1 Collection `workspaces`

Created by migration 019. All built-in rules (`list/view/create/update/delete`) set to `null` — only superusers can touch via auto-CRUD. All access for UI and connector goes through custom endpoints. This protects `*TokenHash` fields from leaking through auto-generated list API.

Fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `projectId` | relation → `projects` | yes | `cascadeDelete: true` |
| `name` | text | yes | max 80 |
| `slug` | text | yes | 3–40 chars, `^[a-z0-9-]+$`, globally unique (drives `USER=aion-$SLUG` on VPS) |
| `createdBy` | relation → `users` | yes | |
| `state` | select | yes | `provisioning` \| `online` \| `offline` \| `degraded` \| `decommissioned` |
| `lastHeartbeatAt` | date | no | null until first heartbeat |
| `externalIp` | text | no | written by `/register` |
| `port` | number | no | written by `/register` |
| `certFingerprint` | text | no | written by `/register`, SHA-256 in `aa:bb:...` form |
| `enrollmentTokenHash` | text | no | sha256 of raw token; null after consume |
| `enrollmentTokenExpiresAt` | date | no | null after consume |
| `workspaceTokenHash` | text | no | sha256 of raw token |
| `connectorVersion` | text | no | reported by connector |
| `program` | select | yes | `claude-code` (extended in phase 8) |
| `model` | text | yes | e.g. `sonnet-4.6` |
| `authMode` | select | yes | `api_key` \| `oauth` (only `api_key` wired in MVP) |

**No `apiKey` field.** Pass-through model: admin types it in UI, UI inlines it in the installer snippet, connector writes it to `$HOME/coordinator/credentials.env` (mode 0600) on the VPS. Pocketbase never sees or stores it.

Indexes:
- `idx_workspaces_project` on `(projectId)` — list by project.
- `idx_workspaces_slug` UNIQUE on `(slug)` — global uniqueness.
- `idx_workspaces_state_heartbeat` on `(state, lastHeartbeatAt)` — makes the cron scan cheap.

### 3.2 Lifecycle

```
[UI: create workspace]
    │ pocketbase: state='provisioning', enrollmentTokenHash=hash(T),
    │              enrollmentTokenExpiresAt=now+15min
    ▼
[UI: copy installer-snippet → admin runs on VPS]
    │ connector → POST /api/workspaces/register { enrollment_token: T, ... }
    │   server: verify hash + TTL, consume (enrollmentTokenHash=null)
    │   server: store externalIp, port, certFingerprint, connectorVersion
    │   server: generate workspace_token W, store hash
    │   server: state='online', lastHeartbeatAt=now
    │   server: return { workspace_id, workspace_token: W }
    ▼
[steady state: heartbeat every 30s with Bearer W]
    │   each heartbeat: lastHeartbeatAt=now;
    │                   state = (coordinator_status.state=='ready') ? 'online' : 'degraded'
    │
    │ cron every 30s:
    │   state IN (online, degraded) AND lastHeartbeatAt < now-60s → state='offline'
    ▼
[UI: re-enroll] → new enrollmentTokenHash, workspaceTokenHash=null, state='provisioning'
[UI: delete]    → cascade delete (admin must still run `aion-connector uninstall` on VPS,
                  or let connector self-exit on 404 heartbeat)
```

## 4. Backend Endpoints

All six endpoints live in `aion-pocketbase/src/api.workspaces.pb.imba`. Auth via two helpers: `requireProjectMember(c, projectId)` and `requireWorkspaceToken(c, workspaceId)`.

### 4.1 `POST /api/workspaces`

**Auth:** JWT + `requireProjectMember(body.projectId)`.

Request:
```json
{ "projectId": "abc", "name": "prod-vps-1", "program": "claude-code",
  "model": "sonnet-4.6", "authMode": "api_key" }
```

Server:
1. Generate `slug` from `name` + 4-hex random suffix; retry on unique-violation.
2. Generate `enrollmentToken = randomHex(32)` — returned ONCE in response, only hash stored.
3. Create record: `state='provisioning'`, `enrollmentTokenHash=sha256(token)`, `enrollmentTokenExpiresAt=now+15min`; all transport fields null; `workspaceTokenHash=null`.

Response:
```json
{ "workspace": { "id": "...", "slug": "...", "state": "provisioning", ... },
  "enrollment_token": "<raw, shown once>" }
```

### 4.2 `GET /api/workspaces/:id/installer`

**Auth:** JWT + `requireProjectMember(workspace.projectId)`.

Returns a JSON template (not ready-made bash — bash template lives in UI so `api_key` and `enrollment_token` never transit through this endpoint):

```json
{ "base_url": "https://aion.example.com", "workspace_id": "abc123",
  "program": "claude-code", "model": "sonnet-4.6", "auth_mode": "api_key" }
```

UI assembles the final shell command client-side, interpolating the `enrollment_token` it received from 4.1 (held in component memory) and the `api_key` the admin just typed.

If `enrollmentTokenHash` is null (already consumed) or `enrollmentTokenExpiresAt < now` (expired), endpoint returns **410 Gone**. UI shows "Installer token expired — press Re-enroll".

### 4.3 `POST /api/workspaces/register`

**Auth:** `requireEnrollmentToken` — looks up record by `workspace_id` from body, verifies `sha256(token) == enrollmentTokenHash` and `enrollmentTokenExpiresAt > now`. Rejects 401 otherwise.

Request:
```json
{ "enrollment_token": "...", "workspace_id": "...",
  "external_ip": "1.2.3.4", "port": 12345, "cert_fingerprint": "sha256:...",
  "coordinator_status": { "state": "ready", "program": "claude-code", "version": "sonnet-4.6" },
  "connector_version": "0.3.3" }
```

Server (atomic transaction):
1. `enrollmentTokenHash = null`, `enrollmentTokenExpiresAt = null` (consume).
2. Write `externalIp`, `port`, `certFingerprint`, `connectorVersion`.
3. Generate `workspaceToken = randomHex(32)`, store `workspaceTokenHash = sha256(workspaceToken)`.
4. `state = 'online'`, `lastHeartbeatAt = now`.

Response:
```json
{ "workspace_id": "...", "workspace_token": "<raw, shown once>" }
```

### 4.4 `POST /api/workspaces/:id/heartbeat`

**Auth:** `requireWorkspaceToken(:id)` — `sha256(Bearer) == workspaceTokenHash`.

Request:
```json
{ "external_ip": "1.2.3.4",
  "coordinator_status": { "state": "ready" | "starting" | "error", ... },
  "connector_version": "0.3.3", "timestamp": 1744834567890 }
```

Server:
1. `lastHeartbeatAt = now`.
2. `state = (coordinator_status.state == 'ready') ? 'online' : 'degraded'`.
3. Update `externalIp` and `connectorVersion` if changed.

If the workspace record does not exist (admin deleted it via §4.6), the auth middleware returns 404 — the connector's phase 1 `cmdHeartbeat` logic interprets this as "orphaned" and triggers `aion-connector uninstall` on the VPS.

Note on the `decommissioned` state: it is listed in the enum as a reserved value for a future soft-delete flow (not MVP). In MVP, delete is always hard-delete, so this state never appears at runtime.

Response: `200 {}`. Phase 3 will return `config_version` here for coordinator sync; MVP response is empty.

### 4.5 `POST /api/workspaces/:id/re-enroll`

**Auth:** JWT + `requireProjectMember(workspace.projectId)`.

In MVP, this endpoint is called **only by the UI**. Connector-initiated re-enroll (with old `workspace_token`) is deferred to phase 3.

Server:
1. Generate new `enrollmentToken`, store hash, `enrollmentTokenExpiresAt = now + 15min`.
2. `workspaceTokenHash = null` — invalidates current VPS. If that VPS is still alive, its next heartbeat gets 401, connector logs "orphaned" and stops.
3. `state = 'provisioning'`.
4. Leave `externalIp`, `port`, `certFingerprint` untouched — UI shows admin "this is the VPS you need to reinstall on".

Response: `{ "enrollment_token": "<raw>" }`.

### 4.6 `DELETE /api/workspaces/:id`

**Auth:** dual-path. Try JWT first (UI flow). Fall back to `requireWorkspaceToken(:id)` (connector uninstall flow).

Server:
1. Hard delete the record (cascades via `projectId` cascade rules if any; in this case nothing cascades to workspaces).
2. Return `200 {}`.

UI flow: admin presses Delete → record gone → the VPS continues to run until admin SSHs and runs `aion-connector uninstall`, or until the connector's next heartbeat returns 404 and the connector self-stops (phase 1 cmdUninstall logic already handles this).

Connector flow: `aion-connector uninstall` sends DELETE with its own `workspace_token`.

## 5. UI

### 5.1 New Page: `/projects/:id/workspaces`

File structure in `aion-application/src/`:

```
pages/
  workspaces-page.imba           # NEW: page container, routes
components/workspaces/
  workspace-list.imba            # NEW: left-column table
  workspace-detail.imba          # NEW: right-column detail panel
  workspace-create-modal.imba    # NEW: creation modal
  workspace-installer-view.imba  # NEW: code block + copy button
  workspace-state-badge.imba     # NEW: colored pill per state
```

Layout:
```
┌────────────────────────────────────────────────────────────┐
│ Project "Foo" › Workspaces                  [+ Create]     │
├──────────────────────┬─────────────────────────────────────┤
│ Workspaces           │ prod-vps-1                          │
│                      │ state:       [online]               │
│ • prod-vps-1 [online]│ external IP: 1.2.3.4:12345          │
│ • staging  [offline] │ fingerprint: sha256:ab:cd:...       │
│ • test-nat [deg.]    │ last HB:     12s ago                │
│                      │ version:     claude-code sonnet-4.6 │
│                      │ conn:        v0.3.3                 │
│                      │                                     │
│                      │ [Re-enroll]  [Delete]               │
└──────────────────────┴─────────────────────────────────────┘
```

**State badge colors:** `provisioning` gray, `online` green, `degraded` amber, `offline` red, `decommissioned` hidden (record deleted).

**Realtime:** page subscribes via `pb.collection('workspaces').subscribe('*', ...)` with client-side filter `projectId == currentProjectId`. Create/update/delete events update the list without polling; cron-driven state changes propagate automatically.

### 5.2 Create Flow

1. `[+ Create]` opens `workspace-create-modal`.
2. Fields: `name` (required), `program` (dropdown, only `claude-code`), `model` (text, default `sonnet-4.6`), `authMode` (dropdown, `oauth` option disabled in MVP), `apiKey` (password field, required if `authMode=api_key`).
3. Submit → `POST /api/workspaces` → response `{ workspace, enrollment_token }`.
4. Modal does NOT close. It switches to the `workspace-installer-view`:
   - Displays the full bash snippet with `enrollment_token` and `apiKey` interpolated client-side.
   - `[Copy]` button copies to clipboard.
   - Warning: "This snippet expires in 15 minutes. If you lose it, press Re-enroll."
5. `[Done]` closes the modal. List now shows the new workspace in `provisioning`.
6. Cron / heartbeat drive `provisioning → online` within ≤2 min; UI updates via realtime.

The `apiKey` field lives in component state only. It is never sent to pocketbase — it is interpolated into the bash snippet on the client. Reload of the page loses it; admin can paste the snippet anyway (it's already copied), but cannot re-open the snippet view after closing without doing a re-enroll (because the `enrollment_token` is also only in memory).

### 5.3 Re-enroll Flow

1. `[Re-enroll]` button on detail panel → confirm dialog: "This invalidates the current VPS installation. Continue?"
2. Modal opens `workspace-create-modal` in "re-enroll mode" — same as step 4 of Create, but prompts for `apiKey` again (pocketbase doesn't have it).
3. Submit → `POST /api/workspaces/:id/re-enroll` → response `{ enrollment_token }`.
4. Same `workspace-installer-view` as Create.
5. Admin copies snippet, runs on VPS; `state` transitions back `provisioning → online`.

### 5.4 Delete Flow

1. `[Delete]` button → confirm: "This permanently removes the workspace. The VPS will stop on its next heartbeat."
2. `DELETE /api/workspaces/:id`.
3. Record disappears from list via realtime.

### 5.5 Clean-Sweep in `aion-application`

**Files to delete entirely:**
- `src/components/server-settings-popup.imba`
- `src/components/agent-console.imba`
- `src/components/slash-commands.imba`

**Files to edit (remove references):**
- `src/components/right-panel.imba` — remove agent/server buttons and sections.
- `src/components/project-settings-popup.imba` — remove agents/servers tab; add `→ Workspaces` link navigating to `/projects/:id/workspaces`.
- `src/components/messages-list.imba` — remove rendering for `agent_sessions` messages.
- `src/components/canvas-panel.imba` — remove agent branches.
- `src/components/popups/terminal.imba`, `editor.imba`, `shared.imba`, `markdown.imba` — scan for and remove imports/references to agents/servers/slash-commands. The popups themselves stay; only legacy hooks are stripped. Some of these files may be zero-touch — the plan will confirm per-file after an audit pass.
- `src/api.imba` — delete methods `servers.*`, `agents.*`, `agentSessions.*`; add `workspaces.*` methods wrapping endpoints 4.1–4.6.
- `src/app.imba` — remove dead imports; add route `/projects/:id/workspaces` → `workspaces-page.imba`.
- `src/index.imba` — remove dead imports.

**Done criterion:** `grep -r 'agent_sessions\|slashCommand\|agentMemory\|api\.servers\|api\.agents' src/` in `aion-application` returns zero matches.

## 6. Cron: `workspace-lifecycle`

File: `aion-pocketbase/src/cron.workspace-lifecycle.pb.imba`.

```imba
cronAdd('workspace-lifecycle', '@every 30s') do
    const threshold = new Date(Date.now() - 60_000).toISOString()
    const records = $app.findRecordsByFilter(
        'workspaces'
        "(state = 'online' || state = 'degraded') && lastHeartbeatAt < {:t}"
        '-lastHeartbeatAt'
        100
        0
        { t: threshold }
    )
    for rec in records
        rec.set('state', 'offline')
        $app.save(rec)
```

Design notes:
- `provisioning` records are not touched (they have `lastHeartbeatAt=null`, which is not `< threshold` in pocketbase filter semantics).
- `decommissioned` and `offline` records are not touched.
- `degraded` is touched — if coordinator was degraded AND no heartbeat for 60s, that's offline.
- Batch size 100: in practice the set of stale workspaces in any 30s window is tiny; 100 is a safety cap to prevent runaway work if the scheduler glitches.

## 7. Installer Delivery

### 7.1 Static `pb_public/install.sh`

Byte-for-byte copy of `aion-connector/bin/install.sh` (already written in Phase 1, 135 lines). Served by pocketbase's built-in static file handler at `https://<aion-host>/install.sh`.

Deployment method: symlink or build-step copy from the connector repo. Phase 2 plan will specify which; MVP choice is a manual copy-on-release (documented in `aion-pocketbase/README.md`).

### 7.2 Dynamic Bash Snippet (Client-Assembled)

Endpoint 4.2 returns only the template fields (no secrets). UI assembles the final command:

```bash
curl -fsSL https://aion.example.com/install.sh | sudo bash -s -- \
    --token a7b9c...  --aion https://aion.example.com \
    --workspace-id abc123 \
    --program claude-code --model sonnet-4.6 \
    --auth-mode api_key --api-key sk-ant-...
```

Rationale for client-side assembly:
1. `enrollment_token` is shown to admin exactly once (response of 4.1). Having it transit through 4.2 would require pocketbase to hold it in plain form, defeating the hash-at-rest design.
2. `api_key` never touches pocketbase (Q7 pass-through).
3. The bash template is stable — it's just string interpolation in the UI component.

## 8. Migration Strategy

### 8.1 `019_workspace_model.imba` — drop-then-create

One migration does the whole sweep. Asymmetric `down` (rollback does not recreate the legacy model — Phase 1 explicitly committed to greenfield).

```imba
export def up db
    # drop legacy model
    for name in ['agent_sessions', 'agents', 'servers']
        try
            const col = $app.findCollectionByNameOrId(name)
            $app.delete(col) if col
        catch e
            # collection may not exist in fresh installs — that's fine
            continue

    # create workspaces
    const col = new Collection
    col.name = 'workspaces'
    col.type = 'base'
    col.fields.add(field.relation('projectId', 'projects', { required: true, cascadeDelete: true }))
    col.fields.add(field.text('name', { required: true, max: 80 }))
    col.fields.add(field.text('slug', { required: true, min: 3, max: 40, pattern: '^[a-z0-9-]+$' }))
    col.fields.add(field.relation('createdBy', 'users', { required: true }))
    col.fields.add(field.select('state', {
        values: ['provisioning', 'online', 'offline', 'degraded', 'decommissioned']
        required: true
    }))
    col.fields.add(field.date('lastHeartbeatAt'))
    col.fields.add(field.text('externalIp'))
    col.fields.add(field.number('port'))
    col.fields.add(field.text('certFingerprint'))
    col.fields.add(field.text('enrollmentTokenHash'))
    col.fields.add(field.date('enrollmentTokenExpiresAt'))
    col.fields.add(field.text('workspaceTokenHash'))
    col.fields.add(field.text('connectorVersion'))
    col.fields.add(field.select('program', { values: ['claude-code'], required: true }))
    col.fields.add(field.text('model', { required: true }))
    col.fields.add(field.select('authMode', { values: ['api_key', 'oauth'], required: true }))
    col.addIndex('idx_workspaces_project', no, 'projectId')
    col.addIndex('idx_workspaces_slug', yes, 'slug')  # unique
    col.addIndex('idx_workspaces_state_heartbeat', no, 'state, lastHeartbeatAt')
    $app.save(col)

export def down db
    try
        const col = $app.findCollectionByNameOrId('workspaces')
        $app.delete(col) if col
    catch e
        return
```

Files 011–018 remain in `_migrations/` as is — they are already applied in the `_migrations` table of prod instances, and removing them would break the migration contract.

## 9. Security Recap

Inherits Phase 1 posture and tightens it:

1. **Tokens at rest:** `enrollment_token` and `workspace_token` are stored only as SHA-256 hashes. Server never returns them after creation.
2. **TTL on enrollment_token:** 15 minutes. Consumed on first successful `/register`. Hash cleared on consume or re-enroll.
3. **API key:** never stored in pocketbase. Lives on VPS in `$HOME/coordinator/credentials.env` (mode 0600, owned by per-workspace OS user `aion-$SLUG`).
4. **Permissions on `workspaces` collection:** all built-in list/view/create/update/delete rules set to `null`. Auto-CRUD is disabled; only custom endpoints and superuser access can touch the collection.
5. **No `workspaceTokenHash` in API responses:** custom endpoints explicitly select safe fields only. UI never sees hashes.
6. **Re-enroll invalidates old VPS:** setting `workspaceTokenHash=null` means the old VPS's next heartbeat gets 401 and its connector self-stops.

## 10. Open Questions / Deferred Decisions

None remaining for MVP. Items explicitly deferred:

- Connector-initiated re-enroll (endpoint exists, UI is the only caller in MVP). Phase 3.
- `config_version` in heartbeat response for coordinator sync. Phase 3.
- Multi-user permissions model inside a project (today: any `project_member` can create/re-enroll/delete any workspace). Revisit if needed.
- OAuth flow for `authMode=oauth`. Phase 3 alongside coordinator sync.

## 11. File Inventory (for the plan)

**aion-pocketbase (new/modified):**
- `src/_migrations/019_workspace_model.imba` — NEW
- `src/api.workspaces.pb.imba` — NEW (6 endpoints)
- `src/cron.workspace-lifecycle.pb.imba` — NEW
- `pb_public/install.sh` — NEW (copy)
- `src/api.servers.pb.imba` — DELETE

**aion-application (new):**
- `src/pages/workspaces-page.imba`
- `src/components/workspaces/workspace-list.imba`
- `src/components/workspaces/workspace-detail.imba`
- `src/components/workspaces/workspace-create-modal.imba`
- `src/components/workspaces/workspace-installer-view.imba`
- `src/components/workspaces/workspace-state-badge.imba`

**aion-application (modified):**
- `src/api.imba` — add `workspaces.*`, remove `servers.*` / `agents.*` / `agentSessions.*`
- `src/app.imba` — add route, remove dead imports
- `src/index.imba` — remove dead imports
- `src/components/right-panel.imba`
- `src/components/project-settings-popup.imba`
- `src/components/messages-list.imba`
- `src/components/canvas-panel.imba`
- `src/components/popups/terminal.imba`
- `src/components/popups/editor.imba`
- `src/components/popups/shared.imba`
- `src/components/popups/markdown.imba`

**aion-application (deleted):**
- `src/components/server-settings-popup.imba`
- `src/components/agent-console.imba`
- `src/components/slash-commands.imba`

**aion-connector:** no changes.
