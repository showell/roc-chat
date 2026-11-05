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
- **Only an admin creates a channel and chooses its members, for now, by their own session and never by an API key (roc-chat's rule).** This is very likely to change. The one exception: a new human's account starts in the default channel, `general` (`Channels.default_name`), which the first start makes (Steve, 2026-11-05). The admin may remove them from it as from any channel.
- **A DM is named by its pair of user ids, in numeric order:** `7_11`, never `11_7`, and one human alone is `5_5`, as in the previous app. A channel's name starts with a letter and holds no `_`, so the two never collide.
- **A DM begins with its first message.** A new human's first DM begins as their account is made: the owner's welcome (below).
- **A new human is welcomed in a DM with the chat's owner (Steve, 2026-11-05).** When a human's account is made, by an invite or by GitHub sign-up, the DM between them and the owner starts under the topic `ChitChat`, with one message from the owner: "Welcome! If Steve is not here, you can still send a message, and he will reply soon.", the name looked up (`app/Welcome.roc`). It goes in the transcript like any other. The DM is named by ids and the message names only the owner, so an invited human's new name changes neither.

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
- **The chat's owner is the first human and the admin.** `UserId.chat_owner` is the id's one home and `Directory.chat_owner` the human's, whose name is read from their file.

### Agent

- **Every agent has exactly one owner, always a human.** The owner creates the agent in the chat and gives it a key.
- Nothing proves an agent is an LLM: a Python bot holding a key would look the same. We have no use for old-style chatbots.
- **Agents use API keys**, so they never drive a browser or a complicated HTTP exchange. They can read the same HTML humans see. Raw markdown with author, id and timestamp as JSON is possible, but no agent has asked for it yet.
- **No mentions as a mechanism.** An agent listens to every message in its channels and works out what applies to it, while also understanding the `@CC` convention.
- **No hop limit.** Agents are not prone to replying to each other forever. Eventually there will be one general rate limit, the same for humans and agents, against abuse.
- **How an agent gets its key (roc-chat's mechanism).** Its owner, signed in, makes it at `/agents` and invites it. The invite's one-time code is shown once, lives ten minutes and redeems once: the agent posts `code=<code>` to `/agents/redeem` and is answered with its key on one line of text. The key is the agent's id, `-`, and 64 hex digits (32 random bytes from the host), sent as `Authorization: Bearer <key>`, as the Zig chat's keys were. Only its hash is kept. A key lives a year, its owner can list and revoke it at `/agents`, and its scope can turn off its reading or its posting. A key never makes an agent, invites, redeems, or lists or revokes keys.
- **What an agent does with its key.** It posts with the same form a browser posts (`markdown=`, to a conversation's URL, a 303; or to its `/send`, a 201 with the message's HTML, or a refusal in one line of text). It reads a conversation's transcript as plain text at `<conversation>/raw`. It listens at `/agents/stream`: one connection carrying every message of every channel it is a member of, each event one line of JSON (`conversation`, `id`, `from`, `date`, `markdown`); with `?since=<date>` it first sends everything since that date.
- **Who may read and post where (roc-chat's rule, for your review).** A channel's members, humans and agents alike, read and post in each of its conversations; a DM's one or two humans in theirs; nobody else, the admin included, until the admin adds themself.

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
- **Users:** a folder per user, named by the user's numeric id, holding one small human-readable file per fact, as the Zig chat keeps them. High-stakes facts, who a user is and how they prove it, live under the auth root, `auth/`; lower-stakes ones (the upload total, later preferences) under `users/`, as the Zig chat keeps its account store under one root and each user's other state under another. Every file below holds one fact, written bare with no line end unless it says so; a reader takes ASCII spaces, tabs and line ends off both ends (`FactFile`), so a file edited by hand still reads.

  | File | Holds | From |
  |---|---|---|
  | `auth/next-id.txt` | the next user id's decimal digits and a line end, `3\n`; `65536\n` once every id is taken | the Zig chat's counter |
  | `auth/<id>/name` | the user's name, exactly as given, UTF-8; rewritten whole, atomically, when an invited human joins under another name, and never after; a human who signs up with GitHub chooses it once | the Zig chat |
  | `auth/<id>/owner` | an agent's owner's id, its digits; a human has no `owner` file | roc-chat's fact |
  | `auth/<id>/password` | a human's password's bcrypt hash, 60 bytes, `$2b$10$` and 53 more (a `$2a$` or `$2y$` hash reads the same, and a cost from 10 to 14; any other scheme or cost is no hash), with a line end or none; never the password. The server's owner writes Steve's on the server's machine, `gopher-roc hash-password > auth/<id>/password`, readable by them alone; the server writes an invited human's, atomically, when they redeem an invite and choose their password (the host's bcrypt at cost 10), and again at each later redemption. A human with none can't sign in, and rewriting or removing it ends every session of theirs (so does each redemption, all but the one it starts); an agent has none | the Zig chat's `password` |
  | `auth/<human>/github-id` | the numeric id of the GitHub account that may sign in as this human, its digits. The server writes it when a human signs up with GitHub, or when a human who has an account already, such as the owner, links GitHub to it, from `/agents` or by going through GitHub signed in. One GitHub id reaches one account, and one account holds one id: signing in with GitHub makes a new account only for a browser signed in as no one. The id, not the login, because GitHub lets a login be renamed and a freed one be taken (`https://api.github.com/users/<login>` says an account's id). Removing it ends every session of theirs that was signed over `github-session-secret` | roc-chat's binding of an account to a GitHub id |
  | `auth/<human>/github-session-secret` | 32 random bytes as 64 hex digits, which the server writes at the human's first GitHub sign-in, and anew when they link GitHub. Their sessions are signed over it, under `.session-secret`, so it proves nothing to whoever reads it; it is what ends their sessions, as a GitHub human may have no password file to rewrite. Rewriting or removing it ends every session of theirs, the next GitHub sign-in making a new one if it is gone | gopher-roc's |
  | `auth/<agent>/keys/<n>/created`, `expires` | when the key was made, and when it stops admitting, in seconds since 1970, digits | roc-chat's facts |
  | `auth/<agent>/keys/<n>/state` | `active` or `revoked` | roc-chat's words |
  | `auth/<agent>/keys/<n>/read`, `post` | the key's scope: `everywhere` or `off` each | roc-chat's words |
  | `auth/<agent>/keys/<n>/hash` | the SHA-256 of the key's 32 secret bytes, 64 lowercase hex digits; never the secret | roc-chat's fact |
  | `auth/<agent>/invites/<n>/created`, `expires`, `read`, `post`, `hash` | as a key's: the invite's own expiry, the scope of the key it redeems to, the hash of its one-time code's 32 bytes | roc-chat's facts |
  | `auth/<agent>/invites/<n>/state` | `live`, `spent` or `revoked` | roc-chat's words |
  | `auth/<human>/inviter` | an invited human's inviter's id, its digits; the founder, a human who signed up with GitHub, and a human the server's owner made by hand, have none, and no one invites them again. Written before `name` | gopher-roc's (roc-chat kept it in its account record) |
  | `auth/<human>/human-invites/<n>/created`, `expires` | when the invite was made, and when it stops redeeming, seven days later, in seconds since 1970, digits | roc-chat's facts |
  | `auth/<human>/human-invites/<n>/state` | `live` or `spent` (there is no revoking a human invite yet) | roc-chat's words |
  | `auth/<human>/human-invites/<n>/by` | the id of the human who made it, its digits: the inviter, or the admin inviting them again. A human's open invites, those they made that are live and unexpired, are at most 10 | roc-chat's fact |
  | `auth/<human>/human-invites/<n>/hash` | the SHA-256 of the one-time code's 32 secret bytes, 64 lowercase hex digits; never the code | roc-chat's fact |
  | `chat/channel/<name>.channel` | the channel's members, one id a line, each with a line end; a blank line or one starting `#` is skipped | the Zig chat's `<name>.channel`, beside the channel's folder of topics |
  | `users/<id>/upload-bytes` | the user's lifetime upload total, digits | the Zig chat |
  | `.github-client-id`, `.github-client-secret` | the OAuth app's id and secret, which the server's owner writes, readable by them alone, as `.session-secret` must be. Neither there, and the chat offers no GitHub sign-in; one without the other stops the start. No file primitive reaches them, and the secret never reaches the Roc (docs/platform.md, "GitHub") | roc-chat's `client_id` and `client_secret` |
  | `.github-oauth-base`, `.github-api-base` | optional: where GitHub's pages and its API are, `https://github.com` and `https://api.github.com` when absent. The end to end names its fake GitHub here | roc-chat's `.github` |
  | `.session-secret` | the server's secret, which signs and checks every session: 32 random bytes as 64 lowercase hex digits (any 32 to 256 bytes are read), readable by its owner alone: the server refuses to start when its group or anyone else may read or write it. The host makes it once, at the server's first start on the folder, and holds it; its name starts with `.`, so no file primitive, and so no Roc, can read or write it. Removing it and starting the server again makes a new one and ends every session | the Zig chat's `_session_secret` |

  A key's or invite's number `<n>` counts 1, 2, 3 within its user's folder, and is never given twice, as nothing in an account's folder is removed, and no account is ever removed. A new human's welcome is written after the counter and before their account, so no account lacks one: a failure there spends an id and holds no name or GitHub id, and the same invite or sign-up tries again. A crash after it leaves a DM naming an id no account has, which no one can reach, as no id is given twice. An invited human's account is written after their welcome, `inviter` then `name`, then the default channel's members, and then their invite; a redemption writes the name the human chose, if it changed, then spends the invite (rewriting `state` alone), before it writes the password. A human who signs up with GitHub is written after their welcome, `github-id` then `name`, then the default channel's members, and then `github-session-secret` as their session starts. Members come after `name`, as a channel holding a member who is no user stops the chat reading its directory; a crash between the two leaves a human in no channel, whom the admin adds. A human linking GitHub has `github-session-secret` written whole, then `github-id`, so a link cut short binds no one. A record of several files is written a file at a time, each made once, `hash` last: a record cut short by a crash has no hash, so it admits no one. A revoke or a redemption rewrites `state` alone, atomically. An account is written `owner` first and `name` last, after the counter, so an id is never given twice and an agent is never read as a human. The first start writes Steve's `name`, `general.channel` holding `1`, and the counter last; a data folder holding accounts or channels and no counter is part of a chat, and the server refuses to start on it.

  The admin creates a channel at `/channels` and adds or removes its members, humans or agents, on its page, `/channels/<name>` (`app/ChannelMembers.roc`), which rewrites its `.channel` file whole, atomically; an admin may still edit the file by hand, as in the Zig chat. Removing a member never removes their account or their id. A secret never reaches the disk: a key's and an invite's are shown once and kept only as their hash, and a password only as its bcrypt hash.

  A session is not on disk: it is the cookie `__Host-gopher_auth`, whose value is the user's id in base64url (unpadded), a `.`, the second it was signed at in decimal, a `.`, and the HMAC-SHA256 under `.session-secret` of the id's digits, a line feed, that second, a line feed and what the human's sign-in files hold, in base64url. That is the hash their `password` file keeps (as its file holds it, the spaces and line ends at either end off), and, while they have a `github-id`, a line feed and the word their `github-session-secret` keeps; a human with no password has the line feed and the word alone. It is signed, never sent, so a session costs no storage and admits its human only while those files hold what it was signed over, however it began: a human with a password and GitHub has one set of sessions, and rewriting either file ends them all, as does their first GitHub sign-in, which writes `github-session-secret`, and linking GitHub, whose answer starts them a new session. It admits its human for a year from its second, and not at all when signed more than five minutes ahead of the clock; it is set `Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax`. Signing out clears the browser's cookie; a copy kept elsewhere stays good until its year is out, its human's password file is rewritten or removed, or the secret is replaced. **User ids are never reused, and users are never deleted**: a session names its human by id alone, so an id given to someone new would hand them every session of the old one's. The counter only rises, and no account folder is removed.
- **Feel like REST over the file system.** A database isn't ruled out in the long run.
- **Anything that can become a URL or a file name is strictly named**, which covers channels and topics. Escaping is allowed but used pragmatically: our users write English, which fits in ASCII. Message text can be any unicode, emoji included.

## Pages

- **The server renders HTML.** JavaScript adds live updates, the compose box's behaviour, and all the styling: the server sends no CSS, and the HTML carries enough for the scripts to style it well. Without JavaScript the page is plain HTML, still readable, and the form still posts.
- **The layout is the Zig chat's: three panes.** A left sidebar, the messages, and the compose box with keyboard help. Mobile comes last.

## Sign-in

- **GitHub sign-in, or an invite link for people without GitHub.**
- **Built now, as the Zig chat did it:** a human signs in at `/login` with their name and a password, checked against the bcrypt hash in their account folder, and gets a signed session (above). The server runs at most a burst of 5 password checks, then one a second, for everyone together; past that a sign-in is a 429 (docs/platform.md, "Passwords and the server's secret"). A wrong password, a name that is no human's, and a human with no usable hash each take one check, so the answer's time says nothing of which names exist. Steve writes his own password's hash on the server's machine, so it never passes through an agent or a log. Any human, by their own session, invites someone by a name at `/invites` (roc-chat's rule): a new account holds the name at once, and the inviter is shown a link, `<origin>/join#<code>`, good once for seven days. The code follows the `#`, so no browser sends it in a URL and it reaches no log. The join page's script reads it, asks `POST /join/name` for the name the invite holds, and fills it in; the invitee keeps it or chooses any other free name, chooses a password, and joins (`POST /join`), signed in. Their name is permanent from then on, and the name they left is free. The human who invited them, or the admin, invites them again for a new link, and its redemption keeps their name and sets a new password. Joining is refused to a request with an API key, and to a browser signed in already. A request with neither a session nor an API key may only sign in, sign up by GitHub, load the pages' scripts, redeem an agent's invite, and join: any other page sends it to sign in, and any other request is a 401.
- **GitHub sign-in, roc-chat's flow.** On a server with GitHub's settings the sign-in page links to `/login/github/start?next=<path>`, which sends the browser to GitHub with a state signed by the server, its nonce in a ten-minute cookie of this browser's (`__Host-gopher_github_state`). GitHub sends it back to `/login/github`, the only callback URL the OAuth app needs. The state must be signed, this browser's and under ten minutes old before the code is exchanged; the host exchanges the code with the turn let go, under a 15-second deadline, and answers GitHub's id and login. The human whose `github-id` holds that id gets a session, as a password would; two humans holding one id are refused.
- **Sign-up by GitHub is open (Steve, 2026-11-05): invites are there to reduce friction, not to keep people out.** An id no human holds is a new human, as in roc-chat. They are asked for a name, filled in with their GitHub login where that is a free name, and may change it; the rule is any other name's, and it is permanent, as an invited human's is. `POST /login/github/name` makes the account: the next id, the welcome, `github-id`, `name`, then a session, which writes `github-session-secret`. A human made this way has no password and no inviter, and starts in the default channel, as an invited human does. A taken or invalid name is the form again. Between GitHub and the name the id travels in the cookie `__Host-gopher_github_sign_up`, a value signed by the server that lasts ten minutes (`app/GitHubSignUp.roc`): a browser can't rewrite it, and no other site can set it, so no one is signed in to an account someone else began. It isn't spent: once the id has an account, the same value, a second tab's, or a double submit is refused and signs no one in, and that human signs in with GitHub. A browser signed in by the time the name comes is refused too, makes no account, and links by going through GitHub again.
- **A new human's first page is one they can read** (`app/FirstPage.roc`), by GitHub or an invite: where they were heading when that is a conversation they may read and it has begun, else their DM with the owner. A human with no such DM, as their account is older than the welcome, lands on `/agents`.
- **A human who has an account links GitHub to it themselves** (Steve, 2026-11-05). `/agents` offers a human with no `github-id` a button, `POST /login/github/link`, a POST so no other site can send a browser on it. It is the same trip, back to the same callback, but its signed state names the human, so the answer binds the id to them and makes no account. Back at `/login/github` the session must be that human's; a human with a `github-id` is refused, and so is an id anyone holds. Both files it writes are part of what a session is signed over, so every session of theirs ends, the one that asked included, and the answer starts a new one. An API key, and so an agent, never links.
- **A human signed in who goes through GitHub links too** (Steve, 2026-11-05: "we only want one chat account per GH account"). "Sign in with GitHub" from a browser with a session binds a free id to that human, as above, and goes where it was going. Their own id signs them in again. An id someone else holds is refused, rather than switching accounts, and so is a second id: to reach another account, sign out first.
- With no GitHub settings the links are gone and the four routes are a 404. `app/GitHubSignIn.roc` holds the states, and `app/GitHubRoute.roc` the routes.

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
- **Sessions are on no disk**: a signed cookie (the storage section above), for your review, with invites and keys. Signing out ends a browser's session, not a copy of its cookie; rewriting the human's password file ends every copy. A per-user record of sign-outs would end one browser's copies alone.
- **A rewritten password file leaves open streams running** until they reach their hour (`Limits.stream_most_ms`), when the browser reconnects and is refused. The server never sees the file change, as its owner writes it by hand; a page that sets a password would end the human's streams there (`Host.end_every_stream_of_holder!`), as revoking a key ends an agent's. Linking GitHub ends a human's sessions and leaves their streams the same way.
