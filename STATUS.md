# yt-transcript — STATUS (V2 async)

**One-line:** Tailscale-only PWA on `hermes-hub` that turns any URL/file/recording into clean text in `~/Obsidian/MrD-Brain/Inbox/youtube/`.

## Architecture (V2)

| Layer | What | Where |
|---|---|---|
| Source | editing copy, project root | `~/Documents/youtube-transcript-app/` |
| Runtime | what launchd executes | `~/Library/Application Support/yt-transcript/` |
| LaunchAgent | `com.servusgroup.yt-transcript` | `~/Library/LaunchAgents/com.servusgroup.yt-transcript.plist` |
| Bind | Tailscale interface only | `100.121.62.15:8765` (hard-pinned) |
| HTTPS (optional) | Tailscale Serve → real cert | `tailscale-serve.command` enables `https://hermes-hub.tail79c077.ts.net/` |
| Logs | `tail -f` to watch | `~/Library/Logs/yt-transcript.log` |
| Vault output | one .txt per transcript with header | `~/Obsidian/MrD-Brain/Inbox/youtube/` |
| Job state | JSON metadata + uploads + partials | `~/Library/Application Support/yt-transcript/jobs/` |
| Whisper | binaries + GGML model files | `/opt/homebrew/bin/whisper-cli` + `…/yt-transcript/models/` |
| Tools sniff | active model + binary paths | `~/Library/Application Support/yt-transcript/whisper.conf` |

### Request lifecycle

1. **YouTube URL** → `POST /fetch` → `fetch.sh` (yt-dlp + VTT clean) → vault file → JSON 200 (synchronous, fast).
2. **Web URL / PDF URL** → `POST /transcribe` JSON → `urlopen` + HTML extractor or `pdftotext` → vault file → JSON 200 (synchronous).
3. **Audio / video file or PWA recording** → `POST /transcribe` multipart → upload streamed to disk → **`202 Accepted` + job_id** → worker thread runs `ffmpeg → whisper-cli`, tees stdout to `<id>.partial`, parses segment timestamps for live progress → on completion, vault file + metadata `status=done`. Client polls `GET /jobs/<id>` every 3s, resumes via `sessionStorage` after reload, shows partial transcript live.
4. **YouTube without captions** → automatic Whisper fallback inside `/fetch` (yt-dlp downloads audio, ffmpeg → whisper).

### Async job model

- Single global `JOB_RUN_LOCK` serializes whisper invocations (model load is heavy; queueing is fine).
- One daemon thread per job, picks up `JOB_RUN_LOCK` to run.
- `DELETE /jobs/<id>` flips `CANCELLED_IDS`, then `subprocess.terminate()` if running.
- On startup: `jobs_startup_sweep()` flips any `running`/`queued` to `interrupted` (no auto-resume — whisper-cli has no resume), prunes >30 days.
- 5 GB upload cap. Streaming multipart-to-disk parser (`stream_multipart_to_disk`) handles multi-GB without OOM.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/`, `/index.html`, `/manifest.webmanifest`, `/sw.js`, `/icon-*.png` | static shell |
| GET | `/health` | `{ok, whisper, model}` |
| GET | `/recent` | last 25 vault `.txt` files |
| GET | `/vault/<name>` | raw transcript text (path-traversal guarded) |
| GET | `/jobs` | last 50 job summaries |
| GET | `/jobs/<id>` | full job state + `partial_text` if running |
| POST | `/fetch` | YouTube URL only (allowlist regex), Whisper-fallback on no-subs |
| POST | `/transcribe` (JSON `{url}`) | web/PDF/YouTube — synchronous |
| POST | `/transcribe` (multipart file) | audio/video → **202 + job_id**; pdf/doc/html/txt/srt → 200 sync |
| DELETE | `/jobs/<id>` | cancel + cleanup |

## File map (project root)

| Purpose | File |
|---|---|
| Server | `serve.py` (1345 lines) |
| UI | `index.html`, `manifest.webmanifest`, `sw.js`, `icon-{192,512}.png` |
| LaunchAgent | `com.servusgroup.yt-transcript.plist` |
| Sync runtime + restart | `install.command` → `install.sh` |
| Whisper toolchain (one-time) | `install-whisper.command` (large-v3, 3 GB) |
| Whisper turbo upgrade | `install-whisper-turbo.command` (turbo, 1.55 GB, ~6× faster) |
| HTTPS via Tailscale | `tailscale-serve.command` |
| Diagnostics | `diagnose.command`, `probe-ts.command` |
| End-to-end tests | `test-jobs.command`, `test-m4a.command`, `test-e2e.{sh,command}` |
| Logs | `*.log` (per-script outputs) |

## Known limitations (V2)

1. **Chunked Transfer-Encoding without Content-Length** is rejected with a clean 400. Python's `http.server` does not natively decode chunked bodies. Real browsers (curl, iOS Safari, Chrome) always send Content-Length for `FormData`, so this is theoretical. Fix path: hand-roll a chunked decoder or upgrade the HTTP layer to `aiohttp` / `Starlette`.
2. **HTTPS via Tailscale Serve required for RECORD on iOS.** `MediaRecorder` and `navigator.clipboard.writeText` need `isSecureContext`; plain `http://…:8765/` does not qualify on iOS Safari. Run `tailscale-serve.command` to enable HTTPS, then load `https://hermes-hub.tail79c077.ts.net/` instead.
3. **Whisper cold load is ~30s** (turbo) / **~45s** (large-v3) before the first segment timestamp appears. Polling shows `running 0%` for that window even on short audio. Mitigated by the live `pollJob` UI showing a spinner + elapsed counter.
4. **No resume after process death.** If the launchd agent restarts mid-transcription, the job is flipped to `interrupted`. User must re-upload. whisper.cpp itself has no resume primitive; would need chunking to add it.
5. **Single-tenant.** Tailscale ACL is the only auth boundary. Anyone on the tailnet can read all transcripts in the vault inbox via `GET /vault/<name>`. Acceptable for Doug's solo tailnet; would need rework for multi-user.
6. **Memory footprint during multipart streaming** stays low (chunked write to disk), but `JOBS_TMP_DIR` and `JOBS_DIR` are on the boot drive — large 5 GB uploads need free space there.
7. **App Store Tailscale CLI is broken** on this Mac (`bundleIdentifier` Swift fatal). All scripts that need the CLI prefer `/opt/homebrew/bin/tailscale` (brew, working) and fall back gracefully.
8. **Synchronous URL handlers** still block the request thread for the duration of the fetch + parse. Web-page fetches with hostile servers could hang the request thread; capped by `urlopen` timeout=30 s. Can move to async if the thread budget is ever a problem.

