#!/bin/bash
# Double-clickable wrapper. Runs install.sh and tees everything to install.log
# so a non-interactive driver can read the result.
cd "$HOME/Documents/youtube-transcript-app/scripts/install" || exit 1
{
  echo "=== install.command started $(date) ==="
  bash ./install.sh
  RC=$?
  echo "=== install.sh exited rc=$RC ==="
} 2>&1 | tee "$HOME/Documents/youtube-transcript-app/logs/install.log"
echo
echo "Log written to ~/Documents/youtube-transcript-app/logs/install.log"
echo "You can close this window."
