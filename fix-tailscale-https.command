#!/bin/bash
# fix-tailscale-https.command
#
# Diagnose and fix HTTP 000 on https://hermes-hub.tail79c077.ts.net/
#
# ROOT CAUSE (from previous session's diagnose-tls.log + fix-tailscale-loop.log):
#   tailscale serve was pointed at http://100.121.62.15:8765 (this Mac's OWN
#   Tailscale IP). That makes the wireguard tunnel proxy back to itself —
#   tailscaled accepts on :443, decrypts, then forwards via the tunnel to
#   100.121.62.15:8765, which routes back through tailscaled. The hop hangs.
#   Curl times out → HTTP 000.
#
#   The fix on May 7 19:51 PDT changed the serve target to http://127.0.0.1:8765
#   (loopback) and serve.py was patched to dual-bind on both 100.121.62.15 and
#   127.0.0.1. That returned 200. But tailscale-serve.command (which still
#   hardcodes TARGET="http://100.121.62.15:8765") was re-run afterward, which
#   stomped the working serve config back into the looping pattern.
#
# THIS SCRIPT:
#   1. Diagnoses current state (CLI/daemon versions, serve config target, cert,
#      listener, openssl handshake, curl).
#   2. Identifies which root cause is live.
#   3. Applies the fix non-interactively if possible:
#        - if loopback listener missing, runs install.command first
#        - tailscale serve reset
#        - tailscale serve --bg --https=443 http://127.0.0.1:8765
#   4. Re-verifies with curl. Up to 6 retries (cert provisioning is async).
#   5. STOPS and prints exact instructions if it hits something requiring
#      Doug's hands (brew upgrade, app relaunch, cert ratelimit).
#
# Idempotent. Safe to run repeatedly.

set -u
cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/fix-tailscale-https.log"
HOSTNAME="hermes-hub.tail79c077.ts.net"
GOOD_TARGET="http://127.0.0.1:8765"
BAD_TARGET_PATTERN="100\\.121\\.62\\.15:8765"   # loops; do not use as serve upstream
BACKEND_PORT=8765

mkdir -p "$(dirname "$LOG")"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; }
hr()   { printf -- '-----------------------------------------------------------------\n'; }

