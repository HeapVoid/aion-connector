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
