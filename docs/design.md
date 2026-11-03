# gopher-roc: the design from first principles

The answers from our listening session on 2026-11-02, gathered in one place for you to correct. Where you gave words, these are your words. Anything marked **open** we haven't settled yet.

## Who it is for

- **A small group of humans and their agents.** Agents do real work and report back where everyone can see it.
- **An agent's report lands in the conversation where the work was asked for.**
- An agent mostly works for its owner, but anyone can ask it things. For now, assume Steve is the only person who works with agents.

## The nouns

### Message

- **A message is Author + DateTime + MarkdownContent, plus the id its conversation gives it.**
- A **MessagePayload** is Author + MarkdownContent, as the writer sent it. With its DateTime it is an unnumbered message (`Message.Unnumbered`): every part checked, waiting only for the Id its conversation gives it. The full Message, with its Id and DateTime, is made as early as possible.
- **Content is markdown text, and may include images.** The flavour is whatever our markdown implementation accepts. Images are opaque to a message: a message with an image tag is valid even when the image can't be reached.
- **Messages are immutable.** An edit is a new message that edits an earlier one. When rendered, a RenderedMessage can be `IsEdited`, or `EditsPriorMessage(MessageId)`.
- **A message doesn't care about eligibility.** "Steve said hello on Tuesday" is a message. Whether Steve may say that in a given place is up to the conversation, not the message.

### Author and User

- **A User is a human or an agent whose identity has already been checked.** Identity is checked at the edge of the system. Messier things like `UnauthenticatedUser` stay at that edge, and everything inside deals in Users.
- **An Author is a User in the role of writing a message.** Pass around small views such as `AuthorInfo` (name and id). A conversation never sees a user's GitHub login, last sign-in or preferences.
- **Names are permanent and case-sensitive.** Someone who signs up as "Steve Howell" is never called "steve howell" by the system. Names are unique regardless of case, so nobody else can be "sTeVe hoWEll". Inside the system, a form like `steve-howell-1` is fine.
- **Every user also has a unique id, and Steve is always id 1.** Ids are handy in URLs. Wherever the name and the id both appear, the system checks that they match.
- **Humans, agents and channels share one namespace.**

### Conversation

- **A conversation is a series of messages written by authors eligible to take part in it.**
- **Ids are sequential within a conversation, so a conversation's order is its id order.**
- **Times are UTC and never go backwards within a conversation.** A message's time is never earlier than the latest message's in its conversation. Equal times are allowed, because times are to the second and two messages can share one. Localising times for display can make two shown times look out of order once a year, when the clocks go back (in the US on 2026-11-01, 1:59 a.m. was followed by 1:00 a.m.), and that is expected.
- **A conversation can stand alone.** You can hand one over and get a RenderedConversation back, without knowing whether it's a channel's or a DM's. That is also how it gets tested.
- **Every conversation has a topic name, which is mandatory.** It also has a unique name on disk and a unique URL for those allowed to read it. Clients, and sometimes the server, cut the friction of naming a topic by suggesting "general" or "ChitChat".
- **A topic name is unique only within its channel or DM.**
- **Long conversations:** a reader gets the whole conversation straight away, with no paging. We don't cater for long conversations; we make them easy to archive or turn into docs. They tend to die off on their own, and Steve only steps in on topics like "general".

### Channel and DM

- **A channel is a named set of members, plus its topics (its conversations).** It may later track more, such as when it was made.
- **A DM is a channel whose members are exactly one or two humans.** One human is your own DM with yourself.
- **DMs are for humans only, for now.** Agents take part only in channels. A channel holding just an agent and its owner is still a named channel.
- **Only an admin creates a channel and chooses its members, for now.** This is very likely to change.
- **A DM is named by its pair of user ids, in numeric order:** `7_11`, never `11_7`, and one human alone is `5_5`, as in the previous app. A channel's name starts with a letter and holds no `_`, so the two never collide.
- **A DM begins with its first message.** Later, an invite's redemption might start one automatically, for example with a "hi" from the inviter.

### Reaction

- **Reactions are not messages; they are their own thing**, drawn beneath the message they belong to.
- **A reaction is one author, one emoji and one message.** A message has zero or more reactions, and zero is the usual case. Two authors can react with the same emoji, and one author can react with several emojis. An author can't react twice with the same emoji, and clicking it again removes it.
- **No history:** only the current set is kept.
- Agents never react, but there's no need to enforce that.

### Images

- **An uploaded image belongs to one conversation**, and exactly that conversation's readers can see it.
- **The HTML gives an image's dimensions** in the native HTML way.

