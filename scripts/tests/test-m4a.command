#!/bin/bash
# End-to-end test of /transcribe with a synthesized m4a, run from this Mac
# directly. If this works, the server-side path is healthy and any failure
# Doug sees is in his browser/PWA, not the server.
cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/test-m4a.log"
{
  echo "=== test-m4a.command $(date) ==="
  echo
  echo "=== environment ==="
  /opt/homebrew/bin/ffmpeg -version | head -1
  /opt/homebrew/bin/whisper-cli --version 2>&1 | head -1 || echo "(whisper-cli --version unsupported, ok)"
  ls -la "$HOME/Library/Application Support/yt-transcript/whisper.conf" 2>/dev/null
  echo "active model (from whisper.conf):"
  awk -F= '/^WHISPER_MODEL_FILE=/{print "  " $2}' "$HOME/Library/Application Support/yt-transcript/whisper.conf"
  echo
  echo "=== generating 3s sine-wave m4a ==="
  TMPDIR_LOCAL=$(mktemp -d)
  TEST_M4A="$TMPDIR_LOCAL/test-tone.m4a"
  /opt/homebrew/bin/ffmpeg -y -loglevel error -f lavfi \
      -i "sine=frequency=440:duration=3" \
      -c:a aac -b:a 64k "$TEST_M4A"
  ls -la "$TEST_M4A"
  /opt/homebrew/bin/ffprobe -v error -show_format -show_streams "$TEST_M4A" \
    | grep -E 'codec_name|codec_long_name|format_name|duration' | head -10
  echo
  echo "=== POST /transcribe (multipart m4a) ==="
  RESP="$TMPDIR_LOCAL/resp.json"
  T0=$(/bin/date +%s)
  CODE=$(/usr/bin/curl -s --max-time 600 \
        -o "$RESP" -w "%{http_code}" \
        -X POST -F "file=@${TEST_M4A};type=audio/mp4" \
        "http://100.121.62.15:8765/transcribe")
  T1=$(/bin/date +%s)
  ELAPSED=$((T1 - T0))
  echo "HTTP $CODE  (wall-clock: ${ELAPSED}s for 3s of audio)"
  echo "--- response body (first 400 chars) ---"
  head -c 400 "$RESP"; echo
  echo
  echo "=== tail of server log ==="
  /usr/bin/tail -25 "$HOME/Library/Logs/yt-transcript.log"
  echo
  echo "=== last 5 .txt files in vault inbox ==="
  /bin/ls -t "$HOME/Obsidian/MrD-Brain/Inbox/youtube"/*.txt 2>/dev/null | head -5
  echo
  rm -rf "$TMPDIR_LOCAL"
  echo "=== done $(date) ==="
} > "$LOG" 2>&1
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
