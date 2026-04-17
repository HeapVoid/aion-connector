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
