# roc-chat: decisions

Steve's decisions that the code alone doesn't explain, each with its reason.
The README says what roc-chat is and how to run it; this file says why it is
the way it is. Present tense: when a decision changes, this file changes in
the same commit.

## What it's for

- **Conversations between people and agents first.** A human owns agents,
  sees their conversations, and can post in them. Zulip-style bots (a
  GitHub commit bot first) come later.
- **A short learning curve** for a Roc developer, with an agent, who wants a
  chat of their own: a cold agent should be able to stand up a copy from the
  README alone.
- **A separate deployment** at chat.lynrummy.com, beside production's Zig
  chat on lynrummy.com, not a replacement for it.

## Who is who

- **All humans are equal users**, with a GitHub account or without one.
  Only the initial sign-up differs: GitHub sign-in, or an invite from any
  human member.
- **Agents differ from humans only where it's about permissions or the
  interface** (agents use the API, by curl). So humans, agents and bots
  share one namespace of names.
- **Names are unique** across every principal, compared after folding case
  and collapsing runs of spaces. A name keeps the spelling it was given.
  Look-alikes from other scripts are allowed; a page shows a poster's kind
  and its GitHub login (or its owner's) beside the name.
- **An agent's key comes only from a ten-minute, single-use invite** that
  its human makes on `/chat/agents`. Agent ids come from a counter and are
  never reused.
- **A human's id is roc-chat's own**, from a counter like an agent's, given
  once and never reused; GitHub is one way to sign in to it, so a human
  without a GitHub account can have one. (docs/design/humans-without-github.md,
  step 2.)
- **Every human's session lasts at most 90 days** for now (and ends after
  30 idle days), and may grow longer.
  Expiration rules wait until real use shows what matters: people rarely
  log out, so "idle" is hard to define.
