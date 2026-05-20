# Infrastructure — how `mrdapps.com` works, and how to add the next app

This is the standard pattern Mr. D uses to expose every small app he builds
on `hermes-hub` (his Mac mini) to the public internet. It's the same setup
that powers every `mrdapps.com` hostname.

You only set it up once. After that, adding a new app is ~4 lines.

## Apps currently live behind this tunnel

| Host                              | Local port | Access | Repo / notes                                                                                                       |
| --------------------------------- | ---------- | ------ | ------------------------------------------------------------------------------------------------------------------ |
| `mrdapps.com`, `www.mrdapps.com`  | `8090`     | public | [`leanddouglas/mrdapps-site`](https://github.com/leanddouglas/mrdapps-site) — landing page / dashboard             |
| `transcript.mrdapps.com`          | `8765`     | public | [`leanddouglas/Transcript-Master`](https://github.com/leanddouglas/Transcript-Master) — this repo                  |
| `tracker.mrdapps.com`             | `8800`     | needs Access | [`leanddouglas/MrD-Tracker`](https://github.com/leanddouglas/MrD-Tracker) — single-file OSINT tracker         |
| `books.mrdapps.com`               | `8801`     | needs Access | [`leanddouglas/onebooks`](https://github.com/leanddouglas/onebooks) — SmartLedger (Supabase-backed)          |
| `ops.mrdapps.com`                 | `8802`     | needs Access | [`leanddouglas/carpet-ops`](https://github.com/leanddouglas/carpet-ops) — offline-first PWA, business ledger |
| `geo.mrdapps.com`                 | `8766` (TS) | needs Access | [`leanddouglas/geo-audit-app`](https://github.com/leanddouglas/geo-audit-app) — reuses existing Tailscale-bound service at `100.121.62.15:8766` |
| `training.mrdapps.com`            | `8804`     | needs Access | [`leanddouglas/servus-training`](https://github.com/leanddouglas/servus-training) — Servus floor-care training |
| `sorriso.mrdapps.com`             | `8805`     | public | [`leanddouglas/SorrisoDentalClinic`](https://github.com/leanddouglas/SorrisoDentalClinic) — client static rebuild  |
| `sorriso-themes.mrdapps.com`      | `8806`     | public | [`leanddouglas/sorriso-dental-clinic-themes`](https://github.com/leanddouglas/sorriso-dental-clinic-themes) — 4 design variants for client review |
| `cars.mrdapps.com`                | `8807`     | needs Access | [`leanddouglas/car-finder-bot`](https://github.com/leanddouglas/car-finder-bot) — Flask dashboard + scrapers (Telegram bot disabled until tokens set) |
| `scrape.mrdapps.com`              | `8808`     | needs Access | [`leanddouglas/scraypr-app`](https://github.com/leanddouglas/scraypr-app) — Express scrape API (frontend not served on `/`; routes live under `/api/`) |
| `simmind.mrdapps.com`             | `8809`     | needs Access | [`leanddouglas/simmind`](https://github.com/leanddouglas/simmind) — FastAPI prediction engine (no root route; UI at `/docs`) |
| `ubot.mrdapps.com`                | `8767`     | needs Access | [`leanddouglas/servus-bot`](https://github.com/leanddouglas/servus-bot) — Flask chat UI over local Ollama (`qwen3:14b`); branded "Ubot" on the dashboard, launchd label `com.servusgroup.ubot`. In-app auth (Flask-Login + SQLite + bcrypt) planned as a separate followup; no Cloudflare Access policy yet, so reachable to anyone with the URL. iMac source-of-truth at `~/Documents/Claude Projects/servus-bot/` → rsync to Mac mini `~/servus-bot/` → `scripts/refresh-servus.sh` re-stages to the launchd runtime. (Briefly also reachable at `servusbotassistant.mrdapps.com` on 2026-05-19 during a rename; that CNAME is orphaned and now 404s.) |

**"needs Access"** above means the app is publicly reachable on the tunnel
but has **no Cloudflare Access policy yet** — Mr. D must add one manually in
the Cloudflare Zero Trust dashboard before treating these as private. See the
"Cloudflare Access — not yet wired" section below.

The landing page polls each app's `/health` endpoint every 30s and shows a
live status dot, so it doubles as a free uptime check for everything on the
tunnel. If you add a new app, also add a card to `mrdapps-site` so it shows
up there.

### How the new apps are staged on disk

The first three "live behind this tunnel" apps (`mrdapps-site`,
`Transcript-Master`, `geo-audit-app`) run from various locations. The 9 new
apps added on **2026-05-17** all follow one pattern:

- **Git source-of-truth:** `~/Documents/<repo>/` — `git pull` here to update.
- **Served from:** `~/Library/Application Support/<slug>/` — `rsync`'d from
  the repo at deploy time.

The split is a workaround for a macOS TCC restriction: launchd-spawned
processes cannot read `~/Documents` without Full Disk Access. Files in
`~/Library/Application Support/` are not TCC-protected, which is why the
existing `yt-transcript` and `geo-audit` services follow the same pattern.

**To redeploy after a `git pull`:**

```bash
# Static apps (just files) — example for tracker:
rsync -a --delete ~/Documents/MrD-Tracker/ \
    "$HOME/Library/Application Support/tracker/"

# Python apps with venv (cars, simmind):
rsync -a --delete --exclude=.venv --exclude=__pycache__ \
    ~/Documents/car-finder-bot/ "$HOME/Library/Application Support/cars/"
# (Re-run `pip install -r requirements.txt` inside the AppSupport venv if
# requirements.txt changed.)

# Node app (scrape):
rsync -a --delete --exclude=node_modules \
    ~/Documents/scraypr-app/ "$HOME/Library/Application Support/scrape/"
# (Re-run `npm install` inside the AppSupport copy if package.json changed.)

# Then restart the launchd job:
launchctl kickstart -k "gui/$(id -u)/com.servusgroup.tracker"
```

**Servus Bot (`servusbotassistant`) — one-command refresh:**

Servus Bot follows a slightly different layout — the iMac rsyncs to `~/servus-bot/`
(not `~/Documents/`) because that's where Mr. D's existing iMac→Mac mini rsync
workflow lands. From there, `scripts/refresh-servus.sh` syncs the home-dir
edit copy into the launchd runtime location and kickstarts the service:

```bash
bash ~/Documents/youtube-transcript-app/scripts/refresh-servus.sh
```

The helper re-installs `requirements.txt` if it changed, then restarts
`com.servusgroup.ubot`. Use this after every iMac→Mac mini rsync.

### Cloudflare Access — not yet wired

The 8 "needs Access" apps above are **publicly reachable on the open
internet** as of 2026-05-17. No `CLOUDFLARE_API_TOKEN` was available at
deploy time and `cloudflared` cannot create Access policies, so the gating
step was deferred.

**Highest urgency — `books.mrdapps.com` (`onebooks`).** This is Doug's
real-money business + personal finance ledger. It loads against the same
Supabase project the Netlify deploy uses, so the actual security boundary is
the project's Row-Level Security policies (see `AUDIT-2026-05-17.md` §2a).
RLS verification has not been done yet — until both RLS is verified AND
Cloudflare Access is enabled, treat `books.mrdapps.com` as exposed.

**To gate any "needs Access" app:**

1. Cloudflare Zero Trust dashboard → Access → Applications → Add an
   application → Self-hosted.
2. Application domain: e.g. `tracker.mrdapps.com`.
3. Identity provider: One-time PIN to your email (`doug@servusgroup.com`)
   for the simplest start; add Google/GitHub later if you want.
4. Policy: Allow → Emails → `doug@servusgroup.com`.
5. Save. The next request to that hostname will hit a Cloudflare login page.

---

## The big picture

```
Internet user
     │
     ▼
   Cloudflare edge (PoPs in YVR, SEA, etc.)
     │
     │  outbound, encrypted, persistent connection
     │  (initiated FROM the Mac — nothing inbound is open)
     ▼
   cloudflared (on hermes-hub, runs as a LaunchAgent)
     │
     ▼
   localhost:8090  → mrdapps-site (landing page / dashboard)
   localhost:8765  → Transcript-Master Python server
   localhost:NNNN  → next app (when you add one)
```

---

## Edge: Caddy (installed, not in the public request path) — 2026-05-18

Doug installed Caddy + a Cloudflare-DNS-issued wildcard cert for
`*.mrdapps.com` on 2026-05-18. **It is not currently in the request path
for any `mrdapps.com` hostname.** Cloudflare Tunnel still routes every
production request straight to the app's `localhost` port — Caddy sits to
one side of that flow.

What's actually running:

- Process: `caddy run --config /etc/caddy/Caddyfile` (PID owned by `root`).
- Listener: `:443` on all interfaces (per the Caddy admin API at
  `http://127.0.0.1:2019/config/`). No `:80` listener.
- Caddyfile (`/etc/caddy/Caddyfile`) handles only `hero.mrdapps.com`,
  `hermes.mrdapps.com`, and `memory.mrdapps.com`. Every other host under
  `*.mrdapps.com` falls through to a `404 "Subdomain not configured"` static
  response. None of the apps in the table above route through Caddy.
- TLS: `tls { dns cloudflare {env.CF_API_TOKEN} }` — wildcard cert auto-issued
  via the Cloudflare DNS-01 challenge. Cert + key live under
  `/var/lib/caddy/.local/share/caddy/` (Caddy default; root-owned).

What this means in practice:

- **Public traffic to `books.mrdapps.com`, `tracker.mrdapps.com`, etc. is
  unchanged.** It still goes Cloudflare edge → cloudflared → `localhost:NNNN`,
  per `~/.cloudflared/config.yml`. Caddy is not consulted.
- **The wildcard cert is essentially idle.** Nothing in the current
  Cloudflare-Tunnel path uses it (Cloudflare terminates TLS at the edge with
  its own cert). The cert is ready if/when something is pointed at Caddy.
- **`hero.mrdapps.com` is wired to `localhost:8001` but `8001` has no app.**
  That's the Hero qwen3 chat backend that went missing when a prior agent
  rebound port `8765`. Reaching `https://hero.mrdapps.com` via Cloudflare
  Tunnel will 502 because there's no tunnel ingress entry for it either.

If you want Caddy to gate or front any of the production apps (basic auth,
rate-limiting, etc.), the change required is **on the cloudflared side, not
the Caddy side**: edit `~/.cloudflared/config.yml` so the relevant
`hostname:` entries point `service: https://localhost` (with a Host header)
instead of `http://localhost:NNNN`, and add matching `handle` blocks in
`/etc/caddy/Caddyfile` for those hosts. That swap was **not** done overnight
on 2026-05-18 — adding `basic_auth` to the Caddyfile alone would gate
nothing, because the public requests don't transit Caddy.

### To reload Caddy

Caddy was started directly by root (not via `brew services` or a LaunchDaemon),
so `sudo` is required for any restart. The admin API at `127.0.0.1:2019`
accepts config changes without sudo, but a clean reload from the file is:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo caddy reload   --config /etc/caddy/Caddyfile
```

### To make Caddy the local edge (future work, not done)

High-level — do not run this overnight without testing each step:

1. Decide on a Caddy listener port (e.g., `:8443`) that cloudflared can hit.
2. Add `handle` blocks in `/etc/caddy/Caddyfile` for every `*.mrdapps.com`
   host with `reverse_proxy localhost:NNNN` plus any `basic_auth` directives.
3. Update `~/.cloudflared/config.yml` so each `hostname:` entry forwards to
   `https://localhost:8443` with `originRequest.httpHostHeader: <host>` so
   Caddy can route by Host.
4. Reload cloudflared, then reload Caddy. Verify each host end-to-end.
5. Only after all hosts are confirmed working should the catch-all 404 stay
   in place — until then, leave a known-good rollback in `config.yml.bak.*`.

---

Key properties:

- **No port forwarding on the router.** Nothing is open from the internet to
  the Mac.
- **No HTTPS cert work.** Cloudflare terminates TLS at the edge with a
  certificate it manages for `*.mrdapps.com`.
- **One tunnel, many apps.** All subdomains of `mrdapps.com` share the same
  `mrdapps` tunnel. Adding an app = one config line + one DNS command.
- **Tailscale still works.** This sits next to Tailscale Serve, not instead
  of it. The same app on `localhost:8765` is reachable at:
  - `https://transcript.mrdapps.com/` — public, anyone
  - `https://hermes-hub.tail79c077.ts.net/` — tailnet-only
  - `http://localhost:8765/` — same Mac

---

## One-time setup (already done — for reference)

```bash
# 1. Install cloudflared
brew install cloudflared

# 2. Authenticate this Mac with the Cloudflare account that owns mrdapps.com
cloudflared tunnel login
#  → opens a browser, you pick the mrdapps.com zone, click Authorize
#  → writes ~/.cloudflared/cert.pem  (this is the "origin certificate")

# 3. Create the named tunnel
cloudflared tunnel create mrdapps
#  → writes ~/.cloudflared/<TUNNEL-UUID>.json  (tunnel credentials — secret)
#  → prints the UUID; we use it in config.yml below

# 4. Write ~/.cloudflared/config.yml (see template below)

# 5. Install the LaunchAgent so cloudflared runs at login
launchctl load ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist
```

---

## File map (where things live)

| Path                                                          | What it is                                          |
| ------------------------------------------------------------- | --------------------------------------------------- |
| `~/.cloudflared/cert.pem`                                     | Origin certificate (account auth). **Secret.**      |
| `~/.cloudflared/<UUID>.json`                                  | Tunnel credentials. **Secret.**                     |
| `~/.cloudflared/config.yml`                                   | Ingress rules — hostname → local service.           |
| `~/Library/LaunchAgents/com.cloudflare.cloudflared.plist`     | Auto-start cloudflared at login.                    |
| `~/Library/Logs/cloudflared.log`                              | Live log.                                           |
| `/opt/homebrew/bin/cloudflared`                               | The binary itself.                                  |

**None of these are in the Transcript-Master repo.** Secrets stay on the Mac.

---

## The ingress config

```yaml
# ~/.cloudflared/config.yml
tunnel: mrdapps
credentials-file: /Users/dougmacminipro/.cloudflared/<TUNNEL-UUID>.json

ingress:
  # One block per app. First match wins.
  - hostname: transcript.mrdapps.com
    service: http://localhost:8765

  # ---> Add new apps above this line <---

  # Catch-all — anything not matched returns 404.
  - service: http_status:404
```

---

## Add a new app — the one-command way

Once the app is running on its port and has a LaunchAgent (Step 1 below):

```bash
bash scripts/add-app.sh <name> <port> [hostname]

# Examples
bash scripts/add-app.sh notes 9000
bash scripts/add-app.sh dash  9100 admin.mrdapps.com
```

`scripts/add-app.sh` does Steps 2–4 below in one shot: backs up
`~/.cloudflared/config.yml`, inserts the new ingress block above the catch-all,
creates the DNS CNAME via `cloudflared tunnel route dns`, reloads the
cloudflared LaunchAgent, waits 5s, and curls the public URL to confirm
routing. Re-running with an already-configured hostname is a safe no-op.

The rest of this section is **what the script does under the hood** — read it
when something goes wrong, or when you need to do something the script
doesn't cover (e.g. removing an app, custom ingress rules).

## Add a new app — the 4-step recipe (manual reference)

Say you've built a new app called `notes` and it's running on `localhost:9000`.
You want it reachable at `https://notes.mrdapps.com/`.

### Step 1 — make sure the app is running and survives reboots

Use `src/com.servusgroup.yt-transcript.plist` in this repo as a template:

```bash
# Copy and edit:
cp src/com.servusgroup.yt-transcript.plist \
   ~/Library/LaunchAgents/com.servusgroup.notes.plist

# Edit the new file — change:
#   <key>Label</key>        → com.servusgroup.notes
#   <key>ProgramArguments</key> → path to your app's entry point
#   <key>WorkingDirectory</key> → your app's folder
#   StandardOutPath/StandardErrorPath → ~/Library/Logs/notes.log

# Load it:
launchctl load ~/Library/LaunchAgents/com.servusgroup.notes.plist

# Sanity check — your app should respond on its port:
curl -s http://localhost:9000/
```

### Step 2 — tell cloudflared about it

Edit `~/.cloudflared/config.yml`. Add a new ingress block **above** the
catch-all 404 line:

```yaml
ingress:
  - hostname: transcript.mrdapps.com
    service: http://localhost:8765

  - hostname: notes.mrdapps.com          # <-- new
    service: http://localhost:9000       # <-- new

  - service: http_status:404
```

Validate before reloading:

```bash
cloudflared tunnel --config ~/.cloudflared/config.yml ingress validate
# → should print "OK"
```

### Step 3 — create the DNS record

```bash
cloudflared tunnel route dns mrdapps notes.mrdapps.com
```

This is the magic step. Cloudflare automatically creates a CNAME for
`notes.mrdapps.com` pointing at the tunnel. No dashboard click required.

### Step 4 — reload cloudflared so it picks up the new config

```bash
launchctl unload ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist
launchctl load   ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist
```

Wait ~10 seconds for DNS to propagate, then:

```bash
curl -sI https://notes.mrdapps.com/
# → should return your app's response, NOT a Cloudflare 502/1033
```

Done. Commit the config.yml change to whatever repo manages this Mac's setup
so you don't lose it (the live file at `~/.cloudflared/config.yml` is the
source of truth, but a copy in git is a useful backup).

---

## Health checks & troubleshooting

```bash
# Is the LaunchAgent loaded?
launchctl list | grep cloudflared

# Is the tunnel registering connections with Cloudflare?
cloudflared tunnel info mrdapps

# Live log
tail -f ~/Library/Logs/cloudflared.log

# Hit the public URL directly
curl -sI https://transcript.mrdapps.com/

# Hit the local service directly (bypass tunnel)
curl -s http://localhost:8765/health
```

### Common failure modes

| Symptom                                      | Likely cause                                            | Fix                                                                    |
| -------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------- |
| `curl` returns Cloudflare error `1033`       | Tunnel isn't connected (cloudflared not running)        | `launchctl list \| grep cloudflared` and check the log                 |
| `curl` returns `502 Bad Gateway`             | Tunnel up, but the local app isn't listening            | `curl http://localhost:PORT/` to confirm; check that app's LaunchAgent |
| `curl` returns `530` / cert error            | DNS pointing somewhere else, not the tunnel             | `cloudflared tunnel route dns mrdapps <host>` to re-create the CNAME   |
| New ingress block ignored                    | cloudflared wasn't reloaded after editing `config.yml`  | Unload + load the LaunchAgent                                          |
| `ingress validate` fails                     | YAML typo — usually indentation or missing `- hostname` | Compare to the template above                                          |

---

## Removing an app

1. Delete its ingress block from `~/.cloudflared/config.yml`.
2. Optionally delete the DNS record:
   `cloudflared tunnel route dns mrdapps --overwrite-dns ...` (or just leave
   the CNAME — once no rule matches, the tunnel returns 404).
3. Reload cloudflared (unload + load).
4. Stop the app's LaunchAgent:
   `launchctl unload ~/Library/LaunchAgents/com.<you>.<app>.plist`.

---

## Security notes (worth knowing)

- The contents of `~/.cloudflared/` (cert.pem, `<UUID>.json`, config.yml) are
  the keys to the kingdom for `mrdapps.com`. They're explicitly excluded from
  this repo via `.gitignore`. Never paste them anywhere.
- `service: http://localhost:NNNN` means the app sees Cloudflare's IP as the
  client. If your app needs the real visitor IP, look at the
  `Cf-Connecting-Ip` header.
- Each new subdomain is publicly reachable by anyone who guesses the name.
  Apps that hold private data MUST have their own auth (or sit behind
  Cloudflare Access — separate feature, separate setup).
