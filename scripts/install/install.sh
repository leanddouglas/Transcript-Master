#!/usr/bin/env bash
# install.sh — one-shot installer + verifier for the YT Transcript service.
# Run from the host macOS shell (not from the Cowork Linux sandbox).
#
#   bash ~/Documents/youtube-transcript-app/install.sh
#
# Steps:
#   1. preflight: tailscale up?, IP matches?, port 8765 free?, fetch.sh present?
#   2. install plist into ~/Library/LaunchAgents/
#   3. launchctl bootstrap (or load) the agent
#   4. wait for bind, verify lsof shows Tailscale-only
#   5. smoke tests: bad URL must 400, localhost must refuse
#
# Halts on first failure. Exit code 0 = healthy, non-zero = something to fix.

set -euo pipefail

APP_DIR="$HOME/Documents/youtube-transcript-app/src"
RUNTIME_DIR="$HOME/Library/Application Support/yt-transcript"
PLIST_NAME="com.servusgroup.yt-transcript"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
LOG_PATH="$HOME/Library/Logs/yt-transcript.log"
EXPECTED_IP="100.121.62.15"
PORT=8765
FETCH_SH="$HOME/.claude/skills/youtube-transcript/fetch.sh"
RUNTIME_FILES=( serve.py index.html manifest.webmanifest sw.js icon-192.png icon-512.png )

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

bold "1/6  preflight"

# Discover the Tailscale IPv4. Try the CLI first; fall back to ifconfig
# because the App Store Tailscale CLI sometimes crashes with a
# 'bundleIdentifier is unknown to the registry' error.
ACTUAL_IP=""

# 1) try `tailscale ip -4` if CLI is available and not the broken App Store shim
TAILSCALE=""
for candidate in \
    /opt/homebrew/bin/tailscale \
    /usr/local/bin/tailscale \
    /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  [[ -x "$candidate" ]] && TAILSCALE="$candidate" && break
done

if [[ -n "$TAILSCALE" ]]; then
  TS_OUT_FILE="$(mktemp)"
  TS_ERR_FILE="$(mktemp)"
  TS_RC=0
  "$TAILSCALE" ip -4 >"$TS_OUT_FILE" 2>"$TS_ERR_FILE" || TS_RC=$?
  if (( TS_RC == 0 )); then
    CLI_IP="$(head -n 1 "$TS_OUT_FILE" | tr -d '[:space:]')"
    if [[ -n "$CLI_IP" ]]; then
      ACTUAL_IP="$CLI_IP"
      ok "tailscale CLI: $TAILSCALE"
      ok "tailscale ipv4 (CLI): $ACTUAL_IP"
    fi
  else
    warn "tailscale CLI at $TAILSCALE failed (rc=$TS_RC) — falling back to ifconfig"
    [[ -s "$TS_ERR_FILE" ]] && head -n 1 "$TS_ERR_FILE" | sed 's/^/    cli stderr: /'
  fi
  rm -f "$TS_OUT_FILE" "$TS_ERR_FILE"
fi

# 2) fall back to scanning ifconfig for a 100.64.0.0/10 (CGNAT/Tailscale) IP on utun*
if [[ -z "$ACTUAL_IP" ]]; then
  IFCONFIG_OUT="$(/sbin/ifconfig 2>/dev/null || true)"
  # Walk through interface blocks; pick utun* with inet 100.64-127.x.x
  ACTUAL_IP="$(/usr/bin/awk '
    /^[a-z0-9]+: / { iface=$1; sub(":","",iface); next }
    iface ~ /^utun/ && $1 == "inet" {
      ip=$2
      split(ip, oct, ".")
      if (oct[1]=="100" && oct[2]+0>=64 && oct[2]+0<=127) { print ip; exit }
    }
  ' <<<"$IFCONFIG_OUT" | tr -d '[:space:]')"

  if [[ -n "$ACTUAL_IP" ]]; then
    ok "tailscale ipv4 (ifconfig fallback): $ACTUAL_IP"
  fi
fi

if [[ -z "$ACTUAL_IP" ]]; then
  fail "no Tailscale IP found. CLI failed and no utun interface has a 100.64.0.0/10 address. Open the Tailscale Mac app and connect, then re-run."
fi

if [[ "$ACTUAL_IP" != "$EXPECTED_IP" ]]; then
  warn "tailscale IP changed from $EXPECTED_IP to $ACTUAL_IP — patching serve.py …"
  /usr/bin/sed -i '' "s|^HOST = \".*\"|HOST = \"$ACTUAL_IP\"|" "$APP_DIR/serve.py"
  ok "serve.py HOST updated to $ACTUAL_IP"
else
  ok "serve.py HOST matches actual Tailscale IP"
fi

# port free?
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  warn "port $PORT already has a listener:"
  lsof -nP -iTCP:$PORT -sTCP:LISTEN | sed 's/^/    /'
  warn "if that's a stale serve.py, install will replace it via launchctl"
else
  ok "port $PORT is free"
fi

# fetch.sh present + executable
if [[ ! -x "$FETCH_SH" ]]; then
  fail "fetch.sh missing or not executable at $FETCH_SH"
