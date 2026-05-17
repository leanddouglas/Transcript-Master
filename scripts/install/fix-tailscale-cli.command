#!/bin/bash
# Three-step Tailscale fix:
#   1. brew upgrade tailscale  -- align CLI to current daemon
#   2. quit + relaunch Tailscale.app  -- some serve features need a daemon
#      restart to pick up admin-console flags (HTTPS Certificates toggle).
#   3. tailscale cert <host>  -- explicitly provision the cert
#   4. tailscale serve --bg --https=443 http://100.121.62.15:8765
#   5. verify with curl
#
# Idempotent. Safe to re-run.

cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/fix-tailscale-cli.log"
HOSTNAME=hermes-hub.tail79c077.ts.net
TARGET="http://100.121.62.15:8765"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; }

{
    echo "=== fix-tailscale-cli.command $(date) ==="
    echo

    bold "1/5  brew upgrade tailscale"
    if ! command -v brew >/dev/null 2>&1; then
        fail "brew not found"; exit 1
    fi
    if brew list tailscale >/dev/null 2>&1; then
        ok "tailscale already installed via brew"
        echo "  upgrading..."
        brew upgrade tailscale 2>&1 | tail -10
    else
        warn "tailscale not installed via brew yet -- installing"
        brew install tailscale 2>&1 | tail -10
    fi
    /opt/homebrew/bin/tailscale --version 2>&1 | head -1 | sed 's/^/    new CLI version: /'

    bold "2/5  relaunch Tailscale.app (so daemon picks up admin-console flags)"
    if /usr/bin/pgrep -f '/Applications/Tailscale\.app' >/dev/null 2>&1; then
        echo "  Tailscale.app is running -- asking it to quit gracefully"
        /usr/bin/osascript -e 'tell application "Tailscale" to quit' 2>&1 | sed 's/^/    /'
        sleep 4
        # Force-kill if still running
        if /usr/bin/pgrep -f '/Applications/Tailscale\.app' >/dev/null 2>&1; then
            warn "still running, sending SIGTERM"
            /usr/bin/pkill -f '/Applications/Tailscale\.app' || true
            sleep 3
        fi
    fi
    /usr/bin/open -a Tailscale 2>&1 | sed 's/^/    /'
    echo "  waiting up to 20s for daemon to come back online..."
    for i in $(seq 1 20); do
        sleep 1
        if /opt/homebrew/bin/tailscale ip -4 >/dev/null 2>&1; then
            ok "daemon back online after ${i}s"
            break
        fi
    done

    bold "3/5  explicit cert provision"
    CERT_DIR=$(mktemp -d)
    cd "$CERT_DIR"
    if /opt/homebrew/bin/tailscale cert "$HOSTNAME" 2>&1 | sed 's/^/    /'; then
        ok "cert provisioned (or already present)"
        ls -la *.crt *.key 2>/dev/null | sed 's/^/    /'
    else
        fail "tailscale cert FAILED -- HTTPS Certificates toggle may not be saved"
        fail "go to https://login.tailscale.com/admin/dns and confirm both"
        fail "MagicDNS and HTTPS Certificates are ON, then re-run."
        cd "$HOME/Documents/youtube-transcript-app"
        rm -rf "$CERT_DIR"
        exit 2
    fi
    cd "$HOME/Documents/youtube-transcript-app"
    rm -rf "$CERT_DIR"

    bold "4/5  tailscale serve (https on :443 -> $TARGET)"
    # Reset any stale serve config first (idempotent path)
    /opt/homebrew/bin/tailscale serve reset 2>&1 | sed 's/^/    /' || true
    set -x
    /opt/homebrew/bin/tailscale serve --bg --https=443 "$TARGET"
    SERVE_RC=$?
    set +x
    if (( SERVE_RC != 0 )); then
        warn "modern syntax exited $SERVE_RC, trying legacy form"
        /opt/homebrew/bin/tailscale serve https / "$TARGET" 2>&1 | sed 's/^/    /'
    fi
    echo "  --- final serve status ---"
    /opt/homebrew/bin/tailscale serve status 2>&1 | sed 's/^/    /'

    bold "5/5  verify HTTPS"
    sleep 3
    for i in 1 2 3 4 5; do
        CODE=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" --max-time 12 "https://$HOSTNAME/" 2>&1)
        echo "  attempt $i: HTTPS -> $CODE"
        [[ "$CODE" == "200" ]] && break
        sleep 4
    done
    if [[ "$CODE" == "200" ]]; then
        ok "https://$HOSTNAME/ -> 200 -- iOS RECORD will work now"
    else
        fail "still not 200 (got $CODE) -- run diagnose-tls.command for the smoking gun"
    fi

    echo
    echo "=== done $(date) ==="
} 2>&1 | tee "$LOG"

echo "Log: ~/Documents/youtube-transcript-app/$LOG"
