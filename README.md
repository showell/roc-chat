# roc-chat

A chat for a small group of humans and their agents, written in Roc on a Zig host. `docs/design.md` holds the design, from first principles, and `docs/platform.md` describes what the host gives the Roc.

**Status (2026-11-19): the first server, with agents, growing toward the cutover.** `/` takes a human back to the conversation they last opened, while they may still read it, and otherwise to `/chat`, Browse: every human as a DM, then the reader's channels, each with its topics and a form that starts a new one; every signed-in page links to it. It serves a conversation's page, a top bar over a sidebar (the same places and topics, the current one marked) and two panes (the messages, and a compose box beside or below them), in a dark or light theme, appends a message posted from the box, shows each new message on every open page of the conversation without a reload, and takes an image uploaded from the box (its Upload button, or a paste). Its users and channels are kept on disk. Steve, the admin, creates channels and adds or removes their members at `/channels`; any human invites another by name at `/invites`, linked from every signed-in page's top bar, and sends them the link shown, `/join#<code>`, where they join under that name or another free one, choosing their password. Steve makes and invites agents at `/agents`; an agent redeems its invite for an API key, and with it posts, reads a transcript as plain text (`/raw`), and listens to every channel it is in on one stream. Steve signs in at `/login` with a password whose bcrypt hash he writes on the server's machine (below), and stays signed in by a signed session cookie; a request with neither a session nor a key gets only the sign-in page, the scripts, the site's icon, an agent's redemption of its invite, and the join page and its two posts. The server listens on 127.0.0.1 only; a proxy on the same machine serves it under its public origin (`--public-origin`).

## What the code holds

