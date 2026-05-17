#!/usr/bin/env bash
# add-app.sh — one-command app deployment to the mrdapps Cloudflare Tunnel.
#
# Usage:
#   ./scripts/add-app.sh <name> <port> [hostname]
#
#   <name>      Subdomain prefix (e.g. "notes"). Also used as YAML comment label.
#   <port>      Local TCP port (1-65535) the app listens on.
#   [hostname]  Optional full hostname. Defaults to <name>.mrdapps.com.
#
# Examples:
#   ./scripts/add-app.sh notes 9000
#       → adds notes.mrdapps.com → http://localhost:9000
#
#   ./scripts/add-app.sh dash 9100 admin.mrdapps.com
#       → adds admin.mrdapps.com → http://localhost:9100
#
# What it does:
#   1. Validates args, port, and hostname idempotency.
#   2. Backs up ~/.cloudflared/config.yml (timestamped .bak).
#   3. Inserts a new ingress block ABOVE the catch-all 404 (awk, not line nums).
#   4. Runs `cloudflared tunnel route dns mrdapps <host>` (warns if it fails —
#      DNS record may already exist from a prior run).
#   5. Reloads the cloudflared LaunchAgent.
#   6. Waits ~5s, then curls the public URL and reports the HTTP status.
#
# Idempotent: re-running with an already-configured hostname is a no-op.
#
# All progress output goes to STDERR. The final summary goes to STDOUT so it
# can be captured (e.g. `add-app.sh notes 9000 > deploy.log`).

set -euo pipefail

CONFIG="${HOME}/.cloudflared/config.yml"
PLIST="${HOME}/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
TUNNEL="mrdapps"

# Colours — only if stdout is a tty.
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_OFF=''
fi

err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; }
warn() { printf '%s%s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_OFF" >&2; }
info() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/add-app.sh <name> <port> [hostname]

  <name>      Subdomain prefix (e.g. "notes"). Also used as YAML comment label.
  <port>      Local TCP port (1-65535) the app listens on.
  [hostname]  Optional full hostname. Defaults to <name>.mrdapps.com.

Examples:
  ./scripts/add-app.sh notes 9000
  ./scripts/add-app.sh dash 9100 admin.mrdapps.com
EOF
}

# --- 1. Args ----------------------------------------------------------------

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  err "ERROR: wrong number of arguments."
  usage
  exit 1
fi

NAME="$1"
PORT="$2"
HOST="${3:-${NAME}.mrdapps.com}"

# --- 2. Validate port -------------------------------------------------------

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  err "ERROR: port must be a number 1-65535, got: $PORT"
  exit 1
fi

# --- 3. Config exists -------------------------------------------------------

if [ ! -f "$CONFIG" ]; then
  err "ERROR: $CONFIG not found."
  exit 1
fi

# --- 4. Idempotency: hostname already configured? ---------------------------

if grep -qE "^[[:space:]]*-[[:space:]]*hostname:[[:space:]]*${HOST}[[:space:]]*$" "$CONFIG"; then
  ok "Already configured: $HOST is in $CONFIG. Nothing to do."
  printf '== add-app.sh — summary ==\n'
  printf '  hostname:  %s\n' "$HOST"
  printf '  status:    already-configured\n'
  printf '  config:    %s\n' "$CONFIG"
  exit 0
fi

# --- 5. Port collision warning ----------------------------------------------

if grep -qE "service:[[:space:]]*http://localhost:${PORT}([^0-9]|$)" "$CONFIG"; then
  warn "WARN: port $PORT is already used by another ingress block — proceeding anyway."
fi

# --- 6. Back up the config --------------------------------------------------

BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG" "$BACKUP"
info "Backed up config → $BACKUP"

# --- 7. Insert ingress block ABOVE the catch-all 404 ------------------------
#
# We anchor on the literal line `- service: http_status:404` (NOT line
# numbers) and buffer any leading comments/blank lines so the new block lands
# ABOVE the catch-all's own descriptive comment and the "Add new apps above
# this line" marker — exactly where a human would type it.

