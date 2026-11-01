# Reviewing a browser-client chunk

How a cold agent reviews one chunk of [the browser client](browser-client.md)
adversarially. Run it from this doc alone. **Your job is to find what is wrong,
not to approve.** A review that finds nothing has to show what it checked.

**The order of questions:**
1. Where does the chunk behave differently from Gopher Chat, and is each
   difference justified?
2. Does it keep the shape Steve chose: server-rendered HTML with thin JS glue?
3. The usual quality checks: correctness, security, the repo's rules, tests.

## What you get

| input | what it is | if it's missing |
|---|---|---|
| branch and commit | the chunk, e.g. `cloud/step-2` at `abc1234`, against `master` | stop and ask |
| the chunk's report | what was built, **each difference from the old app and why**, and the verify output | review anyway, and report the missing list as a High finding |
| the plan step | its number in browser-client.md ("How each step is checked", "The steps") | read it from the plan |
| the brief | the old file:lines the builder was told to match, if a brief was written | use the catalog |

**Read these, in this order:**
1. browser-client.md and the step;
2. DECISIONS.md, "The browser client";
3. the catalog sections the step names (browser-client-catalog.md, §0 first);
4. the report;
5. `git diff master...<commit>` in full;
6. every `js/` file the chunk adds or touches, read whole (the plan requires
   that the JS stays small enough to read whole; if it isn't, that's a finding).

## What you may run

- **Read-only on the repo.** Never edit, commit, push, merge or deploy, and
  never read files under `secrets/` or `keys/` directories.
- **A scratch checkout, as a sibling.** The build takes `../roc-markdown` and
  `../chat-client` by path, so the scratch checkout must sit in `~/showell_repos`:
  `git -C ~/showell_repos/roc-chat worktree add ../roc-chat-review <commit>`.
  Remove it when you're done (`git worktree remove`), since disk is tight.
- **Verify:** `shale tools/verify.shale` in that checkout.
  - Read the line counts, not just the final line. A green is a claim: check
    that the floors (`roc_floor`, `zig_floor`, `e2e_steps`) rose by the tests
    the chunk added, and that the new e2e steps are printed and named.
  - Verify has **no check of roc-chat's own `js/`**: chat-client's
    `tools/check` covers only chat-client. Run `node --check` on each new
    file yourself, and say so in the review.
- **Pages and fragments, by curl.** There is no browser automation (Steve's
  rule: no Playwright).
  - Start the e2e held: `zig build e2e -- --hold`. It prints the port and
    session cookies for A, B and H.
  - GET a page: `curl -s -H 'cookie: <A>' http://127.0.0.1:<port>/<path>`.
  - Writes need `-H 'origin: http://chat.test'`; see tools/browser_check.js
    for the rig's origin.
  - Read a live stream: `curl -sN` on its route while a second curl posts.
  - Fetch the same page as A and as B to see mine versus theirs, and as a
    non-member to check that the answer is a 404.
- **The old code at the catalog's commits,** not whatever is checked out now:
  - `git -C ~/showell_repos/chat-client show 7b6358b8:js/<file>`
  - `git -C ~/showell_repos/angry-gopher show 8c8b25a5:zig-server/src/<file>`
  - The line numbers in the catalog are for those commits.
- **Not allowed:**
  - long waits: one verify, run in the background while you read;
  - anything against lynrummy.com or chat.lynrummy.com.

## Pass 1: divergence from Gopher Chat (the top finding class)

The chunk matches the old program by default. "It works" is not "it matches".
**For every feature the chunk touches:**

1. **Find the old code.** Take the catalog's file:line, then open the old JS
   and Zig themselves and read the function, not the catalog's summary. The
   catalog is a map, and it can be wrong or thin; Recent and Browse have one
   line or less in it.
2. **Fill in the parity table below,** one row per thing that can differ.
3. **For each difference,** look for the justification in a decision in
   DECISIONS.md, the plan's text, or the chunk's report, and cite it by
   section or line.
   - **No justification:** an unexplained divergence, severity High by default
     and Blocker if a user would notice at once (keys, send, losing a draft).
   - **The report justifies it but the plan or a decision contradicts it:**
     also a finding. Steve decides; the builder doesn't.
   - **The old behaviour is a bug** (e.g. a hidden textarea focused, catalog
     §1): a justified fix still has to be stated in the report.