- **A pure core.** `Conversation` grows only by `append`, so its ids are always 1, 2, 3... Alongside it are `Message`, `MessageAnchor` (`MSG_<topic>_<n>` and `msg-<n>`), and `Transcript`, the file in the Zig chat's format. `Transcript` also builds the two kinds of bytes the file system deals in: `Utf8Transcript` (a whole file, untrusted until `decode`) and `Utf8TranscriptMessage` (one message's record, appended).
- **Pages.** The page modules build them only from markup vouched for at `TrustedHtml`'s one door, `dangerously_trust`. Its few callers are the audit trail:
  - `Escape` (text, escaped exactly once);
  - `Html` (elements from closed sets and strict tokens);
  - `Markdown` (roc-markdown's output, its images ruled by `SecureImageTag`);
  - `PageKit`'s fixed head.

  `PageKit` is what every page stands on; each page lives beside the route that serves it (`ConversationPage`, `AgentsPage`, `SignInPage`, `JoinPage`, `PeoplePages`); `PageContract` holds the class names and `data-` attributes the scripts find things by.
- **The pages' scripts.** The server sends no CSS; small scripts style what they find, as chat-client's do. Each is imported whole at compile time by `Script`, the set's one home, so the file is its bytes' one home, and served at `/chat/assets/<name>.js`; the page's policy runs scripts from this origin only (`script-src 'self'`, `HttpAnswer`).
  - `app/palette.js`, in every page's head: chat-client's colours, light and dark, dark unless the viewer chose light; the theme is set before the first paint.
  - `app/chrome.js`: the frame of every signed-in page but `/agents`, a top bar (the title; the 🌙/☀️ theme toggle, the Home link, the links to Browse and the invites page, and the viewer's name) over the page, filling the window. It holds the page's one breakpoint (`Viewport`): a window at most 768 pixels wide, a phone's, is narrow.
  - `app/sidebar.js`: a conversation's sidebar, chat-client's (js/chat_left_sidebar.js) without its pinning: each DM with another human has its presence dot, filled while they are online, and the line above the page says when someone has come online (`Presence`); a 180-pixel rail on the left of a wide window, each place collapsing by its name (kept per place), the current topic highlighted. In a narrow window it is chat-client's drawer: the page's toggle button becomes a ☰ at the start of the top bar, which slides the sidebar in over the page; a tap outside it, Escape, or choosing a topic closes it.
  - `app/panel.js`: the card that Browse, the invites page and the channels' pages sit in, drawn as the messages pane is, and the plain styling of what it holds.
  - `app/compose.js`: lays out the two panes as chat-client does (in a window wider than 768 pixels, the compose box is a 320-pixel rail on the right, closed at first, showing an "Open compose box" button and the keyboard help, and opened by the button or `c`; narrower, the box is a bar below the messages, open at first, its ▾ closing it, the keyboard help left out, and a phone sends with the Send button), and gives the compose box its keys (Ctrl/⌘-Enter sends, as chat-client's does; plain Enter is a new line; Escape in an empty box closes the rail) and its Upload button. A send stays on the page, as chat-client's did: the box is off and says "Sending…" until the server answers (the form posted to the conversation's URL and `/send`, a 201), then empties; the message itself appears through the stream, and the status line says when it has. A refusal shows the server's words and keeps the draft; with no answer in 3 seconds, a dialog says the host may be down. The page's keys are one table here (`Keys`), and the closed rail's keyboard help is built from it.
  - `app/actions.js`: each message's actions, adapted from chat-client: a "react" button (or `:`) opens a picker of emojis, worked by tap or by keys (the arrows, Tab, Enter or Space, Escape back to where the focus was), `+` toggles 👍 on the selected message, a reaction's button takes the viewer's back or adds it, and "edit" (or `e`) on the viewer's own message loads the compose box with `Edit of MSG_…` and its markdown. In a narrow window they are larger, for a finger. A reaction is a POST to the conversation's `/react`; the stream sends the message again (`event: replace`), and feed.js puts it in place.
  - `app/feed.js`: the messages pane, a card at most 600 pixels wide and the only part that scrolls; each message a bubble, the viewer's own on the right (the pane's `data-viewer` against the message's `data-author`), each time in the viewer's zone; and each message the conversation's stream brings (an `EventSource`, at the page's URL and `/stream`), dressed the same and appended. One message is selected, ringed, as in chat-client: ↑ and ↓ move to the previous and next, Home and End to the first and last, Page Up and Page Down scroll a page (or select the first or last at the end), and scrolling or a click selects too; the address bar's `#msg-<n>` follows the selection.
- **Text from outside.** It arrives only as an `UnvalidatedString`, which has no way out except its checking doors.
- **Who is acting.** That is a `SignedIn`, by a session or by an agent's API key, or no one (`SignedIn.Actor`'s `Anonymous`), found by `load_actor!` in `app/Actor.roc`. The session door takes only what `Session.admit` makes, after the host said the cookie's HMAC matches and its second is within a year (`SignInRoute` checks the password and signs the session; the host holds the secret). The key door takes only what `AgentKey.admit` makes, after the hash of the secret an agent sent matched a live key of its own. The third door, `dangerously_assume`, is for the first start, which makes Steve, and for tests. `Route` says which routes no one may use (`Open`); `Access` decides who reads and posts where: a channel's members, a DM's humans, and a key only as far as its scope reaches.
- **Agents.** `Agents` decides what `/agents` may do (`AgentsRoute` answers): only a human by their own session makes, invites and manages their agents; a key comes only from an invite (`AgentInvite`), redeemed once within ten minutes; a key (`AgentKey`) is 32 random bytes from the host, shown once (`Secret`, `SecretToken`) and kept only as its SHA-256 (`SecretHash`). `AgentStream` is an agent's one stream of every message of its channels, a line of JSON each.
- **For a security reader:** start at `UnvalidatedString`, `TrustedHtml`, `SecureImageTag`, `SignedIn` (with `AgentKey`, `AgentInvite`, `HumanInvite` and `GitHubSignIn` behind it) or `RequestOrigin`, and at the host's path rule (`host/file_primitives.zig`).
- **The directory.** `Directory`, `Users`, `Channels`, `Name`, `Dm` and `Place` are pure. The directory is read from disk on every request, in the Zig chat's layout (docs/design.md, "Storage"): `auth/<id>/` for who each user is, `chat/channel/<name>.channel` for a channel's members.
- **The server's parts.**
  - `RequestOrigin` holds every request to this server's own origins first: its `Host` must be `127.0.0.1:<port>`, `localhost:<port>` or the public origin's name, its `Origin`, when sent, the one its `Host` names, and a POST from another origin's page is refused (403).
  - `Route` chooses an answer from the method and path.
  - `ConversationKey` is a place plus a topic, and the one home of the layout: a URL `/chat/channel/<channel>/<topic>` names the folder `chat/channel/<channel>/<topic>/`, and `/chat/dm/<pair>/<topic>` names `chat/dm/<pair>/<topic>/`.
  - `ConversationRoute` answers GET and POST (a 303 back to the page), the compose box's script's POST to `/send` (a 201 with the message's HTML, or the refusal in plain words), and opens a conversation's stream.
  - `Browse` decides what a human is shown, by `Access`, and writes its page; `BrowseRoute` reads each place's topics and answers. A conversation's sidebar (`Sidebar`) lists the same places and topics.
  - `ResumeRoute` answers `/`: the conversation a human last opened, kept as `users/<id>/last-conv` (`LastConversation`) and written when they open one, while they may still read it; else Browse.
  - `Presence` decides who is online, as Gopher Chat did: five minutes after any request but a stream; `PresenceNotices` keeps when each human was last seen in the host's memory and, when one comes online, sends every other human their dot and "<name> has come online." on their own stream key, which each conversation page's stream also carries. `ServerSentEvent` writes the events of a stream.
  - `ConversationStream` is the stream's one home: its bus key, how many messages a reader has seen (`?after=` or `Last-Event-ID`), and each message's frame, the HTML `ConversationPage.message` writes for the page.
  - `UploadRoute` answers an upload and an uploaded image. An image is what its opening bytes say, PNG, JPEG, GIF or WebP, at most 10 MiB, named by 16 random bytes in hex (`UploadedImage`); it is read out of the compose box's form (`MultipartForm`), counted against the uploader's lifetime allowance of 1 GiB (`UploadTotal`, kept in `users/<id>/upload-bytes`, `UserFolder`), kept in its conversation's folder as `uploads/<name>`, and served at the conversation's URL and `/uploads/<name>`. A message shows an image only from its own conversation's uploads (`SecureImageTag`).
  - `FileFacts` is the only module that touches files. Above it, one module per feature keeps that feature's files and is the home of its corner of the layout: `TranscriptFiles` (transcripts, uploaded images, upload totals), `AccountFiles` (accounts, passwords, GitHub links), `InviteFiles` (human invites), `AgentFiles` (agent keys and invites) and `DirectoryFiles` (the directory as read, and channels' members).
  - `SignInRoute` answers `/login` and `/logout`, and checks a request's session. `GitHubRoute` answers `/login/github/start`, `/login/github` and `/login/github/name`; `GitHubSignIn` decides each step of that sign-in, and `GitHubSignUp` is the signed value a new human's id travels in.
  - `app/main.roc` is the edge, the app's five entries, each wiring the modules that do the work: `FirstStart` (the first start's directory, Steve, plus the channel `general` with him in it), `DirectoryStore` (that directory written at the first start, and the directory read on each request, through `DirectoryFiles`), `Actor` (who is acting), `Admission` (a request judged from its head, and the upload's room, given only to someone signed in who may post where they upload) and `Dispatch` (the route answered).

## Commands

    shale tools/verify.shale                    the gate: format, Roc tests, hunts, the demo's frozen page, zig tests, the end to end
    zig build serve -- <data folder>            the server on http://127.0.0.1:9611 (add --port <n> for another,
                                                --public-origin https://<name> for the name a proxy serves it under)
    zig build serve -- hash-password            a password, typed with no echo, to its bcrypt hash on stdout
    zig build demo -- /chat/channel/general/roc-chat demo/data/chat/channel/general/roc-chat/transcript    the sample's page, to stdout
    zig build test                              the host's tests
    zig build end-to-end                        the server against a temporary data root: GET, POST, GET, the file on disk
    shale tools/glue.shale                      after a change to platform/: roc glue's snapshot, which `zig build test` holds the seam to
    shale tools/note.shale                      the page and all the code, as an essay note
    shale tools/deploy.shale                    the prod deploy to https://chat.lynrummy.com (docs/deploy.md: the runbook, and what Caddy must do)

You need the Roc pinned in `roc-version` at `~/tools/roc-<pin>/roc`, and roc-markdown checked out beside this repo, because its package renders the markdown.

## Running the server locally

`demo/data` is the sample data. Copy it, so your posts don't change the frozen demo:

    cp -r demo/data /tmp/roc-chat-data
    zig build serve -- /tmp/roc-chat-data

The first start makes Steve (`auth/1/`) and the channel `general`, with him in it (`chat/channel/general.channel`), and the server's secret, `.session-secret`. Steve has no password until he writes its hash; he types it, unechoed, and nothing else sees it:

    (umask 077 && zig-out/bin/roc-chat hash-password > /tmp/roc-chat-data/auth/1/password)

Then open `http://127.0.0.1:9611/chat/channel/general/roc-chat`, which sends you to sign in as Steve and back. Steve's own DM, `1_1`, is the other place. A topic is created by its first message. A channel's members are its `.channel` file, one id a line, which Steve, the admin, changes at `/channels` (or by hand). Removing a password's file ends every session of its user; removing `.session-secret` and starting the server again ends everyone's.

To offer GitHub sign-in, make an OAuth app whose callback URL is `<public origin>/login/github`, write its id and secret to `.github-client-id` and `.github-client-secret` in the data folder, `chmod 600` both, and start the server. Sign-up is then open: any GitHub account chooses a name and has an account, which starts in `general`, as an invited human's does. A human who has an account already, such as the owner, signs in as they do and links GitHub from `/agents`; GitHub then signs them in to that same account (docs/design.md, "Sign-in"). Signing in with GitHub before they link makes them a new account. With neither file the server offers no GitHub.

From your laptop, tunnel the port and browse as if the server were local:

    ssh -L 9611:127.0.0.1:9611 <box>
    open http://localhost:9611/chat/channel/general/roc-chat

Keep the laptop's port the server's: the server refuses a `Host` that is not `localhost` or `127.0.0.1` at its own port, or its public name (`app/RequestOrigin.roc`), so `ssh -L 8000:127.0.0.1:9611` answers 403. That refusal is what keeps another site's page, or a name rebound to 127.0.0.1, from acting as Steve through your browser.

Post from the compose box (on the right of a wide window, at the bottom of a narrow one), or sign in and send the form a browser would send:

    curl -c /tmp/jar --data-urlencode 'name=Steve' --data-urlencode 'password@-' http://localhost:9611/login
    curl -b /tmp/jar -i --data-urlencode 'markdown=Hello from **curl**' http://localhost:9611/chat/channel/general/roc-chat

(The first reads the password from stdin; `__Host-` cookies are `Secure`, and curl keeps and sends them over `http://localhost`.)

## An agent

At `http://localhost:9611/agents`, make an agent (say CC, id 2), add it to a channel on that channel's page under `/channels`, and press "Invite CC". The page shows the invite's code once; it lives ten minutes. The agent redeems it, with no other credential, for its key, shown once:

    curl --data-urlencode 'code=2-<64 hex digits>' http://localhost:9611/agents/redeem

With the key, the agent posts, reads a transcript, and listens to every channel it is in, catching up from a date:

    curl -H 'Authorization: Bearer 2-<64 hex digits>' --data-urlencode 'markdown=Done.' http://localhost:9611/chat/channel/general/roc-chat
    curl -H 'Authorization: Bearer 2-<64 hex digits>' http://localhost:9611/chat/channel/general/roc-chat/raw
    curl -N -H 'Authorization: Bearer 2-<64 hex digits>' 'http://localhost:9611/agents/stream?since=2026-11-03T00:00:00Z'

Each event of the stream is one line, `data: ` and a JSON object: the conversation's URL path, the message's id, its author, its date and its markdown. A catch-up sends at most each conversation's newest 100 messages since the date; a gap in a conversation's ids says to read the rest from `/raw`. A stream ends after an hour, and at once when its key is revoked: reconnect, from the date of the last event read.

## Forking

The top bar's Home link goes to https://lynrummy.com/. To send it to your own home page, or to have none, change app/HomeLink.roc, then the pages frozen with it (`app/PageSpec.roc`, `app/BrowseSpec.roc`, `demo/roc-chat.html` and `host/end_to_end.zig`'s `home_link`).

## Pitfalls


**The demo's page is frozen.** The gate holds the demo's output to `demo/roc-chat.html` byte for byte, and the end to end holds the server's first GET to the same file. A deliberate change to the page rewrites that file from the demo's output, and the commit says what moved and why.

**A change to `platform/` needs `shale tools/glue.shale`.** `zig build test` fails, naming the function, until the glue snapshot (`host/glue/platform_abi.zig`) is regenerated.
