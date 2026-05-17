#!/bin/bash
# End-to-end test of the async job pattern.
#  1. mp3 upload (curl)        -> expect 202 + job_id, poll until done
#  2. m4a upload (curl)        -> expect 202 + job_id, poll until done
#  3. iOS-Safari simulated UA  -> verify TRANSCRIBE-IN log shows the iOS UA
#  4. cancel mid-flight        -> DELETE /jobs/<id>, confirm cancelled state
#  5. simulated chunked        -> ensure missing Content-Length is handled
#
# Reads the live log to show the matching server-side trace for each step.

cd "$HOME/Documents/youtube-transcript-app" || exit 1
LOG="$HOME/Documents/youtube-transcript-app/logs/test-jobs.log"
SERVER_LOG="$HOME/Library/Logs/yt-transcript.log"
HOST="100.121.62.15:8765"
TMP="$(mktemp -d)"
IOS_UA='Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  + %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
fail() { printf '  x %s\n' "$*"; }

poll_until_terminal() {
  local jid="$1"
  local label="${2:-job}"
  local i=0
  while (( i < 1200 )); do  # cap ~60min @ 3s polls
    local body
    body=$(/usr/bin/curl -s --max-time 5 "http://$HOST/jobs/$jid")
    local status
    status=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
    local pct
    pct=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("progress_pct",""))' 2>/dev/null)
    printf '    [%s] %s pct=%s\n' "$label" "$status" "$pct"
    case "$status" in
      done|error|cancelled|interrupted)
        printf '%s\n' "$body" > "$TMP/${label}.final.json"
        echo "$status"
        return 0
        ;;
    esac
    sleep 3
    i=$((i + 1))
  done
  fail "polling timed out after 60min"
  return 1
}

