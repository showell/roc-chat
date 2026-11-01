# Gopher Chat client features, cataloged for the roc-chat port

As of 2026-11-01. Old client: `~/showell_repos/chat-client` at 7b6358b8 (the
commit both hosts pin). Old server: `~/showell_repos/angry-gopher/zig-server/src`
at 8c8b25a5. New: `~/showell_repos/roc-chat` at d18638a. Paths below are
relative to those roots: `js/` is chat-client, `zs/` is angry-gopher's
`zig-server/src`, and `app/` is roc-chat. CONTRACT.md is chat-client's.

Estimates (S = an hour or two, M = half a day, L = more) are for **fresh JS
against roc-chat**. They leave out server work, which is listed under "roc-chat
lacks".

## 0. Model differences that change every feature

Read these first. Each one changes how a feature ports.

| | old (Gopher Chat) | roc-chat |
|---|---|---|
| page unit | a **topic**: `<conv-base>/<sid>` (`/chat/c/<pair>/<sid>`, `/channel/<name>/<sid>`) | a **conversation** page only: `GET /chat/<id>` (app/Pages.roc:498). Channel and DM topics have JSON and stream routes (app/Topics.roc:1-20, README rows 66-71) but **no browser page** |
| message id | string `<sid>_<n>`, plus `index` (0-based); the number is index+1 | integer `id` (app/Conversations.roc:1095); topic messages also carry `ref` `MSG_<ch>.<topic>_<n>` |
| author | `from` (name) + `from_uid` | `by` principal id (`human:2`); the name comes from the page's hidden `#people` list (app/Pages.roc:531-543, read at :731-732) |
| time | `at` RFC 3339 string | `at` unix seconds (app/Pages.roc:733) |
| mine | client: `from_uid === data-me` (js/chat.js:301) | **no viewer id on the page**: the body has only `data-conv` (app/Pages.roc:522-526). It must be added for mine-styling, edit and reactions |
| send | async: POST returns 204, and the **SSE echo with `cid`** confirms it (js/chat_compose.js:80-95, zs/chat.zig:351-397) | synchronous: POST returns `201` with the message JSON (app/Conversations.roc:871), and the page adds it at once (app/Pages.roc:769-770) |
| backlog | the stream carries the **whole topic** each time: `?since=0`, then `event: backlog-size N`, then N frames (zs/chat_sse.zig:61-74) | the page is server-rendered with the newest 100; the stream resends the newest page (no Last-Event-ID) or what came after Last-Event-ID; `gap` event when too far behind; "Earlier messages" pages back (app/Conversations.roc:960-1000, app/Pages.roc:750-761) |
| client code | ~5,300 lines, 29 files, each widget injecting its own CSS | ~45 lines inline (app/Pages.roc:729-771) and 10 lines of CSS (app/Pages.roc:617-627) |

Both servers render markdown with the **same markup vocabulary**: roc-markdown
emits `a.msg-ref` and `pre.chat-quote` (roc-markdown judge data: `msg-ref/channel`,
`chat-quote` in examples), so the old bubble CSS (js/message.js:67-132) ports as is.

roc-chat already **serves the old bundles** at `/<name>.js` (host/assets.zig:1;
`chat-client-rev` = 7b6358b8). No page loads them. A new client needs a new
name or a new path so the two don't collide, and that pin can then go.

---

## 1. Compose — **M** (S for the basic box; the rest is uploads and emoji)

### Old behaviour
- **The right rail has two states** (js/chat_right_sidebar.js:46-57):
  - closed: an "Open compose box" button, with the key help panel under it;
  - open: the compose body (a form, a textarea, a status line and a hint).
  - `openCompose` hides the closed panel and shows the body, then `onOpen`, which focuses the textarea (js/chat.js:371).
  - `closeCompose` does the reverse, then `onClose`, which focuses the feed (`pane.focus`, js/chat.js:372; js/middle_pane.js:105).
- **The page loads with compose closed** (js/chat_compose.js:260). The final `ChatCompose.focus()` (js/chat.js:419) focuses a hidden textarea, so in effect it does nothing.
- **Keys:**
  - `c` opens compose (js/chat_help.js:133).
  - **Ctrl/⌘-Enter sends** (js/chat_compose.js:314). Plain Enter is a newline; there is no Shift-Enter rule.
  - **Esc closes only when the textarea is empty** ("never lose a draft", js/chat_compose.js:315).
  - On narrow screens a ▾ button closes it (js/chat_responsive.js:96-108).
  - roc-chat today is the opposite: **Enter sends, Shift-Enter adds a line**, and IME composition is respected (app/Pages.roc:763-765). Pick one deliberately.
