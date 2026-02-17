# claude-signal

Signal notifications for Claude Code. Get a text on your phone every time Claude Code finishes a task, completes a session, or sends a notification -- with live plan usage included.

```
[pi] Claude Code done: my-project (end_turn)
Session: 45% ~3h · Weekly: 58% Thu 5a · Sonnet: 9%
```

## Architecture

A Raspberry Pi runs `signal-cli-rest-api` in Docker. Claude Code hooks on any machine pipe event JSON to `claude-notify`, which curls the Pi's API to send a Signal message. Machines reach the Pi over Tailscale.

```
Claude Code hook  ──curl──▶  Pi :8080 (signal-cli-rest-api)  ──▶  Your phone (Signal)
```

## Prerequisites

**Pi (notification hub):**
- Docker + Docker Compose
- `jq`
- A dedicated phone number for Signal (e.g., Google Voice)
- Claude Code installed and authenticated (for usage stats)

**Mac or other machines (optional, notification clients only):**
- `jq`, `curl`
- Tailscale (or other network path to the Pi)

## Install -- Pi

### 1. Clone and deploy

```bash
git clone https://github.com/turbobeest/claude-signal.git
cd claude-signal
./deploy-pi.sh
```

This will:
- Start `signal-cli-rest-api` in Docker on port 8080
- Install `claude-notify` to `~/bin/`
- Create config at `~/.config/claude-notify/config`
- Install a systemd user service for auto-start on boot
- Merge notification hooks into `~/.claude/settings.json`

### 2. Register your Signal number

Disable "Screen calls" in Google Voice settings first, then:

```bash
# Request voice call verification
curl -X POST 'http://localhost:8080/v1/register/+1YOURGVNUMBER' \
  -H 'Content-Type: application/json' \
  -d '{"use_voice": true}'

# Enter the code from the call
curl -X POST 'http://localhost:8080/v1/register/+1YOURGVNUMBER/verify/XXXXXX'
```

### 3. Edit config

```bash
nano ~/.config/claude-notify/config
```

Set these to real numbers:

```bash
SIGNAL_SENDER="+1YOURGVNUMBER"
SIGNAL_RECIPIENT="+1YOURPHONENUMBER"
HOSTNAME_LABEL="pi"
```

### 4. Send a test message

```bash
echo '{"hook_event_name":"Stop","session_id":"test","cwd":"/tmp/test"}' | claude-notify
```

Check your phone for a Signal message. If nothing arrives, test the API directly:

```bash
curl -X POST 'http://localhost:8080/v2/send' \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello from pi","number":"+1YOURGVNUMBER","recipients":["+1YOURPHONENUMBER"]}'
```

### 5. Run the full test suite

```bash
./test-notify.sh
```

## Install -- Mac (optional additional client)

The Mac sends notifications through the Pi's Signal API over Tailscale.

```bash
cd claude-signal
./deploy-mac.sh
```

Edit `~/.config/claude-notify/config`:

```bash
SIGNAL_API_URL="http://claudecode:8080"   # Pi hostname via Tailscale
SIGNAL_SENDER="+1YOURGVNUMBER"
SIGNAL_RECIPIENT="+1YOURPHONENUMBER"
HOSTNAME_LABEL="mac"
```

## How it works

Claude Code hooks fire `claude-notify` on these events (all async, never blocks Claude Code):

| Event | When |
|-------|------|
| `Stop` | Claude finishes a turn |
| `Notification` | Claude sends a notification |
| `TaskCompleted` | A background task completes |
| `SessionEnd` | A session ends |

Each message includes live plan usage (session %, weekly all-models %, per-model %) fetched from Anthropic's OAuth API using the same credentials Claude Code stores locally.

## Config reference

All settings live in `~/.config/claude-notify/config`. See `claude-notify.conf.example` for the full template.

| Setting | Default | Description |
|---------|---------|-------------|
| `SIGNAL_API_URL` | `http://localhost:8080` | signal-cli-rest-api endpoint |
| `SIGNAL_SENDER` | -- | Google Voice number (E.164) |
| `SIGNAL_RECIPIENT` | -- | Your phone number (E.164) |
| `VERBOSITY` | `normal` | `simple`, `normal`, or `rich` |
| `NOTIFY_EVENTS` | all four | Comma-separated event list |
| `CURL_TIMEOUT` | `5` | Seconds before giving up |
| `HOSTNAME_LABEL` | hostname | Prefix on messages: `[pi]`, `[mac]` |

## Troubleshooting

**No messages received:**
```bash
# Check the container is running
docker ps | grep signal-cli

# Check the API is responding
curl http://localhost:8080/v1/about

# Check Signal registration
curl http://localhost:8080/v1/accounts
```

**Usage stats missing from messages:**
- Claude Code must be authenticated (`claude` login)
- Token is read from `~/.config/claude-code/auth.json` (Linux) or macOS Keychain
- If the token is expired, re-login with `claude /login`

**Container doesn't start on boot:**
```bash
# Enable lingering for systemd user services
sudo loginctl enable-linger $USER
```

## Uninstall

```bash
# Remove hooks from Claude Code settings
# (manually edit ~/.claude/settings.json and remove the hooks key)

# Stop and remove container
cd claude-signal && docker compose down

# Remove installed files
rm ~/bin/claude-notify
rm -rf ~/.config/claude-notify
rm ~/.config/systemd/user/signal-cli-rest-api.service
systemctl --user daemon-reload
```
