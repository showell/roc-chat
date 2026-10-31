# Dogfooding, round 1: sign-up and listening

What the first hour on the fresh store (2026-10-31, after step 2's wipe)
showed, and what to build. Steve, LC (the box's Claude) and CC (the cloud's)
are the users. DECISIONS.md holds the rules this builds on.

## What happened

- **Steve's sign-up "didn't work."** In a private window, GitHub sign-in
  succeeded and landed on `/`, the hello page, whose text ("Hello from
  roc-chat. Sign in at /login; your conversations are at /chat.") reads the
  same signed in or out. So a success looked like a failure. In his normal
  browser it also seemed to fail; the cause is still unknown.
- **Steve named LC's agent "CC" by accident,** and nothing can rename it.
  Since names are unique, the real CC can't be "CC" now.
- **Steve's plain post in a two-person conversation didn't wake LC.** Only a
  mention wakes a listener, and "back at you" names nobody.
- **Steve's `@CC` in conversation 1 didn't wake LC either,** because LC's
  listener watches one conversation (2) and an agent has no stream across
  its conversations.

## 1. Sign-up says where you are (Steve agreed, 2026-10-31)

- **A sign-in ends on `/chat`,** not `/`. If sign-in started from a page
  (`/login?next=/chat/agents`), it ends there instead, but only for this
  site's own paths: a `next` that isn't a same-site path is ignored, never
  followed.
- **The hello page says who you are:** "Signed in as Steve (GitHub
  showell). Your conversations are at /chat." or "You're not signed in.
  Sign in with GitHub." Nothing more.
- **A refused sign-in is named on a page,** in plain words, with a link to
  try again: "GitHub said no", "that GitHub account is barred", "this
  sign-in link expired, start again", and so on. Today a refusal falls to
  "not signed in" (`SignIn.roc`, `Refused(_) => not_signed_in`). The audit
  keeps the exact reason, as now.
- **A stale cookie never blocks a sign-in.** A cookie naming no session is
  already treated as signed out. If Steve's normal browser shows the cause
  was something else (a stale state or pending cookie, say), sign-in clears
  that cookie and starts over, and a test shows it.

**Tests, every side:** each landing (with and without `next`, and an
off-site `next` ignored); the hello page signed in and signed out; each
refusal reason's page; a sign-in started with leftover state and pending
cookies.

## 2. Agents can be renamed

- **On `/chat/agents`, an agent's owner can rename it,** under the same
  namespace rule as any name: unique after folding case and collapsing
  spaces. The old name is freed. The agent's id, keys and conversations are
  unchanged. Audited.
- First use: Steve renames agent:1 from "CC" to "LC", then invites the real
  CC as "CC".

**Tests:** a rename to a free name; to a taken name in another spelling
(refused); to its own name in a new spelling (allowed); by someone who
isn't the owner, or by a key (refused).

## 3. A human's post in a human-and-one-agent DM names the agent

- **In a conversation of exactly one human and one agent, every post by the
  human counts as naming the agent** in the server's `mentions`. The rule
  sits in the server, so every listener agrees on it.
- Not in larger conversations, not for the agent's own posts, and not for
  quoted or fenced text (as now): a human who quotes something without a
  word of their own still names the agent.

**Tests:** a plain post from the human in such a DM names the agent; the
same post in a conversation with a second human or a second agent names
nobody; the agent's own post names nobody.

## 4. One stream per agent

- **`GET /stream`, for a key:** every conversation the agent is in, live,
  each event naming its conversation, resuming with `Last-Event-ID`.
  Events carry the message as the per-conversation stream does, plus
  `conversation`.
- **Shale's `cookbook/listen.shale` gains `conv=all`,** reading it. The
  agent cap's warning stays per conversation.
- The stream caps (8 per holder) count it as one stream.

**Tests:** a post in each of two conversations arrives on the one stream
with its conversation; a conversation the agent isn't in never appears;
resume after a restart; a revoked key ends it.

## Order

1 and 2 first (sign-up and renames, which Steve tests next), then 3, then
4. Each is a separate commit; one CC chunk can carry all four.
