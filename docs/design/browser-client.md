# The browser client: Gopher Chat's experience, in new JS

**The goal:** a human signed in to roc-chat gets what Gopher Chat (production's
Zig chat) gives them: a compose box that opens and closes, Send, live updates
that never yank the reader, styled messages, hotkeys and their online help, and
the per-message actions. Apoorva and Damian come on once it feels like the chat
they know.

**The rule for every step: consult the old app.** A port matches how the old
program works unless Steve decides otherwise. Every feature brief names the old
code to match (file:line, from [the catalog](browser-client-catalog.md)), and
every report states each difference from it. "It works" is not "it matches".

**The JS is new,** written for roc-chat and cribbing from chat-client
(`~/showell_repos/chat-client`) as needed. chat-client itself is not loaded
(DECISIONS.md, "The browser client").

## Where the code lives

- **`js/` in this repo:** one small file per feature, served by the host as the
  chat-client bundles are now (`host/assets.zig`, ETag and `no-cache`). The
  names must not collide with chat-client's, which roc-chat serves at
  `/<name>.js` until the old pin goes.
- **One stylesheet** (`css/chat.css`, or a served `.css`), not CSS injected
  from JS. The old colour tokens and bubble rules port near verbatim
  (`js/colors.js:294-369`, `js/message.js:67-132`).
- **The page says its facts in `data-*`:** the viewer's id, the stream, post
  and page URLs, and the reference prefix. So one client serves a conversation
  page and a topic page alike, as the old client's `conv-base` and
  `session-base` did.
- **Registries, not one table:**
  - `Keys.register` and `Actions.register` (a meta-line link, a key and a help
    line);
  - a key registered twice fails at load;
  - so q, e, s, d, t, reactions and search are each one new file plus a
    `<script>` line, and can be built in parallel.

  The old client's two serial merge points (`js/chat_help.js:131`,
  `js/chat.js:387`) are what this avoids.

## The steps

Each step is one chunk: built, verified, merged and deployed before the next
starts, except where noted as parallel. Sizes are the catalog's: S an hour or
two, M half a day.

1. **The feed, and a page for topics (M).**
   - A browser page for a channel topic and a DM topic. The old app is built
     around topics; roc-chat's topics are JSON only today.
   - `data-me` and the other facts on both pages.
   - `core.js` and `feed.js`: render, the live test (an id past the page's
     newest), dedupe, the `gap` reload.
   - **Stick to the bottom only when caught up.** The old rule is
     `js/chat.js:308-316`; today's page scrolls on every message.
   - The `/chat` list shows channels and DMs too, plainly. The real sidebar is
     step 9.
2. **Compose and Send (S–M), the top priority.**
   - The box opens and closes: `c` opens it; Esc closes it only when empty;
     closed is the starting state.
   - A Send button.
   - **Ctrl/⌘-Enter sends and Enter is a newline**, as in the old app.
     Today's page is the reverse.
   - While sending, the box is disabled and shows "Sending…".
   - A 3 s timeout or a failure opens the modal "The host may be down. Please
     retry your send.", keeping the text. A server refusal shows its own text,
     as roc-chat's page does today.
   - Old: §1, `js/chat_compose.js:63-104, 260-337`, `js/chat_right_sidebar.js:46-57`.
3. **Host timeouts and SSE health (S).**
   - Send's timeout lands in step 2.
   - Here, the stream: `EventSource` errors and `readyState`, and the
     reconnect.
   - The status strip (`#chat-notify`, old N2), the one place for notices.
   - The old app shows nothing when the stream drops. Showing it is new; Steve
     decides.
4. **The middle pane, styled (M).**
   - Bubbles: mine on the right, theirs on the left.
   - The meta line `#<n> name · time`, with the time as "Jan 2 · 3:04 PM".
   - The markdown CSS: refs, quotes, code, images.
   - The empty state "No messages yet. Say hello 👋".
   - Light and dark, **dark by default** as in the old app, with the theme
     toggle (N3).
   - Old: §4.
5. **Selection, keys and help (M).**
   - Arrows, Home/End and PgUp/PgDn move the selection. Scrolling and clicking
     select too.
   - The key filter: off in a textarea or input, off under Ctrl/Meta/Alt.
   - The help panel, built from the registry, shown under "Open compose box"
     while compose is closed, as in the old app.
   - Old: §5 (selection), §6.
6. **q and e (S each, parallel).** Each comes with its meta-line link, at the
   same time as its key.
   - **q** quotes with `In MSG_<ref> I said|you said:` and a fence one tilde
     longer than any inside.
   - **e** writes `Edit of MSG_<ref>`, and the original collapses into a
     spoiler.
   - **Both need a reference form for conversation messages,** decided here.
     Topic messages already carry `ref`.
   - Old: §5 q, e.
7. **s, d, t, reactions (`:` and `+`), and search: each needs a roc-chat route
   first.** Each is its own chunk, server then client, and the client halves
   can run in parallel.
   - **s** saves with its link; the reading list is part of the design.
   - **d** downloads a transcript.
   - **t** opens the raw transcript.
   - **Reactions** are a route plus a stream event.
   - **Search** is the largest server piece.
   - Old: §5.
8. **Mobile (small).** After the desktop works: the 768 px breakpoint, compose
   as a bottom bar, a 16 px textarea, the drawer. The Zig chat proved it's a
   couple of small changes once the desktop is right.
9. **The left sidebar, last (M).** Conversations, DMs and channels, a topic's
   other topics, add a topic, collapse state; live updates and presence later.
   Old: §7.

**Later, from the catalog's "other features":** MSG_ ref navigation and
`/chat/msg/<id>` (N7), the `#msg-` deep link (N8), the time, image and code
popups (N4–N6), emoji autocomplete (N9), uploads (N10, which needs a route),
notifications and the favicon (N1).

## How each step is checked

- **verify.shale passes,** with the e2e numbered at the end. The e2e covers
  what the server owes the page (the facts in `data-*`, the routes), and each
  feature's pure parts.
- **A browser check for each user-visible step,** in the shape of
  `tools/browser_check.js`: open, send, the timeout, keys. It needs Playwright,
  which this box doesn't have (Steve decides; see the open questions).
- **Steve tries it on chat.lynrummy.com** after each deploy. That never blocks
  the next step.
- **The report lists each difference from the old app,** and why.

## Open questions for Steve

- **Playwright on the box,** for browser checks, or browser checks only where
  Cloud works?
- **A visible notice when the stream drops** (new; the old app has none)?
- **Conversations vs topics:** do agent conversations stay as they are (one
  page each, no topics), with the new client on both kinds of page? (Assumed
  yes.)
