#!/usr/bin/env bash
# claude-notify.sh -- Send Signal notifications for Claude Code hook events
# Reads hook JSON from stdin, sends formatted message via signal-cli-rest-api.
# Always exits 0 to never block Claude Code.

set -euo pipefail

CONFIG="${CLAUDE_NOTIFY_CONFIG:-${HOME}/.config/claude-notify/config}"

# Bail silently if no config
if [[ ! -f "$CONFIG" ]]; then
    exit 0
fi

# shellcheck source=/dev/null
source "$CONFIG"

# Required config
: "${SIGNAL_API_URL:?}" "${SIGNAL_SENDER:?}" "${SIGNAL_RECIPIENT:?}"

# Defaults
VERBOSITY="${VERBOSITY:-normal}"
NOTIFY_EVENTS="${NOTIFY_EVENTS:-Stop,Notification,TaskCompleted,SessionEnd}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname -s)}"

# OAuth usage endpoint (same endpoint Claude Code itself uses)
ANTHROPIC_USAGE_URL="${ANTHROPIC_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
# macOS: keychain lookup
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-Claude Code-credentials}"
KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-$(whoami)}"
# Linux: file-based credential storage
AUTH_JSON="${AUTH_JSON:-${HOME}/.config/claude-code/auth.json}"
AUTH_JSON_LEGACY="${HOME}/.claude/.credentials.json"

# Read hook JSON from stdin
INPUT="$(cat)"
if [[ -z "$INPUT" ]]; then
    exit 0
fi

# Parse event info
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null) || exit 0
if [[ -z "$EVENT" ]]; then
    exit 0
fi

# Check if this event is in our notify list
if [[ ! ",$NOTIFY_EVENTS," == *",$EVENT,"* ]]; then
    exit 0
fi

# Extract common fields
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty') || true
CWD=$(echo "$INPUT" | jq -r '.cwd // empty') || true
PROJECT=$(basename "${CWD:-unknown}")

# --- Usage stats from Anthropic OAuth API ---
# Extract OAuth token: macOS Keychain first, then Linux file paths
get_oauth_token() {
    local creds

    # macOS: read from Keychain
    if command -v security &>/dev/null; then
        creds=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null) || true
        if [[ -n "$creds" ]]; then
            echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null && return
        fi
    fi

    # Linux: read from auth.json (new path, then legacy)
    local auth_file
    for auth_file in "$AUTH_JSON" "$AUTH_JSON_LEGACY"; do
        if [[ -f "$auth_file" ]]; then
            jq -r '.claudeAiOauth.accessToken // .oauth.accessToken // empty' "$auth_file" 2>/dev/null && return
        fi
    done
}