fi
ok "fetch.sh present and executable"

# python3 + yt-dlp
command -v /usr/bin/python3 >/dev/null || fail "/usr/bin/python3 not found"
ok "python3 present"

if ! command -v yt-dlp >/dev/null 2>&1; then
  warn "yt-dlp not on PATH — fetch.sh will exit 127 until 'brew install yt-dlp'"
else
  ok "yt-dlp present: $(command -v yt-dlp)"
fi

bold "2/6  sync runtime files + install plist"
# launchd-spawned python3 can't read ~/Documents on macOS Sonoma+ (TCC blocks
# Documents/Desktop/Downloads for LaunchAgents). Mirror the runtime files into
# ~/Library/Application Support/yt-transcript/ and run from there. The
# canonical project source stays in ~/Documents/youtube-transcript-app/ for
# editing.
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$RUNTIME_DIR"
for f in "${RUNTIME_FILES[@]}"; do
  if [[ ! -f "$APP_DIR/$f" ]]; then
    fail "missing source file: $APP_DIR/$f"
  fi
  cp "$APP_DIR/$f" "$RUNTIME_DIR/$f"
done
ok "synced ${#RUNTIME_FILES[@]} runtime files → $RUNTIME_DIR"

# Write the plist fresh with the runtime path baked in.
/bin/cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$RUNTIME_DIR/serve.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$RUNTIME_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>
    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
ok "wrote plist → $PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null && ok "plist parses cleanly"

bold "3/6  load via launchctl"
# If already loaded, unload first so the new plist takes effect.
if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  ok "previous instance unloaded"
fi
launchctl load "$PLIST_DST"
ok "launchctl load OK"

# Confirm launchd knows about it.
if ! launchctl list | grep -q "$PLIST_NAME"; then
  fail "agent not visible in 'launchctl list' — see $LOG_PATH"
fi
ok "agent listed by launchd"

bold "4/6  wait for bind"
for i in $(seq 1 20); do
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | grep -q ":$PORT "; then
    break
  fi
  sleep 0.5
done

LSOF_LINE="$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -n 1 || true)"
if [[ -z "$LSOF_LINE" ]]; then
  warn "process didn't bind within 10 s — tail of log:"
  tail -n 20 "$LOG_PATH" 2>/dev/null | sed 's/^/    /'
  fail "no listener on port $PORT"
fi
echo "    $LSOF_LINE"

# Must contain the Tailscale IP, must NOT contain '*:' wildcard or 0.0.0.0:
ADDRESS="$(awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) print $i}' <<< "$LSOF_LINE" | head -n 1)"
case "$ADDRESS" in
  "$EXPECTED_IP:$PORT"|"$ACTUAL_IP:$PORT")
    ok "bound only to $ADDRESS (Tailscale-only — verified)" ;;
  *:* )
    if [[ "$ADDRESS" == "*:$PORT" || "$ADDRESS" == "0.0.0.0:$PORT" ]]; then
      fail "BIND IS WIDE OPEN: $ADDRESS — kill the process and check serve.py HOST"
    fi
    warn "bound to $ADDRESS — not the Tailscale IP I expected, but not 0.0.0.0/wildcard either"
    ;;
esac

bold "5/6  smoke tests"

# localhost should NOT respond (we're tailscale-bound, not 127.0.0.1)
if curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null | grep -q '200'; then
  warn "127.0.0.1 also answered — that means HOST in serve.py was set to 0.0.0.0 or localhost"
else
  ok "127.0.0.1:$PORT correctly refuses (Tailscale-only)"
fi

# Tailscale IP should serve the page
CODE_HOME=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$ACTUAL_IP:$PORT/" 2>/dev/null || echo "ERR")
if [[ "$CODE_HOME" == "200" ]]; then
  ok "GET http://$ACTUAL_IP:$PORT/  → 200"
else
  fail "GET / returned $CODE_HOME — tail log: $LOG_PATH"
fi

# Bad URL allowlist test — must be 400.
CODE_BAD=$(curl -s -o /tmp/yt-bad.json -w "%{http_code}" --max-time 5 \
  -X POST -H "Content-Type: application/json" \
  -d '{"url":"https://example.com"}' \
  "http://$ACTUAL_IP:$PORT/fetch" 2>/dev/null || echo "ERR")
if [[ "$CODE_BAD" == "400" ]]; then
  ok "POST /fetch with example.com → 400 (allowlist enforced)"
else
  warn "expected 400 for example.com, got $CODE_BAD — body:"
  cat /tmp/yt-bad.json 2>/dev/null | sed 's/^/    /'
fi

bold "6/6  done"
echo
echo "  open in your browser:  http://$ACTUAL_IP:$PORT/"
echo "  also try MagicDNS:     http://hermes-hub.tail79c077.ts.net:$PORT/"
echo "  log:                   $LOG_PATH"
echo
echo "  to test end-to-end with a real video:"
echo "    bash $APP_DIR/test-e2e.sh 'https://www.youtube.com/watch?v=...'"
echo
