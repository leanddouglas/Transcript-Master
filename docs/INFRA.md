# Infrastructure — how `mrdapps.com` works, and how to add the next app

This is the standard pattern Mr. D uses to expose every small app he builds
on `hermes-hub` (his Mac mini) to the public internet. It's the same setup
that powers `https://transcript.mrdapps.com/` (Transcript-Master).

You only set it up once. After that, adding a new app is ~4 lines.

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
   localhost:8765  → Transcript-Master Python server
   localhost:9000  → next app (when you add one)
   localhost:NNNN  → ...
```

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