get_usage_line() {
    local token
    token=$(get_oauth_token) || return

    if [[ -z "$token" ]]; then
        return
    fi

    # Call the usage endpoint
    local resp
    resp=$(curl -s --max-time "$CURL_TIMEOUT" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "$ANTHROPIC_USAGE_URL" 2>/dev/null) || return

    if [[ -z "$resp" ]]; then
        return
    fi

    # Parse the response into a compact status line
    # Fields: five_hour (session), seven_day (all models), seven_day_sonnet, seven_day_opus
    local parts=()
    local val reset_ts reset_fmt

    # Session (5-hour window)
    val=$(echo "$resp" | jq -r '.five_hour.utilization // empty' 2>/dev/null) || true
    if [[ -n "$val" ]]; then
        reset_ts=$(echo "$resp" | jq -r '.five_hour.resets_at // empty' 2>/dev/null) || true
        reset_fmt=$(format_reset "$reset_ts")
        parts+=("Session: ${val}%${reset_fmt}")
    fi

    # Weekly all models
    val=$(echo "$resp" | jq -r '.seven_day.utilization // empty' 2>/dev/null) || true
    if [[ -n "$val" ]]; then
        reset_ts=$(echo "$resp" | jq -r '.seven_day.resets_at // empty' 2>/dev/null) || true
        reset_fmt=$(format_reset "$reset_ts")
        parts+=("Weekly: ${val}%${reset_fmt}")
    fi

    # Sonnet-specific weekly limit (if present)
    val=$(echo "$resp" | jq -r '.seven_day_sonnet.utilization // empty' 2>/dev/null) || true
    if [[ -n "$val" ]]; then
        parts+=("Sonnet: ${val}%")
    fi

    # Opus-specific weekly limit (if present)
    val=$(echo "$resp" | jq -r '.seven_day_opus.utilization // empty' 2>/dev/null) || true
    if [[ -n "$val" ]]; then
        parts+=("Opus: ${val}%")
    fi

    if [[ ${#parts[@]} -gt 0 ]]; then
        local joined
        joined=$(IFS='|'; echo "${parts[*]}")
        echo "${joined//|/ · }"
    fi
}

# Format a reset timestamp into relative time (e.g., "3h" or "Thu 5a")
format_reset() {
    local ts="$1"
    if [[ -z "$ts" ]]; then
        return
    fi

    local reset_epoch now_epoch diff_s diff_h
    # macOS date: parse ISO 8601
    reset_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" "+%s" 2>/dev/null) || \
        reset_epoch=$(date -d "$ts" "+%s" 2>/dev/null) || return
    now_epoch=$(date "+%s")
    diff_s=$((reset_epoch - now_epoch))

    if [[ $diff_s -lt 0 ]]; then
        return
    elif [[ $diff_s -lt 86400 ]]; then
        diff_h=$(( (diff_s + 1800) / 3600 ))
        echo " ~${diff_h}h"
    else
        # Show day + hour
        local day hour ampm
        day=$(date -jf "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" "+%a" 2>/dev/null) || \
            day=$(date -d "$ts" "+%a" 2>/dev/null) || return
        hour=$(date -jf "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" "+%-I%P" 2>/dev/null) || \
            hour=$(date -d "$ts" "+%-I%P" 2>/dev/null) || return
        # Shorten am/pm to a/p
        hour="${hour/am/a}"
        hour="${hour/pm/p}"
        echo " ${day} ${hour}"
    fi
}

# Build message based on event type and verbosity
case "$EVENT" in
    Stop)
        STOP_REASON=$(echo "$INPUT" | jq -r '.stop_hook_reason // empty') || true
        case "$VERBOSITY" in
            simple)
                MSG="Claude Code done"
                ;;
            rich)
                MSG="Claude Code finished
Project: ${PROJECT}
Reason: ${STOP_REASON:-end of turn}
Dir: ${CWD:-?}"
                ;;
            *)  # normal
                MSG="Claude Code done: ${PROJECT} (${STOP_REASON:-end of turn})"
                ;;
        esac
        ;;
    Notification)
        TITLE=$(echo "$INPUT" | jq -r '.notification.title // empty') || true
        BODY=$(echo "$INPUT" | jq -r '.notification.body // empty') || true
        case "$VERBOSITY" in
            simple)
                MSG="${TITLE:-Notification}"
                ;;
            rich)
                MSG="Notification: ${TITLE:-?}
${BODY:-}
Project: ${PROJECT}"
                ;;
            *)
                MSG="${TITLE:-Notification}: ${BODY:-}"
                ;;
        esac
        ;;
    TaskCompleted)
        SUBJECT=$(echo "$INPUT" | jq -r '.task.subject // empty') || true
        case "$VERBOSITY" in
            simple)
                MSG="Task done"
                ;;
            rich)
                MSG="Task completed
Subject: ${SUBJECT:-?}
Project: ${PROJECT}"
                ;;
            *)
                MSG="Task done: ${SUBJECT:-task} (${PROJECT})"
                ;;
        esac
        ;;
    SessionEnd)
        case "$VERBOSITY" in
            simple)
                MSG="Session ended"
                ;;
            rich)
                MSG="Session ended
Project: ${PROJECT}
Session: ${SESSION_ID:-?}"
                ;;
            *)
                MSG="Session ended: ${PROJECT}"
                ;;
        esac
        ;;
    *)
        MSG="Claude Code event: ${EVENT} (${PROJECT})"
        ;;
esac

# Prefix with hostname label
MSG="[${HOSTNAME_LABEL}] ${MSG}"

# Append usage stats
USAGE_LINE=$(get_usage_line) || true
if [[ -n "${USAGE_LINE:-}" ]]; then
    MSG="${MSG}
${USAGE_LINE}"
fi

# Send via signal-cli-rest-api
PAYLOAD=$(jq -n \
    --arg msg "$MSG" \
    --arg sender "$SIGNAL_SENDER" \
    --arg recipient "$SIGNAL_RECIPIENT" \
    '{
        "message": $msg,
        "number": $sender,
        "recipients": [$recipient]
    }') || exit 0

curl -s -S \
    --max-time "$CURL_TIMEOUT" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${SIGNAL_API_URL}/v2/send" \
    >/dev/null 2>&1 || true

exit 0
