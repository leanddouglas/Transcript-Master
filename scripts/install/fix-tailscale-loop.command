#!/bin/bash
# Fix the Tailscale Serve self-proxy loop.
#
# tailscaled was configured to forward 443 -> http://100.121.62.15:8765
# (the device's own Tailscale IP). That makes the proxy hop loop back
# through the wireguard tunnel and hang. Tailscale's documented pattern
# is to forward to 127.0.0.1 instead. The serve.py change in this commit
# adds a second listener on 127.0.0.1:8765, so we can flip the serve
# target safely.
#
# Steps:
#   1. install.command  -- syncs the dual-bind serve.py and restarts launchd
#   2. tailscale serve reset
#   3. tailscale serve --bg --https=443 http://127.0.0.1:8765
#   4. verify HTTPS returns 200 from outside the loop

cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/fix-tailscale-loop.log"
HOSTNAME=hermes-hub.tail79c077.ts.net
NEW_TARGET="http://127.0.0.1:8765"
TS=/opt/homebrew/bin/tailscale

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; }

{
    echo "=== fix-tailscale-loop.command $(date) ==="
    echo "new serve target: $NEW_TARGET"
    echo

    bold "1/4  sync new serve.py (dual-bind: Tailscale IP + 127.0.0.1)"
    bash scripts/install/install.command 2>&1 | tail -25 | sed 's/^/    /'
    sleep 2
    # Confirm the loopback bind took effect
    LO=$(/usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null | grep -E '127\.0\.0\.1:8765' | head -1)
    if [[ -n "$LO" ]]; then
        ok "loopback listener up: $LO"
    else
        warn "no 127.0.0.1:8765 listener found yet (may still be starting)"
        /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null | sed 's/^/    /'
    fi

    bold "2/4  reset existing tailscale serve config"
    "$TS" serve reset 2>&1 | sed 's/^/    /'
    sleep 1

    bold "3/4  point tailscale serve at 127.0.0.1:8765"
    set -x
    "$TS" serve --bg --https=443 "$NEW_TARGET"
    SERVE_RC=$?
    set +x
    if (( SERVE_RC != 0 )); then
        fail "tailscale serve refused (rc=$SERVE_RC)"
        exit 1
    fi
    echo "  --- new serve status ---"
    "$TS" serve status 2>&1 | sed 's/^/    /'

    bold "4/4  verify HTTPS"
    sleep 4
    for i in 1 2 3 4 5 6; do
        CODE=$(/usr/bin/curl -s -o /tmp/https_body.html -w "%{http_code}" --max-time 12 "https://$HOSTNAME/")
        echo "  attempt $i: HTTPS https://$HOSTNAME/ -> $CODE"
        [[ "$CODE" == "200" ]] && break
        sleep 4
    done
    if [[ "$CODE" == "200" ]]; then
        ok "https://$HOSTNAME/ -> 200"
        echo "  first 200 chars of body:"
        head -c 200 /tmp/https_body.html | sed 's/^/    /'
    else
        fail "still not 200 (got $CODE)"
        echo "  --- curl -v tail ---"
        /usr/bin/curl -sv --max-time 12 -o /dev/null "https://$HOSTNAME/" 2>&1 | tail -25 | sed 's/^/    /'
        exit 1
    fi
    echo
    echo "  also try (control):"
    /usr/bin/curl -s --max-time 5 "https://$HOSTNAME/health"; echo

    rm -f /tmp/https_body.html
    echo
    echo "==================================================================="
    echo "  iOS / Mac / any tailnet device can now load:"
    echo "    https://$HOSTNAME/"
    echo "  RECORD tab + clipboard Copy will work (HTTPS = secure context)."
    echo "==================================================================="
    echo
    echo "=== done $(date) ==="
} 2>&1 | tee "$LOG"

echo
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
