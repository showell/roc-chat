# Deploying roc-chat

This is the owner's runbook for https://chat.lynrummy.com. A command marked **[PROD WRITE]** changes the prod droplet. Claude runs `tools/deploy.shale` itself, on a `main` that has passed verify; anything else marked so is the owner's.

roc-chat runs on the prod droplet (162.243.1.123), beside Caddy, on 127.0.0.1:9611. Caddy holds the certificate, logs every request and is the only way in.

| What | Where on prod | From |
|---|---|---|
| the binary (static, ReleaseSafe) | `/opt/roc-chat/roc-chat`, root's, read-only to the service | built here by `tools/deploy.shale` |
| the service's folder | `/var/lib/roc-chat`, the `rocchat` user's, mode 700 | the deploy |
| the data root | `/var/lib/roc-chat/data` | seeded by the first start (below) |
| the GitHub app's id and secret | `.github-client-id`, `.github-client-secret` in the data root, mode 600 | the owner ("GitHub setup") |
| the session secret | `.session-secret` in the data root, mode 600 | made by the first start |
| the owner's GitHub id | `auth/1/github-id` in the data root | the owner ("GitHub setup") |
| the unit | `/etc/systemd/system/roc-chat.service` | `deploy/roc-chat.service` |
| the site block | `/etc/caddy/sites/chat.lynrummy.com.caddy` | `deploy/chat.lynrummy.com.caddy` |
| the access log | `/var/log/caddy/chat-access.log` | Caddy's |

## Deploying

Run the gate, then the deploy **[PROD WRITE]**:

```
cd ~/showell_repos/roc-chat && shale tools/verify.shale
cd ~/showell_repos/roc-chat && shale tools/deploy.shale
```

The gate proves that `main`, which is what deploys, passes. It ends `verify: every check passed`.

The deploy runs on a clean `main`, while the server runs, and goes straight through. It builds the release binary here, pushes `main`, copies the binary and proves its sha256, installs the unit when it changed, restarts the server, checks that the chat is seeded, and installs the site block when it changed, after Caddy validates it. It ends with the checks over HTTPS: `/` goes to `/chat`, `/chat` and `/agents` go to sign in, `/login` is roc-chat's page and offers GitHub, and `/login/github/start` goes to GitHub. The restart ends every stream, and the pages and agents reconnect. The data root is never touched. The script's header lists every step and refusal.

To look at the server's side (read-only):

```
ssh steve@162.243.1.123 'systemctl is-active roc-chat; sudo journalctl -u roc-chat -n 20 --no-pager; sudo tail -n 3 /var/log/caddy/chat-access.log'
```

It must say `active`, with no refusals in the journal and recent requests in the log.

## How a fresh data root is seeded

An empty data root gets the first chat at the server's first start, before it listens. Files whose names start with `.` don't count, so the GitHub files can be there first. The start writes:

- `auth/1/name`, holding `Steve`, the owner and admin;
- `chat/channel/general.channel`, holding `1`, so `general` exists with the owner in it before any sign-up;
- `auth/next-id.txt`, holding `2`, written last;
- `.session-secret`.

The owner has no password and no GitHub id until he links GitHub (below), so no one can sign in as him until then, and his name can't be taken. Each new human then starts in `general`, with a DM from the owner under the topic `ChitChat` holding the welcome message, which names the owner from `auth/1/name`. The deploy refuses to point the site at a server missing any of these files.

## GitHub setup

The chat's OAuth app calls back to `https://chat.lynrummy.com/login/github`. Its id and secret live in the data root as `.github-client-id` and `.github-client-secret`, the `rocchat` user's, mode 600. They stay on the droplet, and pass through no terminal or log.

The deploy refuses until both are there, so a first run on a new droplet makes the user and the folders, then stops, naming `.github-client-id`. To check them (read-only, showing names and sizes and no contents):

```
ssh steve@162.243.1.123 'sudo stat -c "%U %a %s %n" /var/lib/roc-chat/data/.github-client-id /var/lib/roc-chat/data/.github-client-secret'
```

