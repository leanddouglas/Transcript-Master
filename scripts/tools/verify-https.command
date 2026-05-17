#!/bin/bash
# One-shot HTTPS verifier. Prints the actual HTTP response codes for both
# the bare hostname (Tailscale Serve / port 443) and the raw IP+port
# (direct HTTP). If HTTPS works, RECORD on iOS will work.
cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/verify-https.log"
{
  echo "=== verify-https.command $(date) ==="
  HOST=hermes-hub.tail79c077.ts.net

  echo "--- HTTPS via tailscale serve (port 443) ---"
  CODE=$(/usr/bin/curl -s -o /tmp/resp1.html -w "%{http_code}\n" --max-time 10 "https://$HOST/")
  echo "HTTPS $HOST/  -> $CODE"
  echo "first 400 chars of body:"
  /usr/bin/head -c 400 /tmp/resp1.html

  echo
  echo "--- HTTPS health endpoint ---"
  /usr/bin/curl -s --max-time 10 "https://$HOST/health"; echo

  echo
  echo "--- HTTPS jobs list ---"
  /usr/bin/curl -s --max-time 10 "https://$HOST/jobs" | /usr/bin/head -c 500; echo

  echo
  echo "--- HTTP via direct Tailscale IP+port (control: should also work) ---"
  CODE=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 "http://100.121.62.15:8765/")
  echo "HTTP 100.121.62.15:8765/  -> $CODE"

  echo
  echo "--- recent jobs (last 5) ---"
  /usr/bin/curl -s --max-time 10 "https://$HOST/jobs" \
    | /usr/bin/python3 -c '
import sys,json
xs = json.load(sys.stdin)[:5]
for x in xs:
    print(f"  {x[\"status\"]:<11} {x.get(\"progress_pct\",0):>3}%  {x[\"job_id\"]}  {x.get(\"filename\")}")
' 2>/dev/null

  rm -f /tmp/resp1.html
  echo
  echo "=== done $(date) ==="
} > "$LOG" 2>&1
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