# Run main flow inside a tee so all output is captured.
{
echo "=== fix-tailscale-https.command $(date) ==="
echo "hostname:        $HOSTNAME"
echo "good target:     $GOOD_TARGET"
echo "bad target rx:   $BAD_TARGET_PATTERN"
echo

# -----------------------------------------------------------------
# 1. Detect a working tailscale CLI.
# -----------------------------------------------------------------
bold "1/9  detect viable tailscale CLI"
TS=""
for cand in \
        /opt/homebrew/bin/tailscale \
        /usr/local/bin/tailscale \
        /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [[ -x "$cand" ]] || continue
    if "$cand" ip -4 >/dev/null 2>&1; then
        TS="$cand"
        ok "using working CLI: $TS"
        "$TS" --version 2>/dev/null | head -1 | sed 's/^/      version: /'
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

# -----------------------------------------------------------------
# 2. CLI vs daemon version. Warning-only — observed mismatch
#    1.96.4 client / 1.96.5 daemon has not actually broken serve
#    on this Mac; previous fix worked despite it.
# -----------------------------------------------------------------
bold "2/9  CLI vs daemon version"
CLI_VER=$("$TS" --version 2>/dev/null | head -1)
DAEMON_VER=$("$TS" status --self=true --peers=false 2>&1 | grep -oE 'Version:[^[:space:]]+' | head -1)
echo "    cli:    $CLI_VER"
echo "    daemon: ${DAEMON_VER:-unknown}"
# Capture "Warning: client version ... != tailscaled server version ..." once
VER_WARN=$("$TS" serve status 2>&1 | grep -i "client version" | head -1)
if [[ -n "$VER_WARN" ]]; then
    warn "$VER_WARN"
    warn "(observed not to block serve on this Mac; continuing)"
fi

# -----------------------------------------------------------------
# 3. Current serve config — this is where the regression shows.
# -----------------------------------------------------------------
bold "3/9  current tailscale serve config"
SERVE_STATUS=$("$TS" serve status 2>&1)
SERVE_JSON=$("$TS" serve status --json 2>&1 || true)
echo "$SERVE_STATUS" | sed 's/^/    /'

CURRENT_TARGET=""
if [[ -n "$SERVE_JSON" ]]; then
    # Pull the Proxy upstream out of the JSON, no jq dependency.
    CURRENT_TARGET=$(echo "$SERVE_JSON" \
        | tr -d '\n' \
        | grep -oE '"Proxy"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"Proxy"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
fi
if [[ -n "$CURRENT_TARGET" ]]; then
    ok "current serve upstream: $CURRENT_TARGET"
else
    warn "no serve upstream currently configured"
fi

# -----------------------------------------------------------------
# 4. Cert state — one-shot fetch tells us if cert provisioning works.
#    Run from a temp dir so we don't litter $HOME/Documents/yt... with
#    stray .crt/.key files.
# -----------------------------------------------------------------
bold "4/9  cert fetch (canonical cert-provision path)"
CERT_TMP=$(mktemp -d)
CERT_OUT=$(cd "$CERT_TMP" && "$TS" cert "$HOSTNAME" 2>&1)
CERT_RC=$?
echo "$CERT_OUT" | sed 's/^/    /'
echo "    rc=$CERT_RC"
CERT_OK=0
if (( CERT_RC == 0 )) && [[ -s "$CERT_TMP/$HOSTNAME.crt" ]]; then
    CERT_OK=1
    SUBJ=$(/usr/bin/openssl x509 -in "$CERT_TMP/$HOSTNAME.crt" -noout -subject 2>/dev/null)
    NA=$(/usr/bin/openssl x509 -in "$CERT_TMP/$HOSTNAME.crt" -noout -enddate 2>/dev/null)
    ok "cert provisioned ($SUBJ; $NA)"
fi
rm -rf "$CERT_TMP"

if (( CERT_OK == 0 )); then
    fail "tailscale cert <hostname> FAILED. This is the blocker."
    fail
    fail "Cert-fetch is the canonical proof that ACME-via-tailnet works."
    fail "If this fails, tailscale serve HTTPS cannot succeed regardless of"
    fail "anything else this script does."
    fail
    fail "Common reasons:"
    fail "  * MagicDNS or HTTPS Certificates disabled in admin console"
    fail "    (Doug confirmed both ON, but worth double-checking:"
    fail "     login.tailscale.com/admin/dns)"
    fail "  * Let's Encrypt rate limit hit (rare, ~5 certs/week per host)"
    fail "  * Tailscale daemon not actually online — try:"
    fail "      sudo launchctl kickstart -k system/com.tailscale.tailscaled"
    fail "  * CLI version mismatch is real — try:"
    fail "      brew upgrade tailscale"
    fail "      then relaunch Tailscale.app from /Applications"
    fail
    fail "STOPPING. Need Doug to act on the above before this script can fix HTTPS."
    exit 2
fi

# -----------------------------------------------------------------
# 5. Listener checks. tailscaled accepts :443 on the Tailscale net
#    interface — lsof on 0.0.0.0:443 won't always show it. We check
#    8765 (the backend) more carefully, since the loopback bind on
#    127.0.0.1:8765 IS what makes the loop-free serve target work.
# -----------------------------------------------------------------
bold "5/9  who is listening on 443 + 8765"
echo "    --- :443 (tailscaled internal; may be empty) ---"
/usr/sbin/lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null | sed 's/^/      /'
echo "    --- :$BACKEND_PORT (yt-transcript backend) ---"
PORT_LSOF=$(/usr/sbin/lsof -nP -iTCP:"$BACKEND_PORT" -sTCP:LISTEN 2>/dev/null)
echo "$PORT_LSOF" | sed 's/^/      /'

LO_LISTEN=0
TS_LISTEN=0
echo "$PORT_LSOF" | grep -qE "127\.0\.0\.1:$BACKEND_PORT" && LO_LISTEN=1
echo "$PORT_LSOF" | grep -qE "100\.121\.62\.15:$BACKEND_PORT" && TS_LISTEN=1
[[ $LO_LISTEN -eq 1 ]] && ok  "loopback listener present (127.0.0.1:$BACKEND_PORT)"
[[ $TS_LISTEN -eq 1 ]] && ok  "tailscale-IP listener present (100.121.62.15:$BACKEND_PORT)"
[[ $LO_LISTEN -eq 0 ]] && warn "no loopback listener — serve.py dual-bind is missing"

# -----------------------------------------------------------------
# 6. TLS handshake probe. /usr/bin/timeout doesn't exist on macOS,
#    so we use a curl-based handshake test (--connect-timeout).
#    This separates "TLS works but proxy hangs" from "TLS broken".
# -----------------------------------------------------------------
bold "6/9  TLS handshake probe (curl --connect-timeout)"
CURL_HANDSHAKE=$(/usr/bin/curl -svk --connect-timeout 8 --max-time 10 \
    -o /dev/null "https://$HOSTNAME/" 2>&1 | tail -25)
echo "$CURL_HANDSHAKE" | sed 's/^/    /'
TLS_OK=0
echo "$CURL_HANDSHAKE" | grep -qiE "(SSL connection using|TLS handshake, Finished)" && TLS_OK=1
[[ $TLS_OK -eq 1 ]] && ok "TLS handshake completes — cert is being served"

# -----------------------------------------------------------------
# 7. Decide which fix to apply.
# -----------------------------------------------------------------
bold "7/9  diagnosis"
NEED_INSTALL=0
NEED_RESET=0
NEED_SET=0
DIAG=""

if [[ "$CURRENT_TARGET" == "$GOOD_TARGET" ]]; then
    DIAG="serve config already points at $GOOD_TARGET (loopback)"
    ok "$DIAG"
    # Maybe the only thing wrong is the backend isn't bound on loopback.
    if (( LO_LISTEN == 0 )); then
        NEED_INSTALL=1
        warn "but loopback listener missing — install.command will fix"
    fi
elif [[ -n "$CURRENT_TARGET" ]] && echo "$CURRENT_TARGET" | grep -qE "$BAD_TARGET_PATTERN"; then
    DIAG="serve points at $CURRENT_TARGET — SELF-PROXY LOOP through wireguard"
    fail "$DIAG"
    fail "this is the regression from re-running tailscale-serve.command"
    NEED_RESET=1
    NEED_SET=1
    (( LO_LISTEN == 0 )) && NEED_INSTALL=1
elif [[ -z "$CURRENT_TARGET" ]]; then
    DIAG="no serve config present"
    warn "$DIAG"
    NEED_SET=1
    (( LO_LISTEN == 0 )) && NEED_INSTALL=1
else
    DIAG="serve points at $CURRENT_TARGET — unexpected upstream"
    fail "$DIAG"
    fail "refusing to clobber an unrecognised serve config."
    fail "review with:  $TS serve status"
    fail "to wipe:      $TS serve reset    (then re-run this script)"
    exit 3
fi

# -----------------------------------------------------------------
# 8. Apply the fix.
# -----------------------------------------------------------------
bold "8/9  applying fix"
if (( NEED_INSTALL == 1 )); then
    bold "  8a. install.command (sync serve.py with dual-bind, restart launchd)"
    if [[ -x scripts/install/install.command ]]; then
        bash scripts/install/install.command 2>&1 | tail -20 | sed 's/^/      /'
    elif [[ -x install.command ]]; then
        bash install.command 2>&1 | tail -20 | sed 's/^/      /'
    else
        fail "install.command not found — can't restore loopback listener"
        fail "STOP. Doug needs to confirm install.command path."
        exit 4
    fi
    sleep 3
    if /usr/sbin/lsof -nP -iTCP:"$BACKEND_PORT" -sTCP:LISTEN 2>/dev/null | grep -qE "127\.0\.0\.1:$BACKEND_PORT"; then
        ok "loopback listener up after install"
    else
        fail "loopback listener still missing after install.command"
        fail "tail this for clues:  ~/Library/Logs/yt-transcript.log"
        exit 4
    fi
fi

if (( NEED_RESET == 1 )); then
    bold "  8b. tailscale serve reset (clears looping config)"
    "$TS" serve reset 2>&1 | sed 's/^/      /'
    sleep 1
fi

if (( NEED_SET == 1 )); then
    bold "  8c. tailscale serve --bg --https=443 $GOOD_TARGET"
    if ! "$TS" serve --bg --https=443 "$GOOD_TARGET" 2>&1 | sed 's/^/      /'; then
        fail "tailscale serve refused. Try:"
        fail "  brew upgrade tailscale && open /Applications/Tailscale.app"
        fail "then re-run this script."
        exit 5
    fi
fi

bold "  8d. new serve status"
"$TS" serve status 2>&1 | sed 's/^/      /'

# -----------------------------------------------------------------
# 9. Verify HTTPS. Cert provisioning can be async — retry up to 6x.
# -----------------------------------------------------------------
bold "9/9  verify HTTPS"
sleep 3
CODE=000
BODY_FILE=$(mktemp)
for i in 1 2 3 4 5 6; do
    CODE=$(/usr/bin/curl -sk -o "$BODY_FILE" -w "%{http_code}" \
        --connect-timeout 8 --max-time 15 "https://$HOSTNAME/")
    echo "    attempt $i: GET https://$HOSTNAME/  ->  $CODE"
    [[ "$CODE" == "200" ]] && break
    sleep 4
done

if [[ "$CODE" == "200" ]]; then
    ok "HTTPS reachable (200)"
    echo "    --- first 200 chars ---"
    head -c 200 "$BODY_FILE" | sed 's/^/      /'
    echo
    # Health endpoint as a control.
    HEALTH=$(/usr/bin/curl -sk --max-time 5 "https://$HOSTNAME/health")
    echo "    /health -> $HEALTH"
    rm -f "$BODY_FILE"
    hr
    echo "READY: open https://$HOSTNAME/ on your iPhone now"
    hr
    echo
    echo "=== fix-tailscale-https.command done $(date) ==="
    exit 0
else
    fail "HTTPS still not 200 (got $CODE)"
    rm -f "$BODY_FILE"
    echo "    --- curl -v tail ---"
    /usr/bin/curl -svk --connect-timeout 8 --max-time 15 -o /dev/null \
        "https://$HOSTNAME/" 2>&1 | tail -25 | sed 's/^/      /'
    echo
    fail "Possible next moves (need Doug):"
    fail "  1. brew upgrade tailscale && open /Applications/Tailscale.app"
    fail "     (align CLI 1.96.4 with daemon 1.96.5)"
    fail "  2. sudo launchctl kickstart -k system/com.tailscale.tailscaled"
    fail "     (force-restart the daemon, then re-run this script)"
    fail "  3. Inspect logs:"
    fail "       ~/Library/Logs/yt-transcript.log     (backend)"
    fail "       /var/log/system.log | grep tailscale (daemon)"
    echo
    echo "=== fix-tailscale-https.command done $(date) ==="
    exit 6
fi

} 2>&1 | tee "$LOG"

echo
echo "Log: $LOG"
echo "You can close this window."