The output must show `rocchat 600`, a size above 0, and each name.

### Linking the owner's GitHub account **[PROD WRITE]**

A new data root's owner has no password. This writes the numeric id of the GitHub account `showell`, which is public, to the owner's `github-id`, so GitHub is how he signs in.

```
ssh steve@162.243.1.123 "sudo -u rocchat sh -c 'cd / && umask 077 && printf 142908 > /var/lib/roc-chat/data/auth/1/github-id' && sudo stat -c '%U %a %s %n' /var/lib/roc-chat/data/auth/1/github-id"
```

The output must show `rocchat 600 6`. The server reads the file at each sign-in, so there is no restart.

**Don't press "Sign in with GitHub" before this is done.** With no link, GitHub makes a second account, and accounts are never removed.

Then, at https://chat.lynrummy.com/, press "Sign in with GitHub". You land on Browse, the top bar says Steve, and no form asks for a name. This proves the link. A browser already signed in to GitHub, on an app it has authorized, goes there and back with no page to see.

## The smoke test

The deploy checks the doors. These steps check what it can't, in a browser:

| Do this | It proves |
|---|---|
| In `general`, start a topic from Browse and post in it. The message appears with no reload. | The compose box, a write to disk, and the page's stream through Caddy. |
| Open the topic in a second window, and post from the first, once at once and once after two minutes. Both appear in the second. | Caddy doesn't buffer a stream, and the keepalive holds it past a quiet spell. |
| Upload an image from the compose box. | A large body passes Caddy's cap, and an image is served back. |
| At `/invites`, invite someone, and open the link in a private window. Join with a name and a password. | Human invites work behind the proxy. You land in a DM with the owner holding the welcome, and `general` is on your Browse. |
| Sign in with a second GitHub account in a private window. | Open sign-up works against the real GitHub. The new human chooses a name, lands in the DM with the welcome, and has `general`. |

## What Caddy must do, and must not

`deploy/chat.lynrummy.com.caddy` is the block. Caddy must:

- terminate HTTPS, as the session cookie is `__Host-` and `Secure`;
- keep `Host`, and pass `Origin`, `Cookie`, `Authorization`, `Sec-Fetch-Site` and `Sec-Fetch-Mode` unchanged. The app judges every request from them (`app/RequestOrigin.roc`) and answers a rewritten `Host` or `Origin` with a 403. A bare `reverse_proxy` does all of this, and the block sets no header on the way in;
- set `X-Forwarded-For` itself, as a bare `reverse_proxy` does with no `trusted_proxies` in the global options. The host counts each client by that header ("The per-client cap"), so a `trusted_proxies` that let a client's own copy through would let it choose its name;
- not buffer `text/event-stream`: `flush_interval -1`, and `encode` lists only other types;
- let a stream run an hour, as the app ends it itself (`Limits.stream_most_ms`) and the block sets no timeout;
- admit a body of 10,551,296 bytes, an upload's 10 MiB image and 64 KiB of form;
- add no path prefix, as every route is at the root.

The routes behind it are `/`, `/chat...`, `/login...`, `/logout`, `/join...`, `/agents...`, `/channels...`, `/invites...` and `/favicon.ico` (`app/Route.roc` has them all), and the block passes them all alike. GitHub's way back is `/login/github`, whose `code` and `state` appear in the access log. A code is good once, and the server spends it at once.

## The per-client cap

The host holds each client to `Limits.requests_per_client_most` requests in flight, 32, and answers one past it with a 429 before the app is asked. A client here is one `X-Forwarded-For` value, which Caddy sets itself, so the count is per client for HTTP/1, 2 and 3 alike, and touches no other site. A stream counts until its task ends, so a client's 8 streams leave it 24 for pages and their scripts. A stream whose client has gone counts until its next write fails, within the 25 seconds of a keepalive, or a newer stream of its holder ends it.

A request with no `X-Forwarded-For` is not counted. Only a request through Caddy can come from elsewhere, as the server listens on 127.0.0.1, so one without the header comes from this machine: a tunnel, a test, the owner.

