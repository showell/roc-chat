# The browser client: Gopher Chat's experience, rebuilt

**The goal:** a human signed in to roc-chat gets what Gopher Chat (production's
Zig chat) gives them:
- a compose box that opens and closes, and Send;
- live updates that never yank the reader;
- styled messages;
- Recent;
- hotkeys with their online help;
- the per-message actions.

Apoorva and Damian come on once it feels like the chat they know.

**The rule for every step: consult the old app.** A port matches how the old
program works unless Steve decides otherwise.
- Every feature brief names the old code to match (file:line, from
  [the catalog](browser-client-catalog.md)).
- Every report states each difference from the old app, and why.

"It works" is not "it matches".

**After every chunk, a cold agent reviews it adversarially** by
[the review method](browser-client-review.md). Its first question is where the
chunk diverges from Gopher Chat without a stated reason.

## The shape: the server sends HTML

**The server serves vanilla HTML,** in the spirit of htmx or datastar, not a
JSON API that the browser renders (Zulip's way).
- **The page arrives rendered.** Each message's bubble (its meta line, its
  links and its body) is HTML the Roc draws.
- **A live update is a fragment the server rendered,** which the page inserts
  as is. The browser's stream carries rendered bubbles. The agents' stream
  (`GET /stream`, JSON) is for agents and stays as it is.
- **The JS is thin glue:** it opens and closes the right pane, posts the form,
  inserts fragments, runs the timeout, and dispatches keys. A feature that can
  be a link or a form is one.
- The JS is new, written for roc-chat, cribbing from chat-client
  (`~/showell_repos/chat-client`) where it helps. chat-client itself is not
  loaded.

**Where the code lives:**
- **The HTML:** the Roc page and fragment renderers.
- **`js/`:** small files, one per feature where that keeps parallel work
  apart, served by the host as the chat-client bundles are now
  (`host/assets.zig`). The names must not collide with chat-client's.
