# The platform: what the Zig host gives the Roc

The host is small on purpose. It serves HTTP with no routing, and it offers a few general file primitives, a clock, random bytes, and the crypto that needs a secret or a slow hash. The Roc decides everything else: routes, file layout, formats and pages. The primitives know nothing about chats.

- Roc's declarations: `platform/Host.roc` (the primitives) and `platform/Http.roc` (the request and the response).
- Zig: `host/file_primitives.zig` (the primitives and their tests), `host/sign_in_primitives.zig` (bcrypt, the HMAC and the server's secret), `host/github_client.zig` (GitHub's settings and its code exchange; `host/fake_github.zig` stands in for GitHub in tests), `host/http.zig` (the server), `host/main.zig` (its command line, and `hash-password`), `host/bus.zig` (where a stream's frames are published), `host/sse.zig` (a stream's headers, keepalive and cap), `host/seam.zig` (the C seam). `host/seam_test.zig` holds every record and tag to `roc glue`'s layout.
- The only caller of the file primitives is `app/FileSystem.roc`.

## The data root and confinement

Every path is relative to one data root, the folder the server is started with (`roc-chat <data folder>`). The host's **path rule** (`path_rule` in `host/file_primitives.zig`) refuses a path that:

- is empty or longer than 1,024 bytes;
- is not UTF-8;
- is absolute;
- has an empty part (`a//b`, a trailing `/`);
- has a part starting with `.`. This covers `.` and `..`, hidden files, and the temporary file a replace writes;
- holds a NUL.

**A link is never followed, at any part of a path.** Each folder is opened from the one before it with `O_NOFOLLOW`, and so is the file. The kernel therefore refuses a link in the same call that opens what is used, so nothing is checked first and swapped later. A refused path answers `PathRefused`, and nothing is touched.

## Failures

The same tags mean the same thing everywhere:

| Tag | Meaning |
|---|---|
| `Missing` | Nothing is there: the file, or a folder on its path. |
| `MissingDirectory` | A write's folder does not exist. Writes never make folders; `make_directory_and_its_parents!` does. |
| `NotUtf8` | The bytes to write, or the bytes read, are not UTF-8. Nothing is written, and nothing is handed back. The binary primitives never answer it. |
| `PathRefused` | The path breaks the rule above, or passes through a link. |
| `Failed` | Anything else: a disk error, a folder the server may not enter, a failed fsync, a file over 17 MiB. The host logs the primitive, the path and the error. |

`Missing` and `Failed` are never one answer. A file that exists but can't be read must never look absent, or it would be written over.

## The file primitives

Each takes its path as bytes. Each write is durable before it answers: the file is fsynced, and so is every folder whose entries changed.

**`read_utf8_bytes_from_file! : List(U8) => { bytes : List(U8), status : [Failed, Found, Missing, NotUtf8, PathRefused] }`**
The whole file, if it is UTF-8 and at most 17 MiB (`read_most`). `bytes` is empty except when the status is `Found`. *Why:* the chat reads a conversation whole.

**The cap is a safety net, not the rule.** The app limits a transcript to 16 MiB (`Transcript.most_bytes` in `app/Transcript.roc`, its one home): a message whose record would grow the file past that is refused with a 409, before anything is appended. The host's cap sits strictly above it, so every file the app wrote stays readable, and only a file the app did not write can reach it. Without the app's limit, a conversation appended past the cap would answer 500 to every GET and POST for good.

**`append_utf8_bytes_to_file! : List(U8), List(U8) => [Appended, Failed, MissingDirectory, NotUtf8, PathRefused]`**
Opens the file with `O_APPEND` and makes it when it is missing (then also fsyncs the folder). It writes the bytes and fsyncs the file. A failed fsync answers `Failed`, but the bytes may already be in the file: the answer means they may not last, not that they are absent. *Why:* a message is one record appended to its transcript.

**`create_file_with_utf8_bytes_unless_it_exists! : List(U8), List(U8) => [AlreadyExists, Created, Failed, MissingDirectory, NotUtf8, PathRefused]`**
An exclusive create (`O_EXCL`), fsynced. If anything is already at the name, the answer is `AlreadyExists` and nothing changes. *Why:* one-time records such as a user's file or an invite, where two writers must never both win.

