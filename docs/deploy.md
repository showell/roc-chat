# Deploying gopher-roc

gopher-roc serves https://chat.lynrummy.com from the prod droplet (162.243.1.123), behind the Caddy already there for lynrummy.com, in the place roc-chat held. The server listens on 127.0.0.1:9611 alone; Caddy holds the certificate, logs every request, and is the only way in. roc-chat ran the same way on the same machine (127.0.0.1:9490), so the cutover changes which service the site block points at, and nothing else on the droplet.

| What | Where on prod | From |
|---|---|---|
| the binary (static, ReleaseSafe) | `/opt/gopher-roc/gopher-roc`, root's, read-only to the service | built here by `tools/deploy.shale` |
| the service's folder | `/var/lib/gopher-roc`, the `gopherroc` user's, mode 700 | made by the deploy |
| the data root | `/var/lib/gopher-roc/data` | the chat's own; its first start makes Steve (`auth/1/`), `general`, and `.session-secret` |
| Steve's password's hash | `/var/lib/gopher-roc/data/auth/1/password` | Steve, with `gopher-roc hash-password` (below) |
| the unit | `/etc/systemd/system/gopher-roc.service` | `deploy/gopher-roc.service` |
| the site block | `/etc/caddy/sites/chat.lynrummy.com.caddy` | `deploy/chat.lynrummy.com.caddy` (it replaces roc-chat's) |
| the access log | `/var/log/caddy/chat-access.log` | Caddy's, the same file roc-chat's block wrote |

## Every deploy

```
cd ~/showell_repos/gopher-roc && shale tools/deploy.shale
```

It runs from gopher-roc's root, on `main`, with no arguments. It refuses on a dirty tree or while roc-chat still runs, pushes, builds, copies and proves the binary, restarts, installs the site block when it changed (Caddy validates it first, and the old one goes back if it fails), and ends by checking over HTTPS that `/login` is gopher-roc's sign-in page and `/agents` sends a browser with no session to it. Its header lists every step and every refusal.

## The cutover from roc-chat

Run these in order. Nothing of roc-chat's is deleted: its binary, unit, data and secrets stay where they are, for the way back.

**1. A backup of roc-chat's data** (on this box, in `~/build/roc-chat-backups`):

```
cd ~/showell_repos/roc-chat && shale tools/backup.shale
```

**2. Keep roc-chat's site block, then stop roc-chat.** The site answers 502 from here until step 3 ends.

```
ssh steve@162.243.1.123 'set -e; mkdir -p ~/roc-chat-rollback; cp /etc/caddy/sites/chat.lynrummy.com.caddy ~/roc-chat-rollback/; sudo systemctl disable --now roc-chat; systemctl is-active roc-chat || true'
```

The last line must say `inactive`.

**3. The deploy.** The first one makes the `gopherroc` user, `/opt/gopher-roc`, `/var/lib/gopher-roc/data` and the unit; the first start makes the chat in the empty data root (Steve as id 1, the founder; the channel `general` with him in it; `.session-secret`); then the site block points chat.lynrummy.com at 127.0.0.1:9611.

```
cd ~/showell_repos/gopher-roc && shale tools/deploy.shale
```

It ends saying Steve has no password yet.

**4. No secret is carried over.** roc-chat's three secrets, in `/var/lib/roc-chat/data/secrets/`, stay there for the way back:

- `github-client-id` and `github-client-secret`, the GitHub OAuth app's: gopher-roc has no GitHub sign-in, so nothing reads them.
- `signing-key`, the 32 random bytes that sign roc-chat's sessions: gopher-roc would read it as a `.session-secret` (any 32 to 256 bytes), but it gains nothing. gopher-roc's cookie is `__Host-gopher_auth`, signed over other bytes; roc-chat's is `__Host-session`. No roc-chat session admits anyone to gopher-roc whatever the key, so every browser signs in again either way, and one key serving two formats is a coupling with no use. The fresh `.session-secret` the first start made is the one to keep.

roc-chat's agents' keys and invites are hashes in its own store, of its own format: they do not carry either. Every agent is made and invited again at `/agents`.

**5. Steve's password.** Typed on the droplet, unechoed, twice; only its bcrypt hash is written, readable by `gopherroc` alone. The server reads it at each sign-in, so no restart.

```
ssh -t steve@162.243.1.123 "sudo -u gopherroc sh -c 'cd / && umask 077 && /opt/gopher-roc/gopher-roc hash-password > /var/lib/gopher-roc/data/auth/1/password'"
```

If the two typings differ it says so and leaves the file empty, which admits no one: run it again.

**6. The smoke test.** The deploy has already checked `/login` and `/agents` over HTTPS. Then, in a browser:

1. https://chat.lynrummy.com/login: sign in as `Steve` with the password from step 5. It lands on `/agents`.
2. https://chat.lynrummy.com/chat/channel/general/hello: post a message from the compose box; it appears without a reload.
3. Open the same page in a second window: a message posted in one appears in the other (the stream works through Caddy).
4. At `/agents`, make an agent and invite it; redeem the code (README, "An agent") and post with its key.

## The way back

roc-chat's data, secrets, binary and unit were never touched. Stop gopher-roc, put roc-chat's site block back, and start roc-chat:

```
ssh steve@162.243.1.123 'set -e; sudo systemctl disable --now gopher-roc; sudo install -m 644 ~/roc-chat-rollback/chat.lynrummy.com.caddy /etc/caddy/sites/chat.lynrummy.com.caddy; sudo caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile; sudo systemctl reload caddy; sudo systemctl enable --now roc-chat; systemctl is-active roc-chat'
```

The last line must say `active`; https://chat.lynrummy.com/login then sends the browser to GitHub. gopher-roc's folder stays as it was, so going forward again is step 3 alone (the deploy refuses while roc-chat runs, so step 2's `disable --now roc-chat` first).

## What Caddy must do, and must not

`deploy/chat.lynrummy.com.caddy` is the block; each line says why it is there.

**Caddy must:**

- **terminate HTTPS**: the session cookie is `__Host-` and `Secure`, so signing in needs it;
- **keep `Host`**, and pass `Origin`, `Cookie`, `Authorization`, `Sec-Fetch-Site` and `Sec-Fetch-Mode` unchanged: the app judges every request to its own origin from them (`app/RequestOrigin.roc`) and finds who is acting from `Cookie` or `Authorization`. A bare `reverse_proxy` does all of this; the block sets no header on the way in;
- **not buffer `text/event-stream`**: `flush_interval -1`, and `encode` compresses only the types it lists, never an event stream;
- **let a stream run an hour**: the app ends a stream itself at an hour (`Limits.stream_most_ms`), and the block sets no timeout that would end one sooner; Caddy sets none unless told;
- **admit a body of 10,551,296 bytes** (`max_size`), an upload's 10 MiB image and 64 KiB of form (`upload_body_allowance` in `app/main.roc`); the app holds each route to its own smaller cap;
- **not cache**: Caddy caches nothing unless a cache is configured, and none is.

**Rate-limiting is not done, and is open.** The app does not limit sign-ins: each `POST /login` costs a bcrypt check in the turn, and docs/platform.md ("The denial-of-service bound") says a proxy in front must hold each client to a rate of connections and of sign-ins. Prod's Caddy is the stock build, with no rate limiter (angry-gopher's deploy/README.md defers `xcaddy` + `caddy-ratelimit`), so the block has none.

**Caddy must not** rewrite `Host` or `Origin` (the app answers 403), or add a path prefix (every route is at the root: `/login`, `/agents`, `/chat/...`).

## Pitfalls

- **`/` is a 404.** gopher-roc has no page there yet; `/login` is the front door, and signing in lands on `/agents`.
- **A Caddy reload ends every open stream**, roc-chat's and gopher-roc's alike; the pages and agents reconnect.
- **The access log is Caddy's before Caddy validates:** `caddy validate` runs as root and would make a missing log root's, and the reload would then fail. The deploy makes it first.
- **Signing in needs HTTPS.** A test against the bare droplet over plain http serves the sign-in page but keeps no session. Locally, an `ssh -L 9611:127.0.0.1:9611` tunnel works (README, "Running the server locally").