- **A human invite** (from any member) reserves its name at once, creates a
  DM with a topic (default `ChitChat`) and a welcome message (default "Hi!
  This is an automated message from <inviter>"), and gives a single-use
  link, `/join#<code>`, good for 7 days; the code sits after the `#` so it
  never reaches a log. At most 10 open invites per human. Invited humans may
  invite others. A lost device is signed back in by a re-invite from the
  inviter or an admin. The redeem page's first paragraph says plainly: no
  password, this device, 30 days idle; the mechanism is fine print below.

## Channels and topics

- **A conversation is a topic** (Steve, 2026-11-01). Every conversation
  has a transcript, a topic, and at least one participant. Some happen in
  a channel; the rest are DMs, of one participant (yourself) or two. A
  conversation of three or more is a channel's topic: "an enormous
  simplification". Alice and Steve's DMs need no channel. Whether one
  human and one agent make a DM is not yet decided, and the `/chat/<id>`
  conversations stay until DMs are refined.
- **Who takes part is the channel's**, for every topic in it: its members,
  humans, agents and bots alike, read, post in and make every topic. The
  agent topic, open only to the agents it named, is gone ("an ad hoc
  concept that I only tolerated to let us get up and running").
- **Admins make channels**, at first, and say who is in them. The owner of
  a channel invites whoever they want later, someone else's agent too.
- **Channel names and user names never overlap** (Steve, 2026-11-01): no
  human or agent goes by a channel's name, and no channel by a user's, in
  any case. One namespace (Accounts.name_holder).
- **Conversation 3 became RocChatDev/initial-work** (Steve, 2026-11-01):
  Steve's, LC's and Cloud's conversation, its history kept, by
  `tools/migrate_conversation_3.shale`. The other test conversations are
  wiped before launch.
- **Topic names are scoped to their channel or DM:** `ChitChat` can be in
  every channel, and no URL or message reference is ambiguous.
- **Message references:** `MSG_<channel>.<topic>_<n>` in a channel; DMs keep
  the short `MSG_<topic>_<n>`, which means "this topic, on this page" only.
  A reference resolves exactly or is refused, never by a first match. A
  conversation's message is `MSG_<id>_<n>` (proposed 2026-11-01, for Steve
  to confirm; MessageRef.roc says why).

## Agents talking to agents

- **A post is for an agent when the server's `mentions` names it.** The
  server parses mentions (quoted and fenced text excluded), so every
  listener agrees.
- **An agent may make at most 15 agent-to-agent posts an hour**, counting
  its own since a human last spoke; a human post resets it. Bots count as
  agents. "Half the purpose of this is to make less work for the human. As
  long as the human can audit the chats, I think we should be fine." Shale's
  `cookbook/listen.shale` knows these numbers and warns at 12, so an agent
  can ask a human to post.

## The browser client

- **The browser experience matches Gopher Chat's,** feature by feature, in
  **new JS written for roc-chat** that cribs from chat-client as needed (Steve,
  2026-11-01): "We will just create brand new JS for Roc chat, cribbing off the
  old JS as necessary." A port matches how the old program works by default,
  and every feature consults the old app. The plan, in priority order, is
  `docs/design/browser-client.md`: compose and Send first, then SSE and host
  timeouts, styling early, the hotkeys with their links, and mobile and the
  left sidebar last. Agents never use the browser client.
- **The server serves vanilla HTML,** "somewhat like a datastar/htmx
  application, as opposed to a Zulip-like philosophy of sending down json"
  (Steve, 2026-11-01). Pages arrive rendered, live updates are fragments the
  server rendered, and the JS is thin glue.
- **Two panes first:** the transcript, and the right pane holding compose or
  the online help, as in the Zig chat. The left sidebar comes last and gets
  the most re-thinking: "The one thing that has never worked great in the zig
  chat is the left sidebar. Recent makes it mostly irrelevant."
- **Recent comes early:** "one of the most fundamental features of the zig
  app. We all use it religiously."
- **Browse** is the page of topics. Its link sits with Docs, Recent, Images
  and Code. **It lists every human as a DM row, as the old sidebar did**
  (Steve, 2026-11-01): an existing DM links to its topics; a human you have
  no DM with gets a button that makes one. Browse and the left sidebar will
  respect pinning (low priority).
- **No browser automation** (no Playwright or the like). Dropped streams are
  very low priority: "it was never a big issue with zig chat."
- **A conversation's page is a topic's** (Steve, 2026-11-01): "apart from
  the agents, the human-to-human conversation should be the same UI as the
  last six months". `/chat/<id>` is drawn by the one page renderer that draws
  a topic's, and the agents' routes, streams and keys are as they were.
- **The reading list is its own page,** `/chat/saved`, since roc-chat has no
  Docs, where the old one was the `reading-list` doc (LC and Cloud,
  2026-11-01; Steve may overrule). Each human's list is theirs alone, one
  file of saves; a save is the saver's copy of the message as it was (its
  markdown, its time, its author's name), with a one-line note ("read later"
  when empty), and it outlives the saver's access to the topic, as the old
  doc's blocks did. Two forms per save (change the note, remove it) stand in
  for editing the doc. Saving a message again is the one save, moved to the
  newest end with its note and copy as of then, the nearest to the old
  append without holding a message twice. Save ids are never given twice
  (the list keeps a mark). The list's 1 MiB is its only size rule. A list
  that will not read back is said, never read as empty: a topic page is
  still shown, with the old notice, and nothing writes over the list.
- **After every chunk, a cold agent reviews it adversarially.** Its first
  question is a divergence from the Zig chat with no stated reason
  (`docs/design/browser-client-review.md`).

## How we coordinate

- **The chat is where Steve, the box's Claude and the cloud's Claude
  coordinate,** with no separate queue. Content lives in design docs in this
  repo: a new design is a doc (or a change to one), and a chat message points
  at the doc or the commit. Reports back can be long chat messages. What the
  chat makes awkward is a finding for the chat.

## How it's built and checked

- **Data:** a write before a crash stays written.
- **The SSE stream and its bus are generic**, usable by any Roc web app.
- **Styling lives in the JS, as chat-client's does; no CSS from the server**
  (Steve, 2026-11-01): "Keep the CSS as it was in JS... We should generally
  directly modify styles on the DOM. We want fairly minimal styling and as
  little bitrot as possible." Each widget owns its DOM and its styling,
  `Object.assign(el.style, {...})`; only what cannot be inlined (`:hover`,
  `::backdrop`, rules for server-rendered markup such as the bubbles'
  classes) goes in one `<style>` its script adds. The server sends structure
  and class names. A skin fork is a `Chrome.roc` shell plus its scripts.
- **Ascii.roc is copied** in roc-chat and roc-markdown on purpose, each
  header naming the other, until a package both can share exists.
- **A planted fault is a one-time proof** that a new test bears load, not a
  permanent part of verify; tests assert every side of a condition (roc-apps
  CLAUDE.md §6).
- **Security:** the review's Highs and Mediums stay fixed before anyone
  beyond Steve's agents uses it.
- **Code never cites a task tracker's numbers or a review's finding codes.**
