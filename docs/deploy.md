# Deploying gopher-roc

This is the owner's runbook for moving https://chat.lynrummy.com from roc-chat to gopher-roc, and for every deploy after that. Run the commands in order, from this box. A command marked **[PROD WRITE]** changes the prod droplet, and only the owner runs those. Nothing here has run against prod yet.

gopher-roc runs on the prod droplet (162.243.1.123), beside Caddy, on 127.0.0.1:9611. Caddy holds the certificate, logs every request and is the only way in. roc-chat runs the same way on 127.0.0.1:9490, so the cutover changes which service the site block points at, and nothing else on the droplet.

| What | Where on prod | From |
|---|---|---|
| the binary (static, ReleaseSafe) | `/opt/gopher-roc/gopher-roc`, root's, read-only to the service | built here by `tools/deploy.shale` |
| the service's folder | `/var/lib/gopher-roc`, the `gopherroc` user's, mode 700 | the deploy |
| the data root | `/var/lib/gopher-roc/data` | seeded by the first start (below) |
| the GitHub app's id and secret | `.github-client-id`, `.github-client-secret` in the data root, mode 600 | copied from roc-chat's on prod, step 4 |
| the session secret | `.session-secret` in the data root, mode 600 | made by the first start |
| the owner's password's hash | `auth/1/password` in the data root | the owner, step 8 |
| the unit | `/etc/systemd/system/gopher-roc.service` | `deploy/gopher-roc.service` |
| the site block | `/etc/caddy/sites/chat.lynrummy.com.caddy` | `deploy/chat.lynrummy.com.caddy`, in place of roc-chat's |
| the access log | `/var/log/caddy/chat-access.log` | Caddy's, the file roc-chat's block wrote |

## What carries over, and what doesn't

- **The GitHub OAuth app carries over.** roc-chat's app already calls back to `https://chat.lynrummy.com/login/github`, the URL gopher-roc uses, so GitHub needs no change. Step 4 copies its id and secret on prod, and they never leave the droplet.
- **The owner's account carries over in name only.** The first start makes `Steve` as id 1. roc-chat's accounts are in another format, so the owner gets a new password (step 8) and links GitHub to it (step 9).
- **The session key doesn't carry over.** gopher-roc could read roc-chat's `signing-key` as its `.session-secret`, but keeping it would keep nothing. The cookie has another name and signs other bytes, so every browser signs in again either way, and one key would then serve two formats. The first start makes a fresh one.
- **Conversations, other accounts, agents and their keys don't carry over.** Apoorva signs in fresh with GitHub. Every agent is made and invited again.
- **Nothing of roc-chat's is deleted.** Its binary, unit, data, secrets and port 9490 stay as they are, for the way back.

## How a fresh data root is seeded

An empty data root gets the first chat at the server's first start, before it listens. Files whose names start with `.` don't count, so the GitHub files can be there first. The start writes:

- `auth/1/name`, holding `Steve`, the owner and admin;
- `chat/channel/general.channel`, holding `1`, so `general` exists with the owner in it before any sign-up;
- `auth/next-id.txt`, holding `2`, written last;
- `.session-secret`.

The owner has no password until step 8, so no one can sign in as him until then, and his name can't be taken. Each new human then starts in `general`, with a DM from the owner under the topic `ChitChat` holding the welcome message, which names the owner from `auth/1/name`. The deploy refuses to point the site at a server missing any of these files.

## The cutover

### 0. Merge, and run the gate

```
cd ~/showell_repos/gopher-roc && git merge --ff-only deploy/prod && shale tools/verify.shale
```

This proves that what deploys is `main`, and that `main` passes. It ends `verify: every check passed`.

### 1. Look at prod (read-only)

```
ssh steve@162.243.1.123 'caddy version; caddy list-modules | grep -iE "rate|limit"; ss -ltn | grep -E ":(9490|9611) "; sudo ls -l /var/lib/roc-chat/data/secrets; df -h /var/lib; free -m'
```

This proves four things. No module line means prod's Caddy is the stock build, as "The per-client cap" assumes. Port 9490 is listening and 9611 isn't. `github-client-id` and `github-client-secret` are in the listing, which shows names and sizes and no contents. There is room on the disk.

### 2. Back up roc-chat's data

```
cd ~/showell_repos/roc-chat && shale tools/backup.shale
```

This reads prod and writes one tar to `~/build/roc-chat-backups` on this box. It proves the data can be brought back whatever happens next. It leaves `secrets/` out.

