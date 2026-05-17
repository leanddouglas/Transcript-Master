#!/bin/bash
# Service health snapshot. Read-only; doesn't change state.
cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/health-check.log"
{
  echo "=== health-check.command $(date) ==="
  echo
  echo "=== 1. curl -v http://100.121.62.15:8765/ ==="
  /usr/bin/curl -v --max-time 5 -o /dev/null "http://100.121.62.15:8765/" 2>&1 | head -25
  echo
  echo "=== 1b. curl HTTPS via Tailscale Serve (if configured) ==="
  /usr/bin/curl -sv --max-time 5 -o /dev/null "https://hermes-hub.tail79c077.ts.net/" 2>&1 | head -15
  echo
  echo "=== 2. lsof -i :8765 ==="
  /usr/sbin/lsof -nP -iTCP:8765 2>&1
  echo
  echo "=== 3. pgrep -fl yt-transcript / serve.py ==="
  /usr/bin/pgrep -fl 'yt-transcript|serve\.py' 2>&1
  echo
  echo "=== 4. tail -30 ~/Library/Logs/yt-transcript.log ==="
  /usr/bin/tail -30 "$HOME/Library/Logs/yt-transcript.log"
  echo
  echo "=== 5a. tailscale status ==="
  TS=""
  for c in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [[ -x "$c" ]] && "$c" ip -4 >/dev/null 2>&1 && TS="$c" && break
  done
  if [[ -n "$TS" ]]; then
    "$TS" status 2>&1 | head -20
    echo "    --- tailscale serve status ---"
    "$TS" serve status 2>&1 | sed 's/^/      /' | head -10
    echo "    --- tailscale funnel status ---"
    "$TS" funnel status 2>&1 | sed 's/^/      /' | head -5
  else
    echo "(no working tailscale CLI)"
  fi
  echo
  echo "=== 6. netstat connection count on :8765 ==="
  /usr/sbin/netstat -an 2>/dev/null | /usr/bin/grep -E '\.8765|:8765'
  echo
  echo "=== 7. process tree under launchd (com.servusgroup.yt-transcript) ==="
  /bin/launchctl list 2>/dev/null | /usr/bin/grep -i yt-transcript
  echo
  echo "=== 8. recent jobs JSON (last 5) ==="
  /bin/ls -t "$HOME/Library/Application Support/yt-transcript/jobs/"*.json 2>/dev/null | head -5 | while read f; do
    echo "  $f"
    /usr/bin/python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('   ',d.get('job_id'),d.get('status'),d.get('progress_pct',0),'%','--',d.get('filename'),'--',d.get('error',''))
" "$f"
  done
  echo
  echo "=== done $(date) ==="
} > "$LOG" 2>&1
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