- **Send button:** a `type=submit` "Send" and an "Upload" button (js/chat_compose.js:267-271). The hint reads "Markdown supported · :emoji: autocompletes · attach an image or screencast · Ctrl/⌘-Enter to send" (:284).
- **While sending** (js/chat_compose.js:80-95):
  - blank text does nothing;
  - it makes a `cid` (`crypto.randomUUID`, or a fallback) and remembers the last 20 in `sentCids` (:86);
  - it disables the textarea and every button, and shows "Sending…" in the muted colour (:87-88);
  - it **starts a 3000 ms timer that calls `hostDown`** (:89);
  - it POSTs `markdown` and `cid` with the header `X-Chat-Async: 1`.
- **Ack:** the stream frame carrying our `cid` calls `ackIfPending` (js/chat.js:317-337 → js/chat_compose.js:332-337):
  - it clears the timer, empties the textarea, re-enables everything and focuses the textarea;
  - chat.js also puts "✓ your message was sent to <id>" in the `#chat-notify` strip, a link that focuses the bubble.
  - `sentHere` (js/chat_compose.js:330) matches only this tab's cids, so an echo that arrives *after* a give-up still shows "sent". That notice is what tells the user not to resend.
- **Failure or timeout** (`hostDown`, js/chat_compose.js:63-69):
  - it keeps the text, re-enables the box, and opens a modal `<dialog class=chat-alert-dialog>` saying **"The host may be down. Please retry your send."**;
  - closing the dialog refocuses the textarea (:71-79);
  - a non-2xx POST takes the same path (:93-94). The server's 400 text, such as "not sent: malformed markdown…" (zs/chat.zig:371-385), is **never shown**.
- **Quote, edit and pending sends:** while a send is pending, quote and edit are ignored (js/chat.js:82, :95).
- **Drafts: none.** Nothing is persisted. The only guard is the Esc-only-when-empty rule.
- **Uploads**, part of compose (js/chat_compose.js:105-248):
  - the Upload button opens a file picker, and pasting an image or video into the textarea uploads it;
  - JPEG and PNG are shrunk in the browser to a 2048 px longest side (`resizePlan` :136, `shrinkPicture` :151, with a 15 s watchdog);
  - an XHR shows progress (percent, then "Saving…"), patience is 5 min, and one upload runs at a time;
  - success inserts an `<img src alt>` or `<video src>` at the caret;
  - the limits come from the page's `data-upload-*` attributes (js/chat.js:379-383).
- **Emoji autocomplete** (js/chat_emoji.js:165-210):
  - typing `:` at a word start opens a menu;
  - Up/Down move, Enter/Tab accept, Esc closes;
  - a closing `:` on an exact name completes it;
  - the textarea ends up holding the unicode glyph.
- **CSS:** `ensureStyles` in js/chat_compose.js:30-56 (`.chat-compose-*`, `.chat-status`, `.chat-hint`, `.chat-alert-dialog`), the rail at js/chat_right_sidebar.js:32-44, and mobile at js/chat_responsive.js:50-65.

### Routes
- Old: `POST <session-base>/send` (CONTRACT.md:111; zs/chat.zig:292, handler :351-397) and `POST <session-base>/upload` (CONTRACT.md:112; zs/chat_upload.zig).
- roc-chat: `POST /conversations/<id>/messages`, with the raw markdown body and a 201 + message answer (README:46); topics: `POST /channels/<n>/topics/<t>/messages` (README:68).