block_file=$(mktemp)
tmp=$(mktemp)
trap 'rm -f "$block_file" "$tmp"' EXIT

cat > "$block_file" <<EOF

  # ${NAME} app
  - hostname: ${HOST}
    service: http://localhost:${PORT}
EOF

if awk -v block_file="$block_file" '
  {
    # Buffer contiguous comment / blank lines so we can insert before them.
    if ($0 ~ /^[[:space:]]*(#.*)?$/) {
      buf[++bi] = $0
      next
    }
    if ($0 ~ /^[[:space:]]*-[[:space:]]*service:[[:space:]]*http_status:404/ && !inserted) {
      # Emit new block first, then the buffered comments, then the catch-all.
      while ((getline line < block_file) > 0) print line
      close(block_file)
      inserted = 1
      for (i = 1; i <= bi; i++) print buf[i]
      bi = 0
      print
      next
    }
    # Normal line: flush buffered comments, then print.
    for (i = 1; i <= bi; i++) print buf[i]
    bi = 0
    print
  }
  END {
    for (i = 1; i <= bi; i++) print buf[i]
    if (!inserted) exit 2
  }
' "$CONFIG" > "$tmp"; then
  mv "$tmp" "$CONFIG"
  rm -f "$block_file"
  trap - EXIT
  ok "Inserted ingress block for $HOST → http://localhost:${PORT}"
else
  err "ERROR: could not find catch-all '- service: http_status:404' line in $CONFIG."
  err "       Refusing to edit — restore from $BACKUP if anything moved."
  exit 1
fi

# --- 8. DNS route -----------------------------------------------------------

info "Creating DNS route via cloudflared..."
if cloudflared tunnel route dns "$TUNNEL" "$HOST" >&2; then
  ok "DNS record created (or already pointed at the tunnel)."
else
  warn "WARN: 'cloudflared tunnel route dns' returned non-zero."
  warn "      Most likely the CNAME already exists from a prior run — that's fine."
  warn "      Verify with: cloudflared tunnel info $TUNNEL"
fi

# --- 9. Reload cloudflared --------------------------------------------------

info "Reloading cloudflared LaunchAgent..."
launchctl unload "$PLIST" 2>/dev/null || warn "WARN: unload returned non-zero (was it loaded?)"
launchctl load   "$PLIST"
ok "Reloaded."

# --- 10. Wait & verify ------------------------------------------------------

info "Waiting 5s for tunnel to re-register..."
sleep 5

CODE=$(curl -sI "https://${HOST}/" -o /dev/null -w '%{http_code}' --max-time 10 || echo "000")

case "$CODE" in
  2*|3*|4*)
    ok "Tunnel routing works — HTTP $CODE from https://${HOST}/"
    STATUS="ok"
    ;;
  5*)
    warn "Got HTTP $CODE — tunnel reached Cloudflare, but the LOCAL app on port $PORT may not be running."
    warn "Hint: curl -s http://localhost:${PORT}/   and check the app's LaunchAgent."
    STATUS="local-app-not-responding"
    ;;
  000)
    warn "curl could not reach https://${HOST}/ — DNS may still be propagating."
    warn "Retry in ~30s: curl -sI https://${HOST}/"
    STATUS="unreachable"
    ;;
  *)
    warn "Unexpected response code: $CODE"
    STATUS="unknown"
    ;;
esac

# --- 11. Final summary (stdout) ---------------------------------------------

printf '\n'
printf '== add-app.sh — summary ==\n'
printf '  name:      %s\n' "$NAME"
printf '  hostname:  %s\n' "$HOST"
printf '  port:      %s\n' "$PORT"
printf '  http_code: %s\n' "$CODE"
printf '  status:    %s\n' "$STATUS"
printf '\n'
printf '  config:    %s\n' "$CONFIG"
printf '  backup:    %s\n' "$BACKUP"
printf '  log:       ~/Library/Logs/cloudflared.log\n'
printf '\n'
printf '  to remove: # delete the block from %s and reload\n' "$CONFIG"