### 3. First deploy run: the user and the folders **[PROD WRITE]**

```
cd ~/showell_repos/gopher-roc && shale tools/deploy.shale
```

roc-chat keeps serving. The run makes the `gopherroc` user, `/opt/gopher-roc` and `/var/lib/gopher-roc/data`, then stops on purpose, naming `.github-client-id`. That stop is the proof that the folders exist.

### 4. Copy the GitHub app's id and secret **[PROD WRITE]**

```
ssh steve@162.243.1.123 'set -e; for f in id secret; do sudo install -o gopherroc -g gopherroc -m 600 /var/lib/roc-chat/data/secrets/github-client-$f /var/lib/gopher-roc/data/.github-client-$f; done; sudo stat -c "%U %a %s %n" /var/lib/gopher-roc/data/.github-client-id /var/lib/gopher-roc/data/.github-client-secret'
```

The two values go from file to file on prod, and pass through no terminal or log. The output must show `gopherroc 600`, a size above 0, and each name. The server refuses to start on a file open to others, and it reads these files only at its start, so they come before step 7.

### 5. Second deploy run: the build

```
cd ~/showell_repos/gopher-roc && shale tools/deploy.shale
```

roc-chat keeps serving. The run builds the release binary here, about three minutes, then stops on purpose, saying roc-chat still runs. That stop proves the GitHub files are there and the build succeeded, and it keeps the build out of the outage.

### 6. Keep roc-chat's site block, and stop roc-chat **[PROD WRITE]**

```
ssh steve@162.243.1.123 'set -e; mkdir -p ~/roc-chat-rollback; cp /etc/caddy/sites/chat.lynrummy.com.caddy ~/roc-chat-rollback/; sudo systemctl disable --now roc-chat; systemctl is-active roc-chat || true'
```

The last line must say `inactive`. The site answers 502 from here until step 7 ends. Any listener of roc-chat's reconnects until then, and stops at step 7 with a 401, as its key means nothing to gopher-roc.

### 7. Third deploy run: the cutover **[PROD WRITE]**

```
cd ~/showell_repos/gopher-roc && shale tools/deploy.shale
```

The run copies the binary and proves its sha256, installs the unit, starts the server, checks that the first start seeded the chat, installs the site block after Caddy validates it, and reloads Caddy. This is the first time the block meets a Caddy, as this box has none to run. Its directives are those of roc-chat's live block, with another port and body size. If it fails to validate, the old block goes back and the run stops, and the way back below applies.

The run ends with the checks over HTTPS: `/` goes to `/chat`, `/chat` and `/agents` go to sign in, `/login` is gopher-roc's page and offers GitHub, and `/login/github/start` goes to GitHub. It then says the owner has no password yet and hasn't linked GitHub. The site is up from here, and open to GitHub sign-ups.

### 8. Set the owner's password **[PROD WRITE]**

```
ssh -t steve@162.243.1.123 "sudo -u gopherroc sh -c 'cd / && umask 077 && /opt/gopher-roc/gopher-roc hash-password > /var/lib/gopher-roc/data/auth/1/password'"
```

You type it twice on the droplet, with no echo. Only its bcrypt hash is written, readable by `gopherroc` alone, and the password reaches no agent, log or argument list. The server reads the file at each sign-in, so there is no restart. If the two typings differ, it says so and leaves the file empty, which admits no one: run it again.

### 9. Sign in with the password, then link GitHub

**Don't press "Sign in with GitHub" before this step is done.** With no link, GitHub makes a second account, and accounts are never removed. Your GitHub account would then be taken, and a link from `Steve` would be refused.

1. At https://chat.lynrummy.com/, sign in as `Steve` with the password from step 8. You land on Browse.
2. At https://chat.lynrummy.com/agents, press "Link GitHub", and authorize. You land back on Browse, still signed in.
3. Sign out, and sign in with GitHub. The top bar says Steve. This proves the link.

If GitHub made a second account first, the page it landed on, `/chat/dm/1_<n>/ChitChat`, gives its number `<n>`. This command frees your GitHub account **[PROD WRITE]**. Then sign out and do this step again. The stray account stays in the chat, with no way to sign in.

```
ssh steve@162.243.1.123 'sudo rm /var/lib/gopher-roc/data/auth/<n>/github-id'
```

### 10. The smoke test

The deploy has already checked the doors. These steps check what it can't, in a browser:

| Do this | It proves |
|---|---|
| In `general`, start a topic from Browse and post in it. The message appears with no reload. | The compose box, a write to disk, and the page's stream through Caddy. |
| Open the topic in a second window, and post from the first, once at once and once after two minutes. Both appear in the second. | Caddy doesn't buffer a stream, and the keepalive holds it past a quiet spell. |
| Upload an image from the compose box. | A large body passes Caddy's cap, and an image is served back. |
| At `/invites`, invite someone, and open the link in a private window. Join with a name and a password. | Human invites work behind the proxy. You land in a DM with the owner holding the welcome, and `general` is on your Browse. |
| Have Apoorva sign in with GitHub, or use a second GitHub account in a private window. | Open sign-up works against the real GitHub. She chooses a name, lands in the DM with the welcome, and has `general`. |

Then look at the server's side (read-only):

```
ssh steve@162.243.1.123 'systemctl is-active gopher-roc; sudo journalctl -u gopher-roc -n 20 --no-pager; sudo tail -n 3 /var/log/caddy/chat-access.log'
```

It must say `active`, with no refusals in the journal and these requests in the log.

### 11. LC

Make LC an account, and give it a key. The listener is still to come: see "LC's listener" below.

1. At `/agents`, make the agent `LC`.
2. Add it to a channel at `/channels`, as agents take part only in channels. `general` is where every new human lands, so LC in `general` hears them all. A channel of its own keeps it apart. You choose.
3. At `/agents`, press "Invite LC". The page shows a one-time code, which lives ten minutes.
4. Redeem it on this box, with the code in place of `<code>`. The key goes from curl straight to the secrets mount, and no script or terminal sees it. `--fail` matters: without it, a refused code's words would be stored as the key.

```
cd ~/showell_repos/gopher-roc && shale <<'SHALE'
local r = run({"curl", "-sS", "--fail", "--data-urlencode", "code=<code>", "https://chat.lynrummy.com/agents/redeem"},
  {timeout_ms = 30000, stdout_secret = "keys:gopher_roc_lc_key"})
if not r.secret_written then fail("not stored: curl exited " .. r.code .. ", " .. r.out) end
print("stored")
SHALE
```

## Every later deploy

```
cd ~/showell_repos/gopher-roc && shale tools/deploy.shale
```

**[PROD WRITE]** It runs on a clean `main`, and goes straight through. The restart ends every stream, and the pages and agents reconnect. The data root is never touched. Its header lists every step and refusal.

## The way back to roc-chat

roc-chat's data, secrets, binary, unit and port were never touched, so going back is one command **[PROD WRITE]**:

```
ssh steve@162.243.1.123 'set -e; sudo systemctl disable --now gopher-roc; sudo install -m 644 ~/roc-chat-rollback/chat.lynrummy.com.caddy /etc/caddy/sites/chat.lynrummy.com.caddy; sudo caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile; sudo systemctl reload caddy; sudo systemctl enable --now roc-chat; systemctl is-active roc-chat'
```

The last line must say `active`, and https://chat.lynrummy.com/login then sends the browser to GitHub. That proves roc-chat serves again. Its accounts, sessions and agents' keys work as before, and whatever was posted on gopher-roc stays in gopher-roc's folder, unseen by roc-chat. To go forward again, run steps 6 and 7. The password, the link and everything else in the data root are still there.

## What Caddy must do, and must not

`deploy/chat.lynrummy.com.caddy` is the block. Caddy must:

- terminate HTTPS, as the session cookie is `__Host-` and `Secure`;
- keep `Host`, and pass `Origin`, `Cookie`, `Authorization`, `Sec-Fetch-Site` and `Sec-Fetch-Mode` unchanged. The app judges every request from them (`app/RequestOrigin.roc`) and answers a rewritten `Host` or `Origin` with a 403. A bare `reverse_proxy` does all of this, and the block sets no header on the way in;
- not buffer `text/event-stream`: `flush_interval -1`, and `encode` lists only other types;
- let a stream run an hour, as the app ends it itself (`Limits.stream_most_ms`) and the block sets no timeout;
- admit a body of 10,551,296 bytes, an upload's 10 MiB image and 64 KiB of form;
- add no path prefix, as every route is at the root.

The routes behind it are `/`, `/chat...`, `/login...`, `/logout`, `/join...`, `/agents...`, `/channels...` and `/invites...` (`app/Route.roc` has them all), and the block passes them all alike. GitHub's way back is `/login/github`, whose `code` and `state` appear in the access log. A code is good once, and the server spends it at once.

