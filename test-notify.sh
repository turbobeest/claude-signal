#!/usr/bin/env bash
# test-notify.sh -- End-to-end test for claude-notify
set -euo pipefail

CONFIG="${HOME}/.config/claude-notify/config"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }

echo "=== Claude Notify: Test Suite ==="
echo ""

# --- Test 1: Config exists ---
echo "1. Config file"
if [[ -f "$CONFIG" ]]; then
    pass "Config exists at ${CONFIG}"
else
    fail "Config not found at ${CONFIG}"
    echo "     Run a deploy script first."
    echo ""
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
fi

# --- Test 2: Config has real phone numbers ---
echo "2. Config values"
# shellcheck source=/dev/null
source "$CONFIG"

if [[ "${SIGNAL_SENDER:-}" == *"XXXX"* ]] || [[ -z "${SIGNAL_SENDER:-}" ]]; then
    fail "SIGNAL_SENDER is not configured (still placeholder)"
else
    pass "SIGNAL_SENDER is set"
fi

if [[ "${SIGNAL_RECIPIENT:-}" == *"XXXX"* ]] || [[ -z "${SIGNAL_RECIPIENT:-}" ]]; then
    fail "SIGNAL_RECIPIENT is not configured (still placeholder)"
else
    pass "SIGNAL_RECIPIENT is set"
fi

# --- Test 3: Script installed and executable ---
echo "3. Script installation"
if command -v claude-notify &>/dev/null; then
    pass "claude-notify is in PATH"
elif [[ -x "${HOME}/.local/bin/claude-notify" ]]; then
    pass "claude-notify found at ~/.local/bin/claude-notify"
    # Use full path for remaining tests
    CLAUDE_NOTIFY="${HOME}/.local/bin/claude-notify"
elif [[ -x "${HOME}/bin/claude-notify" ]]; then
    pass "claude-notify found at ~/bin/claude-notify"
    CLAUDE_NOTIFY="${HOME}/bin/claude-notify"
else
    fail "claude-notify not found"
fi

CLAUDE_NOTIFY="${CLAUDE_NOTIFY:-claude-notify}"

# --- Test 4: Signal API connectivity ---
echo "4. Signal API connectivity"
API_URL="${SIGNAL_API_URL:-http://localhost:8080}"

if curl -s --max-time 5 "${API_URL}/v1/about" >/dev/null 2>&1; then
    pass "Signal API reachable at ${API_URL}"
    ABOUT=$(curl -s --max-time 5 "${API_URL}/v1/about" 2>/dev/null || true)
    if [[ -n "$ABOUT" ]]; then
        echo "       API info: ${ABOUT}"
    fi
else
    fail "Signal API not reachable at ${API_URL}"
fi

# --- Test 5: Simulate events ---
echo "5. Simulating hook events"

simulate_event() {
    local name="$1"
    local json="$2"
    if echo "$json" | "$CLAUDE_NOTIFY" 2>/dev/null; then
        pass "Event ${name} -- sent (or failed silently as expected)"
    else
        # Should never happen since script always exits 0
        fail "Event ${name} -- script exited non-zero"
    fi
}

simulate_event "Stop" '{
    "hook_event_name": "Stop",
    "stop_hook_reason": "end_turn",
    "session_id": "test-session-001",
    "cwd": "/Users/terbeest/projects/test-project"
}'

simulate_event "Notification" '{
    "hook_event_name": "Notification",
    "notification": {
        "title": "Test Notification",
        "body": "This is a test notification from the test suite."
    },
    "session_id": "test-session-001",
    "cwd": "/Users/terbeest/projects/test-project"
}'

simulate_event "TaskCompleted" '{
    "hook_event_name": "TaskCompleted",
    "task": {
        "subject": "Test task completion"
    },
    "session_id": "test-session-001",
    "cwd": "/Users/terbeest/projects/test-project"
}'

simulate_event "SessionEnd" '{
    "hook_event_name": "SessionEnd",
    "session_id": "test-session-001",
    "cwd": "/Users/terbeest/projects/test-project"
}'

# --- Test 6: Filtered event (should not send) ---
echo "6. Event filtering"
# Temporarily override config to only notify on Stop
ORIG_EVENTS="$NOTIFY_EVENTS"
export NOTIFY_EVENTS="Stop"

# SessionEnd should be filtered out -- script should still exit 0
if echo '{"hook_event_name":"SessionEnd","session_id":"x","cwd":"/tmp"}' | NOTIFY_EVENTS="Stop" "$CLAUDE_NOTIFY" 2>/dev/null; then
    pass "Filtered event exits 0 (no send)"
else
    fail "Filtered event exited non-zero"
fi

# --- Test 7: Missing/bad input ---
echo "7. Error resilience"
if echo '' | "$CLAUDE_NOTIFY" 2>/dev/null; then
    pass "Empty input exits 0"
else
    fail "Empty input exited non-zero"
fi

if echo 'not json at all' | "$CLAUDE_NOTIFY" 2>/dev/null; then
    pass "Bad JSON exits 0"
else
    fail "Bad JSON exited non-zero"
fi

# --- Summary ---
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