- **Styling in the JS, no CSS from the server** (DECISIONS.md, "How it's
  built and checked"; Steve: "Keep the CSS as it was in JS... We want fairly
  minimal styling and as little bitrot as possible"). Each widget styles its
  own elements; rules for server-rendered markup go in one `<style>` its
  script adds, as `js/message.js` does. The old colour tokens and bubble
  rules port near verbatim (`js/colors.js:294-369`, `js/message.js:67-132`).
- **Keys and help:** one registry. A feature registers its key, its link and
  its help line, and a key registered twice fails at load. So q, e, s and the
  rest don't all edit one table, as the old `js/chat_help.js:131` and
  `js/chat.js:387` forced.

## The layout: two panes

**The transcript and the right pane,** where the right pane is the compose box
or the online help, as in the Zig chat (`js/chat_right_sidebar.js:46-57`).
- No left sidebar until the last step. It's the part of the Zig chat that never
  worked well, Recent makes it mostly irrelevant, and it gets the most
  re-thinking.
- **The top bar holds the app's links in the Zig chat's place:** Browse,
  Recent, and later Docs, Images and Code, each as it lands. The old app's
  are at `zs/chat_chrome.zig:88-93`: "Chat · Docs · Recent · Images · Code".
  **Browse replaces Chat** (Steve: "The Chat link did a goofy decision on what
  to show that was never satisfying anyway").

**Settled details** (each matches the old app):
- **Mine vs theirs:** the server marks each bubble with its author, and the
  JS adds `mine` from the page's viewer id, since one live fragment goes to
  every viewer. This is the old client's rule (`js/chat.js:301`).
- **Times:** the server writes a machine-readable time, and the JS shows it in
  the viewer's zone as "Jan 2 · 3:04 PM" (`js/message.js:158-165`).
- **Ctrl/⌘-Enter sends everywhere,** agent conversations included.
- **The status strip** (`#chat-notify`) and "✓ your message was sent" are part
  of step 2 (`js/chat.js:317-337`). Later features put their notices there.
- **Verify runs `node --check`** on every file in `js/`.

**Agent conversations keep their own page for now** (`/chat/<id>`). They pick
up the shared pieces (styling, compose) as those land.

## The steps

Each step is one chunk: built, verified, reviewed, merged and deployed before
the next, except where noted as parallel. Sizes are the catalog's: S an hour or
two, M half a day.

1. **Browse, the topic page, and the transcript (M).**
   - **Browse:** every other human as a DM (by numeric id, as the old
     sidebar's Conversations), then the channels you're in, each with their
     topics. An existing DM lists its topics; a human with no DM yet has a
     button that makes one (`POST /chat/dm/<n>`, behind Origin) and lands
     back on Browse at it (Steve's call). Its link is in the top bar.
   - **The topic page:** a channel or DM topic's transcript, server-rendered,
     its messages live from fragments the server renders.
   - **The viewer known to the page,** so the server can draw mine and theirs.
   - **Stick to the bottom only when caught up.** The old rule is
     `js/chat.js:308-316`; today's page scrolls on every message.
   - **The two-pane frame:** the right pane can hold the help panel, empty for
     now.
2. **Compose and Send (S–M), the top priority.**
   - The box opens and closes: `c` and the "Open compose box" button open it;
     Esc closes it only when empty; closed is the starting state.
   - A Send button.
   - **Ctrl/⌘-Enter sends and Enter is a newline**, as in the old app.
   - While sending, the box is disabled and shows "Sending…".
   - **The host timeout:** after 3 s without an answer, or on a failure, the
     modal "The host may be down. Please retry your send.", with the text
     kept. A server refusal shows its own text.
   - Old: catalog §1, `js/chat_compose.js:63-104, 260-337`.
3. **The transcript, styled (M).**
   - Bubbles: mine on the right, theirs on the left.
   - The meta line `#<n> name · time`, with the time as "Jan 2 · 3:04 PM".
   - The markdown CSS: refs, quotes, code, images.
   - The empty state "No messages yet. Say hello 👋".
   - Dark by default, with the theme toggle.
   - Old: §4.
4. **Recent (M), early, because everyone uses it constantly.**
   - The live feed of activity across everything you can read.
   - Its link is in the top bar.
   - Old: N13, `js/recent.js`, `/chat/recent/stream`. The catalog has it in
     one line, so its brief starts with a deeper read of the old Recent page.
5. **Selection, keys and help (M).**
   - Arrows, Home/End and PgUp/PgDn move the selection; scrolling and clicking
     select too.
   - The key filter: off in a textarea or input, off under Ctrl/Meta/Alt.
   - The help panel, built from the registry, in the right pane while compose
     is closed.
   - Old: §5 (selection), §6.
6. **q and e (S each, parallel).** Each comes with its link, drawn by the
   server, at the same time as its key.
   - **q** quotes with `In MSG_<ref> I said|you said:` and a fence one tilde
     longer than any inside.
   - **e** writes `Edit of MSG_<ref>`, and the original collapses into a
     spoiler.
   - Topic messages carry `ref`. Agent conversations need a reference form
     before they get these.
   - Old: §5 q, e.
7. **s, d, t, reactions (`:` and `+`), and search: each needs a route first.**
   Each is its own chunk, server then client, and they can run in parallel.
   - **s** saves with its link; the reading list is part of the design.
   - **d** downloads a transcript.
   - **t** opens the raw transcript.
   - **Reactions** are a route and a live fragment.
   - **Search** is the largest server piece.
   - Old: §5.

**Later, low priority:**
- **Mobile:** after the desktop works. The Zig chat proved it's a couple of
  small changes once the desktop is right.
- **Pinned topics:** Browse and the left sidebar will respect pinning.
- **Dropped streams:** never a real problem in the Zig chat.
- **The other catalog features:** MSG_ ref navigation and `/chat/msg/<id>`
  (N7), the `#msg-` deep link (N8), the popups (N4–N6), emoji autocomplete
  (N9), uploads (N10), notifications and the favicon (N1), Docs, Images and
  Code.

**Last: the left sidebar,** re-thought rather than ported (old: §7).

## How each step is checked

- **verify.shale passes,** with new e2e steps at the end. Because the server
  renders the HTML, the e2e can check what a page and a fragment hold: the
  meta line, the links, the right pane, Browse's entries, Recent's items.
- **The JS stays small enough to read whole,** and the review reads it. There
  is no browser automation (Steve: no Playwright or the like).
- **Steve tries it on chat.lynrummy.com** after each deploy, and that never
  blocks the next step.
- **The cold review** (above), and the report's list of differences from the
  old app.