**`replace_file_with_utf8_bytes_atomically! : List(U8), List(U8) => [Failed, MissingDirectory, NotUtf8, PathRefused, Replaced]`**
Writes a temporary beside the file (`.<name>.replacing`), fsyncs it, renames it over the file, and fsyncs the folder. A failure before the rename leaves the old file whole. The next replace takes over a temporary left by a stopped one. *Why:* rewriting a small file, such as reactions or preferences, without ever leaving a half-written one.

**`read_binary_bytes_from_file! : List(U8) => { bytes : List(U8), status : [Failed, Found, Missing, PathRefused] }`**
The whole file as it is, with no UTF-8 check, at most 17 MiB (`read_most`, as a text read). *Why:* an uploaded image is served from its file.

**`create_file_with_binary_bytes_unless_it_exists! : List(U8), List(U8) => [AlreadyExists, Created, Failed, MissingDirectory, PathRefused]`**
The exclusive create above, for bytes of any kind. *Why:* an uploaded image is kept under a fresh name, and a name is never written twice.

**`make_directory_and_its_parents! : List(U8) => [Failed, Made, PathRefused]`**
Makes each missing folder on the path and fsyncs its parent. Folders that already exist count as `Made`. A file in the way is `Failed`. *Why:* the writes above never make folders, so making them is a separate, visible step.

**`list_names_in_directory! : List(U8) => { names : List(List(U8)), status : [Failed, Found, Missing, NotUtf8, PathRefused] }`**
The folder's names, sorted bytewise, never one starting with `.`. A name that is not UTF-8 makes the answer `NotUtf8`. *Why:* to find a place's topics, and later the users.

## The clock and randomness

**`current_utc_seconds_since_epoch! : {} => I64`**
Whole seconds since 1970-01-01T00:00:00Z, from the real-time clock. `DateTime.from_seconds_since_epoch` turns this into a message's time. *Why:* the server, not the client, dates every message.

**`fill_with_random_bytes! : U64 => List(U8)`**
That many bytes from the OS's secure source, at most 1,024. Asking for more, or the source failing, stops the server: the first is a bug in the app, and in the second case nothing safe can be handed back. *Why:* an agent's key and an invite's code are 32 of them, and an uploaded image's name 16.

**`sha256_of_bytes! : List(U8) => List(U8)`**
The SHA-256 digest of the bytes, 32 bytes, from Zig's standard library. *Why:* the chat keeps a key's or an invite's secret only as its hash (`app/SecretHash.roc`), and the Roc holds no crypto of its own.

## Passwords and the server's secret

The server's secret is the file `.session-secret` in the data root: 32 random bytes as 64 lowercase hex digits, readable by its owner alone, made once when the server starts on a folder that has none (`ServerSecret` in `host/sign_in_primitives.zig`), and read then; one shorter than 32 bytes or longer than 256 stops the start, and so does one whose mode gives its group or anyone else any right (`mode & 0o077`), with a message saying to `chmod 600` it. Its name starts with `.`, so the path rule keeps every file primitive from it: the Roc signs and checks bytes with it, and can never read it. Removing it and starting again makes a new one, and every signature made with the old one stops matching.

**`hmac_sha256_with_server_secret! : List(U8) => List(U8)`**
The HMAC-SHA256 of the bytes under the server's secret, 32 bytes. *Why:* the app signs a session (`app/Session.roc`) and never holds the key.

**`hmac_sha256_with_server_secret_matches! : List(U8), List(U8) => [DoesNotMatch, Matches]`**
Whether the second is the HMAC-SHA256 of the first under the server's secret, compared in constant time; a second of any length but 32 does not match. *Why:* a session's check, which no timing tells anything of.

**`bcrypt_hash_of_password! : List(U8) => List(U8)`**
A fresh bcrypt hash of the password, at cost 10, under 16 random bytes of salt, in its modular-crypt form (`$2b$10$` and 53 more bytes). A password longer than 72 bytes is hashed by HMAC-SHA512 first, as Zig's bcrypt does. *Why:* the same hash `roc-chat hash-password` writes, for an invited human's password, which they choose as they redeem their invite (`app/HumanInvitesRoute.roc`). It runs in the turn and is not spent from the bucket below: only a live invite's code reaches it, and each code is spent by its one redemption. The session the redemption starts is signed over the hash it wrote, so a redemption ends every session of its human signed before it.

