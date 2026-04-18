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
