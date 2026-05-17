# Transcript-Master

A small home-grown web app on `hermes-hub` (Mac mini Pro) that turns any URL,
file, or audio recording into clean text in `~/Obsidian/MrD-Brain/Inbox/youtube/`.
Built by Mr. D (Douglas da Silva) for his own daily work — a one-page PWA that
runs locally and is reachable from anywhere.

**How to reach it:**

| Where from                    | URL                                                       |
| ----------------------------- | --------------------------------------------------------- |
| Public, anywhere (Cloudflare) | <https://transcript.mrdapps.com/>                         |
| Tailscale network (HTTPS)     | <https://hermes-hub.tail79c077.ts.net/>                   |
| Same Mac, plain loopback      | <http://localhost:8765/>                                  |

All three point at the same Python server on `localhost:8765`. The public URL
is served by a **Cloudflare Tunnel** named `mrdapps` — no port forwarding, no
public IP, no certs to manage. Details in [docs/INFRA.md](./docs/INFRA.md).

For deep architecture / endpoints / known limits, see [STATUS.md](./STATUS.md).

---

## Folder layout

```
youtube-transcript-app/
├── README.md          you are here
├── STATUS.md          architecture, endpoints, known limits, V3 ideas
│
├── src/               app source -- install.sh syncs these to the runtime
│   ├── serve.py
│   ├── index.html
│   ├── manifest.webmanifest
│   ├── sw.js
│   ├── icon-192.png / icon-512.png
│   └── com.servusgroup.yt-transcript.plist (reference; install.sh writes
│                                            the live one fresh each time)
│
├── scripts/
│   ├── install/       one-time setup -- always start here
│   │   ├── install.command            sync src -> runtime + restart agent
│   │   ├── install.sh                 (called by install.command)
│   │   ├── install-whisper.command    whisper-cpp + ffmpeg + 3 GB model
│   │   ├── install-whisper-turbo.command  upgrade to large-v3-turbo (1.5 GB, ~6x faster)
│   │   ├── tailscale-serve.command    expose HTTPS via tailscale serve
│   │   ├── fix-tailscale-cli.command  brew upgrade + Tailscale.app restart
│   │   └── fix-tailscale-loop.command dual-bind serve.py + serve at 127.0.0.1
│   │
│   ├── tools/         day-to-day utilities
│   │   ├── record-call.command        mic + BlackHole capture, auto-upload
│   │   ├── diagnose.command           full service health snapshot
│   │   ├── diagnose-tls.command       TLS / cert / serve-config snapshot
│   │   ├── verify-https.command       quick "is HTTPS up?" check
│   │   ├── health-check.command       processes, ports, recent jobs
│   │   └── probe-ts.command           tailscale CLI probe
│   │
│   └── tests/         e2e tests (curl-based, no PWA needed)
│       ├── test-jobs.command          full async job pattern e2e
│       ├── test-m4a.command           single m4a -> /transcribe
│       ├── test-e2e.command           YouTube URL -> transcript
│       └── test-e2e.sh                (called by test-e2e.command)
│
├── logs/              every .command writes its log here
│
└── recordings/        record-call.command writes timestamped m4a here
```

## Common tasks

```bash
# Push code changes from src/ to the live runtime + restart the agent
bash scripts/install/install.command

# Verify the service is up
bash scripts/tools/verify-https.command   # https://hermes-hub.tail79c077.ts.net/
bash scripts/tools/health-check.command   # process tree, lsof, recent jobs

# Record a call (Slack huddle / Zoom / WhatsApp Mac / etc.) and auto-transcribe
bash scripts/tools/record-call.command

# Run end-to-end tests against the live service
bash scripts/tests/test-jobs.command      # mp3, m4a, iOS-UA, cancel, list
bash scripts/tests/test-m4a.command       # short m4a only
bash scripts/tests/test-e2e.command       # YouTube subs path

# If anything ever goes weird
bash scripts/tools/diagnose.command       # broad health check
bash scripts/tools/diagnose-tls.command   # TLS-specific
```

## Where things live at runtime

The source in `src/` is the editing copy. `install.command` syncs it to:

- **`~/Library/Application Support/yt-transcript/`** -- the live serve.py
  + index.html + statics + Whisper model + `whisper.conf`
- **`~/Library/LaunchAgents/com.servusgroup.yt-transcript.plist`** -- launchd
  agent definition (regenerated from scratch every install)
- **`~/Library/Logs/yt-transcript.log`** -- the live service log
- **`~/Library/Application Support/yt-transcript/jobs/`** -- async job state
  (one `.json` per job + the uploaded file + a `.partial` whisper stream)

## Quick health check

```bash
launchctl list | grep yt-transcript                 # agent loaded?
lsof -nP -iTCP:8765 -sTCP:LISTEN                    # listening on Tailscale + loopback?
tail -f ~/Library/Logs/yt-transcript.log            # live log
curl -s http://localhost:8765/health | jq .         # local health JSON
curl -s https://hermes-hub.tail79c077.ts.net/health | jq .    # via Tailscale
curl -s https://transcript.mrdapps.com/health | jq .          # via public Cloudflare
```

## How the public URL works (in one minute)

1. **Python app** listens on `localhost:8765` (started by the launchd plist
   `com.servusgroup.yt-transcript`).
2. **`cloudflared`** runs as a user LaunchAgent (`com.cloudflare.cloudflared`)
   on the same Mac. It opens an outbound connection to Cloudflare — no inbound
   ports are exposed to the internet.
3. **Cloudflare** receives requests for `transcript.mrdapps.com`, sends them
   down that outbound tunnel to the Mac, where `cloudflared` forwards them to
   `http://localhost:8765`.
4. **DNS** for `mrdapps.com` lives at Cloudflare (the domain is registered
   there too), so `transcript.mrdapps.com` is just a CNAME that Cloudflare
   manages automatically when you run `cloudflared tunnel route dns ...`.

The tunnel is named **`mrdapps`** and its config lives at
`~/.cloudflared/config.yml`. Credentials for the tunnel are at
`~/.cloudflared/<TUNNEL-UUID>.json` and `~/.cloudflared/cert.pem`. **None of
those files are in this repo** (they're secrets — `.gitignore` is set up to
keep them out).

## Add a new app to `mrdapps.com` (the standard pattern)

This is the recipe Mr. D uses for every new little tool he builds. Say you've
built a second app — call it `notes` — and it runs on `localhost:9000`. To
make it reachable at `https://notes.mrdapps.com/`:

```bash
# 1. Make sure your app is actually running on its port.
curl -s http://localhost:9000/   # sanity check

# 2. Add a launchd plist so it auto-starts on login. Use
#    src/com.servusgroup.yt-transcript.plist in this repo as a template —
#    change Label, ProgramArguments, WorkingDirectory.
#    Save it to ~/Library/LaunchAgents/com.<you>.notes.plist, then:
launchctl load ~/Library/LaunchAgents/com.<you>.notes.plist

# 3. Add one ingress rule in ~/.cloudflared/config.yml — ABOVE the
#    catch-all 404 line. Example:
#
#      - hostname: notes.mrdapps.com
#        service: http://localhost:9000

# 4. Create the DNS record (Cloudflare does this automatically — no
#    dashboard click needed):
cloudflared tunnel route dns mrdapps notes.mrdapps.com

# 5. Reload cloudflared so it picks up the new config:
launchctl unload ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist
launchctl load   ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist

# 6. Test it:
curl -sI https://notes.mrdapps.com/
```

That's it. One tunnel, one DNS zone, unlimited subdomains. Full step-by-step
with troubleshooting in [docs/INFRA.md](./docs/INFRA.md).

