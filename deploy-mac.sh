#!/usr/bin/env bash
# deploy-mac.sh -- Deploy claude-notify on macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/claude-notify"
SETTINGS_FILE="${HOME}/.claude/settings.json"
PI_HOST="${PI_HOST:-claudecode}"
PI_PORT="${PI_PORT:-8080}"

echo "=== Claude Notify: Mac Deployment ==="

# --- Check dependencies ---
echo "Checking dependencies..."
for cmd in jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not installed."
        exit 1
    fi
done
echo "  All dependencies present."

# --- Test Pi connectivity ---
echo "Testing Pi connectivity at ${PI_HOST}:${PI_PORT}..."
if curl -s --max-time 5 "http://${PI_HOST}:${PI_PORT}/v1/about" >/dev/null 2>&1; then
    echo "  Pi signal-cli-rest-api is reachable."
else
    echo "  WARNING: Cannot reach Pi at http://${PI_HOST}:${PI_PORT}"
    echo "  Continuing anyway -- fix connectivity before testing."
fi

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
    sed "s|SIGNAL_API_URL=\"http://localhost:8080\"|SIGNAL_API_URL=\"http://${PI_HOST}:${PI_PORT}\"|" \
        "${SCRIPT_DIR}/claude-notify.conf.example" > "${CONFIG_DIR}/config"
    chmod 600 "${CONFIG_DIR}/config"
    echo "  Config created at ${CONFIG_DIR}/config"
    echo "  >>> Edit it with real phone numbers before testing! <<<"
else
    echo "  Config already exists at ${CONFIG_DIR}/config -- skipping."
fi

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
echo "  2. Set SIGNAL_API_URL=http://${PI_HOST}:${PI_PORT}"
echo "  3. Run ./test-notify.sh to verify everything works"