## The per-client cap

docs/platform.md asks the proxy to cap the connections a client may hold and the rate it opens them. **This is not done, and the block can't do it.** Stock Caddy has no directive for it, and prod's Caddy is the stock package (angry-gopher's deploy/README.md). A directive it doesn't know would fail `caddy validate`, and the block would never install. `max_conns_per_host` under `reverse_proxy` counts every client together, so one client could use it up for all the others.

Today the app bounds these per client or in all: 8 streams a holder and 64 in all, 5 password checks and one more a second for everyone together, 64 MiB of bodies in flight, and 10 seconds for a request to arrive and 10 for its answer. It doesn't bound how many plain connections a client holds open within those 10 seconds. A flood can cost memory and fill the 1,024 file descriptors a service gets by default. The server logs a failed accept and goes on, and it doesn't stop.

There are three ways to add a cap, and each is the owner's to decide:

1. **The host counts requests in flight per `X-Forwarded-For`.** Caddy sets that header itself and ignores a client's own copy unless `trusted_proxies` says otherwise, so the count is per client for HTTP/1, 2 and 3 alike, and touches no other site. It is new code in `host/http.zig`, with tests.
2. **A Caddy built with `mholt/caddy-ratelimit`,** keyed on `{remote_host}`. That is a rate and not a count of what is open, and it replaces the binary that serves every site on the droplet.
3. **A kernel `connlimit` rule on TCP 443.** That is a true count of connections, but it covers every site, doesn't see HTTP/2's many requests on one connection, and doesn't see HTTP/3, which is UDP.

The first is the recommendation. None of them blocks the cutover: roc-chat ran with no cap either.

## LC's listener

`cookbook:listen.shale` doesn't work against gopher-roc. Against a local server with a live key, it stops at once with a 404, named. What it needs, against what it does for roc-chat:

| | roc-chat, as the recipe reads it | gopher-roc |
|---|---|---|
| The stream | `GET /stream`, or `/conversations/<n>/stream` | `GET /agents/stream`, and both of the others are a 404 |
| Resuming | `Last-Event-ID`, an event's `id:` | no `id:` line: `?since=<date>`, from the `date` of the last event read, and that second's messages may come twice |
| A repeat | dropped by conversation and id | the same, `conversation` now a URL path such as `/chat/channel/general/hello` |
| Who wrote it | `by`, such as `agent:2` | `from`, a name such as `Steve` |
| The time | `at`, seconds | `date`, as `2026-11-05T17:33:05Z` |
| Who it's for | the server's `mentions`, and a message without them stops the run | no `mentions`, by design: the listener decides from the `markdown`, as `@LC`, and must skip quoted and fenced text itself |
| A gap | a `gap` event | no event: a jump in a conversation's ids, past the 100 newest a catch-up sends, and the rest is at `<conversation>/raw` |
| Agents answering agents | the server's limit of 15 an hour, which the recipe warns of | no such limit, so the warning goes |

The reconnecting and the batching carry over unchanged. A 401 still means a revoked key, a stream still ends by itself after an hour, and `: ping` lines are still comments. Each window must ask for `?since=`, because a live-only stream misses whatever is posted between windows, and a listener that has seen nothing yet must start from its own start time.

So LC needs a new listener: a copy of the recipe in this repo's `tools/`, as a script starts in the repository that uses it. Until it exists, LC can post and read with its key, and a plain `curl -N` of `/agents/stream` hears everything. It is not needed for the cutover.

## Pitfalls

- **Don't run roc-chat's `tools/deploy.shale` after the cutover.** It would put its block back and restart roc-chat. The way back above is the way to do that.
- **The server reads the GitHub files only at its start.** A new secret needs `sudo systemctl restart gopher-roc`.
- **A file open to others stops the start.** `.session-secret` and the GitHub files must be mode 600, and the journal names the one that isn't.
- **A Caddy reload ends every open stream** on the droplet's sites. The pages and agents reconnect.
- **The access log is Caddy's before Caddy validates.** `caddy validate` runs as root and would make a missing log root's, and the reload would then fail. The deploy makes it first.
- **Signing in needs HTTPS.** A test over plain http to the droplet serves the sign-in page and keeps no session. Locally, an `ssh -L 9611:127.0.0.1:9611` tunnel works (README, "Running the server locally").
- **There is no remote yet.** The deploy says so and goes on, so what serves exists only on this box. When `main` has an upstream, the deploy pushes it first.
