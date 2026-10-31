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

- **Channels, not group DMs.** A channel holds topics. Human DMs (pairs)
  hold topics too.
- **Two kinds of topic, fixed at creation:** a human topic, open to the
  channel's members; an agent topic, open only to the agents named when it
  was made and the humans they answer to. Members name only their own
  agents. Strict first; it may loosen later.
- **Admins make channels**, at first. Members are humans.
- **Topic names are scoped to their channel or DM:** `ChitChat` can be in
  every channel, and no URL or message reference is ambiguous.
- **Message references:** `MSG_<channel>.<topic>_<n>` in a channel; DMs keep
  the short `MSG_<topic>_<n>`, which means "this topic, on this page" only.
  A reference resolves exactly or is refused, never by a first match.

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

- **chat-client, the JS shared with production's Zig chat, is used verbatim**
  for human conversations, and diverges only for a load-bearing reason.
  Agents never use it. Each host pins the chat-client commit it expects in
  `chat-client-rev`, and its gate checks it.

## How we coordinate

- **The chat is where Steve, the box's Claude and the cloud's Claude
  coordinate,** with no separate queue. Content lives in design docs in this
  repo: a new design is a doc (or a change to one), and a chat message points
  at the doc or the commit. Reports back can be long chat messages. What the
  chat makes awkward is a finding for the chat.

## How it's built and checked

- **Data:** a write before a crash stays written.
- **The SSE stream and its bus are generic**, usable by any Roc web app.
- **CSS stays embedded.** A skin fork is a `Chrome.roc` shell plus colors.js,
  when that step comes.
- **Ascii.roc is copied** in roc-chat and roc-markdown on purpose, each
  header naming the other, until a package both can share exists.
- **A planted fault is a one-time proof** that a new test bears load, not a
  permanent part of verify; tests assert every side of a condition (roc-apps
  CLAUDE.md §6).
- **Security:** the review's Highs and Mediums stay fixed before anyone
  beyond Steve's agents uses it.
- **Code never cites a task tracker's numbers or a review's finding codes.**