**`password_matches_bcrypt_hash! : List(U8), List(U8) => [DoesNotMatch, Matches, NotABcryptHash, TooManyChecks]`**
Whether the password, the first, is the one the bcrypt hash, the second, was made from; `$2a$`, `$2b$` and `$2y$` hashes are read alike, at a cost from 10 to 14 (`is_acceptable_bcrypt_hash`). A second that is no bcrypt hash, another scheme or a cost outside that range included, is `NotABcryptHash`, never a wrong password, so a torn file is said as one; the host logs it. A check costs about 70 ms in a release build. **Every check is spent from one bucket**, the server's for every client (`PasswordChecks` in `host/sign_in_primitives.zig`): it holds 5 checks and gains one back each second (`password_check_burst` and `password_check_refill_ms` in `Limits`). When it is empty the answer is `TooManyChecks` at once, nothing compared, and the app answers a 429. So guessing runs at one password a second at most, and a flood of sign-ins costs a few percent of one core. **bcrypt runs with the turn let go** (`host/seam.zig`): the check is spent in the turn, then the call is set aside, the turn released, the hash compared, and the turn taken back before the Roc goes on. The Roc's answer still comes from within the turn, from what it read before the check and the verdict; another request may be answered while the check runs, so the app must not lean on what it read before it staying true. Signing in leans on nothing that may change: the session it signs is signed over the hash it checked (`app/Session.roc`), so a password rewritten meanwhile leaves a session that admits no one, and a user, once made, is never removed. *Why:* signing in (`app/SignInRoute.roc`), which also checks `dummy_hash` where a name has no hash to check (no such user, an agent, no password file, or one holding no hash), so its time tells no one which names exist.

## GitHub

The host holds GitHub's settings, read once at the start (`Settings` in `host/github_client.zig`) from files in the data root: `.github-client-id` and `.github-client-secret`, and, when GitHub is elsewhere, `.github-oauth-base` and `.github-api-base`. Each must be readable by its owner alone. No file at all means no GitHub, and the app offers none. Any file with the id or the secret missing, a file open to others, an empty or over-long one, and a base URL that is neither `https://` nor `http://` to a loopback literal each stop the start, saying which. Each name starts with `.`, so no file primitive reaches them.

**`github_sign_in_settings! : {} => { authorize_base : List(U8), client_id : List(U8), status : [Configured, NotConfigured] }`**
The public half of the settings: the browser sees both in the URL it is sent to. *Why:* the app builds that URL and decides whether to offer GitHub at all. The client secret has no primitive.

**`github_identity_for_code! : List(U8) => { id : U64, login : List(U8), status : [Denied, Failed, Identified] }`**
GitHub's word on a code: the host posts it to `{oauth base}/login/oauth/access_token` with the client id and secret, asks `{api base}/user` who the token belongs to, and wipes the token. `Identified`, with the id and login GitHub answered; `Denied` when GitHub said no; `Failed` when it didn't answer within its deadlines (5 s to connect, 15 s for the whole) or made no sense. The login is a fact, unchecked: `app/GitHubLogin.roc` judges it. **The exchange runs with the turn let go** (`host/seam.zig`), as a password's check does, so no request waits on GitHub, and the app must not lean on what it read before the call staying true. It reads the `github-id` files after it. A new human's account is made by a later request, in one turn with no call that lets it go, so two sign-ups can't both find an id free. *Why:* signing in (`app/GitHubRoute.roc`), where the client secret and the token stay out of the Roc.

**`roc-chat hash-password`** is the way a password's hash is made on the server's machine: from a terminal it asks twice with the echo off, and puts the echo back however it ends (a refusal, Ctrl-C, a hang-up, `SIGTERM`); else it reads stdin's first line. It refuses a line over 4 KiB, two that differ, and any password the sign-in form would refuse, by asking the app (`roc_password_verdict : List(U8) -> [Accepted, Refused]`, `password_verdict` in `app/main.roc`, which reads the bytes as the form does), so the rule (`app/Password.roc`: 1 to 72 bytes of UTF-8) has one home. It prints the hash and a line end. Its owner redirects it into the user's `password` file (docs/design.md, "Storage"); the password reaches no log, no argument list and no agent.

