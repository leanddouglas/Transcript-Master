#!/usr/bin/env bash
# refresh-servus.sh — sync ~/servus-bot/ (edit dir, rsync'd from iMac)
# into the launchd runtime dir, then restart the service.
set -euo pipefail

SRC="$HOME/servus-bot/"
DST="$HOME/Library/Application Support/servus-bot/"

if [ ! -d "$SRC" ]; then
  echo "✗ Source not found: $SRC" >&2
  exit 1
fi

rsync -a --delete \
  --exclude='.venv' --exclude='__pycache__' --exclude='.git' \
  --exclude='.DS_Store' --exclude='*.log' \
  "$SRC" "$DST"

# If requirements.txt changed, re-install into the runtime venv.
if [ -f "$DST/requirements.txt" ] && [ -x "$DST/.venv/bin/pip" ]; then
  "$DST/.venv/bin/pip" install --quiet -r "$DST/requirements.txt"
fi

launchctl kickstart -k "gui/$(id -u)/com.servusgroup.ubot"
echo "✓ Refreshed and restarted servus-bot"
