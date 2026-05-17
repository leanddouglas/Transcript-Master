#!/usr/bin/env bash
# test-e2e.sh — full end-to-end test with a real YouTube URL.
# Usage: bash test-e2e.sh 'https://www.youtube.com/watch?v=...'
#
# What this checks:
#   - POST /fetch returns the cleaned transcript text
#   - corresponding .txt landed in the vault inbox
#   - KeepAlive: kill serve.py, wait, confirm it comes back

set -euo pipefail

URL="${1:-}"
PORT=8765
INBOX="$HOME/Obsidian/MrD-Brain/inbox/youtube"
LOG_PATH="$HOME/Library/Logs/yt-transcript.log"

# Derive the bind IP from the live socket itself — robust to App Store
# Tailscale CLI bugs.
IP="$(/usr/sbin/lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null \
       | awk '/LISTEN/ { for (i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/) { sub(/:.*/,"",$i); print $i; exit } }')"
if [[ -z "$IP" ]]; then
  echo "no listener on port $PORT — run install.command first"; exit 1
fi

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

if [[ -z "$URL" ]]; then
  echo "usage: bash test-e2e.sh 'https://www.youtube.com/watch?v=...'"
  exit 2
fi

bold "1/3  POST /fetch"
BEFORE_COUNT=$(ls -1 "$INBOX"/*.txt 2>/dev/null | wc -l | tr -d ' ')
RESP=$(mktemp)
CODE=$(curl -s -o "$RESP" -w "%{http_code}" --max-time 180 \
  -X POST -H "Content-Type: application/json" \
  -d "$(printf '{"url":"%s"}' "$URL")" \
  "http://$IP:$PORT/fetch")
if [[ "$CODE" != "200" ]]; then
  echo "    HTTP $CODE — body:"; cat "$RESP" | sed 's/^/    /'
  fail "fetch failed"
fi
FILENAME=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["filename"])' "$RESP")
LEN=$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["text"]))' "$RESP")
ok "filename: $FILENAME  ($LEN chars)"

bold "2/3  vault file"
AFTER_COUNT=$(ls -1 "$INBOX"/*.txt 2>/dev/null | wc -l | tr -d ' ')
if (( AFTER_COUNT > BEFORE_COUNT )); then
  ok "$INBOX gained $((AFTER_COUNT - BEFORE_COUNT)) file(s)"
elif [[ -f "$INBOX/$FILENAME" ]]; then
  ok "$INBOX/$FILENAME exists (was already there)"
else
  fail "expected file not in vault inbox: $INBOX/$FILENAME"
fi

bold "3/3  KeepAlive"
PID=$(pgrep -f 'serve\.py' | head -n 1 || true)
if [[ -z "$PID" ]]; then
  fail "no serve.py process running"
fi
echo "    killing pid $PID …"
kill "$PID" 2>/dev/null || true
sleep 6
NEW_PID=$(pgrep -f 'serve\.py' | head -n 1 || true)
if [[ -z "$NEW_PID" || "$NEW_PID" == "$PID" ]]; then
  fail "KeepAlive didn't restart serve.py — old=$PID new=${NEW_PID:-none}"
fi
ok "launchd brought up new pid $NEW_PID (old was $PID)"

# Confirm it's serving again.
sleep 1
CODE2=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$IP:$PORT/" || echo ERR)
[[ "$CODE2" == "200" ]] || fail "service didn't come back: GET / → $CODE2"
ok "service back up at http://$IP:$PORT/"

echo
echo "all e2e checks passed."
