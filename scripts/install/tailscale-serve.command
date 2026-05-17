#!/bin/bash
# Expose the YT transcript app at https://hermes-hub.tail79c077.ts.net/ via
# Tailscale Serve. Real cert from Tailscale's MagicDNS infrastructure,
# tailnet-only by default (Funnel = public; Serve = tailnet only).
#
# Why: iOS Safari MediaRecorder requires isSecureContext, which means HTTPS.
# Plain http://hermes-hub.tail79c077.ts.net:8765/ does not qualify.
#
# Idempotent. If Serve already points at this app, exits 0 with no change.
# If Serve points at something else, prints the current config and refuses
# to clobber it. Run `tailscale serve reset` first if you want a clean slate.

cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/tailscale-serve.log"
TARGET="http://100.121.62.15:8765"
HOSTNAME="hermes-hub.tail79c077.ts.net"

# Define helpers at top-level (the { ... } | tee block runs in a subshell;
# functions defined out here are still inherited).
bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; }

verify_https() {
    bold "verify HTTPS reachable"
    sleep 2
    local URL="https://$HOSTNAME/"
    local CODE
    CODE=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" --max-time 12 "$URL" 2>&1)
    if [[ "$CODE" == "200" ]]; then
        ok "GET $URL -> 200 (cert verified)"
    else
        warn "GET $URL -> $CODE"
        fail "If this is the first run, Tailscale may need ~30s to provision"
        fail "the LetsEncrypt-via-tailnet cert. Re-run this script in a minute."
    fi
    echo
    echo "==================================================================="
    echo "  iOS / Mac / any tailnet device can now load:"
    echo "    https://$HOSTNAME/"
    echo "  RECORD tab will work (HTTPS = isSecureContext = MediaRecorder)."
    echo "  Clipboard Copy works without long-press fallback."
    echo "==================================================================="
}

{
    echo "=== tailscale-serve.command $(date) ==="
    echo "target:   $TARGET"
    echo "hostname: $HOSTNAME"
    echo

    bold "1/5 detect viable tailscale CLI"
    TS=""
    # Order: brew (known-working) > /usr/local (App Store, broken on this Mac
    # with bundleIdentifier crash) > the .app binary directly.
    for cand in \
            /opt/homebrew/bin/tailscale \
            /usr/local/bin/tailscale \
            /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        [[ -x "$cand" ]] || continue
        # Smoke test: can it return its own IP without crashing?
        if "$cand" ip -4 >/dev/null 2>&1; then
            TS="$cand"
            ok "using working CLI: $TS"
            break
        else
            warn "CLI present but errors out (skipping): $cand"
        fi
    done
    if [[ -z "$TS" ]]; then
        fail "no working tailscale CLI found"
        fail "install one with:  brew install tailscale"
        exit 1
    fi
    "$TS" --version 2>/dev/null | head -1 | sed 's/^/    version: /'

    bold "2/5 check existing serve/funnel state"
    SERVE_FILE=$(mktemp)
    FUNNEL_FILE=$(mktemp)
    "$TS" serve  status >"$SERVE_FILE"  2>&1 || true
    "$TS" funnel status >"$FUNNEL_FILE" 2>&1 || true

    echo "    --- tailscale serve status ---"
    sed 's/^/      /' "$SERVE_FILE"
    echo "    --- tailscale funnel status ---"
    sed 's/^/      /' "$FUNNEL_FILE"

    # Idempotent path: if serve already points at our target, exit 0.
    if grep -qF "$TARGET" "$SERVE_FILE" 2>/dev/null; then
        ok "serve already points at $TARGET -- nothing to change"
        rm -f "$SERVE_FILE" "$FUNNEL_FILE"
        verify_https
        echo
        echo "=== tailscale-serve.command done $(date) ==="
        exit 0
    fi

    # Refuse to clobber any existing :443 / https config that's NOT us.
    HAS_OTHER=0
    if grep -qE "https://|:443|proxy http" "$SERVE_FILE" 2>/dev/null \
       && ! grep -qiE "^[[:space:]]*$|no serve config|no serve" "$SERVE_FILE"; then
        HAS_OTHER=1
    fi
    if (( HAS_OTHER == 1 )); then
        fail "serve has an existing config that does NOT match our target."
        fail "current serve config (above) needs review."
        fail
        fail "to wipe and start fresh:"
        fail "    $TS serve reset"
        fail "then re-run this script."
        rm -f "$SERVE_FILE" "$FUNNEL_FILE"
        exit 2
    fi

    # Funnel warning: if Funnel is on, our Serve route will be public.
    FUNNEL_ON=0
    if grep -qiE "funnel on|funneling|public.*on" "$FUNNEL_FILE" 2>/dev/null; then
        FUNNEL_ON=1
    fi
    # Cross-check via tailscale status (where the earlier diagnostic showed
    # `# Funnel on:` for this device).
    if "$TS" status 2>/dev/null | grep -qiE "funnel on"; then
        FUNNEL_ON=1
    fi
    if (( FUNNEL_ON == 1 )); then
        warn "Funnel appears to be ON for this device."
        warn "That would expose this app PUBLICLY on the internet."
        warn "If you want tailnet-only access, run AFTER this script:"
        warn "    $TS funnel reset"
    fi

    rm -f "$SERVE_FILE" "$FUNNEL_FILE"

    bold "3/5 enable tailscale serve"
    # Modern (1.50+) syntax: --bg --https=443 followed by the upstream target.
    SERVE_RC=0
    if ! "$TS" serve --bg --https=443 "$TARGET" 2>&1; then
        SERVE_RC=$?
        warn "modern syntax exited $SERVE_RC; trying legacy 'serve https / proxy <target>' form"
        SERVE_RC=0
        "$TS" serve https / "$TARGET" 2>&1 || SERVE_RC=$?
    fi
    if (( SERVE_RC != 0 )); then
        fail "tailscale serve refused both syntaxes (rc=$SERVE_RC)"
        fail "your tailscale daemon may be too old; try: brew upgrade tailscale"
        exit 1
    fi
    ok "serve route configured: https://$HOSTNAME/  ->  $TARGET"

    bold "4/5 confirm new state"
    "$TS" serve status 2>&1 | sed 's/^/    /'

    verify_https

    echo
    echo "=== tailscale-serve.command done $(date) ==="
} 2>&1 | tee "$LOG"

echo
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
echo "You can close this window."