### Admin

- **Steve is the only admin for now.** There may be more later, but always all-or-nothing: no levels of admin inside the chat.

### Agent

- **Every agent has exactly one owner, always a human.** The owner creates the agent in the chat and gives it a key.
- Nothing proves an agent is an LLM: a Python bot holding a key would look the same. We have no use for old-style chatbots.
- **Agents use API keys**, so they never drive a browser or a complicated HTTP exchange. They can read the same HTML humans see. Raw markdown with author, id and timestamp as JSON is possible, but no agent has asked for it yet.
- **No mentions as a mechanism.** An agent listens to every message in its channels and works out what applies to it, while also understanding the `@CC` convention.
- **No hop limit.** Agents are not prone to replying to each other forever. Eventually there will be one general rate limit, the same for humans and agents, against abuse.

## Delivery

- **When a message lands, every member of the channel who is signed in gets it straight away.** There are no notifications and no tracking of unread messages.
- **Recent** has one tile per conversation, newest first, by each conversation's latest message.
- **A live message arrives as the same HTML a full reload would show.**
- **If a browser's connection drops, it catches up as the Zig chat's did:** the browser reconnects by itself and the server sends only the messages it missed. If the stream dies for good, the page reloads itself; if it dies again within a minute, the page shows a notice instead (Steve, 2026-11-03).
- **An agent holds one connection carrying all of its channels.** If that's awkward to build, that's a design smell. When the connection drops, the agent catches up by asking for **everything since a timestamp** (message ids would also work).
- How a browser's connections are split is my call, checked against what the Zig chat does. New messages matter more than, say, presence, and the two can run at different rates.
- **Presence:** eventually, as lean as the Zig chat's.

## Storage: the file system is the database

- **One folder per conversation, with its messages appended.** For our scale, the whole conversation is **one human-readable file**, readable with `cat`, author and timestamp included:

```
-------------
MSG_apoorva-autumn_13
from: Steve
date: 2026-09-03T19:11:32Z

apoorva@zulip.com ok?

-------------
MSG_apoorva-autumn_14
from: apoorva
date: 2026-09-03T19:12:28Z

apoorvavpendse@gmail.com would be better
```

- **Markdown is stored exactly as written.** A body line that is exactly the separator `-------------` is stored as `\-------------` and turned back on reading. This escaping happens at the chat's edge, outside the markdown processor. When a message looks hostile, refuse it.
- **Reactions:** one file per conversation, beside its messages, in the Zig chat's JSONL format.
- **Users:** one human-readable file per user, easy to find and named by name and id (e.g. `apoorva-2.info`). A user may have several files, so that high-stakes data (passwords) is kept apart from low-stakes data (preferences).
- **Feel like REST over the file system.** A database isn't ruled out in the long run.
- **Anything that can become a URL or a file name is strictly named**, which covers channels and topics. Escaping is allowed but used pragmatically: our users write English, which fits in ASCII. Message text can be any unicode, emoji included.

## Pages

- **The server renders HTML.** JavaScript adds only live updates and styling. The server sends very little styling, and the HTML carries enough for a client to style it well.
- **The layout is the Zig chat's: three panes.** A left sidebar, the messages, and the compose box with keyboard help. Mobile comes last.

## Sign-in

- **GitHub sign-in, or an invite link for people without GitHub.**

## Scope

- **The Zig chat is a superset of what we need.** Dropped: pinning topics, back/forward navigation, Docs, image search and code search.
- **The Zig chat keeps serving human-to-human chat**, so gopher-roc's first job is agents.
- **First milestone:** the three-way conversation roc-chat had, between Steve, LC and CC. The agents join through properly secure invites, and Steve explicitly creates a channel that explicitly includes them.

## How it gets built

- **A new repository, `gopher-roc`** (a code name to rename later). Crib from roc-chat as needed, but truly build up from nothing, **gates included**.
- **Roc on a Zig host**, with as much Roc as possible. Zig's HTTP server should be the main Zig piece.
- **The pure core comes first**, with no DM or channel meaning, and gets rendered early to dogfood it. For example, a Conversation module with fake content, served from a Python web server or the essay surface.

## Open

- **Eligibility:** who may read and write a conversation, beyond channel membership and an owner's limits on their agents. You deferred this on purpose.
- **Rate limiting:** one mechanism for humans and agents.
- **How a browser's live connections are split.** My call, after reading the Zig chat.
- **What exactly invites, keys and sessions look like on disk.** That is yours to decide when we get there.