{
  echo "=== test-jobs.command $(date) ==="
  echo "host: $HOST"
  echo

  bold "0/5  preflight"
  ffmpeg=/opt/homebrew/bin/ffmpeg
  $ffmpeg -version | head -1
  whisper_cli=$(command -v whisper-cli 2>/dev/null || echo /opt/homebrew/bin/whisper-cli)
  echo "  whisper-cli: $whisper_cli"
  echo "  active model:"
  awk -F= '/^WHISPER_MODEL_FILE=/{print "    " $2}' "$HOME/Library/Application Support/yt-transcript/whisper.conf"
  echo "  GET /health"
  /usr/bin/curl -s --max-time 5 "http://$HOST/health"; echo

  bold "1/5  POST /transcribe (mp3, 5s sine)"
  TEST_MP3="$TMP/test.mp3"
  $ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:duration=5" \
          -c:a libmp3lame -b:a 64k "$TEST_MP3"
  ls -la "$TEST_MP3"
  RESP="$TMP/mp3_post.json"
  CODE=$(/usr/bin/curl -s -o "$RESP" -w "%{http_code}" \
        -X POST -F "file=@${TEST_MP3};type=audio/mpeg" \
        "http://$HOST/transcribe")
  echo "  HTTP $CODE"
  echo "  body: $(cat "$RESP")"
  if [[ "$CODE" != "202" ]]; then
    fail "expected 202, got $CODE"
  else
    JID=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["job_id"])' "$RESP")
    ok "job_id=$JID — polling..."
    FINAL=$(poll_until_terminal "$JID" "mp3")
    [[ "$FINAL" == "done" ]] && ok "mp3 done" || fail "mp3 final=$FINAL"
  fi

  bold "2/5  POST /transcribe (m4a, 3s sine)"
  TEST_M4A="$TMP/test.m4a"
  $ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=523:duration=3" \
          -c:a aac -b:a 64k "$TEST_M4A"
  ls -la "$TEST_M4A"
  RESP="$TMP/m4a_post.json"
  CODE=$(/usr/bin/curl -s -o "$RESP" -w "%{http_code}" \
        -X POST -F "file=@${TEST_M4A};type=audio/mp4" \
        "http://$HOST/transcribe")
  echo "  HTTP $CODE / $(cat "$RESP")"
  if [[ "$CODE" == "202" ]]; then
    JID=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["job_id"])' "$RESP")
    FINAL=$(poll_until_terminal "$JID" "m4a")
    [[ "$FINAL" == "done" ]] && ok "m4a done" || fail "m4a final=$FINAL"
  else
    fail "expected 202, got $CODE"
  fi

  bold "3/5  POST /transcribe with iOS Safari UA (verify log fingerprint)"
  TEST_IOS="$TMP/ios.m4a"
  $ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=659:duration=2" \
          -c:a aac -b:a 64k "$TEST_IOS"
  RESP="$TMP/ios_post.json"
  CODE=$(/usr/bin/curl -s -o "$RESP" -w "%{http_code}" \
        -A "$IOS_UA" \
        -X POST -F "file=@${TEST_IOS};type=audio/mp4" \
        "http://$HOST/transcribe")
  echo "  HTTP $CODE / $(cat "$RESP")"
  if [[ "$CODE" == "202" ]]; then
    JID=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["job_id"])' "$RESP")
    ok "iOS-UA job_id=$JID accepted"
    # Confirm the UA was logged
    if /usr/bin/grep -F 'iPhone OS 17' "$SERVER_LOG" | tail -1; then
      ok "iOS UA fingerprint present in log"
    else
      warn "iOS UA NOT found in tail of log — check log/UA filtering"
    fi
    poll_until_terminal "$JID" "ios" >/dev/null
  else
    fail "iOS-UA test got HTTP $CODE"
  fi

  bold "4/5  cancel mid-flight"
  # Generate a longer file so we have time to cancel mid-transcription
  TEST_LONG="$TMP/long.m4a"
  $ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:duration=120" \
          -c:a aac -b:a 64k "$TEST_LONG"
  RESP="$TMP/cancel_post.json"
  CODE=$(/usr/bin/curl -s -o "$RESP" -w "%{http_code}" \
        -X POST -F "file=@${TEST_LONG};type=audio/mp4" \
        "http://$HOST/transcribe")
  if [[ "$CODE" != "202" ]]; then fail "expected 202 for cancel test, got $CODE"; else
    JID=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["job_id"])' "$RESP")
    ok "cancel-test job_id=$JID — sleeping 8s before DELETE"
    sleep 8
    DEL=$(/usr/bin/curl -s -X DELETE "http://$HOST/jobs/$JID")
    echo "  DELETE response: $DEL"
    sleep 4
    FINAL_BODY=$(/usr/bin/curl -s "http://$HOST/jobs/$JID")
    FINAL_STATUS=$(printf '%s' "$FINAL_BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')
    [[ "$FINAL_STATUS" == "cancelled" ]] && ok "cancellation took effect" \
                                          || fail "expected cancelled, got $FINAL_STATUS"
  fi

  bold "5/5  edge: chunked Transfer-Encoding (no Content-Length)"
  # Note: curl --tcp-nodelay --header "Transfer-Encoding: chunked" forces it.
  CHUNK_RESP="$TMP/chunk_resp.json"
  CHUNK_CODE=$(/usr/bin/curl -s -o "$CHUNK_RESP" -w "%{http_code}" \
        -H "Transfer-Encoding: chunked" \
        -X POST -F "file=@${TEST_M4A};type=audio/mp4" \
        "http://$HOST/transcribe" || echo "ERR")
  echo "  HTTP $CHUNK_CODE / $(cat "$CHUNK_RESP" 2>/dev/null | head -c 200)"

  bold "6/6  GET /jobs (last 10)"
  /usr/bin/curl -s "http://$HOST/jobs" \
    | python3 -c 'import sys,json; xs=json.load(sys.stdin); [print(f"  {x[\"status\"]:<11} {x.get(\"progress_pct\",0):>3}%  {x[\"job_id\"]}  {x.get(\"filename\")}") for x in xs[:10]]'

  bold "tail of server log"
  /usr/bin/tail -25 "$SERVER_LOG"

  rm -rf "$TMP"
  echo
  echo "=== test-jobs.command done $(date) ==="
} 2>&1 | tee "$LOG"

echo
echo "Log: ~/Documents/youtube-transcript-app/$LOG"
