# gopher-roc

A chat for a small group of humans and their agents, written in Roc on a Zig host. `gopher-roc` is a code name. `docs/design.md` holds the design, from first principles, and `docs/platform.md` describes what the host gives the Roc. This is a fresh start from roc-chat, which it borrows from as needed.

**Status (2026-11-02): the first server.** It serves a conversation's page and appends a message to it, and nothing more. There is no sign-in yet: every request acts as Steve. That is why the server listens on 127.0.0.1 only.

## What the code holds

- **A pure core.** `Conversation` grows only by `append`, so its ids are always 1, 2, 3... Alongside it are `Message`, `MsgAnchor` (`MSG_<topic>_<n>` and `msg-<n>`), and `Transcript`, the file in the Zig chat's format. `Transcript` also builds the two kinds of bytes the file system deals in: `Utf8Transcript` (a whole file, untrusted until `decode`) and `Utf8TranscriptMessage` (one message's record, appended).
- **Pages.** `Page` builds them only from markup vouched for at `TrustedHtml`'s one door, `dangerously_trust`. Its few callers are the audit trail:
  - `Escape` (text, escaped exactly once);
  - `Html` (elements from closed sets and strict tokens);
  - `Markdown` (roc-markdown's output, its images ruled by `SecureImageTag`);
  - `Page`'s fixed head and style sheet.
- **Text from outside.** It arrives only as an `UnvalidatedString`, which has no way out except its checking doors.
- **Who is acting.** That is a `SignedIn`, and its door, `dangerously_assume`, stands in for sessions.
- **For a security reader:** start at `UnvalidatedString`, `TrustedHtml`, `SecureImageTag` or `SignedIn`, and at the host's path rule (`host/file_primitives.zig`).
- **The directory.** `Directory`, `Users`, `Channels`, `Name`, `Dm` and `Place` are pure.
- **The server's parts.**
  - `Route` chooses an answer from the method and path.
  - `ConversationKey` is a place plus a topic, and the one home of the layout: a URL `/chat/channel/<channel>/<topic>` names the folder `chat/channel/<channel>/<topic>/`, and `/chat/dm/<pair>/<topic>` names `chat/dm/<pair>/<topic>/`.
  - `ConversationRoute` answers GET and POST.
  - `FileSystem` is the only module that touches files.
  - `app/main.roc` is the edge, holding both stand-ins: the directory, until one is stored (Steve, plus the channel `general`), and `acting`, which is Steve, assumed.

## Commands

    shale tools/verify.shale                    the gate: format, Roc tests, hunts, the demo's frozen page, zig tests, the end to end
    zig build serve -- <data folder>            the server on http://127.0.0.1:9611 (add --port <n> for another)
    zig build demo -- gopher-roc demo/data/chat/channel/general/gopher-roc/transcript    the sample's page, to stdout
    zig build test                              the host's tests
    zig build end-to-end                        the server against a temporary data root: GET, POST, GET, the file on disk
    shale tools/glue.shale                      after a change to platform/: roc glue's snapshot, which `zig build test` holds the seam to
    shale tools/note.shale                      the page and all the code, as an essay note

You need the Roc pinned in `roc-version` at `~/tools/roc-<pin>/roc`, and roc-markdown checked out beside this repo, because its package renders the markdown.

## Running the server locally

`demo/data` is the sample data. Copy it, so your posts don't change the frozen demo:

    cp -r demo/data /tmp/gopher-data
    zig build serve -- /tmp/gopher-data

Then open `http://127.0.0.1:9611/chat/channel/general/gopher-roc`. Two places exist so far: the channel `general` and Steve's own DM, `1_1`. A topic is created by its first message.

From your laptop, tunnel the port and browse as if the server were local:

    ssh -L 9611:127.0.0.1:9611 <box>
    open http://localhost:9611/chat/channel/general/gopher-roc

The page has no compose box yet. To post, send the form a browser would send:

    curl -i --data-urlencode 'markdown=Hello from **curl**' http://localhost:9611/chat/channel/general/gopher-roc

## Pitfalls

**A renamed or deleted module breaks the build** with "checking cache failed: file_open FileNotFound app/<Old>.roc". Zig's cache still remembers the old file as an input. Delete `.zig-cache` (it is git-ignored) and build again.

**The demo's page is frozen.** The gate holds the demo's output to `demo/gopher-roc.html` byte for byte, and the end to end holds the server's first GET to the same file. A deliberate change to the page rewrites that file from the demo's output, and the commit says what moved and why.

**A change to `platform/` needs `shale tools/glue.shale`.** `zig build test` fails, naming the function, until the glue snapshot (`host/glue/platform_abi.zig`) is regenerated.
