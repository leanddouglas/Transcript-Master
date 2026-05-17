#!/bin/bash
# record-call.command
#
# One-button call recorder. Captures mic + system audio simultaneously via
# the BlackHole virtual audio driver, saves a timestamped .m4a to the
# vault inbox, and (optionally) uploads it straight to /transcribe so the
# transcript lands in MrD-Brain/Inbox/youtube/ a few minutes later.
#
# Workflow:
#   1. double-click this file (opens Terminal)
#   2. follow on-screen prompts (BlackHole install, output routing)
#   3. start the call
#   4. Ctrl+C in this terminal when done
#   5. confirm "Upload? Y" -> transcript shows up in your vault
#
# Heads-up: recording calls without consent is illegal in some places.
# Tell the other party at the start: "I'm capturing this for my notes."

set -o pipefail
cd "$HOME/Documents/youtube-transcript-app" || exit 1

RECORDINGS_DIR="$HOME/Documents/youtube-transcript-app/recordings"
mkdir -p "$RECORDINGS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEFAULT_LABEL="call"
FFMPEG=/opt/homebrew/bin/ffmpeg
SERVER_URL="https://hermes-hub.tail79c077.ts.net"
LOOPBACK_URL="http://127.0.0.1:8765"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; }

clear
cat <<'BANNER'
====================================================================
  Call Recorder  --  hermes-hub
  Captures mic + system audio, saves to vault, optional auto-upload.
====================================================================
BANNER

# --------- 1) ffmpeg present? ---------
if [[ ! -x "$FFMPEG" ]]; then
    fail "ffmpeg missing at $FFMPEG -- run install-whisper.command first"
    read -p "press enter to exit "
    exit 1
fi
ok "ffmpeg: $FFMPEG"

# --------- 2) BlackHole present? ---------
bold "checking BlackHole virtual audio driver"
BH_INSTALLED=0
if brew list blackhole-2ch >/dev/null 2>&1; then
    ok "BlackHole 2ch already installed via brew"
    BH_INSTALLED=1
fi
# Even if not via brew, BlackHole could be installed manually --
# detect it from ffmpeg's device list later.

if (( BH_INSTALLED == 0 )); then
    warn "BlackHole 2ch not detected via brew."
    echo
    echo "    BlackHole is a free virtual audio driver. It's required so"
    echo "    we can capture the OTHER side of a call (the other party's"
    echo "    voice played out of your speakers). Without it, we can only"
    echo "    record YOUR mic."
    echo
    read -p "    install BlackHole now? [y/N] " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        brew install blackhole-2ch || { fail "brew install failed"; }
        if brew list blackhole-2ch >/dev/null 2>&1; then
            ok "BlackHole installed"
            echo
            echo "    macOS may need to grant permission for the audio driver."
            echo "    If recording produces silence, open:"
            echo "      System Settings -> Privacy & Security"
            echo "    and approve the 'Existential Audio' kernel extension."
            BH_INSTALLED=1
        fi
    else
        warn "skipping BlackHole install -- will record MIC ONLY"
    fi
fi

# --------- 3) detect device indices via ffmpeg avfoundation ---------
bold "detecting audio devices"
DEVICES=$("$FFMPEG" -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true)

# Print just the audio devices section so the user can see what's available.
echo "$DEVICES" | /usr/bin/awk '
    /AVFoundation audio devices/{flag=1; next}
    /AVFoundation video devices/{flag=0}
    flag{ print "    " $0 }
'

# avfoundation lines look like:
#     [AVFoundation indev @ 0x...] [0] MacBook Pro Microphone
# We need the [0] index from each.
parse_idx() {
    # $1 = grep pattern (case-insensitive)
    echo "$DEVICES" \
      | /usr/bin/awk '/AVFoundation audio devices/,/AVFoundation video devices/' \
      | /usr/bin/grep -iE "$1" \
      | /usr/bin/head -1 \
      | /usr/bin/sed -nE 's/.*\] \[([0-9]+)\] .*/\1/p'
}

MIC_IDX=$(parse_idx 'mac.*microphone|built-in microphone|built-in mic|airpods|microphone')
BH_IDX=$(parse_idx 'blackhole')

if [[ -z "$MIC_IDX" ]]; then
    fail "could not detect a microphone in ffmpeg's avfoundation list"
    fail "above output should show audio devices -- copy + paste back to me"
    read -p "press enter to exit "
    exit 1
fi
ok "mic device index = $MIC_IDX"

if [[ -n "$BH_IDX" ]]; then
    ok "BlackHole device index = $BH_IDX"
    DUAL=1
else
    if (( BH_INSTALLED == 1 )); then
        warn "BlackHole installed but not visible to ffmpeg yet"
        warn "macOS sometimes needs a logout/login for new audio drivers"
        warn "falling back to mic-only recording for this session"
    fi
    DUAL=0
fi