4. **Hunt the omissions too.** Something the old code does that the chunk
   silently leaves out is a divergence: a status line, a focus move, a
   disabled button, an empty state, an alias key.

**The parity table** (fill in a row for every item that applies):

| dimension | compare | typical old source |
|---|---|---|
| keys | the key, its aliases, the filter (textarea, input, contentEditable; Ctrl, Meta, Alt), `preventDefault` or not, with and without a selection | js/chat_help.js:131-201, js/message_view.js:368-383 |
| text | every user-visible string, verbatim, including ellipses, arrows and emoji | grep the old JS for the string |
| layout | which pane, the order, widths (feed ≤600px, rail 320px), what's visible in which state | js/chat_right_sidebar.js:32-57, js/middle_pane.js:43-71 |
| defaults | starting state (compose closed, theme dark), localStorage keys (`chat-theme`) | js/chat_compose.js:260, js/colors.js:388-404 |
| timing | timeouts and debounces, and what each covers | catalog §3 table |
| flow | what happens after success and failure: focus, clearing, re-enabling, the notice strip | js/chat_compose.js:63-104, :330-337; js/chat.js:317-337 |
| empty and error states | the wording, and where it shows (modal, strip or inline) | js/chat.js:213-219; js/notify.js:235-239 |
| scroll and selection | stick only when caught up, what gets selected after an append | js/chat.js:308-316, js/middle_pane.js:88-93 |
| style | colour tokens, bubble rules and the meta line, near verbatim | js/colors.js:294-369, js/message.js:67-165 |

**Model differences are not divergences** when the chunk handles them the
catalog's way (§0): the synchronous 201 instead of the cid echo, integer ids,
unix-seconds `at`, no backlog marker. A different handling is a finding.

## Pass 2: the architecture

The server serves vanilla HTML, in the spirit of htmx or datastar
(DECISIONS.md, "The browser client"). Each of these is a finding:

| breach | how to spot it |
|---|---|
| JSON rendered in the browser | JS that builds a bubble, a list item or a meta line from fields; `innerHTML` with template strings; `JSON.parse` on anything but the agents' stream |
| logic in the JS that belongs in the Roc | JS that decides who may do what, mine versus theirs beyond reading a server-set attribute, ref formats, quoting rules the server could emit, or sorting and filtering lists |
| a JS feature that could be a link or a form | a `fetch` POST where a `<form>` would do; `window.open` or `location=` for what an `<a href>` does; a button with no `href` for navigation |
| the page not arriving rendered | an empty container that the JS fills on load |
| a fragment not server-rendered | the browser's stream carries JSON for bubbles, or the page re-renders what the fragment holds |
| the key registry bypassed | a second `keydown` table, or a key not registered with its help line and link; a key registered twice must fail at load |
| CSS injected from JS | `ensureStyles`-style `<style>` creation (the plan wants one served stylesheet) |
| chat-client loaded, or name collisions | a page loading `/<chat-client name>.js`, or a new `js/` file named like one of chat-client's |
| the agents' stream changed | `GET /stream` or its JSON altered for the browser's sake |

**JS the plan does allow:** opening and closing the right pane, posting the
form, inserting fragments, the 3 s timeout, key dispatch, selection, and
stick-to-bottom. Glue that grows past that needs its reason in the report.

## Pass 3: quality

- **Correctness and edge cases:**
  - an empty topic, one message, and the 100-message page boundary;
  - a `gap` event, a reconnect, and a duplicate frame (dedupe by id);
  - a whitespace-only send, a very long body, and markdown the server refuses;
  - a double send, and pressing Esc while a send is pending;
  - non-ASCII names and topics.
