#!/bin/bash
# Download whisper.cpp's large-v3-turbo model (~1.55 GB) and switch the
# yt-transcript service over to it. Keeps the large-v3 file in place so
# we can fall back instantly by editing whisper.conf.
#
#   bash install-whisper-turbo.command
#
# Resumes interrupted downloads (--continue-at -). Re-runnable safely.

cd "$HOME/Documents/youtube-transcript-app" || exit 1
set -o pipefail

LOG="$HOME/Documents/youtube-transcript-app/logs/install-whisper-turbo.log"
MODELS_DIR="$HOME/Library/Application Support/yt-transcript/models"
TURBO_NAME="ggml-large-v3-turbo.bin"
TURBO_FILE="$MODELS_DIR/$TURBO_NAME"
TURBO_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$TURBO_NAME"
CONFIG="$HOME/Library/Application Support/yt-transcript/whisper.conf"

# Reference size of ggml-large-v3-turbo.bin (Q5_0 quant, current canonical
# release). Real value as of 2026-04 is ~1,624,555,275 bytes.
TURBO_REF_SIZE=1624555275
# Acceptable size tolerance: +/- 5%.
SIZE_MIN=$((TURBO_REF_SIZE * 95 / 100))
SIZE_MAX=$((TURBO_REF_SIZE * 105 / 100))

