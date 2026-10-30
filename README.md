# roc-chat

The Roc chat's own server: the chat is a Roc app (`app/`, on the platform in
`platform/`), and its host (`host/`) is a small Zig server on `std.http`.

**Status (2026-10-29): the smallest real chat, with agents and API keys;
it serves chat.lynrummy.com (DEPLOY.md).**
- **Sign-in and agents:** sign-in on the auth core; a signed-in human makes
  agents they own (each id given once, never again), mints keys acting as
  themselves, and invites their agents, which redeem a ten-minute code for
  a key and talk to the chat with `Authorization: Bearer`.
- **Conversations:** a human or a key starts one with named participants;
  a participant posts markdown (rendered by roc-markdown, refused when
  hostile); anyone ConvAccess lets see it reads its transcript a page at a time;
  each open stream gets each message once, live, resuming from
  `Last-Event-ID`. A page and a stream's backlog are read from where
  their first message starts, never the transcript whole.
- **Media only from the chat's uploads:** the chat tells roc-markdown its
  uploads are under `/user_uploads/` (`Conversations.markdown`), since where
  its files live is the chat's to say, not the renderer's; a member's image
  aimed at any other path, the chat's own routes included, is text.
- **Caps per human** (`app/Limits.roc`): 20 agents, 200 keys, 200 invites
  and 1,000 conversations started. A request past one is a 403 that names
  it. A human's conversations, keys and invites are read from their own
  index (the Store's header), never by scanning everyone's.
- **What a client sees:** two plain pages (`/chat`, `/chat/<id>`) to read
  and post in a browser; the rest is JSON, an event stream, and the chat
  client's scripts. The old chat's breadth is still to come. The design is
  the essay notes `roc-chat-host-design` and `roc-chat-auth-design`
  (essay-repl-server `notes/`).

## The routes

| | |
|---|---|
| `GET /` | A hello page, rendered by roc-markdown. |
| `GET /login` | Sign-in: the browser sent to GitHub with a signed state. |
| `GET /login/github` | GitHub's callback: the exchange off the turn, then a session or the name form. |
| `POST /login/name` | The display name for a new account; the session cookie. |
| `GET /me` | Who this session is. |
| `GET /conversations` | The viewer's own: `{"conversations":[{"id":N,"with":[{"id":"human:2","name":"…"}]}]}`, each one ConvAccess lets them post in. |
| `POST /conversations` | Start one: a form, `with=` the others' ids, comma-separated (`human:2,agent:7`). The signed-in human is in it. `201 {"id":N}`. |
| `GET /conversations/<id>` | A page of its transcript: the newest 100 messages, or the 100 before `?before=<id>`, oldest first: `{"id":N,"messages":[…],"earlier":bool}`. `earlier` says messages come before the page's first; `?before=` that first's id loads them. |
| `POST /conversations/<id>/messages` | Post: the body is the markdown, as is. `201` and the message. |
| `GET /conversations/<id>/stream` | Its messages, live (SSE, events named `message`, each id the message's), after `Last-Event-ID` when the browser resumes. The backlog is at most the newest page; a browser further behind gets a `gap` event first, `{"before":<id>}`, and pages back for the rest. |
| `POST /agents` | Make an agent you own: a form, `name=` (DisplayName's rule). `201 {"id":"agent:7","name":"CC","owner":"human:2"}`; a bad name a 400. |
| `POST /keys` | Mint a key for yourself: a form, each field optional: `read=` and `post=` (`everywhere`, the default; `off`; `only:3,9`), `admin=on` (off by default), `lifetime=` seconds (at most a year, the default). `201` and the key, with its `secret` (64 hex digits), **shown this once**. `as=agent:7` is a 403: an agent's key comes from an invite. |
| `GET /keys` | Your keys and your agents': `{"keys":[{"id":4,"acts_as":"agent:7","read":"everywhere","post":"everywhere","admin":"off","created":…,"expires":…,"revoked":false}]}`, never a secret. |
| `POST /keys/<id>/revoke` | Revoke one of them, for good: `200` and the key; another's, or none, a 404. |
| `POST /invites` | Invite one of your agents or bots: a form, `as=agent:7` and a mint's other fields, for the key it redeems to. `201 {"id":3,"for":"agent:7","expires":…,"code":"…"}`, the `code` (64 hex digits) **shown this once**, good for ten minutes and one redemption. |
| `GET /invites` | Your live invites: `{"invites":[{"id":3,"for":"agent:7","expires":…}]}`, never a code. |
| `POST /invites/<id>/revoke` | Revoke one: `200` and the invite; another's, or none live, a 404. |
| `POST /invites/redeem` | The agent's: a form, `code=`, and **no cookie or key** (the code is the credential). `201` and the key, as a mint answers, its `secret` shown this once. Any refusal is one `401 invite refused` (Agents' header lists them). |
| `GET /chat` | The page: the viewer's conversations, each a link, and a form to start one. Signed out, a 303 to `/login`; a key, a 403 (a page is a browser's). |
| `GET /chat/<id>` | A conversation's page: its newest page of messages (a button loads each page before), new ones live (`EventSource`), a box to post in (Enter sends, Shift-Enter adds a line). A 404 to a viewer who may not see it. |
| `GET /<name>.js` | The chat client's scripts. |

A message is `{"id":3,"at":1761600000,"by":"human:2","markdown":"…","html":"…"}`.
Who is asking is a session's cookie or an API key's Bearer header, never
both (`Credentials.load_viewer!`); who may see and who may post is ConvAccess's.
Signed out is a 401; a conversation the viewer may not see is a 404, as one
that is not there; one it sees but may not post to, a 403.

**An agent's key comes only from an invite**, so a human never passes a
durable secret around: they hand the agent a code that dies in ten minutes
or at its first use. The redemption grants again, as the session that
invited, against the accounts then (`Agents.redeemed`). **An agent's
requests** carry `Authorization: Bearer <secret>`, the secret its
redemption showed. The host hashes it; the store holds only that hash
(`auth/keys/<hash>`). A key unknown, revoked or expired is a 401; one used
outside its scope, the 403 or 404 a session gets. A key starts a
conversation only where it could post to it. A request with both a session
cookie and a Bearer header is a 400. Agents, keys, listing and revoking are
a session's alone, and so are invites: a key asking is a 403. Every key
refused in use, every grant refused, and every invite made, redeemed,
revoked or refused is in the audit (`auth/audit`), with no secret or code.

## Before you build

- **Linux on x86-64**, and **stock Zig 0.17.0**. Any other target fails at
  configure time.
- **Roc, the nightly `roc-version` pins** (`nightly-2026-10-29-a0a9fc2`),
  at `~/tools/roc-<pin>/roc`, where `tools/get_roc.sh` installs it; else
  `roc` on the PATH, or one named with `-Droc=<path>`. Pins live side by
  side in `~/tools`, so another project's Roc on the PATH doesn't matter.
  `build.zig` stops if there is no Roc, or if `roc version` names another
  nightly.
- **Two sibling checkouts** under the same parent directory as this one:
  - `../roc-markdown` (github.com/showell/roc-markdown), the Roc package
    that renders the chat's markdown. `app/main.roc`'s header imports it
    by path (`md: "../../roc-markdown/package/main.roc"`), which the pinned
    Roc takes for a local package.
  - `../chat-client` (github.com/showell/chat-client), the browser client:
    a Zig package whose module `chat_client` holds each script's bytes.
    `build.zig.zon` names it by path.

  Both are taken at whatever their checkouts hold. A pinned, fetched
  dependency (a tarball by hash, laid out in a generated tree for Roc)
  would pin them; sibling paths are the simplest thing that works at this
  Roc's pin.

## Build, test, serve

```
zig build test      # roc test, the host's tests, the glue check, and the end to end
zig build e2e       # the end to end alone: two clients, sign-in to stream, a line a step
shale tools/verify.shale   # every check, the planted faults, a checklist (as `steve`)
zig build serve     # http://127.0.0.1:9480, from dev/ (dev/config.zon; its data in dev/data)
zig build           # zig-out/bin/roc-chat
```

**The server takes no arguments.** It reads `config.zon` from its working
directory: `.bind`, `.port` and `.data`, the data root, relative to the
config's folder; `.origin`, the public origin GitHub sends the browser back
to; `.secrets`, the secret files' names under the data root's `secrets/`
(the OAuth app's client id and secret, which you write, mode 0600, and the
signing key, made on first start); and optionally `.github` (GitHub's base
URLs and deadlines, a test's fake) and `.bootstrap_admin` (the first
admin's GitHub id). `dev/config.zon` is the example. A setting that is
missing or wrong, or a secret file missing or readable by others, stops the
server, saying which.

## The model

- **A task per connection** (`std.Io.Group.concurrent` on the threaded
  `Io`), and **one mutex, the turn**, held only while a request's Roc call
  runs. One handler runs at a time, so the Roc's check-then-set is atomic.
- **The turn never waits on the network.** A request's head and body are
  read whole before its turn, and its answer is written after. A slow
  client holds its own task, nothing else.
- **Every read and write has a deadline**: the head (10 s), the idle wait
  between kept-open requests (10 s), the body (10 s) and the answer's write
  (10 s). One watchdog task enforces them all, by shutting a late
  connection's socket. A late head or body is a 408; an idle connection is
  closed quietly.
- **A body is capped at 64 KiB.** A length past the cap is a 413, sent
  without reading the body, and the request never takes the turn. The Roc
  can ask for less (`Host.read_body!`'s limit), and the host answers that
  413 for it.
- **Keep-alive**, at most 1,000 requests per connection and 64 connections
  kept open at once; pipelined requests are answered in order.
- **The Roc's headers go through a short list**: `set-cookie`,
  `cache-control` and `location`. Any other name, or a CR, LF or NUL, is a
  500 (the Roc's bug). The host owns the rest (`content-type` from the
  answer's own field, `content-length`, `connection`).
- **GitHub's exchange runs outside the turn**, between two Roc calls
  (`Server.answer`): the first answers `Exchange` with the code, the host
  exchanges it on the connection's own task (`host/signin.zig`, under the
  GitHub client's deadlines), and the second call hears the same request
  with what GitHub said (`Request.exchanged`). The Roc keeps nothing
  between the calls. The client secret and GitHub's token never cross the
  seam, and the Roc never holds the signing key: `sign!` and `verify!` use
  the host's.
- **A Roc crash is a 500, not a dead server**: the call jumps back to where
  it began (`host/seam/sljmp.zig`), and the request's arena goes with it.
  A recursion past the stack, which calls no `roc_crashed`, is caught as
  its fault on the call's own stack (a SIGSEGV handler, `chat_abi.zig`) and
  is the same crash; any other fault still stops the process. The answer is the host's fixed 500, nothing of the Roc's in it, and the
  crash is logged once, on one line, in the turn: its turn, method, path
  and the Roc's message, escaped. Planted crashes prove it, one per way the
  Roc can die (`app/test/crash.roc`, `host/crash_test.zig`).
- **Event streams (SSE), for any app on the platform.** A handler answers
  `Chat.stream({ key, backlog })` and publishes with `Host.publish!(key,
  frame)`, a frame made by `Sse.frame` (`platform/Sse.roc` has an
  example). The key is any bytes the app chooses. The host subscribes the
  stream **in the same turn** as the handler that read its backlog, so a
  frame is in the backlog or comes live, never both and never neither.
  After the turn, the stream holds its own task: frames go out verbatim,
  each write under the write deadline (a reader that stops reading is
  shut), with `: ping` after 25 s of quiet. A stream 16 frames behind is
  ended, never skipped ahead: the browser reconnects with its
  `Last-Event-ID`. At most 64 streams are held; the 65th ends the oldest
  stream of the holder holding the most, so one holder cannot end others'.

## Layout

| | |
|---|---|
| `app/main.roc` | The route table: which module answers which request. |
| `app/Conversations.roc` | The conversations on the wire: list, start, read, post, stream. |
| `app/Pages.roc` | The two pages, their few lines of CSS and script inline. What a page writes itself is escaped; a message's HTML is roc-markdown's, as is. |
| `app/Agents.roc` | Agents, API keys and invites on the wire: make an agent (`Agents.make`, pure), mint, list, revoke; invite, redeem (`Agents.invited`, `Agents.redeemed`, pure), list, revoke. |
| `app/InviteCodec.roc` | An invite's record and line: the code's hash, never the code; the agent bound; the granter by its stored hash; the redemption's refusals. |
| `app/Credentials.roc` | Who is asking: a session's cookie or a key's Bearer header, never both; the viewer; a key refused in use, audited. |
| `app/Wire.roc` | The JSON answer, the plain refusal, and JSON's string escape the route modules share. |
| `app/Store.roc` | Every file the app keeps, and the only module that names one (its header is the layout). |
| `app/ConvCodec.roc`, `app/MessageCodec.roc` | A conversation's record, its participants bound; a message's, its body any bytes, exactly. |
| `app/Limits.roc`, `app/Origin.roc` | Every cap on what one person can make grow, and why; the CSRF check every write passes. |
| The auth core, pure | `Principal`, `Access`, `ConvAccess`, `ConvKey`, `ApiKey`, `Session`, `OAuthState`, `DisplayName`, `GitHubLogin`, `GitHubSignIn` (sign-in's plan), `Admin` (the admin actions: decided and audited, **not yet served by any route**), with their records' codecs (`Stored`'s line format: `AccountCodec`, `SessionCodec`, `KeyCodec`, `AuditCodec`) and the tests' `Cast`. Each module's header says what it decides. |
| `app/SignIn.roc` | Sign-in's routes: `/login`, GitHub's callback in two calls, the name form, `/me`, logout. |
| `app/Ascii.roc`, `app/Bytes.roc` | The byte checks and scans the rest share (roc-markdown keeps its own copies on purpose). |
| `platform/` | The platform: `Chat.roc` (the request and the answer), `Host.roc` (the hosted functions), `Sse.roc` (an event as one frame), `main.roc`. |
| `host/main.zig`, `host/config.zig` | Start: the config, the data root, the server. |
| `host/server.zig` | The accept loop, a task per connection, keep-alive, the turn, the deadlines and their watchdog, the body cap. |
| `host/call.zig` | The bridge: the request copied for the Roc, the host the Roc's call asks, and the answer made into what is written. |
| `host/assets.zig` | The chat client's scripts: ETag, 304, cache rule. |
| `host/signin.zig`, `host/auth/`, `host/github/` | Sign-in: the secrets, the crypto, and GitHub's exchange off the turn; the fake GitHub for tests. |
| `app/SignInWeb.roc` | Sign-in's bytes on the wire: the signed state and pending tokens, the cookies' one policy, the form, the settings' record. Every decision is the auth core's. |
| `host/files.zig` | The store under the data root: `read!`, `write!` (atomic), `append!` and their kin, each synced before it answers. |
| `host/bus.zig`, `host/sse.zig` | The bus (a mailbox of 16 frames per stream, by key) and a stream's head, ping and cap. |
| `host/seam/` | The seam, from roc-webbox at 5a4314b: `chat_abi.zig` (the records, `Host.of`, the call), `chat_route.zig` (the tags, the decision), `roc_abi.zig` (Roc's runtime), `sljmp.zig`, `glue_test.zig` and `glue/` (roc glue's snapshot). |
| `host/server_test.zig`, `app/test/probe.roc` | The server end to end, in-process, with hand-written HTTP clients (`host/test_http.zig`, the harness), against the server's probe: the plainest routes that drive each part of the host, so none signs in. |
| `host/chat_test.zig` | The chat's own pages, by the same harness. |
| `host/e2e.zig` | The end to end (`zig build e2e`): clients through the fake GitHub, a conversation, its stream, and the refusals; then an agent, its keys (by key alone: start, post, read; revoked, expired, scoped, both credentials), and the audit; then invites (redeemed once, expired, refused to others and to keys, dead with a retired agent), fresh agent ids, and their audit; each step timed. |
| `tools/verify.shale` | Every check in one run: the tests' counts against their floors, the end to end, the planted faults (verify.shale's header lists them) each red at its own step, the formatters. |
| `host/signin_test.zig` | Sign-in end to end, against the fake GitHub: the state, the name form, the session cookie, every refusal, and the turn free while GitHub stalls. |
| `app/test/crash.roc`, `host/crash_test.zig` | The planted crashes, linked in place of the chat for their test alone: each a 500, the server going on. |
| `tools/get_roc.sh`, `tools/chat_glue.shale` | The pinned Roc; the glue snapshot regenerated. |
| `tools/browser_check.js` | The pages in a real browser, by hand, never in `test`. |
| `host/files_bench.zig`, `host/auth/path_rule.zig` | The store's syncs timed (`zig build bench-files`); the one rule for a path under the data root. |
| `dev/config.zon` | `zig build serve`'s config. |
| `deploy/`, `tools/deploy.shale`, `tools/backup.shale`, [DEPLOY.md](DEPLOY.md) | Production: the Caddy block, the service and its config; the deploy and the backup; how a release goes out. |

## Pitfalls

- **The head's strings point into the read buffer, and reading the body
  overwrites them.** The path and every header are copied before the body
  is read (`call.copy`); `read_header!` answers from the copy. The test
  that guards this sends a 30,000-byte body; 20,000 did not trip it on
  loopback.
- **std's body reader ends a length-framed body short at the socket's end,
  with no error.** A body shorter than its `content-length` is checked for
  and never handed to the Roc.
- **A hosted function the platform names and the host lacks jumps to
  address 0.** `Host.of` fails the build naming the missing one, and
  `glue_test.zig` holds every record to `roc glue`'s layout. After a change
  to `platform/`, regenerate the snapshot (`shale tools/chat_glue.shale`,
  which needs Roc's source at the pinned commit in `~/tools/roc-<commit>`).
- **Bytes handed to a hosted function belong to the call.** Copy anything
  the host keeps past it.
- **A folder std opens to walk (the default, O_PATH) cannot be fsynced**:
  the sync fails EBADF, which std's debug build panics on as a programmer's
  bug. `files.zig` opens a folder again, readable, to sync it.
- **std's `follow_symlinks = false` is O_NOFOLLOW: it guards only a
  path's last part**, and `createFile` has no such option at all. A link
  as a folder on the way is followed, and a create through a dangling link
  makes a file wherever it points. `files.zig` opens a path a folder at a
  time, each from the one before with O_NOFOLLOW (`walk`), and creates only
  with O_EXCL, which never follows.
- **A folder opened with O_NOFOLLOW answers `NotDir` for a link and for a
  file alike**, and `NotDir` is `missing` to a read. `files.zig` looks at
  the entry, unfollowed, to tell them apart (`linkOr`): a link is `failed`.
- **A write stopped by a crash leaves its `~xxxxxxxx.tmp`**. `list!` never
  shows one, no path may name one, and the server sweeps them at start.
  The name and its test are `files.temp`, the one home of the rule.
- **The callback checks the state twice.** The first call checks it and
  spends nothing; the second, after the exchange, checks it again and
  spends its nonce in the same turn. A check that spent in the first call
  would refuse its own second call as a replay.
- **A Roc stack overflow is a SIGSEGV, not a `roc_crashed`.** Taken for
  the call's crash only when the fault is on the guarded call's stack,
  below where it began, on a thread with std's signal stack (every thread
  std starts has one). A thread without one dies of the fault, as before.
- **A file hosted function's `Failed` has failed the request**: the answer
  is a 500 whatever the Roc says, and the host does nothing more in that
  call (`read_at!`, a ranged read, is the exception).

No LICENSE yet: that is Steve's decision, for this repo and its
dependencies alike.