The app also bounds these, per client or in all: 8 streams a holder and 64 in all, 5 password checks and one more a second for everyone together, 64 MiB of bodies in flight, and 10 seconds for a request to arrive and 10 for its answer.

The cap is a count, not a rate. A client may open and finish requests as fast as it likes, a refused connection holds its file descriptor for up to a second's linger, and many addresses are many clients, which an IPv6 client's own /64 gives it. A flood from those can still cost memory and fill the 1,024 file descriptors a service gets by default. The server logs a failed accept and goes on, and it doesn't stop. A rate needs a Caddy built with `mholt/caddy-ratelimit`, which replaces the binary that serves every site on the droplet, and stock Caddy has no directive for one.

## LC's listener

`tools/listen.shale` is LC's listener, an adaptation of `cookbook:listen.shale`. It prints one line for each post by someone else whose own words say `@LC`.

LC needs an account and a key first:

1. At `/agents`, make the agent `LC`.
2. Add it to a channel at `/channels`, as agents take part only in channels. `general` is where every new human lands, so LC in `general` hears them all. A channel of its own keeps it apart. You choose.
3. At `/agents`, press "Invite LC". The page shows a one-time code, which lives ten minutes.
4. Redeem it on this box, with the code in place of `<code>`. The key goes from curl straight to the secrets mount, and no script or terminal sees it. `--fail` matters: without it, a refused code's words would be stored as the key.

```
cd ~/showell_repos/roc-chat && shale <<'SHALE'
local r = run({"curl", "-sS", "--fail", "--data-urlencode", "code=<code>", "https://chat.lynrummy.com/agents/redeem"},
  {timeout_ms = 30000, stdout_secret = "keys:roc_chat_lc_key"})
if not r.secret_written then fail("not stored: curl exited " .. r.code .. ", " .. r.out) end
print("stored")
SHALE
```

Run the listener from this repo's root:

```
cd ~/showell_repos/roc-chat && shale tools/listen.shale once=1
cd ~/showell_repos/roc-chat && shale tools/listen.shale log=listen.log
```

The first ends at the first window that holds a post for LC, and its last line says the `since=` and `ids=` to go on with, so a detached run can wake a session and start again with nothing missed or heard twice. The second appends each line to the log until it stops, which it does after about 22 hours of quiet, naming the same two values. A run starts from its own start time unless `since=` says otherwise. `site=`, `me=` and `key=` default to https://chat.lynrummy.com, `LC` and `keys:roc_chat_lc_key`. `window=` is how long each curl holds the stream, 20 seconds by default, so a post is heard at most that late.

It reads `GET /agents/stream` and resumes with `?since=<date>`, from the `date` of the last event read. That second's messages may come twice, and it drops a repeat by conversation and id. A post is for LC when its `markdown` says `@LC` outside quoted and fenced text; the name leading a post, as in `LC, a question`, doesn't count. Nothing limits agents answering agents.

It reconnects by itself after a deploy, a 502 or a 429. It stops nonzero, named, on a 401 or 403 (the key is revoked or wrong), a 400 or 404, an event that lacks a field, or a jump in a conversation's ids, whose stop names the `/raw` transcript to read. A conversation it has read nothing of yet has no ids to jump from, so a catch-up cut at the 100 newest shows no gap there. `shale tools/listen.shale self_test=1` tests its decisions, and verify runs that.

## Pitfalls

- **The server reads the GitHub files only at its start.** A new secret needs `sudo systemctl restart roc-chat`.
- **A file open to others stops the start.** `.session-secret` and the GitHub files must be mode 600, and the journal names the one that isn't.
- **A Caddy reload ends every open stream** on the droplet's sites. The pages and agents reconnect.
- **The access log is Caddy's before Caddy validates.** `caddy validate` runs as root and would make a missing log root's, and the reload would then fail. The deploy makes it first.
- **Signing in needs HTTPS.** A test over plain http to the droplet serves the sign-in page and keeps no session. Locally, an `ssh -L 9611:127.0.0.1:9611` tunnel works (README, "Running the server locally").
