#!/bin/bash
# Diagnose why https://hermes-hub.tail79c077.ts.net/ isn't issuing a cert.
# Read-only except for one explicit `tailscale cert` fetch which is harmless
# (caches the cert if successful). Captures everything to diagnose-tls.log.

cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/diagnose-tls.log"
HOSTNAME=hermes-hub.tail79c077.ts.net

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; }

# Find a working tailscale CLI (App Store CLI is broken on this Mac)
TS=""
for cand in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [[ -x "$cand" ]] || continue
    if "$cand" ip -4 >/dev/null 2>&1; then
        TS="$cand"; break
    fi
done

{
    echo "=== diagnose-tls.command $(date) ==="
    echo "hostname: $HOSTNAME"
    echo "tailscale CLI: ${TS:-NONE}"
    [[ -z "$TS" ]] && { fail "no working tailscale CLI found"; exit 1; }
    echo

    bold "1/8  versions"
    echo "  --- CLI version ---"
    "$TS" --version 2>&1 | sed 's/^/    /'
    echo "  --- Tailscale.app daemon version (via tailscaled) ---"
    /usr/bin/pgrep -fl 'tailscaled|Tailscale\.app' 2>&1 | head -3 | sed 's/^/    /'
    "$TS" status --json 2>/dev/null \
      | /usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); print("    daemon BackendState:", d.get("BackendState")); print("    Version:", d.get("Version")); print("    Self.Online:", d.get("Self",{}).get("Online")); print("    Self.HostName:", d.get("Self",{}).get("HostName"))' 2>&1

    bold "2/8  tailscale serve status"
    "$TS" serve status 2>&1 | sed 's/^/    /'
    echo "  --- raw serve config (--json) ---"
    "$TS" serve status --json 2>&1 | sed 's/^/    /' | head -20

    bold "3/8  tailscale funnel status"
    "$TS" funnel status 2>&1 | sed 's/^/    /'

    bold "4/8  cert fetch attempt (this is the real cert-issuance path)"
    echo "  running: $TS cert $HOSTNAME"
    CERT_DIR=$(mktemp -d)
    cd "$CERT_DIR"
    CERT_OUT=$("$TS" cert "$HOSTNAME" 2>&1)
    CERT_RC=$?
    echo "  rc=$CERT_RC"
    echo "$CERT_OUT" | sed 's/^/    /'
    if (( CERT_RC == 0 )); then
        ok "cert files written:"
        ls -la *.crt *.key 2>/dev/null | sed 's/^/    /'
        # Inspect cert
        CRT=$(ls *.crt 2>/dev/null | head -1)
        if [[ -n "$CRT" ]]; then
            echo "  --- cert subject + issuer + dates ---"
            /usr/bin/openssl x509 -in "$CRT" -noout -subject -issuer -dates 2>&1 | sed 's/^/    /'
        fi
    else
        fail "cert fetch FAILED -- this is the smoking gun"
    fi
    cd "$HOME/Documents/youtube-transcript-app"
    rm -rf "$CERT_DIR"

    bold "5/8  is anything listening on :443?"
    /usr/sbin/lsof -nP -iTCP:443 -sTCP:LISTEN 2>&1 | sed 's/^/    /' | head -10
    LSOF_443=$(/usr/sbin/lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo "    listeners on :443 = $LSOF_443"

    bold "6/8  TLS handshake probe via openssl"
    echo "  --- openssl s_client (timeout 10s) ---"
    /usr/bin/timeout 10 /usr/bin/openssl s_client -servername "$HOSTNAME" -connect "${HOSTNAME}:443" </dev/null 2>&1 \
      | head -30 | sed 's/^/    /'

    bold "7/8  curl HTTPS"
    /usr/bin/curl -vk --max-time 10 -o /dev/null "https://$HOSTNAME/" 2>&1 | head -25 | sed 's/^/    /'

    bold "8/8  recent yt-transcript log (any TLS bleed)"
    /usr/bin/tail -15 "$HOME/Library/Logs/yt-transcript.log" | sed 's/^/    /'

    echo
    bold "summary heuristics"
    if (( CERT_RC != 0 )); then
        echo "  >> tailscale cert FAILED (rc=$CERT_RC). Read its error above."
        echo "     Common causes:"
        echo "       - HTTPS Certificates not actually saved in admin console"
        echo "         (toggle off + on, force re-save)"
        echo "       - daemon still on old Tailscale.app build that lacks cert support"
        echo "         (relaunch Tailscale.app, or upgrade)"
        echo "       - rate-limited by LetsEncrypt (wait 1h)"
    elif (( LSOF_443 == 0 )); then
        echo "  >> cert exists but no listener on :443."
        echo "     'tailscale serve' was either never run, or its config dropped."
        echo "     Re-run: $TS serve --bg --https=443 http://100.121.62.15:8765"
    else
        echo "  >> cert + :443 listener look OK. TLS-handshake or proxy issue."
        echo "     Check serve config matches our app; check daemon logs."
    fi
    echo
    echo "=== done $(date) ==="
} > "$LOG" 2>&1

echo "Log: ~/Documents/youtube-transcript-app/$LOG"