- **Security:**
  - **Escaping:** every place the Roc writes user text into HTML (names,
    topic names, refs, attributes, the `data-*` values). Fetch a page whose
    poster's name holds `<b>"&'`, as e2e does at host/e2e.zig:525, and check
    that it comes back as text. In the JS, flag `innerHTML` with anything
    except a server fragment.
  - **CSRF:** every new non-GET route passes app/Origin.roc's check. Look for
    a test where a foreign Origin is refused and the configured one taken.
  - **Who sees what:** a page and a stream for a topic you can't read must be
    404, never 403, and never an empty page that leaks its existence. Check
    that agent topics stay theirs and their humans', and that Browse and
    Recent list only what ConvAccess or Topic allow.
- **The repo's rules:**
  - for Roc, roc-apps CLAUDE.md (§6 testing, §8 docs, §9 security) and
    docs/roc-style.md;
  - comments carry a why, in present tense, with no narrative or history;
  - no tracker or finding codes in code;
  - the README's route table and DECISIONS.md move in the same commit as the
    change.
- **Tests:**
  - each boolean and tag is asserted on every side, both the refusal and the
    near-miss that's taken (DECISIONS.md, "How it's built and checked");
  - the report says a planted fault was seen red before green for each new
    test, and names it. Verify plants nothing, so the report is the only
    evidence: if it's missing, that's a finding;
  - the e2e checks what the page and fragment hold (the meta line, links,
    the right pane), not just a 200.
- **A green is a claim:** confirm the new e2e steps and expects are among
  those that ran (the counts, their names), and that verify ran on the
  reviewed commit, not an earlier one.

## Output

Put the review in the chat or the PR, scannable, highest severity first.
**List the divergence findings first, whatever the severity of the rest.**

```
Review: step <n>, <branch> @ <sha>   verdict: MERGE | MERGE AFTER FIXES | REWORK
Checked: verify <N of N, floors old→new>, node --check <files>, curl of <pages>,
         old files opened: <list>

| # | sev | class | finding | old (file:line) | new (file:line) | justification found |
|---|-----|-------|---------|-----------------|-----------------|---------------------|
| 1 | High | divergence | Esc closes a non-empty box | js/chat_compose.js:315 | js/compose.js:41 | none |
| 2 | High | architecture | bubbles built from JSON in JS | — | js/feed.js:12-40 | — |
| 3 | Med | quality | name unescaped in data-me | — | app/Pages.roc:530 | — |