## The start

`roc_start : {} => [Failed, Ready]`, once, before the server listens (`start_app` in `host/http.zig`). An empty data folder gets the first chat (`app/main.roc`, `first_directory`); one that holds a chat is read; one that holds part of one, or can't be read, is `Failed`, and `listen` returns `error.AppStartFailed` rather than serve from it. An account folder with no `name` is one cut short as it was made, and is no account: the chat still starts. Then the host reads the server's secret, making it first if there is none.

The server is `roc-chat <data folder> [--port <n>] [--public-origin https://<name>]`. `--public-origin` names the origin a proxy on this machine serves it under: `https://`, a lowercase host name, and a port or none, nothing else (`is_public_origin` in `host/main.zig`); the host hands it to the app on every request, as it does the port.

## HTTP, with no routing

`roc_admission : Http.RequestHead => Http.Admission`, then `roc_handle_http_request : Http.Request => Http.Response`

- **A request's head is judged first**, before any body is read. The head is `{ method, path, headers, port }`, each as in the request below. The app answers `Refuse(response)`, which the host writes without reading the body, or `Admit({ body_most, body_grace_ms })`: the host reads a body of at most `body_most` bytes (past it, 413), within what is left of the request's read time and `body_grace_ms` more (past it, 408). So the app holds every limit on a body: a form's 64 KiB, and an upload's 10 MiB image with 64 KiB for its form and five minutes more (`form_body_allowance` and `upload_body_allowance` in `app/main.roc`; the judgement reads the directory from disk, since an upload's room is given only to a conversation the directory holds), and a request from another origin costs nothing but its head. A refusal that is a stream, or that a response's own rules refuse (below), is the app's bug: a 500. The platform lays the admission flat for the host (`admission_for_host` in `platform/main.roc`).

- **A request** is `{ method, path, query, headers, body, port, public_origin }`, all but the port as bytes. The method is `GET` and so on. The path runs up to any `?`, and the query is what follows it, undecoded. The headers are as sent, and the body is read whole. The port is the one the server listens on, and the public origin the one it was started with, or empty: facts the app needs to know its own origins (`app/RequestOrigin.roc`).
- **The response** is `{ status : U16, headers, body, kind : [Whole, Stream], stream_key, stream_holder }`. A `Whole` answer is written as given, and names no stream (its key and holder are empty). A status that isn't a real one, or a header holding CR, LF or NUL, is a bug in the app: the host answers 500 instead.
- **A stream** (`Stream`) is held open: status 200, the host's stream headers (`text/event-stream`, `no-cache`, no proxy buffering) and then the app's, the body, and then every frame published to `stream_key` while it is open, each written as it is. The host subscribes the stream to its key before the call that answered it ends, so a frame published by a later call reaches it, and the body (the app's backlog, read in the same call) holds everything before. A stream quiet for 25 s sends a comment line, `: ping`. A stream ends when a write fails, or when its mailbox (16 frames) overflows, so a reader that falls behind is ended rather than shown a gap; the browser reconnects and the app resumes it. A stream also ends once it has been held an hour (`Limits.stream_most_ms`), so its client reconnects and is asked again who it is. `stream_holder` names who holds it, 1 to 64 bytes: a holder keeps at most 8 streams, a new one ending that holder's oldest at once, and at most 64 are held in all. A stream answered with another status, an empty key or holder, or a holder over 64 bytes is the app's bug, a 500.

**`publish_bytes_to_streams_on_key! : List(U8), List(U8) => {}`**
The bytes, as they are, to every stream held open on the key; none there, and nothing is sent. The host copies them, and knows nothing of what they mean: a key and the frames are the app's (`app/ConversationStream.roc`). *Why:* an open page sees a new message without reloading.

**`end_every_stream_of_holder! : List(U8) => {}`**
Every stream held by the holder ended now, its socket shut and its task woken; none held, and nothing happens. *Why:* a revoked key's agent stops listening at once, and reconnects to be refused (`app/AgentsRoute.roc`).

**Limits:** a head of at most 16 KiB (past it, 431); a body as the app admits it (above). The request must arrive within 10 s, and its body within the app's grace after that, or the answer is 408. The bodies being read or held at once, across every connection, are at most 64 MiB (`body_bytes_in_flight_most`): a request is charged its stated length, or its whole allowance when chunked, from before its body is read until it is answered, and one that would pass the cap gets a 503, its body unread. A client, as the proxy names it in `X-Forwarded-For`, has at most 32 requests in flight (`requests_per_client_most`), streams among them: each counts from when its head is read until its task ends, and one past the cap gets a 429 before the app is asked. A request with no such header did not come through the proxy, and isn't counted. The answer must be written within 10 s, or the connection is cut. After a refusal (the app's, or a 408, 413, 429, 431 or 503), the server reads and drops what the client still sends for at most 1 s before closing, so the client gets its refusal rather than a reset (`Limits` and `linger` in `host/http.zig`).

**Each connection is served on a task of its own, one request per connection**, and each answer says `connection: close`. One mutex, the turn, is held while a Roc call runs (the admission, then the answer), and only then: the Roc never sees two calls at once, so two writes never race. The turn never waits on the network. A body is read between the two calls, and the answer is written after the second, so a slow client holds only its own task, never the server.

**The denial-of-service bound.** A client's requests in flight are capped (above), so one client can't hold many connections. Nothing limits the connections of many clients together, or the rate at which one opens them: each connection takes a task. Sign-ins are bounded by the server's own bucket (above), and a check never holds the turn. A rate of `POST /login`s per client is nice to have: without one, a flood from anywhere empties the one bucket, and a human signing in meanwhile gets a 429 until it stops (a session already signed in is unaffected). Stock Caddy has no rate limit, so prod has none: docs/deploy.md, "The per-client cap", says what is left open.

**The server listens on 127.0.0.1 only**, and the bind address is not an option: a public name reaches it through a proxy on the same machine. The app finds who is acting from the request alone (`load_actor!` in `app/main.roc`). A request with `Authorization: Bearer <key>` acts as the agent its key admits, or is a 401; it is judged by that header alone, never by a cookie. Any other acts as the human its session cookie admits (`app/Session.roc`), or as no one (`Anonymous`), who may only sign in, sign up by GitHub, load the scripts and redeem an invite, an agent's or a human's. The port defaults to 9611 (`--port` changes it).

**127.0.0.1 alone does not keep out a web page.** A browser on this machine, or on a laptop through `ssh -L`, or anywhere through the public name, carries any page's requests to the server: a form on another site can POST to it, and a name rebound to 127.0.0.1 can read a page. So the app holds every request to its own origins from its head, before its body is read (`app/RequestOrigin.roc`): the `Host` must be exactly `127.0.0.1:<port>`, `localhost:<port>` or the public origin's name; a request whose `Origin` is not the one its `Host` names (`http://` and a local name for a local `Host`, the public origin exactly for its own) is refused, so the check never relies on a proxy taking an `Origin` off; a request that writes is refused when its `Sec-Fetch-Site` is not `same-origin`; and a GET another site's page made (`Sec-Fetch-Site` `cross-site` or `same-site`) is refused unless it is a navigation (`Sec-Fetch-Mode` `navigate`), so no other page can hold a stream open as a signed-in human. A header sent twice is refused as a foreign one. Each refusal is a 403. Every answer says `Cross-Origin-Resource-Policy: same-origin`, so a browser hands none of them to another site's page. The host decides none of this; it hands the app the headers, the port and the public origin.

**An upload's room is a member's.** The head's judgement finds who is acting as the whole request's does; only someone signed in who may post in the conversation gets an upload's 10 MiB and five minutes, and anyone else a form's 64 KiB (`body_allowance` in `app/main.roc`).

## Memory and crashes

**Memory:** each connection's Roc calls share one arena, freed whole when the request ends. `roc_dealloc` frees nothing. A stream frees its arena once its first bytes are written, so a stream held for hours holds none of the transcript its call read, decoded and rendered: the hub keeps its own copy of the key, and the stream's slot its own copy of the holder. A stream ended for a newer one of its holder has its subscriber ended too, so its task stops waiting at once.

**A Roc crash stops the server** and prints Roc's message. A crash means the app broke a promise, and the server does not keep answering after that.
