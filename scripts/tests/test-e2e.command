#!/bin/bash
# Double-clickable e2e test. Uses "Me at the zoo" (the first YouTube video, jNQXAC9IVRw)
# because it's short, has English subs, and is unlikely to ever go away.
cd "$HOME/Documents/youtube-transcript-app" || exit 1
{
  echo "=== test-e2e.command started $(date) ==="
  bash scripts/tests/test-e2e.sh 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
  RC=$?
  echo "=== test-e2e.sh exited rc=$RC ==="
} 2>&1 | tee "$HOME/Documents/youtube-transcript-app/logs/test-e2e.log"
echo
echo "Log written to ~/Documents/youtube-transcript-app/logs/test-e2e.log"
echo "You can close this window."