Justified divergences (one line each, with the cite): ...
For Steve (ambiguities in the plan, not the builder's fault): ...
```

- **Severity:**
  - **Blocker:** wrong for users, insecure, or the wrong architecture, so the
    chunk needs rework;
  - **High:** must be fixed before merge, and this includes every unexplained
    divergence;
  - **Med:** fix before merge unless Steve waives it;
  - **Low:** a nit, listed after the rest, at most five of them.
- **Class:** `divergence`, `architecture` or `quality`.
- **Verdict:**
  - any Blocker means **REWORK**;
  - any High or Med means **MERGE AFTER FIXES**, with the fixes listed;
  - otherwise **MERGE**.
- **Evidence on both sides:** a finding without an old file:line (for a
  divergence) or a new file:line is a guess. Mark it so, or drop it.

## Anti-patterns

- **Rubber-stamping:** "looks good, verify green." A MERGE verdict still
  lists what you opened and compared.
- **Taking the builder's word:**
  - "matches the old app" means nothing until you've read the old code;
  - "tests cover it" means nothing until you've read the test;
  - "planted fault seen red" means nothing until the report names the plant.
- **Burying the divergences:** twenty style nits above one wrong key. The
  divergence findings always come first.
- **Asking for deferred work as if it were missing:** mobile, pinned topics,
  the left sidebar, dropped streams or reconnect UI, and the N-features the
  plan lists under "Later" are not findings. A chunk that *builds* one
  unasked is scope creep: a Low, or a Med if it costs review time.
- **Inventing features the old app never had:** a "new messages" pill, unread
  counts, drafts or grouping (catalog, "Not present in the old app"). If the
  chunk adds one, that's a divergence.
- **Reviewing against the catalog alone:** it summarises, so open the code.
- **Changing the code:** you report; the builder fixes.

## Per-step checklists

Each step's checklist is on top of passes 1–3. The old sources are given at
the catalog's commits.

**1. Browse, the topic page, the transcript**
- **Browse has no old page.** Its old counterparts are the left sidebar's
  Conversations and Sessions lists (js/chat_left_sidebar.js:242-292,
  zs/chat_page.zig:108-170) and the top bar (zs/chat_chrome.zig:88-93,
  "Chat · Docs · Recent · Images · Code"). Compare the order (DMs then
  channels, topics sorted alphabetically) and the empty state ("No sessions
  yet"). Check that it lists only readable topics.
- **The topic page:** server-rendered, with live fragments. Check that the
  page and the stream are 404 for non-members.
- **The viewer is on the page** (old `data-me`, js/chat.js:301), and escaped.
- **Stick to the bottom only when caught up**, with caught-up read *before*
  the append (js/chat.js:308-316, js/middle_pane.js:88-93). The old
  `scrollIntoView` on every message (app/Pages.roc:748) must be gone.
- **The live test:** no backlog marker, so the catalog's rule is "id > the
  largest rendered". Check that the first connect's resend doesn't yank or
  duplicate.
- **The two-pane frame:** the right pane exists and is empty;
  js/chat_right_sidebar.js:46-57 is the shape.

**2. Compose and Send**
- **The open/close states:**
  - closed is the starting state;
  - the button reads "Open compose box";
  - `c` opens it;
  - Esc closes only when the box is empty;
  - focus goes to the textarea on open and to the feed on close
    (js/chat_compose.js:260-337, js/chat.js:371-372).
- **Keys:** Ctrl/⌘-Enter sends and plain Enter is a newline. The current
  `/chat/<id>` page does the opposite (app/Pages.roc:763-765); see "For
  Steve" below.
- **While pending:**
  - a blank send does nothing;
  - the textarea and every button are disabled;
  - "Sending…" shows in the muted colour;
  - a timer of 3000 ms (js/chat_compose.js:80-95).
- **Failure:**
  - the modal reads verbatim "The host may be down. Please retry your send."
    and keeps the text;
  - closing it refocuses the textarea (js/chat_compose.js:63-79);
  - a server refusal shows its own text. This is a plan-justified divergence:
    the old app never showed it.
- **Success:** the box is cleared, re-enabled and refocused, and compose stays
  open (js/chat_compose.js:332-337). The old "✓ your message was sent to <id>"
  strip (js/chat.js:317-337) is missing from the plan: the report must say
  whether it was dropped and why.
- **The hint line,** less upload and emoji (js/chat_compose.js:284), and the
  Send button (js/chat_compose.js:267-271).

**3. The transcript, styled**
- **Tokens:** js/colors.js:294-369 near verbatim; theme dark by default under
  `localStorage['chat-theme']`, set before first paint (zs/chat_chrome.zig:147);
  the toggle 🌙/☀️ (js/chat_theme.js:437-462).
- **Bubbles** (js/message.js:67-132):
  - margins, padding, radius and `max-width:88%`;
  - mine on the right, theirs on the left;
  - no grouping;
  - the meta line `#<n> name · time` at 11px, muted;
  - the time as "Jan 2 · 3:04 PM" in the viewer's zone (js/message.js:158-165).
- **Markdown CSS:** `a.msg-ref`, `pre`, `pre.chat-quote`, `img` max 320px,
  and `video` (js/message.js:88-115).
- **The empty state,** verbatim: "No messages yet. Say hello 👋"
  (js/chat.js:213-219).
- **The column:** ≤600px, the history card (js/middle_pane.js:43-71).

**4. Recent**
- Read js/recent.js whole, plus zs/recent.zig and zs/recent_feed.zig. The
  catalog is one line (N13).
- **Compare:**
  - what an item shows and its wording;
  - the order;
  - the "3 min ago" ages and their 20 s repaint (js/recent.js:98);
  - doc activity (deferred; it should be stated);
  - the stream (js/recent.js:241);
  - the empty state;
  - where its link sits in the top bar.
- **Who sees what:** only what the viewer can read, on the page and in the
  stream.

**5. Selection, keys, help**
- **Navigation:** arrows, Home/End and PgUp/PgDn, with the edge jump
  (js/message_view.js:337-383), and no j/k.
- **Scroll selects** (:292-303), with the 150 ms suppression (:265-270), and
  click selects in the capture phase (:328-333). The ring is
  `0 0 0 2px #ffcf3a` (:199). The hash is `#msg-` after 700 ms (js/chat.js:196-202).
- **The filter** (js/chat_help.js:192-201): a key that needs a selection,
  pressed without one, does nothing and doesn't `preventDefault` (:145-157).
- **The registry:**
  - it renders the panel, titled "Keyboard", with button rows (:160-178);
  - the order is alphabetical, then `/ : +`;
  - aliases are hidden;
  - the panel shows only while compose is closed (:190);
  - it refuses a duplicate at load.

**6. q and e** (each with its server-drawn link)
- **q:**
  - the text is `In MSG_<ref> I said|you said:\n~~~ quote\n…\n~~~\n\n`,
    inserted at the caret;
  - the fence is one tilde longer than any inside (js/chat.js:75-90);
  - the aliases `r` and `>` are kept (js/chat_help.js:185-186);
  - it's ignored while pending;
  - the meta-line label is "quote-reply".
- **e:**
  - it works on mine only, and is ignored while pending;
  - the text is `Edit of MSG_<ref>\n\n<markdown>`, with the caret after the
    prefix (js/chat.js:94-100, js/chat_compose.js:101-104);
  - the supersession applies only to the same author;
  - the original shows "Edited in MSG_<new>" plus an "original" `<details>`
    (js/message.js:262-276), drawn by the server.
- Check that the ref format is the server's (app/MessageRef.roc), not rebuilt
  in the JS.

**7. s, d, t, reactions, search** (each with its route first)
- **s:**
  - the popup pre-filled "read later"; Enter saves, Esc or Cancel dismisses;
  - the strip text, and "✓ saved" in green;
  - "Save failed" (js/chat.js:122-152, js/chat_save_popup.js:110-190).
- **d:** a .tar.gz of the transcript plus images, sent as an attachment
  (zs/chat_download.zig). **t:** the raw markdown in a new tab
  (zs/chat.zig:300-302). Both have links as the plan requires; the old ones
  had none.
- **Reactions:**
  - `+` toggles 👍 and `:` opens the picker;
  - clicking a chip toggles it;
  - not optimistic; "Reaction failed" on failure (js/chat_reactions.js,
    js/message.js:280-294);
  - the live fragment is server-drawn.
- **Search:**
  - two phases, a 150 ms debounce;
  - each status's text (js/chat_search.js:85-101);
  - Esc steps back;
  - stale answers dropped;
  - the minimum word length counted in bytes;
  - access-filtered results.

**Later items:** check them only when a chunk claims one. Mobile breaks at
768px with a 16px textarea (js/viewport.js:22, js/chat_responsive.js);
N7 `/chat/msg/<id>`; N8 "That message is no longer here."; the N4–N6 popups;
N9 emoji; N10 uploads (5 min, the progress text); N1 the favicon `#8a2be2`;
the left sidebar is re-thought, so its divergences are expected and must be
stated, not ported.

## For Steve: plan gaps a reviewer should flag, not blame on the builder

- **mine versus theirs in a broadcast fragment:** one fragment goes to every
  subscriber, so either the server renders per subscriber or the JS sets the
  class from `data-me`. Which one?
- **The time in the viewer's zone:** the server doesn't know the zone, so
  either the JS localizes a server-rendered time or the time is shown in UTC.
- **The browser's topic stream:** a new route, or a variant of the JSON one
  (`/channels/.../stream`)?
- **Compose on `/chat/<id>`:** does step 2 flip Enter to Ctrl/⌘-Enter there
  too?
- **The "sent" strip and N2:** in scope for step 2 or not?
- **Browse:** it has no old page to match, and its top-bar entry replaces the
  old "Chat".
- **Verify** has no syntax or lint check for roc-chat's own `js/`.
