# The platform: what the Zig host gives the Roc

The host is small on purpose. It serves HTTP with no routing, and it offers a few general file primitives, a clock and random bytes. The Roc decides everything else: routes, file layout, formats and pages. The primitives know nothing about chats.

- Roc's declarations: `platform/Host.roc` (the primitives) and `platform/Http.roc` (the request and the response).
- Zig: `host/file_primitives.zig` (the primitives and their tests), `host/http.zig` (the server), `host/bus.zig` (where a stream's frames are published), `host/sse.zig` (a stream's headers, keepalive and cap), `host/seam.zig` (the C seam). `host/seam_test.zig` holds every record and tag to `roc glue`'s layout.
- The only caller of the file primitives is `app/FileSystem.roc`.

## The data root and confinement

Every path is relative to one data root, the folder the server is started with (`gopher-roc <data folder>`). The host's **path rule** (`path_rule` in `host/file_primitives.zig`) refuses a path that:

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
That many bytes from the OS's secure source, at most 1,024. Asking for more, or the source failing, stops the server: the first is a bug in the app, and in the second case nothing safe can be handed back. *Why:* session and invite secrets, later.

## HTTP, with no routing

`roc_handle_http_request : Http.Request => Http.Response`

- **A request** is `{ method, path, query, headers, body, port }`, all but the port as bytes. The method is `GET` and so on. The path runs up to any `?`, and the query is what follows it, undecoded. The headers are as sent, and the body is read whole. The port is the one the server listens on, a fact the app needs to know its own origin (`app/RequestOrigin.roc`).
- **The response** is `{ status : U16, headers, body, kind : [Whole, Stream], stream_key, stream_holder }`. A `Whole` answer is written as given, and names no stream (its key and holder are empty). A status that isn't a real one, or a header holding CR, LF or NUL, is a bug in the app: the host answers 500 instead.
- **A stream** (`Stream`) is held open: status 200, the host's stream headers (`text/event-stream`, `no-cache`, no proxy buffering) and then the app's, the body, and then every frame published to `stream_key` while it is open, each written as it is. The host subscribes the stream to its key before the call that answered it ends, so a frame published by a later call reaches it, and the body (the app's backlog, read in the same call) holds everything before. A stream quiet for 25 s sends a comment line, `: ping`. A stream ends when a write fails, or when its mailbox (16 frames) overflows, so a reader that falls behind is ended rather than shown a gap; the browser reconnects and the app resumes it. `stream_holder` names who holds it, 1 to 64 bytes: a holder keeps at most 8 streams, a new one ending that holder's oldest, and at most 64 are held in all. A stream answered with another status, an empty key or holder, or a holder over 64 bytes is the app's bug, a 500.

**`publish_bytes_to_streams_on_key! : List(U8), List(U8) => {}`**
The bytes, as they are, to every stream held open on the key; none there, and nothing is sent. The host copies them, and knows nothing of what they mean: a key and the frames are the app's (`app/ConversationStream.roc`). *Why:* an open page sees a new message without reloading.

**Limits:** a head of at most 16 KiB (past it, 431), and a body of at most 64 KiB (past it, 413). The request must arrive whole within 10 s, or the answer is 408. An upload, a POST to a path ending `/upload`, may have a body of 10 MiB and 64 KiB, which has five minutes to arrive after its head (`upload_body_most`, `upload_body_read_ms`); the app holds the image in it to its own limit, 10 MiB (`app/UploadedImage.roc`). The answer must be written within 10 s, or the connection is cut. After a refusal (408, 413, 431), the server reads and drops what the client still sends for at most 1 s before closing, so the client gets its refusal rather than a reset (`Limits` and `linger` in `host/http.zig`).

**Each connection is served on a task of its own, one request per connection**, and each answer says `connection: close`. One mutex, the turn, is held while a request's Roc call runs, and only then: the Roc never sees two calls at once, so two writes never race. The turn never waits on the network. A request is read whole before its turn, and its answer is written after, so a slow client holds only its own task, never the server.

**The denial-of-service bound.** Nothing limits how many connections are open at once: each takes a task, and a client that opens many holds many (streams alone are capped, above). That is accepted today because only this machine can connect (127.0.0.1, and through `ssh -L` the owner's own laptop), and every such client is trusted. Anything that lets others reach the server (sign-in, a public address) needs a per-client limit first.

**The server listens on 127.0.0.1 only**, and the bind address is not an option. Until sign-in exists, the app takes every request as Steve's (`acting` in `app/main.roc`, through `SignedIn.dangerously_assume`). Anyone who could reach the server could therefore post as him. The port defaults to 9611 (`--port` changes it).

**127.0.0.1 alone does not keep out a web page.** A browser on this machine, or on a laptop through `ssh -L`, carries any page's requests to the server: a form on another site can POST to `http://localhost:9611/...`, and a name rebound to 127.0.0.1 can read a page. So the app holds every request to its own origin before routing it (`app/RequestOrigin.roc`): the `Host` must be exactly `127.0.0.1:<port>` or `localhost:<port>`, and a request that writes is refused when its `Origin` or `Sec-Fetch-Site` names another origin. Each refusal is a 403. The host decides none of this; it hands the app the headers and the port.

## Memory and crashes

**Memory:** each Roc call gets one arena, which is freed whole when the request ends. `roc_dealloc` frees nothing. There is nothing more until we measure.

**A Roc crash stops the server** and prints Roc's message. A crash means the app broke a promise, and the server does not keep answering after that.
