# aion-connector

Universal connector that turns any VPS into an AI agent server for [AION](https://aion.ifastbet.com) — the collaborative platform for teams and AI.

The connector runs on your server, listens for tasks from AION, and executes them via [acpx](https://github.com/nicobailey/acpx) — a universal CLI client for the Agent Client Protocol (ACP). This means **one connector supports 17+ AI coding agents** through a single interface. It also provides a **WebSocket terminal** (via node-pty) for direct shell access from AION's UI.

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

Your server needs [Node.js](https://nodejs.org) v18+ and the agent(s) you want to use.

```bash
# Install Node.js (Ubuntu/Debian)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs

# Build tools for node-pty native module
sudo apt-get install -y build-essential python3

# Install connector globally
npm install -g aion-connector

# Install your agent (example: Pi)
npm install -g @mariozechner/pi-coding-agent
```

Other agent install examples:

```bash
npm install -g @anthropic-ai/claude-code   # Claude Code
npm install -g opencode                      # OpenCode
```

> **Note:** `node-pty` (used for the WebSocket terminal) compiles from source on Linux via node-gyp during `npm install`. This happens automatically — you just need `build-essential` and `python3`.

### 2. Configure

Create a config file `aion.config.json`:

```json
{
  "port": 7777,
  "projects": {
    "YOUR_PROJECT_ID": {
      "token": "your-secret-token",
      "dir": "./projects/my-project",
      "agents": {
        "pi": { "description": "Pi Assistant" },
        "claude": { "description": "Claude Code" }
      }
    }
  }
}
```

**Where to get these values:**
- **Project ID** — visible in your AION project URL or settings
- **Token** — create a server in AION project settings, copy the generated token
- **Agents** — list the agent CLIs you've installed on this server

### 3. Run

```bash
aion-connector ./aion.config.json
```

The connector starts an HTTP + WebSocket server on port 7777 and waits for tasks from AION.

## Production Setup (systemd)

```bash
sudo cat > /etc/systemd/system/aion-connector.service << EOF
[Unit]
Description=AION Connector
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node /usr/lib/node_modules/aion-connector/dist/cli.js /root/aion-connector/aion.config.json
Restart=always
RestartSec=5
Environment=HOME=/root
WorkingDirectory=/root/aion-connector

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable aion-connector
sudo systemctl start aion-connector
```

```bash
sudo systemctl status aion-connector        # Check status
sudo journalctl -u aion-connector -f        # View live logs
sudo systemctl restart aion-connector       # Restart
```

## Config Reference

```json
{
  "port": 7777,
  "host": "0.0.0.0",
  "projects": {
    "project-id": {
      "token": "secret-token",
      "dir": "/path/to/workspace",
      "agents": {
        "agent-name": { "description": "Human-readable name" }
      }
    }
  }
}
```

| Field | Default | Description |
|---|---|---|
| `port` | `7777` | HTTP/WS server port |
| `host` | `0.0.0.0` | Bind address |
| `projects` | — | Map of project ID → project config |
| `projects.*.token` | — | Auth token (must match AION server settings) |
| `projects.*.dir` | — | Workspace directory for cloned repos |
| `projects.*.agents` | — | Map of agent CLI name → metadata |

### Multiple projects

One connector can serve multiple AION projects:

```json
{
  "port": 7777,
  "projects": {
    "project-a": {
      "token": "token-a",
      "dir": "/root/repos/project-a",
      "agents": { "pi": { "description": "Pi" } }
    },
    "project-b": {
      "token": "token-b",
      "dir": "/root/repos/project-b",
      "agents": { "claude": { "description": "Claude" } }
    }
  }
}
```

## How It Works

```
AION Platform                          Your VPS
┌──────────────┐                    ┌──────────────────┐
│              │   POST (tasks)     │                  │
│    AION      │ ────────────────>  │  aion-connector  │
│   server     │                    │                  │
│              │   POST (output)    │    ┌──────────┐  │
│              │ <────────────────  │    │   acpx   │  │
│              │                    │    │  (agent) │  │
│              │   WebSocket        │    └──────────┘  │
│              │ <═══════════════>  │    ┌──────────┐  │
│              │   (terminal)       │    │ node-pty │  │
│              │                    │    │  (shell) │  │
└──────────────┘                    │    └──────────┘  │
                                    └──────────────────┘
```

1. A user types `/pi fix the login bug` in an AION chat
2. AION sends the prompt to your connector via HTTP
3. The connector syncs repositories (clones or pulls)
4. The connector runs `acpx pi "fix the login bug"` in the repo directory
5. Output streams back to AION in real time
6. When the agent finishes, a summary and changed files are sent back

The connector also accepts WebSocket connections for an interactive terminal — AION's UI opens a shell session directly on your server via node-pty.

### Channel Protocol v1

Every HTTP message is a `POST` with this structure:

```json
{
  "v": 1,
  "action": "invoke",
  "token": "your-token",
  "payload": { ... }
}
```

**Inbound actions** (AION → Connector):

| Action | Description |
|---|---|
| `ping` | Health check — returns `{"ok": true, "v": 1}` |
| `invoke` | Run agent with a prompt |
| `agents` | List available agents for the project |
| `repos.sync` | Clone or pull repositories |
| `files.tree` | List files in a workspace (git ls-files) |
| `files.read` | Read a file's content |
| `git.status` | Get `git status --porcelain` |
| `git.diff` | Get `git diff` output |
| `workspaces` | List cloned repositories |
| `terminal.spawn` | Start an HTTP-based terminal session |
| `terminal.input` | Send input to terminal session |
| `terminal.output` | Read terminal output |
| `terminal.resize` | Resize terminal |
| `terminal.close` | Close terminal session |

**WebSocket endpoint:** `ws://HOST:PORT/ws?token=TOKEN` — opens an interactive PTY terminal with full color support.

**Outbound actions** (Connector → AION):

| Action | Description |
|---|---|
| `output` | Streaming agent output (NDJSON lines) |
| `complete` | Agent finished, with summary and changed files |
| `error` | Agent failed, with error message |

## Troubleshooting

### Connector won't start — port in use

```bash
ss -tlnp | grep 7777
fuser -k 7777/tcp
```

### Agent command not found

`acpx` needs the agent CLI installed globally:

```bash
acpx --version          # Is acpx installed?
acpx pi --help          # Does it see your agent?
```

### node-pty build fails

```bash
sudo apt-get install -y build-essential python3
npm rebuild node-pty
```

### Connector responds to ping but agent fails

```bash
journalctl -u aion-connector -n 50 --no-pager
```

Common causes:
- **Missing API key** — most agents need an API key env var (e.g. `ANTHROPIC_API_KEY` for Claude)
- **Agent not installed globally** — `npm install -g <agent-package>`

### Can't reach connector from AION

1. Open the port in your firewall: `ufw allow 7777/tcp`
2. Set VPS Host in AION to `http://YOUR_IP:7777`
3. Token in AION must match the token in your config

Test:

```bash
curl -X POST http://YOUR_IP:7777 \
  -H 'Content-Type: application/json' \
  -d '{"v":1, "action":"ping", "token":"YOUR_TOKEN"}'
# → {"ok":true,"v":1}
```

### Updating

```bash
npm update -g aion-connector
sudo systemctl restart aion-connector
```

## Requirements

- [Node.js](https://nodejs.org) v18+
- Linux VPS (Ubuntu 22.04+ recommended)
- `build-essential` + `python3` (for node-pty compilation)
- At least one AI agent CLI installed globally

## Security

- Only accepts requests with a valid project token
- Sensitive files (`.env`, `.git`, `.pem`, `.key`, `credentials`, `.secret`) are blocked from being read
- Path traversal attempts are rejected
- Repositories are cloned into isolated project directories
- WebSocket terminal requires valid token authentication

## License

MIT