# --------- 4) one-time output-routing instructions for BlackHole ---------
if (( DUAL == 1 )); then
    bold "one-time macOS audio routing"
    cat <<'INSTRUCTIONS'
    To capture the OTHER side of a call (Slack huddle, WhatsApp Mac,
    Zoom, etc.), system audio output must be routed to BlackHole.
    Easiest way:

      1. Open Audio MIDI Setup  (Applications -> Utilities)
      2. Click + (lower-left) -> Create Multi-Output Device
      3. Check both 'Built-in Output' (or your headphones) AND 'BlackHole 2ch'
      4. Right-click the new Multi-Output Device -> 'Use This Device for Sound Output'
         (or pick it from the menu-bar audio dropdown)

    From now on, you'll still HEAR the call normally, AND BlackHole
    will be receiving the same audio silently for capture.

    Already set up?  Press ENTER to continue. Otherwise Ctrl+C, set it up,
    then re-run this script.
INSTRUCTIONS
    read -p "    " _
fi

# --------- 5) optional label ---------
echo
read -p "label for this recording (e.g. 'standup-monday'), or ENTER to skip: " LABEL
if [[ -z "$LABEL" ]]; then
    LABEL="$DEFAULT_LABEL"
fi
LABEL=$(echo "$LABEL" | /usr/bin/sed -E 's/[^A-Za-z0-9_-]+/-/g' | /usr/bin/sed -E 's/^-+|-+$//g')
[[ -z "$LABEL" ]] && LABEL="$DEFAULT_LABEL"
OUTPUT="$RECORDINGS_DIR/$LABEL-$TIMESTAMP.m4a"

# --------- 6) record ---------
bold "recording -- press Ctrl+C to stop"
echo "    output: $OUTPUT"
echo "    mode:   $([ $DUAL -eq 1 ] && echo 'mic + BlackHole (mixed)' || echo 'mic only')"
echo
echo "    starting in 3..."
sleep 1; echo "    starting in 2..."
sleep 1; echo "    starting in 1..."
sleep 1
echo

START=$(date +%s)
if (( DUAL == 1 )); then
    # Two avfoundation inputs (mic + BlackHole), mixed via amix into one stream.
    # -ac 1 mono saves space and is what whisper wants anyway.
    "$FFMPEG" -hide_banner -loglevel warning -nostdin \
        -f avfoundation -i ":$MIC_IDX" \
        -f avfoundation -i ":$BH_IDX" \
        -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[mix]" \
        -map "[mix]" \
        -ac 1 -ar 44100 \
        -c:a aac -b:a 128k \
        -movflags +faststart \
        "$OUTPUT"
    RC=$?
else
    "$FFMPEG" -hide_banner -loglevel warning -nostdin \
        -f avfoundation -i ":$MIC_IDX" \
        -ac 1 -ar 44100 \
        -c:a aac -b:a 128k \
        -movflags +faststart \
        "$OUTPUT"
    RC=$?
fi
END=$(date +%s)
DURATION=$((END - START))

echo
# ffmpeg returns 255 on SIGINT (Ctrl+C) but the file is still finalized.
if [[ ! -f "$OUTPUT" ]] || (( $(/usr/bin/stat -f '%z' "$OUTPUT" 2>/dev/null || echo 0) < 1000 )); then
    fail "recording failed -- output is empty or missing"
    fail "ffmpeg rc=$RC, duration=${DURATION}s"
    read -p "press enter to exit "
    exit 1
fi
SIZE=$(/usr/bin/stat -f '%z' "$OUTPUT")
ok "recorded ${DURATION}s -> $OUTPUT ($SIZE bytes)"

# --------- 7) upload? ---------
echo
read -p "upload to transcribe service now? [Y/n] " yn
if [[ ! "$yn" =~ ^[Nn] ]]; then
    # Try HTTPS first, fall back to loopback if it can't reach.
    bold "uploading to $SERVER_URL/transcribe"
    RESP_FILE=$(mktemp)
    CODE=$(/usr/bin/curl -s -o "$RESP_FILE" -w "%{http_code}" --max-time 90 \
            -X POST -F "file=@${OUTPUT};type=audio/mp4" \
            "$SERVER_URL/transcribe" || echo ERR)
    if [[ "$CODE" != "202" ]] && [[ "$CODE" != "200" ]]; then
        warn "HTTPS upload returned $CODE -- retrying via loopback"
        CODE=$(/usr/bin/curl -s -o "$RESP_FILE" -w "%{http_code}" --max-time 90 \
                -X POST -F "file=@${OUTPUT};type=audio/mp4" \
                "$LOOPBACK_URL/transcribe" || echo ERR)
    fi
    BODY=$(cat "$RESP_FILE")
    rm -f "$RESP_FILE"
    echo "    HTTP $CODE"
    echo "$BODY" | /usr/bin/head -c 500 | /usr/bin/sed 's/^/    /'
    echo

    JID=$(echo "$BODY" | /usr/bin/python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("job_id",""))
except Exception:
    pass
' 2>/dev/null)

    if [[ -n "$JID" ]]; then
        ok "queued as job $JID"
        echo
        echo "    track progress:  $SERVER_URL/jobs/$JID"
        echo "    or open the PWA -- the in-flight job auto-resumes"
        echo "    transcript will land in: ~/Obsidian/MrD-Brain/Inbox/youtube/"
    else
        warn "no job_id in response -- check the server log"
    fi
fi

echo
echo "recording saved at: $OUTPUT"
echo "(stays here permanently; safe to re-upload by hand)"
echo
echo "done."
read -p "press enter to close this window "