PLIST_LABEL="com.servusgroup.yt-transcript"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mx\033[0m %s\n' "$*"; }

{
  echo "=== install-whisper-turbo.command started $(date) ==="
  echo "target: $TURBO_FILE"
  echo "url:    $TURBO_URL"
  echo "expect: ~$TURBO_REF_SIZE bytes (+/- 5%)"
  echo

  bold "1/5  preflight"
  if ! command -v curl >/dev/null 2>&1; then
    fail "curl not found"; exit 1
  fi
  ok "curl: $(command -v curl)"

  if [[ ! -f "$CONFIG" ]]; then
    fail "whisper.conf missing at $CONFIG -- run install-whisper.command first"
    exit 1
  fi
  ok "found existing whisper.conf"
  echo "  existing config:"
  sed 's/^/    /' "$CONFIG"
  echo

  mkdir -p "$MODELS_DIR"
  ok "models dir: $MODELS_DIR"

  bold "2/5  download (resumable)"
  if [[ -f "$TURBO_FILE" ]]; then
    EXISTING_SIZE=$(stat -f '%z' "$TURBO_FILE")
    if (( EXISTING_SIZE >= SIZE_MIN && EXISTING_SIZE <= SIZE_MAX )); then
      ok "$TURBO_NAME already present and size-valid ($EXISTING_SIZE bytes)"
    else
      warn "$TURBO_NAME is present but size $EXISTING_SIZE outside [$SIZE_MIN..$SIZE_MAX] -- resuming"
    fi
  fi

  if [[ ! -f "$TURBO_FILE" ]] || (( $(stat -f '%z' "$TURBO_FILE") < SIZE_MIN )); then
    echo "  downloading (this is ~1.55 GB; resumable on interrupt)..."
    if ! curl --location --fail --retry 5 --retry-delay 5 \
              --continue-at - --progress-bar \
              --output "$TURBO_FILE" "$TURBO_URL"; then
      fail "download failed"
      exit 1
    fi
  fi

  FINAL_SIZE=$(stat -f '%z' "$TURBO_FILE")
  if (( FINAL_SIZE < SIZE_MIN || FINAL_SIZE > SIZE_MAX )); then
    fail "downloaded size $FINAL_SIZE outside expected range [$SIZE_MIN..$SIZE_MAX]"
    fail "the file may be a Hugging Face HTML 'redirect' page or a corrupt LFS pointer."
    fail "delete $TURBO_FILE and try again."
    exit 1
  fi
  ok "downloaded model: $FINAL_SIZE bytes"

  bold "3/5  patch whisper.conf (keep large-v3 path on file as a comment)"
  # Read existing values into shell variables, then rewrite cleanly.
  # shellcheck disable=SC2046
  eval "$(awk -F= '
    /^WHISPER_BIN=/         { print "EXISTING_WHISPER_BIN=\"" substr($0, index($0,"=")+1) "\"" }
    /^WHISPER_MODEL_FILE=/  { print "EXISTING_WHISPER_MODEL_FILE=\"" substr($0, index($0,"=")+1) "\"" }
    /^FFMPEG_BIN=/          { print "EXISTING_FFMPEG_BIN=\"" substr($0, index($0,"=")+1) "\"" }
    /^PDFTOTEXT_BIN=/       { print "EXISTING_PDFTOTEXT_BIN=\"" substr($0, index($0,"=")+1) "\"" }
    /^PANDOC_BIN=/          { print "EXISTING_PANDOC_BIN=\"" substr($0, index($0,"=")+1) "\"" }
  ' "$CONFIG")"

  WHISPER_BIN_OUT="${EXISTING_WHISPER_BIN:-/opt/homebrew/bin/whisper-cli}"
  FFMPEG_OUT="${EXISTING_FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
  PDFTOTEXT_OUT="${EXISTING_PDFTOTEXT_BIN:-/opt/homebrew/bin/pdftotext}"
  PANDOC_OUT="${EXISTING_PANDOC_BIN:-/opt/homebrew/bin/pandoc}"
  PREVIOUS_MODEL="${EXISTING_WHISPER_MODEL_FILE:-}"

  # Backup existing config before overwriting.
  cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
  ok "backed up old config to $CONFIG.bak.*"

  cat > "$CONFIG" <<EOF
# yt-transcript whisper config -- written by install-whisper-turbo.command
# To revert to large-v3, change WHISPER_MODEL_FILE back to the FALLBACK line
# below and run: launchctl kickstart -k gui/\$(id -u)/$PLIST_LABEL
WHISPER_BIN=$WHISPER_BIN_OUT
WHISPER_MODEL_FILE=$TURBO_FILE
# FALLBACK: $PREVIOUS_MODEL
FFMPEG_BIN=$FFMPEG_OUT
PDFTOTEXT_BIN=$PDFTOTEXT_OUT
PANDOC_BIN=$PANDOC_OUT
EOF
  ok "whisper.conf now points at $TURBO_NAME"
  echo "  new config:"
  sed 's/^/    /' "$CONFIG"
  echo

  bold "4/5  restart launchd agent"
  if [[ ! -f "$PLIST_PATH" ]]; then
    warn "plist missing at $PLIST_PATH -- agent never installed?"
  else
    UID_NUM=$(id -u)
    if launchctl print "gui/$UID_NUM/$PLIST_LABEL" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/$UID_NUM/$PLIST_LABEL" \
        && ok "kickstart -k issued (process restart, plist re-read)" \
        || warn "kickstart returned non-zero -- falling back to unload/load"
    fi
    if ! launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
      launchctl load "$PLIST_PATH" && ok "load OK"
    fi
  fi

  bold "5/5  verify"
  sleep 2
  for i in 1 2 3 4 5 6 7 8; do
    if /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then break; fi
    sleep 0.5
  done

  LSOF_LINE="$(/usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -n 1 || true)"
  if [[ -n "$LSOF_LINE" ]]; then
    ok "service back up:"
    echo "    $LSOF_LINE"
  else
    fail "no listener on :8765 after kickstart -- check $HOME/Library/Logs/yt-transcript.log"
  fi

  echo
  echo "model in use:"
  awk -F= '/^WHISPER_MODEL_FILE=/{print "  " $2}' "$CONFIG"
  echo
  echo "you can now re-run test-m4a.command and compare wall-clock time."
  echo
  echo "=== install-whisper-turbo.command finished $(date) ==="
} 2>&1 | tee "$LOG"

echo
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
echo "You can close this window."
