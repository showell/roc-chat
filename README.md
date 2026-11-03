# gopher-roc

A chat for a small group of humans and their agents, written in Roc on a Zig host. `gopher-roc` is a code name. `docs/design.md` holds the design, from first principles, and `docs/platform.md` describes what the host gives the Roc. This is a fresh start from roc-chat, which it borrows from as needed.

**Status (2026-11-03): the first server.** It serves a conversation's page, a top bar over two panes (the messages, and a compose box beside or below them), in a dark or light theme, appends a message posted from the box, shows each new message on every open page of the conversation without a reload, and takes an image uploaded from the box (its Upload button, or a paste), and nothing more. There is no sign-in yet: every request acts as Steve. That is why the server listens on 127.0.0.1 only.

## What the code holds

- **A pure core.** `Conversation` grows only by `append`, so its ids are always 1, 2, 3... Alongside it are `Message`, `MsgAnchor` (`MSG_<topic>_<n>` and `msg-<n>`), and `Transcript`, the file in the Zig chat's format. `Transcript` also builds the two kinds of bytes the file system deals in: `Utf8Transcript` (a whole file, untrusted until `decode`) and `Utf8TranscriptMessage` (one message's record, appended).
- **Pages.** `Page` builds them only from markup vouched for at `TrustedHtml`'s one door, `dangerously_trust`. Its few callers are the audit trail:
  - `Escape` (text, escaped exactly once);
  - `Html` (elements from closed sets and strict tokens);
  - `Markdown` (roc-markdown's output, its images ruled by `SecureImageTag`);
  - `Page`'s fixed head.
- **The pages' scripts.** The server sends no CSS; four small scripts style what they find, as roc-chat's and chat-client's do. Each is imported whole at compile time by `Script`, the set's one home, so the file is its bytes' one home, and served at `/chat/assets/<name>.js`; the page's policy runs scripts from this origin only (`script-src 'self'`, `HttpAnswer`). The page works without them: the messages read top to bottom, and the box is a plain form.
  - `app/palette.js`, in every page's head: chat-client's colours, light and dark, dark unless the viewer chose light; the theme is set before the first paint.
  - `app/chrome.js`: the frame, a top bar (the topic; the 🌙/☀️ theme toggle and the viewer's name) over the panes, filling the window.
  - `app/compose.js`: lays out the two panes as chat-client does (in a window wider than 768 pixels, the compose box is a 320-pixel rail on the right, closed at first, showing an "Open compose box" button and the keyboard help, and opened by the button or `c`; narrower, the box sits below the messages), and gives the compose box its keys (Ctrl/⌘-Enter sends, as the old chat-client's does; plain Enter is a new line; Escape in an empty box closes the rail) and its Upload button. A send stays on the page, as chat-client's did: the box is off and says "Sending…" until the server answers (the form posted to the conversation's URL and `/send`, a 201), then empties; the message itself appears through the stream, and the status line says when it has. A refusal shows the server's words and keeps the draft; with no answer in 3 seconds, a dialog says the host may be down. The page's keys are one table here (`Keys`), and the closed rail's keyboard help is built from it.
  - `app/feed.js`: the messages pane, a card at most 600 pixels wide and the only part that scrolls; each message a bubble, the viewer's own on the right (the pane's `data-viewer` against the message's `data-author`), each time in the viewer's zone; and each message the conversation's stream brings (an `EventSource`, at the page's URL and `/stream`), dressed the same and appended. One message is selected, ringed, as in chat-client: ↑ and ↓ move to the previous and next, Home and End to the first and last, Page Up and Page Down scroll a page (or select the first or last at the end), and scrolling or a click selects too; the address bar's `#msg-<n>` follows the selection.
- **Text from outside.** It arrives only as an `UnvalidatedString`, which has no way out except its checking doors.
- **Who is acting.** That is a `SignedIn`, and its door, `dangerously_assume`, stands in for sessions.
- **For a security reader:** start at `UnvalidatedString`, `TrustedHtml`, `SecureImageTag`, `SignedIn` or `RequestOrigin`, and at the host's path rule (`host/file_primitives.zig`).
- **The directory.** `Directory`, `Users`, `Channels`, `Name`, `Dm` and `Place` are pure.
- **The server's parts.**
  - `RequestOrigin` holds every request to this server's own origin first: its `Host` must be `127.0.0.1:<port>` or `localhost:<port>`, and a POST from another origin's page is refused (403).
  - `Route` chooses an answer from the method and path.
  - `ConversationKey` is a place plus a topic, and the one home of the layout: a URL `/chat/channel/<channel>/<topic>` names the folder `chat/channel/<channel>/<topic>/`, and `/chat/dm/<pair>/<topic>` names `chat/dm/<pair>/<topic>/`.
  - `ConversationRoute` answers GET and POST (a 303 back to the page), the compose box's script's POST to `/send` (a 201 with the message's HTML, or the refusal in plain words), and opens a conversation's stream.
  - `ConversationStream` is the stream's one home: its bus key, how many messages a reader has seen (`?after=` or `Last-Event-ID`), and each message's frame, the HTML `Page.message` writes for the page.
  - `UploadRoute` answers an upload and an uploaded image. An image is what its opening bytes say, PNG, JPEG, GIF or WebP, at most 10 MiB, named by 16 random bytes in hex (`UploadedImage`); it is read out of the compose box's form (`MultipartForm`), counted against the uploader's lifetime allowance of 1 GiB (`UploadTotal`, kept in `users/<id>/upload-bytes`, `UserFolder`), kept in its conversation's folder as `uploads/<name>`, and served at the conversation's URL and `/uploads/<name>`. A message shows an image only from its own conversation's uploads (`SecureImageTag`).
  - `FileSystem` is the only module that touches files.
  - `app/main.roc` is the edge, holding both stand-ins: the directory, until one is stored (Steve, plus the channel `general`), and `acting`, which is Steve, assumed.

## Commands

    shale tools/verify.shale                    the gate: format, Roc tests, hunts, the demo's frozen page, zig tests, the end to end
    zig build serve -- <data folder>            the server on http://127.0.0.1:9611 (add --port <n> for another)
    zig build demo -- /chat/channel/general/gopher-roc demo/data/chat/channel/general/gopher-roc/transcript    the sample's page, to stdout
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

Keep the laptop's port the server's: the server refuses a `Host` that is not `localhost` or `127.0.0.1` at its own port (`app/RequestOrigin.roc`), so `ssh -L 8000:127.0.0.1:9611` answers 403. That refusal is what keeps another site's page, or a name rebound to 127.0.0.1, from acting as Steve through your browser.

Post from the compose box (on the right of a wide window, at the bottom of a narrow one), or send the form a browser would send:

    curl -i --data-urlencode 'markdown=Hello from **curl**' http://localhost:9611/chat/channel/general/gopher-roc

## Pitfalls


**The demo's page is frozen.** The gate holds the demo's output to `demo/gopher-roc.html` byte for byte, and the end to end holds the server's first GET to the same file. A deliberate change to the page rewrites that file from the demo's output, and the commit says what moved and why.

**A change to `platform/` needs `shale tools/glue.shale`.** `zig build test` fails, naming the function, until the glue snapshot (`host/glue/platform_abi.zig`) is regenerated.
