# roc-chat

The Roc chat's own server: the chat is a Roc app (`app/`, on the platform in
`platform/`), and its host (`host/`) is a small Zig server on `std.http`.
It will serve chat.lynrummy.com at `/`.

**Status (2026-10-29): the server core, the files, and GitHub sign-in.**
The Roc app is a stub that proves the seam both ways (a hello page rendered
by roc-markdown, a POST echoed at `/echo`, the chat client's scripts), plus
sign-in on the auth core: `/login`, GitHub's callback `/login/github`, the
display-name form `/login/name`, and `/me`, which says who a session is.
There is no chat logic yet; the bus and SSE streams come next. The design is
the essay notes `roc-chat-host-design` and `roc-chat-auth-design`
(essay-repl-server `notes/`).

## Before you build

- **Linux on x86-64**, and **stock Zig 0.17.0**. Any other target fails at
  configure time.
- **Roc, the nightly `roc-version` pins** (`nightly-2026-10-09-258ab27`),
  as `roc` on the PATH or named with `-Droc=<path>`. `build.zig` stops if
  there is no Roc, or if `roc version` names another nightly.
  `tools/get_roc.sh` installs the pinned one into `~/roc-<pin>/` and links
  `~/.local/bin/roc` to it.
- **Two sibling checkouts** under the same parent directory as this one:
  - `../roc-markdown` (github.com/showell/roc-markdown), the Roc package
    that renders the chat's markdown. `app/main.roc`'s header imports it
    by path (`md: "../../roc-markdown/package/main.roc"`), which the pinned
    Roc takes for a local package.
  - `../chat-client` (github.com/showell/chat-client), the browser client:
    a Zig package whose module `chat_client` holds each script's bytes.
    `build.zig.zon` names it by path.

  Both are taken at whatever their checkouts hold. A pinned, fetched
  dependency (a tarball by hash, laid out in a generated tree for Roc) is
  the design's later plan (D2). Sibling paths are the simplest thing that
  works at this pin.

## Build, test, serve

```
zig build test      # roc test, then the host's tests and the glue check, each with the app's Roc linked
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
  `Last-Event-ID`. At most 64 streams are held; the 65th ends the oldest.
- **`/stub/` is a stub of the bus** (`app/main.roc`, `host/stub_log.zig`,
  `Host.stub_append!` and `Host.stub_read!`): frames kept in memory, so the
  stream tests have a backlog. Step 6's chat replaces it with the store.

## Layout

| | |
|---|---|
| `app/main.roc` | The chat (for now, the stub). |
| `platform/` | The platform: `Chat.roc` (the request and the answer), `Host.roc` (the hosted functions), `Sse.roc` (an event as one frame), `main.roc`. |
| `host/main.zig`, `host/config.zig` | Start: the config, the data root, the server. |
| `host/server.zig` | The accept loop, a task per connection, keep-alive, the turn, the deadlines and their watchdog, the body cap. |
| `host/call.zig` | The bridge: the request copied for the Roc, the host the Roc's call asks, and the answer made into what is written. |
| `host/assets.zig` | The chat client's scripts: ETag, 304, cache rule. |
| `host/signin.zig`, `host/auth/`, `host/github/` | Sign-in: the secrets, the crypto, and GitHub's exchange off the turn; the fake GitHub for tests. |
| `app/SignInWeb.roc` | Sign-in's bytes on the wire: the signed state and pending tokens, the cookies' one policy, the form, the settings' record. Every decision is the auth core's. |
| `host/files.zig` | The store under the data root: `read!`, `write!` (atomic), `append!` and their kin, each synced before it answers. |
| `host/bus.zig`, `host/sse.zig` | The bus (a mailbox of 16 frames per stream, by key) and a stream's head, ping and cap. |
| `host/stub_log.zig` | The stub route's frames, until step 6. |
| `host/seam/` | The seam, from roc-webbox at 5a4314b: `chat_abi.zig` (the records, `Host.of`, the call), `chat_route.zig` (the tags, the decision), `roc_abi.zig` (Roc's runtime), `sljmp.zig`, `glue_test.zig` and `glue/` (roc glue's snapshot). |
| `host/server_test.zig` | The server end to end, in-process, with hand-written HTTP clients. |
| `host/signin_test.zig` | Sign-in end to end, against the fake GitHub: the state, the name form, the session cookie, every refusal, and the turn free while GitHub stalls. |
| `tools/get_roc.sh`, `tools/chat_glue.shale` | The pinned Roc; the glue snapshot regenerated. |
| `dev/config.zon` | `zig build serve`'s config. |

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
- **A file hosted function's `Failed` has failed the request**: the answer
  is a 500 whatever the Roc says, and the host does nothing more in that
  call (`read_at!` and `write_cache!`, a cache's, are the exceptions).

No LICENSE yet: that is Steve's decision (D9), for this repo and its
dependencies alike.
