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

# api_key mode requires --api-key; oauth mode doesn't (cli.imba handles both branches)
if [ "$AUTH_MODE" = "api_key" ] && [ -z "$API_KEY" ]; then
  echo "missing --api-key (required when --auth-mode=api_key)"
  exit 2
fi
if [ "$AUTH_MODE" != "api_key" ] && [ "$AUTH_MODE" != "oauth" ]; then
  echo "--auth-mode must be api_key or oauth"
  exit 2
fi

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
CREATED_USER=0
echo "-- provisioning user $USER --"
if ! id "$USER" >/dev/null 2>&1; then
  useradd -m -d "$USER_HOME" -s /bin/bash "$USER"
  CREATED_USER=1
fi

# Rollback helper. Only stops the unit via the user's own systemctl (machinectl
# `-M user@` requires systemd-container which is absent on many stock VPS images).
# Only deletes the user if we created it this run — a pre-existing workspace
# must survive a failed re-enroll with its $HOME intact.
rollback() {
  echo "!! install failed — rolling back"
  if id "$USER" >/dev/null 2>&1; then
    local UID_N
    UID_N="$(id -u "$USER")"
    sudo -u "$USER" -H XDG_RUNTIME_DIR="/run/user/$UID_N" \
      systemctl --user stop aion-connector.service 2>/dev/null || true
    sudo -u "$USER" -H XDG_RUNTIME_DIR="/run/user/$UID_N" \
      systemctl --user disable aion-connector.service 2>/dev/null || true
  fi
  if [ "$CREATED_USER" = "1" ]; then
    userdel -r "$USER" 2>/dev/null || true
  fi
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