## V3 candidates

- **Chunked Transfer-Encoding decoder** so PWA edge cases stop being a footnote.
- **Job persistence with resume** — chunk audio into 60-second windows, transcribe sequentially, persist segment offsets so a kill/restart picks up where it left off.
- **Multi-user / per-tailnet-identity** — `tailscale serve` exposes the device identity in headers; we could namespace vault inboxes per user.
- **Diarization** (who-said-what) — pyannote or whisperX after the base transcription. Optional toggle in UI.
- **Translation** as a second pass via Hermes (`mrd-qwen3-secure`) — “I have a transcript in pt-BR, give me en-US” via local LLM.
- **Server-Sent Events for live partials** instead of 3-second polling — drops latency, halves request count, smoother on iOS.
- **Push notifications when long jobs complete** so Doug doesn't have to keep the PWA tab open for 30-min audiobook transcriptions.
- **Better recent strip** — read from `/jobs` instead of `/recent` so in-flight + recent past are unified, with status pills.

## Operational cheat sheet

```bash
# sync source -> runtime, restart agent, smoke-test
bash ~/Documents/youtube-transcript-app/install.command

# install or refresh Whisper + ffmpeg + poppler + pandoc
bash ~/Documents/youtube-transcript-app/install-whisper.command         # large-v3 (3 GB)
bash ~/Documents/youtube-transcript-app/install-whisper-turbo.command   # turbo (1.55 GB, fast)

# expose HTTPS via Tailscale (unblocks iOS RECORD)
bash ~/Documents/youtube-transcript-app/tailscale-serve.command

# end-to-end sanity (curl-based, no Finder/PWA)
bash ~/Documents/youtube-transcript-app/test-jobs.command
bash ~/Documents/youtube-transcript-app/test-m4a.command

# what's the agent doing right now
launchctl list | grep yt-transcript
lsof -nP -iTCP:8765 -sTCP:LISTEN
tail -f ~/Library/Logs/yt-transcript.log

# inspect a specific job
curl -s http://100.121.62.15:8765/jobs/<id> | jq .

# nuke a stuck job
curl -s -X DELETE http://100.121.62.15:8765/jobs/<id>

# revert turbo -> large-v3 (or any model)
# edit ~/Library/Application Support/yt-transcript/whisper.conf,
# change WHISPER_MODEL_FILE, then:
launchctl kickstart -k gui/$(id -u)/com.servusgroup.yt-transcript
```

_Last touched: V2 async pivot. See `~/Documents/CLAUDE.md` for the project-level operating context (BridgeWard skill, mentor SOUL, vault layout)._
