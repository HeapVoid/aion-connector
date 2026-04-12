# aion-connector

Universal connector that turns any VPS into an AI agent server for [AION](https://aion.ifastbet.com) — the collaborative platform for teams and AI.

The connector runs on your server, listens for tasks from AION, and executes them via [acpx](https://github.com/nicobailey/acpx) — a universal CLI client for the Agent Client Protocol (ACP). This means **one connector supports 17+ AI coding agents** through a single interface.

## Supported Agents

| Agent | Command | Notes |
|---|---|---|
| Claude Code | `claude` | Anthropic's coding agent |
| Codex | `codex` | OpenAI's coding agent |
| Pi | `pi` | Mario Zechner's coding agent |
| OpenCode | `opencode` | Open-source coding agent |
| Gemini | `gemini` | Google's coding agent |
| Cursor | `cursor` | Cursor's agent mode |
| Copilot | `copilot` | GitHub Copilot agent |
| Kiro | `kiro` | AWS coding agent |
| Qwen | `qwen` | Alibaba's coding agent |
| Trae | `trae` | ByteDance's coding agent |
| OpenClaw | `openclaw` | — |
| Droid | `droid` | — |
| Kilocode | `kilocode` | — |
| Kimi | `kimi` | Moonshot's agent |
| Qoder | `qoder` | — |
| iFlow | `iflow` | — |

Any agent that supports ACP will work automatically.

## Quick Start

### 1. Install

Your server needs [Bun](https://bun.sh) (runtime) and the agent you want to use.

```bash
# Install Bun
curl -fsSL https://bun.sh/install | bash

# Make bun available system-wide
ln -sf ~/.bun/bin/bun /usr/local/bin/bun

# Install connector
npm install -g aion-connector

# Install your agent (example: Pi)
npm install -g @mariozechner/pi-coding-agent
```

Other agent install examples:

```bash
# Claude Code
npm install -g @anthropic-ai/claude-code

# OpenCode
npm install -g opencode
```

### 2. Get your token

In AION, go to your project settings and create a new agent. You'll get:
- **Agent name** — the agent type to use (e.g. `claude`, `pi`, `codex`)
- **VPS Token** — authentication token for your connector
- **VPS Host** — set this to `http://YOUR_SERVER_IP:7777`

### 3. Run

```bash
aion-connector --token YOUR_TOKEN --agent pi
```

That's it. The connector starts an HTTP server on port 7777 and waits for tasks from AION.

### Options

```
--agent NAME     Agent to use: claude, codex, pi, opencode, gemini...
--token TOKEN    Auth token from AION agent settings
--port PORT      HTTP server port (default: 7777)
--host HOST      Bind address (default: 0.0.0.0)
--dir PATH       Directory for cloned repositories (default: ./repos)
--no-autoupdate  Disable auto-update
```

## Production Setup (systemd)

For production, run the connector as a systemd service so it starts on boot and restarts on crashes.

### Create the service file

```bash
sudo cat > /etc/systemd/system/aion-connector.service << EOF
[Unit]
Description=AION Connector
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/aion-connector --token YOUR_TOKEN --agent pi --dir /root/repos
Restart=always
RestartSec=5
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF
```

### Enable and start

```bash
# Create repos directory
mkdir -p /root/repos

# Reload systemd, enable on boot, start now
sudo systemctl daemon-reload
sudo systemctl enable aion-connector
sudo systemctl start aion-connector
```

### Manage the service

```bash
# Check status
sudo systemctl status aion-connector

# View live logs
sudo journalctl -u aion-connector -f

# Restart after config change
sudo systemctl restart aion-connector

# Stop
sudo systemctl stop aion-connector
```

## Running Multiple Agents

You can run multiple agents on the same server — just use different ports and service names.

```bash
# Agent 1: Pi on port 7777
aion-connector --token TOKEN_1 --agent pi --port 7777

# Agent 2: Claude on port 7778
aion-connector --token TOKEN_2 --agent claude --port 7778
```

For systemd, create separate service files:

```bash
# /etc/systemd/system/aion-connector-pi.service    → port 7777
# /etc/systemd/system/aion-connector-claude.service → port 7778
```

In AION, set each agent's VPS Host to the corresponding port (`http://YOUR_IP:7777`, `http://YOUR_IP:7778`).

## How It Works

```
AION Platform                          Your VPS
┌──────────────┐                    ┌──────────────────┐
│              │   POST /channel    │                  │
│    AION      │ ────────────────>  │  aion-connector  │
│   server     │                    │                  │
│              │   POST /agents/    │    ┌──────────┐  │
│              │ <────────────────  │    │   acpx   │  │
│              │    channel         │    │  (agent) │  │
└──────────────┘                    │    └──────────┘  │
                                    │    ┌──────────┐  │
                                    │    │   repos   │  │
                                    │    │ (cloned)  │  │
                                    │    └──────────┘  │
                                    └──────────────────┘
```

1. A user types `/pi fix the login bug` in an AION chat
2. AION sends the prompt to your connector via Channel Protocol v1
3. The connector syncs repositories (clones or pulls)
4. The connector runs `acpx pi "fix the login bug"` in the repo directory
5. Output streams back to AION in real time
6. When the agent finishes, a summary and list of changed files are sent back

### Channel Protocol v1

The connector communicates with AION through a simple JSON protocol. Every message is a `POST` request with this structure:

```json
{
  "v": 1,
  "action": "invoke",
  "token": "your-vps-token",
  "payload": { ... }
}
```

**Inbound actions** (AION → Connector):

| Action | Description |
|---|---|
| `ping` | Health check. Returns `{"ok": true, "v": 1}` |
| `invoke` | Run agent with a prompt |
| `repos.sync` | Clone or pull repositories |
| `files.tree` | List files in a workspace (git ls-files) |
| `files.read` | Read a file's content |
| `git.status` | Get `git status --porcelain` |
| `git.diff` | Get `git diff` output |
| `workspaces` | List cloned repositories |

**Outbound actions** (Connector → AION):

| Action | Description |
|---|---|
| `output` | Streaming agent output (NDJSON lines) |
| `complete` | Agent finished, with summary and changed files |
| `error` | Agent failed, with error message |

## Troubleshooting

### Connector won't start — port in use

```bash
# Find what's using the port
ss -tlnp | grep 7777

# Kill it
fuser -k 7777/tcp
```

### Agent command not found

`acpx` needs the agent CLI to be installed globally. Check:

```bash
# Is acpx installed?
acpx --version

# Does it see your agent?
acpx pi --help    # or: acpx claude --help
```

If the agent isn't found, install it:

```bash
npm install -g @mariozechner/pi-coding-agent   # Pi
npm install -g @anthropic-ai/claude-code        # Claude
```

### Connector responds to ping but agent fails

Check the logs:

```bash
# systemd logs
journalctl -u aion-connector -n 50 --no-pager

# or if running manually, check stderr output
```

Common causes:
- **Missing API key** — most agents need an API key. Set it as an environment variable before starting (e.g. `ANTHROPIC_API_KEY` for Claude, `PI_API_KEY` for Pi)
- **Agent not installed** — see above
- **Repository not cloned** — the connector clones repos automatically when AION sends a `repos.sync` or `invoke` with repos. Check that the `--dir` path is writable

### Can't reach connector from AION

Make sure:
1. The port is open in your firewall: `ufw allow 7777/tcp`
2. The VPS Host in AION matches your server: `http://YOUR_IP:7777`
3. The token in AION matches the `--token` you started with

Test from your local machine:

```bash
curl -X POST http://YOUR_IP:7777 \
  -H 'Content-Type: application/json' \
  -d '{"v":1, "action":"ping", "token":"YOUR_TOKEN"}'
# Should return: {"ok":true,"v":1}
```

### Updating

```bash
npm update -g aion-connector
sudo systemctl restart aion-connector
```

## Requirements

- [Bun](https://bun.sh) v1.0+
- Linux VPS (Ubuntu 22.04+ recommended)
- At least one AI agent CLI installed globally

## Security Notes

- The connector only accepts POST requests with a valid token
- Sensitive files (`.env`, `.git`, `.pem`, `.key`, `credentials`, `.secret`) are blocked from being read
- Path traversal attempts are rejected
- Repositories are cloned into an isolated directory

## License

MIT
