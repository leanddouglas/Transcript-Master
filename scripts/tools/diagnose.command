#!/bin/bash
# Diagnostic dump: capture state of the yt-transcript service + Tailscale.
cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/diagnose.log"
{
  echo "=== diagnose.command $(date) ==="
  echo "host: $(hostname)"
  echo
  echo "=== 1. launchctl list | grep yt-transcript ==="
  /bin/launchctl list 2>/dev/null | grep -i yt-transcript || echo "(no yt-transcript agent loaded)"
  echo
  echo "=== 2. lsof -i :8765 ==="
  /usr/sbin/lsof -nP -iTCP:8765 2>/dev/null || echo "(nothing listening on 8765)"
  echo
  echo "=== 3. pgrep -fl serve.py ==="
  /usr/bin/pgrep -fl 'serve\.py' || echo "(no serve.py process)"
  echo
  echo "=== 4. tail -60 ~/Library/Logs/yt-transcript.log ==="
  /usr/bin/tail -60 "$HOME/Library/Logs/yt-transcript.log" 2>/dev/null || echo "(no log file)"
  echo
  echo "=== 5. curl -v http://100.121.62.15:8765/ (local Mac) ==="
  /usr/bin/curl -v --max-time 5 -o /dev/null "http://100.121.62.15:8765/" 2>&1 | head -40
  echo
  echo "=== 5b. curl -v http://127.0.0.1:8765/ (loopback) ==="
  /usr/bin/curl -v --max-time 3 -o /dev/null "http://127.0.0.1:8765/" 2>&1 | head -20
  echo
  echo "=== 6a. ifconfig — utun + tailscale interfaces ==="
  /sbin/ifconfig 2>/dev/null | /usr/bin/awk '
    /^[a-z0-9]+: / { iface=$1; sub(":","",iface); flag=0 }
    iface ~ /^utun/ && /inet 100\./ { print iface, $0; flag=1 }
    flag && /^[a-z0-9]+: / { flag=0 }
  '
  echo
  echo "=== 6b. tailscaled launchd ==="
  /bin/launchctl list 2>/dev/null | grep -i tailscale || echo "(no tailscale agents)"
  /bin/launchctl print system/com.tailscale.tailscaled 2>/dev/null | /usr/bin/grep -E 'state =|last exit code' | head -5 || true
  echo
  echo "=== 6c. /opt/homebrew/bin/tailscale status (brew CLI, talks to App Store daemon) ==="
  /opt/homebrew/bin/tailscale status 2>&1 | head -10
  echo
  echo "=== 6d. App Store Tailscale process ==="
  /usr/bin/pgrep -fl 'IPNExtension|/Applications/Tailscale\.app' | head -5
  echo
  echo "=== 7a. scutil --dns | grep -i tail ==="
  /usr/sbin/scutil --dns 2>/dev/null | /usr/bin/grep -i 'tail\|domain' | head -10
  echo
  echo "=== 7b. dig hermes-hub.tail79c077.ts.net ==="
  /usr/bin/dig +short hermes-hub.tail79c077.ts.net 2>&1 | head -5
  echo
  echo "=== 7c. ping -c 2 -W 1 100.121.62.15 ==="
  /sbin/ping -c 2 -W 1 100.121.62.15 2>&1 | head -8
  echo
  echo "=== 8. plist content (sanity) ==="
  /usr/bin/plutil -p "$HOME/Library/LaunchAgents/com.servusgroup.yt-transcript.plist" 2>&1 | head -25
  echo
  echo "=== 9. runtime serve.py mtime ==="
  /bin/ls -la "$HOME/Library/Application Support/yt-transcript/serve.py" 2>&1
  echo
  echo "=== 10. last few lines of stdout/stderr from launchd ==="
  /usr/bin/tail -10 "$HOME/Library/Logs/yt-transcript.log" 2>/dev/null
  echo
  echo "=== done $(date) ==="
} > "$LOG" 2>&1

echo
echo "Diagnostic written to ~/Documents/youtube-transcript-app/$LOG"
echo "You can close this window."