### roc-chat has
- An always-open textarea, Enter to send, `#said` for the error text (it *does* show the server's refusal), and dedupe by DOM id (app/Pages.roc:540, 762-771).
- No open/close, no disable-while-sending, no timeout, no uploads, no emoji.

### Notes for the port
- There is no cid echo to wait for: the POST answer is the confirmation. "Host may be down" becomes a `fetch` with an `AbortController` timeout of 3 s (match the old value) plus a network-error catch.
- Keep the old modal text verbatim if Steve wants parity. Show the server's 4xx text, as roc-chat already does.
- roc-chat has **no upload route**: app/Conversations.roc:132-135 names `/user_uploads/` as a future folder only. So Upload/paste is blocked on the server (L server-side); the client half, with the resize, is M.

---

## 2. SSE updates — **M**

### Old behaviour
- **One `EventSource`** on `<session-base>/stream?since=0` (js/chat.js:253).
- **Backlog vs live:**
  - every connection, the first and each reconnect, starts with `event: backlog-size` (js/chat.js:279-295);
  - it captures `wasCaughtUpAtBacklogStart = pane.caughtUp()`, sets `inBacklog`, and calls `pane.startBacklog(n)`;
  - a size that is not digits closes the stream and notifies "This topic did not load right; reload to try again." (:286-291);
  - backlog frames are appended in batch mode (:302-306), and the view skips settle, scroll and click work (js/message_view.js:459-492);
  - `finishBacklog` (js/chat.js:262-277) anchors once: to the `#msg-<id>` from the URL (or "That message is no longer here." and the bottom), else to the bottom if the user was caught up, else leaves scroll alone (the reconnect case);
  - an **image-decode stabilizer** re-anchors as `<img>`s load, for up to 5 s, and stops on a real user scroll (js/message_view.js:392-408).
- **Reconnects:**
  - the browser's own: no `onerror` handler, no UI, no custom backoff;
  - the server sends no `retry:` (none in zig-webbox/src/sse.zig), so the browser default applies (about 3 s in Chrome);
  - frames carry `id: <index>` (CONTRACT.md:171), so the browser sends `Last-Event-ID`, and the server resumes **after** it: `resumeAt`, n+1 (zig-webbox/src/sse.zig:76-95);
  - the reconnect's `backlog-size` then counts only the missed frames.
- **Gaps:** the server's 16-frame mailbox drops a frame when full, marks the subscriber `missed`, and ends the stream (zig-webbox/src/bus.zig:57-94, :361-364). The browser reconnects and resumes by Last-Event-ID, so nothing is lost. The client has **no gap logic and no dedupe** (`appendMessage`, js/chat.js:229-235, appends blindly); it relies on the resume being exact.
- **Keepalive:** a server `: ping` every 25 s (zig-webbox/src/bus.zig:66, :304). The client ignores it.
- **Scroll on a live message** (js/chat.js:308-316):
  - `stick = pane.caughtUp()` is read *before* the append (last bubble bottom ≤ history bottom + 1, js/middle_pane.js:88-93);
  - if stuck, `cursorToExtreme(true)` scrolls to the bottom and selects the last bubble;
  - if not stuck, **nothing**: no "new messages below" pill, no unread divider, no count.
- **"New message" indications:**
  - in this topic: only the own-send notice;
  - other topics and conversations: `/chat/notifications` (feature N1 below), which puts a link in the strip and paints the favicon;
  - a ping for the open topic is suppressed (js/notify.js:256).
- **bfcache:** `pageshow` with `persisted` reloads the page (js/chat.js:257).
- **Edits arrive as messages:** an "Edit of MSG_<id>" message makes the original bubble collapse into a spoiler, but only when the authors match (js/chat.js:221-235; js/message.js:262-276).
- **Reactions arrive as `event: reaction`** (js/chat.js:297).
- **Search refresh:** if the search modal is open, a live message re-asks it (js/chat.js:338).

### Routes
- Old: `GET <session-base>/stream?since=0`, with events `backlog-size`, `message` and `reaction` (CONTRACT.md:157-187; zs/chat_sse.zig:48-78).
- roc-chat: `GET /conversations/<id>/stream`, events `message` (id = message id) and `gap` `{"before":id}` (README:47; app/Conversations.roc:960-1060); topic streams likewise (README:68).

### roc-chat has
- An EventSource with dedupe by `#m<id>` (app/Pages.roc:744-749, 759-761).
- `gap` reloads the page.
- **It always calls `scrollIntoView` on every new message**, which yanks a reader who has scrolled up (:748).
- No backlog marker: on first connect the stream resends the newest page, which the page already shows. Dedupe makes that harmless, but the client cannot tell backlog from live, for the scroll-follow and the "sent" notice. Use "id > the largest id rendered at load" as the live test, or ask for a marker.
- "Earlier messages" paging (:750-758) has no old equivalent: the old app always streams the whole topic.

---

## 3. Host timeouts — **S** (it falls out of 1 and 2)

Every client-side timer and retry in the old client:

| what | value | where | what the user sees |
|---|---|---|---|
| send echo | 3000 ms from the click, covering both the POST and the echo | js/chat_compose.js:89 | modal "The host may be down. Please retry your send." (:68); text kept |
| send POST fails or is non-2xx | immediate | js/chat_compose.js:93-94 | the same modal |
| late echo after a give-up | — | js/chat.js:317, js/chat_compose.js:330 | strip: "✓ your message was sent to <id>" (text still in the box) |
| topic stream drop | browser default (no `retry:`, no onerror) | js/chat.js:253 | **nothing**; frames resume silently |
| other streams (sidebar, notifications, recent, code, images) | browser default | js/chat_left_sidebar.js:230, js/notify.js:247, js/recent.js:241, js/code.js:79, js/images.js:109 | nothing |
| upload | 5 min XHR timeout | js/chat_compose.js:114, :217, :246 | "Upload gave up after 5 minutes. Please try again." |
| upload, connection drop | — | js/chat_compose.js:245 | "Upload failed: the connection dropped. Please try again." |
| photo shrink watchdog | 15 s, then the original is sent | js/chat_compose.js:132, :159 | none |
| search debounce | 150 ms | js/chat_search.js:70, :157 | "Searching…" |
| search errors | per status | js/chat_search.js:85-101 | signed out / "Searching too fast" (429) / "still getting ready" (503) / "Search failed (n)" / "could not be reached" |
| saved-set load failure | — | js/chat.js:58-60 | strip: "Could not read which messages you saved; reload to try again." |
| reaction POST failure | — | js/chat_reactions.js:63-64 | strip: "Reaction failed" |
| save POST failure | — | js/chat.js:137-139 | strip: "Save failed" |
| selection → URL hash | 700 ms rest | js/message_view.js:214, :245-260 | the URL `#msg-<id>` updates |
| docs autosave and preview | 1200 ms debounce | js/docs.js:55-57 | "Save failed (status)" |
| Recent page ages | repaint every 20 s | js/recent.js:98 | "3 min ago" ticks |
| drag-to-pin touch hold | 280 ms | js/chat_drag_to_pin.js:74, :114 | — |

**There is no offline or host-down banner anywhere, and no stream-health
indicator.** If Steve wants one in roc-chat, it is new (S): `EventSource.onerror`
and `readyState`, shown in the notify strip.

---

## 4. Middle-pane styling — **M**

### Old behaviour
All of it is CSS injected by JS. The server ships only the page shell: `chat_css`
at zs/chat_page.zig:192-203 (`html,body{height:100%}`, a full-width
`.app-body-wrap`, `#chat-root` and `.chat-layout` as flex rows with a 20px gap).
The base styles are in zs/chat_chrome.zig:117-136 (sans-serif, `a` and `h1` in the
accent colour, `.muted`).

- **Theme tokens:** js/colors.js:294-369 holds the LIGHT and DARK palettes as `--cc-*` custom properties.
  - `install()` reads `localStorage['chat-theme']`, **default dark**, and sets `html[data-theme]` (:388-404); it is called inline in `<head>` (zs/chat_chrome.zig:147).
  - The toggle button is in js/chat_theme.js:437-462.
- **The column** (js/middle_pane.js:43-71): the main column (`flex:1; max-width:600px`, inline styles), then a navbar strip holding only the 🔍 button, then the history (`overflow-y:auto; border 1px; radius 8px; padding 12px; bg cardBg`, focusable with `tabIndex=-1`).
- **Bubbles** (js/message.js:72-74):
  - `.chat-msg { margin:0 0 12px; padding:8px 10px; border-radius:8px; max-width:88% }`;
  - `.mine` (mineBg `#e7e7ff` / dark `#1c2433`) is pushed **right** with `margin-left:auto`;
  - `.theirs` (theirsBg `#f0f0e6` / `#22221c`) sits left.
- **Meta line** (js/message.js:76-86, built at :197-222):
  - `#<n> <from> · <time>`, then underlined text buttons: quote-reply, edit (own only), save / ✓ saved;
  - 11px, muted;
  - clicking the time opens the world-clock popup (js/chat_time_popup.js; zones NYC, India, London, SF, Sydney plus the viewer's own, :14-23);
  - time format: "Jan 2 · 3:04 PM" in the viewer's zone (`formatLocalTime`, js/message.js:158-165).
- **Grouping of consecutive messages: none.** Every bubble carries its own meta line.
- **Selection ring:** `.mv-selected { box-shadow:0 0 0 2px #ffcf3a }` (js/message_view.js:199).
- **Markdown CSS** (js/message.js:88-115):
  - `.chat-body { overflow-wrap:anywhere }`, with first/last `p` margins zeroed;
  - `a.msg-ref`: monospace chip, accentSoftBg;
  - `pre`: codeBg, padding 8, radius 4, `overflow-x:auto`, **cursor pointer** (a click opens the code popup);
  - `pre.chat-quote`: inherit font, pre-wrap, quoteBg, a 3px left border in quoteBorder, muted text;
  - `img`: `max-width:100%; max-height:320px; display:block; cursor:zoom-in` (a click opens the image popup with a zoom slider, js/chat_image_popup.js:31-93);
  - `video`: max-height 480;
  - external links: the server's `target=_blank`.
  - **No rules for tables, blockquote, lists, inline `code` or headings.** Browser defaults apply. roc-chat's page already styles tables (app/Pages.roc:621).
- **Reaction chips:** js/message.js:118-122. **Edited spoiler:** :124-132.
- **Empty state:** "No messages yet. Say hello 👋" (js/chat.js:213-219).
- **Mobile** (breakpoint `max-width:768px`, the only one, js/viewport.js:22; it sets `html.vp-narrow`):
  - the layout goes to a column, the feed full-bleed, the compose a bottom bar capped at 45vh, the key help hidden;
  - the textarea font is 16px (so iOS doesn't zoom);
  - the left rail moves into the hamburger drawer (js/chat_responsive.js:33-83; js/chrome_drawer.js).
- **Layout:** three columns: rail 180px (js/chat_left_sidebar.js:34), feed ≤600px, compose 320px (js/chat_right_sidebar.js:36).

### roc-chat has
- `<article id=m<id>><header>name · time</header><div class=body>…` (app/Pages.roc:552-566).
- CSS: a top border per article, a grey header, table borders (app/Pages.roc:617-627). Light only, one column, `max-width:46rem`.
- `toLocaleString` for time (:733).

### Port notes
- The colour tables and bubble rules port near verbatim: copy them into one stylesheet served by roc-chat, rather than injecting from JS.
- mine-vs-theirs needs a viewer id on the page (§0).
- Grouping is new design work, not a port.

---

## 5. Per-message actions

### Selection model (shared by q, e, s, `:` and `+`) — **M**, and the prerequisite
- **Bubbles are numbered 1..N.** `selected` is 0 for none (js/message_view.js:226-227).
- **Keys:** **Arrow Up/Down move** (no j/k), Home/End go to the ends, PgUp/PgDn page, and at an edge PgUp/PgDn jump to the end (js/message_view.js:368-383, `moveCursor` :337-351, `pageNav` :358-364).
- **Scroll moves the selection:** after a scroll it goes to the first fully visible bubble, else the first whose top is visible, else the straddler (`selectionCandidate`, :292-303). Programmatic scrolls are suppressed for 150 ms (`armedScroll`, :265-270).
- **Click selects:** a capture-phase listener runs before the bubble's own click routing (:328-333).
- **After the backlog:** the selection goes to the last bubble when anchored at the bottom (:481-487).
- **`focusBubble(idx)`** centres the bubble in the container (not `scrollIntoView`) and selects it (:441-455).
- **The URL hash** `#msg-<id>` is set by `replaceState` after a 700 ms rest (js/chat.js:196-202).
- **Hotkeys that need a selection do nothing without one, and don't `preventDefault`** (js/chat_help.js:145-157).

### q — quote-reply (also `r` and `>`) — **S**
- **Key:** js/chat_help.js:136, with the aliases at :185-186.
- **Link:** the "quote-reply" button in the meta line (js/message.js:205-207, click :231).
- **What it does** (`doQuote`, js/chat.js:81-90):
  - it is ignored while a send is pending;
  - it focuses the bubble and opens compose;
  - it inserts at the caret: `In MSG_<ref> I said|you said:\n~~~ quote\n<markdown>\n~~~\n\n`;
  - the fence is one tilde longer than any inner tilde run (`pickQuoteFence`, :75-80);
  - the ref is `<channel>.<id>` on a channel page, otherwise the bare id (`travelingRef`, :24-28).
- **Request:** none; it is client-only.
- **roc-chat:** messages carry `markdown`. Conversation messages have **no MSG_ ref form** (refs are topic-shaped, app/MessageRef.roc), so on a `/chat/<id>` page the quote has nothing to link to. Topic messages carry `ref`.

### e — edit (own messages only) — **S** for the client; the rendering of supersession is the bigger half
- **Key:** js/chat_help.js:135. **Link:** "edit", shown only on `mine` (js/message.js:211-216).
- **What it does** (`doEdit`, js/chat.js:94-100):
  - it is ignored while pending or when the message isn't mine;
  - it opens compose with `Edit of MSG_<id>\n\n<original markdown>`, the caret after the prefix (`setMarkdown`, js/chat_compose.js:101-104);
  - sending posts an ordinary new message.
- **How the edit shows:** an "Edit of MSG_<id>" message from the **same author** (`sameAuthor`: `from_uid`, else the name, js/chat.js:225-228) replaces the original bubble's body with "Edited in MSG_<new>" and a `<details>` "original" spoiler showing the raw markdown (js/message.js:262-276). It applies to backlog and live alike, and only if the original is already rendered.
- **Request:** none extra; it is the send.
- **roc-chat:** nothing. It needs a viewer id and a ref format for conversation messages, or the feature lives only on topic pages.

### s — save to reading list — **S** for the client, **L** for the server
- **Key:** js/chat_help.js:137. **Link:** "save", or "✓ saved" in green (js/message.js:186-194, :217-220).
- **What it does:**
  - `doSave` opens `ChatSavePopup` (js/chat_save_popup.js:110-190): a one-line dialog pre-filled "read later", where Enter saves and Esc, Cancel or a backdrop click dismisses;
  - `postSave` (js/chat.js:122-140) POSTs `/chat/docs/save_to_reading_list` with the form fields `conv, sid, id, from, at` (viewer-zone formatted), `body` (markdown) and `note`;
  - on 2xx it marks the bubble saved and shows the strip "MSG_<id> saved to [reading list (Docs)]" linking `/chat/docs/reading-list` (:144-152);
  - otherwise it shows "Save failed".
- **Loading the saved set:** on load, `GET <session-base>/saved` → an array of ids (js/chat.js:55-62; zs/chat.zig:306, :332-342).
- **roc-chat:** no docs, no reading list, no saved route.

### d — download transcript — **S** for the client; the server needs a route
- **Key:** js/chat_help.js:134. **No link** in the feed; the key help panel's button is the only click target.
- **What it does:** it makes a temporary `<a href=<session-base>/download>` and clicks it (js/chat.js:405-411). The server answers with a **.tar.gz of the transcript plus its images** as `Content-Disposition: attachment` (zs/chat.zig:303-305 → `download.serveBundle`, zs/chat_download.zig).
- **roc-chat:** no route.

### t — raw transcript — **S** for the client; the server needs a route
- **What it does:** **opens the topic's literal on-disk markdown file in a new tab**: `window.open(<session-base>/raw)` (js/chat.js:401; key js/chat_help.js:138; server zs/chat.zig:300-302 `serveRawTranscript`).
- **No link** besides the help panel button.
- **roc-chat:** no route. A message's `markdown` is in the JSON, so a client-side "raw" view could be built from `GET /conversations/<id>` pages instead, but it would cover only the loaded pages.

### Reactions — `:` (pick) and `+` (thumbs-up) — **M**
- **Keys:**
  - `:` opens `ChatEmoji.pick` anchored at the selected bubble: a filter input plus the list, where Up/Down move, Enter picks, Esc or blur closes, and focus returns to the feed (js/chat.js:105-110; js/chat_emoji.js:217-242);
  - `+` toggles 👍 (js/chat.js:398; js/chat_help.js:140-141).
- **Link:** the chips under the body. Clicking one toggles it (js/message.js:234-235, rendered :280-294). **No "add reaction" button**: a new emoji is keyboard-only via `:`.
- **State** (js/chat_reactions.js):
  - on load, `GET <session-base>/reactions` returns text, one JSON line per event (:68-72);
  - live `event: reaction` frames carry the same lines (js/chat.js:297);
  - the fold keeps the last line per message × uid × emoji (:38-49);
  - lines that arrive before their bubble wait, and `paint(n)` runs after each append (js/chat.js:232).
- **Toggle:** POST `<session-base>/react` with `msg` (number), `emoji` and `on`=1/0. It is **not optimistic**: the echo repaints, and failure shows the strip "Reaction failed" (:58-65).
- **Server:** zs/chat.zig:309-312, zs/reactions.zig.
- **roc-chat:** nothing.

### Search (`/`) — **M** for the client, **L** for the server
- **Key:** `/` (js/chat_help.js:139). **Link:** a 🔍 button in the navbar above the feed (js/chat_search.js:260-265).
- **What it does** (js/chat_search.js:108-247): a two-phase modal `<dialog>`, fixed near the top of the window.
  - **Phase 1:** debounced 150 ms; `GET /chat/search/words?prefix=` returns words with counts; Up/Down choose, Enter searches the chosen word or the typed text.
  - **Phase 2:** `GET /chat/search/messages?word=` returns excerpts with `<mark>`; Enter on one in this topic jumps to it (`jumpToId`, or "That message has not reached this page yet…", js/chat.js:347-353); one elsewhere navigates to `<conv>/<sid>#msg-<id>`.
  - Esc in phase 2 steps back to phase 1; Esc in phase 1 closes. A stale answer is dropped by a sequence number (:79-102).
  - The minimum word length comes from `data-search-min`, in UTF-8 bytes (:147-149).
- **Server:** zs/chat_search.zig, zs/search_index.zig, zs/search_tokens.zig.
- **roc-chat:** no search route (the only "search" hit is a byte scan in app/Bytes.roc).

---

## 6. Hotkey dispatch and online help — **S**

### Old behaviour
- **Two document-level `keydown` listeners**, both with the same filter: skip when the active element is TEXTAREA, INPUT or contentEditable, and skip when Ctrl, Meta or Alt is held:
  - MessageView owns the nav keys: arrows, Home/End, PgUp/PgDn (js/message_view.js:368-383);
  - ChatHelp owns the letter and symbol keys (js/chat_help.js:192-201).
- They don't overlap by construction: different keys. A key with no binding passes through to the browser.
- **One table drives both dispatch and the panel:** `shortcuts(deps)` at js/chat_help.js:131-143, entries `{key, label, requiresSelection, action}`. The letters are alphabetical, then `/ : +`. The aliases `r` and `>` point at `q` but don't appear in the panel (:185-186). The same table renders the panel (`renderKeyhelp`, :160-178): title "Keyboard", and each row a real `<button class=chat-keyhelp-key>` that runs the same action, plus the label.
- **The panel lives under the "Open compose box" button**, in the closed rail (`deps.rail.closedPanel`, :190). So **help is visible only while compose is closed**, and it is hidden on narrow screens (js/chat_responsive.js:54).
- **Not in the panel:** the nav keys, Esc and Ctrl/⌘-Enter. The compose hint line lists Ctrl/⌘-Enter.
- **Panel content today:** c compose · d download transcript + images (.tar.gz) · e edit selected message · q quote-reply to selected message (q, r, or >) · s save selected message to your reading list · t open the raw transcript in a new tab · / search every topic · : react to selected message (pick an emoji) · + thumbs-up the selected message.
- **Focus rules:**
  - while the textarea has focus, every hotkey is off;
  - an ack refocuses the textarea, so after sending you press Esc (on the now-empty box) to close compose, get the feed focus back, and turn the hotkeys on again;
  - modals (search, save, emoji picker) take focus and hand it back through `focusFeed` or `onClose`.
- **Wiring:** chat.js passes every action into `ChatHelp.init` (js/chat.js:387-412). This is **the merge point**: adding a feature means editing chat_help.js's table *and* chat.js's deps.

### roc-chat has
Nothing: no hotkeys and no help.

---

## 7. Left sidebar — **M** (L with drag-to-pin)

### Old behaviour
- **Data:** inline JSON `#chat-sidebar-data` (js/chat.js:357-364), built by `buildSidebarJSON` (zs/chat_page.zig:108-170).
- **Three collapsible sections** (js/chat_left_sidebar.js:242-292):
  - **Conversations:** every other user as a DM, then every channel as `# name`, the active one highlighted;
  - **Pinned Sessions:** a drop target, with the hint "Drag a session here to pin it";
  - **Sessions:** this conversation's other topics, sorted alphabetically, or "No sessions yet".
- **Collapse state** is sticky per section in `localStorage` `chat-sidebar-collapsed:<section>` (:82-90). Titles are keyboard-togglable with Enter or Space (:141-143).
- **Add Topic form** at the bottom: POST `<conv-base>/new` `topic=`, which navigates to the new topic (js/chat_add_topic.js; js/chat_left_sidebar.js:282-287).
- **Drag-to-pin:** pointer events (mouse arms at once, touch waits for 280 ms or a horizontal swipe). It moves the row optimistically, POSTs `<conv-base>/<sid>/pin|unpin`, and reverts on failure (js/chat_drag_to_pin.js:74-218).
- **Live updates:** `/chat/sidebar/stream` (:229-240):
  - `user-arrived` appends a DM row;
  - `topic-added` inserts the topic sorted, only if it belongs to this conversation;
  - `user-online` adds the `online` class.
- **Presence:**
  - a 9px dot on user rows only: hollow blue when idle, solid green when online (:45-55, :106-109);
  - first paint uses `online:true` from the server (`presence.isOnline`, zs/chat_page.zig:126);
  - live, there is **only a "came online" edge** (after ≥5 min idle) and **no offline fade** until reload (:218-227).
- **Mobile:** the rail moves into the hamburger drawer (js/chat_responsive.js:74-83).

### Routes
`/chat/sidebar/stream`, `<conv-base>/new`, `<conv-base>/<sid>/pin|unpin` (CONTRACT.md:116-118, :123).

### roc-chat has
- `/chat` lists conversations as links, with a start form (app/Pages.roc ConversationList).
- On the conversation page, only an "All conversations" link (app/Pages.roc:529).
- `GET /channels/<n>/topics` and `GET /dms` exist as JSON (README:69-70).
- No sidebar stream and no presence.

---

## Other client features (one line each)

- **N1 Cross-conversation notifications and favicon:** `/chat/notifications` SSE puts a link in `#chat-notify` and paints the favicon solid violet `#8a2be2` (canvas). It suppresses pings for the open topic and clears the favicon on click (js/notify.js:207-265). roc-chat lacks the stream. **M**
- **N2 Status strip `#chat-notify`:** the one place for every notice (sent, saved, errors) (js/notify.js:235-239). **S**
- **N3 Theme toggle:** 🌙/☀️ in the top bar, `localStorage` `chat-theme`, default dark (js/chat_theme.js; js/colors.js:388-412). **S**
- **N4 Time popup:** a world clock on clicking a timestamp (js/chat_time_popup.js:85-138). **S**
- **N5 Image popup:** zoom slider, fit on load (js/chat_image_popup.js:31-93). **S**
- **N6 Code popup:** clicking any `pre` shows its text in a monospace dialog (js/chat_code_popup.js:31-71; routing js/message.js:142-150). **S**
- **N7 MSG_ ref navigation:** a same-page ref focuses its bubble; anything else opens `/chat/msg/<id>` in a new tab (js/chat.js:162-177; server redirect zs/chat.zig:149). roc-chat lacks `/chat/msg/`. **S**
- **N8 `#msg-<id>` deep link on load:** it lands on the message after the backlog, or says "That message is no longer here." (js/chat.js:247-250, :265-272). **S**
- **N9 Emoji autocomplete in compose:** the whitelist is in js/chat_emoji.js:29-…, the logic at :165-210. **S**
- **N10 Uploads (button and paste, browser-side shrink):** see §1. **M** for the client; there is no route.
- **N11 First-topic bootstrap page:** an empty conversation shows Add Topic pre-filled "general" (js/chat_first_topic.js; zs/chat_page.zig:48). **S**
- **N12 Mobile chrome drawer:** a hamburger that clones the top-bar links (js/chrome_drawer.js:1-146; js/viewport.js). **M**
- **N13 Recent page:** a live feed of chat and doc activity (js/recent.js; `/chat/recent/stream`). **M**
- **N14 Code page:** every code block posted (js/code.js; `/chat/code/stream`). **M**
- **N15 Images page:** every image, lazy-loaded (js/images.js:37-117; `/chat/images/stream`). **M**
- **N16 Docs editor:** autosave with live preview, "Post to chat", and a save on unload by beacon (js/docs.js). It is also the reading list's home. **L** with its server.
- **N17 bfcache reload:** js/chat.js:257. **S**
- **Not present in the old app:** desktop or Notification-API notifications, unread counts, typing indicators, drafts, a read cursor, message grouping, an offline banner, a "new messages below" pill.

---

## Server routes roc-chat lacks (for the features above)

Old route (CONTRACT.md:106-131), the feature it serves, and roc-chat's status:

- `<sid>/send` + cid echo → compose. roc-chat has `POST …/messages`, synchronous; **fine, simpler**.
- `<sid>/stream?since=0` + `backlog-size` → SSE. roc-chat has `…/stream` + `gap`; there is no backlog marker, so the client infers live from id.
- `<sid>/upload`, `/uploads/<f>` → uploads. **Missing.**
- `<sid>/reactions`, `<sid>/react`, `event: reaction` → reactions. **Missing.**
- `<sid>/saved`, `/chat/docs/save_to_reading_list` → save. **Missing** (no docs).
- `<sid>/raw` → t. **Missing.**
- `<sid>/download` → d. **Missing.**
- `/chat/search/words`, `/chat/search/messages` → search. **Missing.**
- `/chat/sidebar/stream`, presence → sidebar. **Missing.**
- `/chat/notifications` → N1. **Missing.**
- `<conv-base>/new` → add topic. roc-chat has `POST /channels/<n>/topics`, DM topics (README:66, :71).
- `<sid>/pin|unpin` → drag-to-pin. **Missing.**
- `/chat/msg/<id>` → N7. **Missing.**
- **A page carries the viewer id (`data-me`)** → mine, edit, reactions. **Missing** on `/chat/<id>`.
- **A browser page for a channel or DM topic** → the whole old UX is topic-shaped. **Missing**: topics are JSON and streams only.

---

## Suggested structure for the new JS

The old client already has the right bones: "workhorse, edges and substrate"
(chat-client README:57-63). Each widget is a `window.X = (function(){…})()` IIFE
that owns its DOM and CSS. **Two places force serial edits:**

- js/chat_help.js:131-143: the one keymap table;
- js/chat.js:387-412: the deps object that hands every action to ChatHelp;
- plus chat.js's `renderBubble` deps (js/chat.js:184-190) for the meta-line buttons.

Replace them with registries, so a feature is one new file and a `<script>` line.

```
core.js       the page's facts (conv, viewer id, base URLs) read once from
              data-* attributes; fetch helpers with the 3 s timeout; notify(msg)
feed.js       the message store (records by id), the bubble render, selection
              (arrows; Home/End/Pg*), backlog-vs-live, stick-to-bottom
keys.js       Keys.register({key, aliases, label, needsSelection, run}) and the
              one document keydown, with the old filter (skip textarea, input
              and contenteditable; skip Ctrl, Meta and Alt). It refuses a key
              registered twice (fail loud, at load)
help.js       renders the panel from Keys.list(), every row a button
actions.js    Actions.register({name, label, title, key, mineOnly, run(rec)}):
              puts a button in each bubble's meta line, registers the key,
              and so lists itself in help; feed.js calls Actions.metaButtons(rec)
compose.js    open/close, send, the timeout modal; the API: open(), insert(text),
              set(text, caret), isPending()
quote.js      Actions.register({name:'quote', key:'q', aliases:['r','>'], ...})
edit.js       Actions.register({name:'edit', key:'e', mineOnly:true, ...}) + the
              "Edit of" supersession hook (Feed.onAppend)
save.js, reactions.js, search.js, download.js, raw.js   the same pattern
```

- **Load order:** core, feed, keys, actions, help, compose, then the features in any order, then a final `Help.render()` (or render help lazily on first open).
- **Parallel work:** each feature agent touches only its own file and one `<script>` tag in app/Pages.roc's script list. The tag list is the only shared line, and a trivial merge.
- **The selection model is the hard prerequisite** for q, e, s and the reactions. Build feed.js with selection first; the actions then only need `Feed.selected()` → record.
- Keep the old rule that a key needing a selection does nothing, and doesn't preventDefault, without one (js/chat_help.js:145-157).
- **Help placement:** the old panel shows only while compose is closed. Decide whether roc-chat keeps that or uses a `?` overlay. A `?` key would be new; the old app has none.

### Dependency order

1. core + feed (render, the stick-to-bottom fix, the live test by id, `data-me` on the page) **M**
2. compose (open/close, send, timeout, error text) **S–M**
3. styling (port colors.js tokens and the message.js CSS into a stylesheet) **M**
4. selection + keys + help + actions registries **M**
5. q, e (client-only; parallel) **S each**. These need a ref format on the page roc-chat serves; a topic page makes it natural.
6. reactions, s, d, t, search: each blocked on a roc-chat route first; the client halves can go in parallel afterwards.
7. sidebar, notifications, presence (lowest; server streams first).
