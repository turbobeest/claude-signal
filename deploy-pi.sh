#!/usr/bin/env bash
# deploy-pi.sh -- Deploy claude-notify on the Raspberry Pi (claudecode)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/bin"
CONFIG_DIR="${HOME}/.config/claude-notify"
SETTINGS_FILE="${HOME}/.claude/settings.json"

echo "=== Claude Notify: Pi Deployment ==="

# --- Check dependencies ---
echo "Checking dependencies..."
for cmd in jq docker; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not installed."
        exit 1
    fi
done

if ! docker compose version &>/dev/null; then
    echo "ERROR: docker compose plugin is required."
    exit 1
fi

echo "  All dependencies present."

# --- Install script ---
echo "Installing claude-notify to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
cp "${SCRIPT_DIR}/claude-notify.sh" "${INSTALL_DIR}/claude-notify"
chmod +x "${INSTALL_DIR}/claude-notify"
echo "  Installed."

# --- Create config ---
if [[ ! -f "${CONFIG_DIR}/config" ]]; then
    echo "Creating config from template..."
    mkdir -p "$CONFIG_DIR"
    sed 's|HOSTNAME_LABEL="mac"|HOSTNAME_LABEL="pi"|; s|SIGNAL_API_URL="http://localhost:8080"|SIGNAL_API_URL="http://localhost:8080"|' \
        "${SCRIPT_DIR}/claude-notify.conf.example" > "${CONFIG_DIR}/config"
    chmod 600 "${CONFIG_DIR}/config"
    echo "  Config created at ${CONFIG_DIR}/config"
    echo "  >>> Edit it with real phone numbers before testing! <<<"
else
    echo "  Config already exists at ${CONFIG_DIR}/config -- skipping."
fi

# --- Start Docker container ---
echo "Starting signal-cli-rest-api container..."
cd "${SCRIPT_DIR}"
docker compose up -d
echo "  Container started."

# --- Install systemd service ---
echo "Installing systemd service for auto-start..."
SERVICE_FILE="${HOME}/.config/systemd/user/signal-cli-rest-api.service"
mkdir -p "$(dirname "$SERVICE_FILE")"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=signal-cli-rest-api for Claude Code notifications
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable signal-cli-rest-api.service
echo "  Systemd service installed and enabled."

# --- Merge hooks into settings.json ---
echo "Merging hooks into ${SETTINGS_FILE}..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

if [[ -f "$SETTINGS_FILE" ]]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "  Backed up existing settings."
else
    echo '{}' > "$SETTINGS_FILE"
fi

HOOKS_FILE="${SCRIPT_DIR}/hooks/signal-notify-hooks.json"

# Merge: existing settings + hook definitions. Existing hooks for the same
# events are replaced; hooks for other events are preserved.
MERGED=$(jq -s '
    .[0] as $settings |
    .[1].hooks as $new_hooks |
    $settings * { hooks: (($settings.hooks // {}) * $new_hooks) }
' "$SETTINGS_FILE" "$HOOKS_FILE")

echo "$MERGED" | jq '.' > "$SETTINGS_FILE"
echo "  Hooks merged."

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit ${CONFIG_DIR}/config with real phone numbers"
echo "  2. Register your Google Voice number with Signal:"
echo "     curl -X POST 'http://localhost:8080/v1/register/+1XXXXXXXXXX' -H 'Content-Type: application/json' -d '{\"use_voice\": true}'"
echo "  3. Verify registration:"
echo "     curl -X POST 'http://localhost:8080/v1/register/+1XXXXXXXXXX/verify/CODE'"
echo "  4. Test: echo '{\"hook_event_name\":\"Stop\",\"session_id\":\"test\",\"cwd\":\"/tmp\"}' | claude-notify"
