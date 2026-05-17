#!/bin/bash
# Install Whisper.cpp + companion tools (ffmpeg, poppler for PDF, pandoc for docs)
# and download a Whisper model. Runs once. Re-runnable safely.
#
# Override the model with:
#   WHISPER_MODEL=medium.en bash install-whisper.command
# Defaults to large-v3 (~3 GB, multilingual, best quality).

cd "$HOME/Documents/youtube-transcript-app" || exit 1
set -o pipefail

LOG="$HOME/Documents/youtube-transcript-app/logs/install-whisper.log"
MODEL="${WHISPER_MODEL:-large-v3}"
MODELS_DIR="$HOME/Library/Application Support/yt-transcript/models"
MODEL_FILE="$MODELS_DIR/ggml-${MODEL}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; }

{
  echo "=== install-whisper.command started $(date) ==="
  echo "model: $MODEL"
  echo "model file target: $MODEL_FILE"
  echo

  bold "1/4  brew dependencies"
  if ! command -v brew >/dev/null 2>&1; then
    fail "homebrew not found -- install from brew.sh first"; exit 1
  fi

  for pkg in whisper-cpp ffmpeg poppler pandoc; do
    if brew list "$pkg" >/dev/null 2>&1; then
      ok "$pkg already installed"
    else
      echo "  installing $pkg..."
      brew install "$pkg" || { fail "brew install $pkg failed"; exit 1; }
      ok "$pkg installed"
    fi
  done

  bold "2/4  binary check"
  WHISPER_BIN=""
  for cand in whisper-cli whisper-cpp main; do
    if command -v "$cand" >/dev/null 2>&1; then
      WHISPER_BIN="$(command -v "$cand")"
      break
    fi
  done
  if [[ -z "$WHISPER_BIN" ]]; then
    fail "whisper binary not found on PATH after install -- try 'brew link whisper-cpp'"
    exit 1
  fi
  ok "whisper binary: $WHISPER_BIN"
  ok "ffmpeg:         $(command -v ffmpeg)"
  ok "pdftotext:      $(command -v pdftotext)"
  ok "pandoc:         $(command -v pandoc)"

  bold "3/4  whisper model"
  mkdir -p "$MODELS_DIR"
  if [[ -f "$MODEL_FILE" ]]; then
    SIZE=$(stat -f '%z' "$MODEL_FILE")
    if (( SIZE > 100000000 )); then
      ok "model already present: $MODEL_FILE ($SIZE bytes)"
    else
      warn "existing model file is suspiciously small ($SIZE bytes) -- re-downloading"
      rm -f "$MODEL_FILE"
    fi
  fi
  if [[ ! -f "$MODEL_FILE" ]]; then
    echo "  downloading $MODEL_URL"
    echo "  (this can take several minutes for large-v3 -- ~3 GB)"
    # Resume support, show progress.
    curl --location --fail --retry 3 --continue-at - --progress-bar \
         --output "$MODEL_FILE" "$MODEL_URL" \
      || { fail "model download failed"; rm -f "$MODEL_FILE"; exit 1; }
    ok "model downloaded: $(stat -f '%z' "$MODEL_FILE") bytes"
  fi

  bold "4/4  config file for serve.py"
  CONFIG="$HOME/Library/Application Support/yt-transcript/whisper.conf"
  cat > "$CONFIG" <<EOF
WHISPER_BIN=$WHISPER_BIN
WHISPER_MODEL_FILE=$MODEL_FILE
FFMPEG_BIN=$(command -v ffmpeg)
PDFTOTEXT_BIN=$(command -v pdftotext)
PANDOC_BIN=$(command -v pandoc)
EOF
  ok "config written → $CONFIG"
  cat "$CONFIG" | sed 's/^/    /'

  echo
  echo "=== install-whisper.command finished OK $(date) ==="
} 2>&1 | tee "$LOG"

echo
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
echo "You can close this window."
