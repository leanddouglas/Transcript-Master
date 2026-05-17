#!/bin/bash
cd "$HOME/Documents/youtube-transcript-app" || exit 1
{
  echo "=== probe-ts.command $(date) ==="
  echo "--- which tailscale ---"
  which -a tailscale
  echo "--- /opt/homebrew/bin/tailscale ip -4 ---"
  /opt/homebrew/bin/tailscale ip -4 2>&1
  echo "rc=$?"
  echo "--- /opt/homebrew/bin/tailscale status (head) ---"
  /opt/homebrew/bin/tailscale status 2>&1 | head -3
  echo "rc=${PIPESTATUS[0]}"
  echo "--- brew services list | grep tailscale ---"
  brew services list 2>/dev/null | grep -i tailscale || echo "(no brew service running — good)"
  echo "--- App Store daemon (IPNExtension) ---"
  pgrep -lf 'IPNExtension|Tailscale' | head -5
} 2>&1 | tee "$HOME/Documents/youtube-transcript-app/logs/probe-ts.log"
echo
echo "Log: ~/Documents/youtube-transcript-app/probe-ts.log"
