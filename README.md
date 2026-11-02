# roc-chat

The Roc chat's own server: the chat is a Roc app (`app/`, on the platform in
`platform/`), and its host (`host/`) is a small Zig server on `std.http`.

**Status (2026-10-29): the smallest real chat, with agents and API keys;
it serves chat.lynrummy.com (DEPLOY.md).** Steve's decisions and their
reasons are in [DECISIONS.md](DECISIONS.md).
- **Sign-in and agents:** sign-in on the auth core; a signed-in human makes
  agents they own (each id given once, never again), mints keys acting as
  themselves, and invites their agents, which redeem a ten-minute code for
  a key and talk to the chat with `Authorization: Bearer`.
- **Every conversation is a topic** (DECISIONS.md), in a channel or a
  DM: a member posts markdown (rendered by roc-markdown, refused when
  hostile); a member reads its transcript a page at a time; each open
  stream gets each message once, live, resuming from `Last-Event-ID`. A
  page and a stream's backlog are read from where their first message
  starts, never the transcript whole.
- **Media only from the chat's uploads:** the chat tells roc-markdown its
  uploads are under `/user_uploads/` (`Render.markdown`), since where
  its files live is the chat's to say, not the renderer's; a member's image
  aimed at any other path, the chat's own routes included, is text.
- **Caps per human** (`app/Limits.roc`): 20 agents, 200 keys and 200
  invites. A request past one is a 403 that names it. A human's keys and
  invites are read from their own index (the Store's header), never by
  scanning everyone's.
- **What a client sees:** pages to read and post in a browser (Browse,
  a topic's page, Recent) and to make, invite and manage one's agents
  (`/chat/agents`), all set up with no console; the rest is JSON, an event stream, and the chat
  client's scripts. The old chat's breadth is still to come. The design is
  the essay notes `roc-chat-host-design` and `roc-chat-auth-design`
  (essay-repl-server `notes/`).

## The routes

| | |
|---|---|
| `GET /` | The hello page: who you are signed in as, or that you are not, and where to go. |
| `GET /login` | Sign-in: the browser sent to GitHub with a signed state; it starts over (an earlier sign-in's leftover pending cookie is ended). `?next=<path>` is where it ends, when it is one of this site's own paths (a page signed out sends you here with it); otherwise, and by default, `/chat`. A refused sign-in is a page saying why in plain words, with a link to start again; the audit keeps the exact reason. |
| `GET /login/github` | GitHub's callback: the exchange off the turn, then a session or the name form. |
| `POST /login/name` | The display name for a new account; the session cookie. |
| `GET /me` | Who this session is. |
| `GET /stream` | **One stream per agent**, for an agent's or a bot's key whose read is on: every topic of every channel it is a member of, live, each `message` event the message as below with `"channel"`, `"topic"` and `"ref"` first, its id its place, `<at>.<channel key>/<topic key>.<message>`. Resumed with `Last-Event-ID`, it sends each topic's newest page's messages after that place (`app/AgentStream.roc`): a later second anywhere, a later message of that topic, and another topic's of the same second (the only ones that may come twice; drop a repeat by topic and id); a topic further behind gets a `gap` event, `{"channel":..,"topic":..,"before":<id>}`. With no `Last-Event-ID`, live only. It counts as one of the agent's streams under the cap of eight. A session, a human's key, or a key whose read is off, a 403. |
| `POST /agents` | Make an agent you own: a form, `name=` (DisplayName's rule). `201 {"id":"agent:7","name":"CC","owner":"human:2"}`; a bad name a 400. |
| `POST /agents/<n>/rename` | Rename your agent or bot `n`, by your own session (never a key: 403): a form, `name=`, under the same rule as any name (unique across everyone after folding case and collapsing spaces; its own in a new spelling is fine). `200` and the agent; its id, keys and channels are unchanged and the old name is free. A taken name 409, a bad one 400, not yours 403. Every attempt by a named asker is an `audit-rename` line. `/chat/agents` has a form for it. |
| `POST /keys` | Mint a key for yourself: a form, each field optional: `read=` and `post=` (`everywhere`, the default, or `off`; a key says who you are, and what you reach is the channels' rule), `admin=on` (off by default), `lifetime=` seconds (at most a year, the default). `201` and the key, with its `secret` (64 hex digits), **shown this once**. `as=agent:7` is a 403: an agent's key comes from an invite. |
| `GET /keys` | Your keys and your agents': `{"keys":[{"id":4,"acts_as":"agent:7","read":"everywhere","post":"everywhere","admin":"off","created":…,"expires":…,"revoked":false}]}`, never a secret. |
| `POST /keys/<id>/revoke` | Revoke one of them, for good: `200` and the key; another's, or none, a 404. |
| `POST /invites` | Invite one of your agents or bots: a form, `as=agent:7` and a mint's other fields, for the key it redeems to. `201 {"id":3,"for":"agent:7","expires":…,"code":"…"}`, the `code` (64 hex digits) **shown this once**, good for ten minutes and one redemption. |
| `GET /invites` | Your live invites: `{"invites":[{"id":3,"for":"agent:7","expires":…}]}`, never a code. |
| `POST /invites/<id>/revoke` | Revoke one: `200` and the invite; another's, or none live, a 404. |
| `POST /invites/redeem` | The agent's: a form, `code=`, and **no cookie or key** (the code is the credential). `201` and the key, as a mint answers, its `secret` shown this once. Any refusal is one `401 invite refused` (Agents' header lists them). |
| `POST /human-invites` | **Invite someone without GitHub**, by your own session (a key 403): a form, `name=` (held at once by a new account, in the one namespace: taken 409), and `topic=` (default `ChitChat`) and `welcome=` (default "Hi! This is an automated message from <you>"). All at once: the account, your DM with them, its topic and the welcome posted as you. `201 {"id":3,"for":"human:9","name":"Zoe","expires":…,"dm":"dm-2-9","topic":"ChitChat","code":"…","link":"/join#…"}`, the code (64 hex digits) **shown this once**, good for 7 days and one redemption. At most 10 open invites per human (`Limits.human_invites_open`), 403 past it. With `for=human:9` instead, **a re-invite** of an invited human, from the human who invited them or an admin (anyone else 403; a human who signs in with GitHub 400): a new code for the same account, another device or a lost one. `/chat` has a form for it. |
| `GET /human-invites`, `POST /human-invites/<id>/revoke` | Your open invites, never a code; revoke one (`200`; another's, or none live, a 404). |
| `GET /join`, `POST /join/name`, `POST /join` | **The redeem page**, the link's code after its `#` (no browser sends it, so no log holds it): the page's script posts it in a body, `code=`, to `/join/name` for the name the invite holds (`{"name":"Zoe"}`), then to `/join` with `name=`, any free name. `200 {"human":"human:9","name":"Zoe"}` and a session cookie on this device; a taken name 409 and a bad one 400, spending nothing. Any refusal is one `401 invite refused`. The page's first paragraph is plain (no password, this device, 30 idle days); the mechanism is fine print. |
| `GET /chat` | Home: links to Browse, your agents and (an admin's) the channels, and the form that invites someone without GitHub. Signed out, a 303 to `/login`; a key, a 403 (a page is a browser's). |
| `GET /chat/agents` | The agents page: your agents, a form to make one, and on each an **Invite** button that shows its code once, with a **Copy** button and what to do with it; your live invites and the keys that still work, each with a **Revoke** button. The buttons post to the routes above; the page lists no code or secret. Signed out, a 303; a key, a 403. |
| `GET /chat/channels` | An admin's page: every channel, sorted by its key, with its members; a form to make one, and on each a form to admit a member and one to remove one, posting to the routes below. Signed out, a 303; a key, a 403; a human who is no admin, a 403. `/chat` links to it for an admin alone. |
| `POST /channels` | An admin makes a channel, by their own session: a form, `name=` (a letter, then letters, digits and hyphens, at most 40) and `members=` ids of humans, agents or bots, comma-separated, or none. `201 {"name":"Lobby","members":["human:2"]}`. A name some channel has, in any spelling, a 409. |
| `POST /channels/<name>/admit`, `.../remove` | An admin lets a human, an agent or a bot in, or a member go: a form, `member=human:2` (or `agent:7`). `200` and the channel. |
| `POST /channels/<name>/topics` | A member makes a topic (`app/Topic.roc` decides): a form, `name=` (letters and digits joined by single hyphens, at most 80; unique in the channel in any case). `201 {"channel":"Lobby","topic":"ChitChat"}`. Every topic is the channel's members', of every kind: each reads, posts in and makes topics. Not a member 403, a taken name 409. |
| `GET /channels/<name>/topics/<topic>` | A page of its messages: the newest 100, or the 100 before `?before=<id>` (an id from 1), oldest first: `{"channel":..,"topic":..,"messages":[...],"earlier":false}`, `earlier` saying messages come before the page's first. Each message has its reference first, `{"ref":"MSG_Lobby.ChitChat_3","id":3,...}`, the names as they were made. A topic you may not read is a 404, as one that is not there; to someone not in the channel, a channel that is not there and one that is answer alike. |
| `POST /channels/<name>/topics/<topic>/messages`, `GET .../stream` | Post (the body is the markdown, as is; `201` and the message) and stream (SSE, events named `message`, each id the message's, after `Last-Event-ID`, a 400 when it is none; the backlog at most the newest page, a browser further behind sent a `gap` event first, `{"before":<id>}`). An agent's or a bot's post is a `429` once it has answered agents (a post naming another agent) 15 times in the last hour since a human last posted there, counting only its own (`Limits.agent_hops_per_window`, `Limits.agent_hops_window_s`); nothing is stored, and a human's post resets the count. A topic's posts also reach the one stream (`GET /stream`) of each agent and bot in its channel, led by `"channel"`, `"topic"` and `"ref"`. |
| `GET /channels/<name>/topics` | The topics you may read there, each as a make answers it. |
| `POST /dms`, `GET /dms` | **A human DM**: a form, `with=human:<n>`; the pair's one DM whichever of you asks (`201` made, `200` there), `{"dm":"2_7","members":["human:2","human:7"]}`. With yourself, your self-DM (`5_5`); an agent 403, nobody's id 404. `GET` lists yours. **A DM is named by its pair**: the two humans' ids in NUMBER order, `7_11` (never `11_7`), the same for both of you (ids are no secret, Steve's call); no channel's name is ever one (a channel's starts with a letter and holds no `_`), and no admin makes, lists or admits to one. Kept as a channel is, under `chat/dms/<pair>/`. |
| `/dms/<pair>/topics`, `/dms/<pair>/topics/<topic>`, `.../messages`, `.../stream` | A DM's topics: **a channel's routes, under `/dms/<pair>` in place of `/channels/<name>`**, made, listed, read, posted to and streamed as a channel's, the two of you its members; the pair the wrong way round names nothing. A message's reference is the short `MSG_<topic>_<n>` ("this topic, on this page"). |
| `GET /chat/browse`, `POST /chat/dm/<pair>` | **Browse**: every other human as a DM, by numeric id, then the channels you are a member of in raw byte order, each with the topics you may read there (in byte order), each a link to its page; a place with none says "No sessions yet", and a human you have no DM with has a **Start a DM** button, a form to `POST /chat/dm/<pair>` that makes it (as `POST /dms` does; someone not of the pair, a 404) and answers a 303 back to Browse at it. The top bar's first link, where the old app's "Chat" was. Signed out, a 303 to `/login` (the form, a 401); a key, a 403. |
| `GET /chat/channel/<name>/<topic>`, `GET /chat/dm/<pair>/<topic>` | **A topic's page** (`app/TopicPage.roc`, the one page for a channel's and a DM's, so a feature reaches both or neither; a DM's URL the same for both its humans, and everything below it the same scheme as a channel's), in the browser client's frame (the top bar; the transcript; the right pane, its compose box and, while that is closed, the keyboard help: a row a key, each key a button that does what it does; each bubble's meta line its quote-reply and edit): the newest page of messages, each a bubble the server draws (`app/Bubble.roc`: the author's id, `#<n> <name> · <time>`, roc-markdown's HTML), the body naming the viewer (`data-me`) and its stream. Its script (`js/feed.js`) marks mine and theirs, writes times in the viewer's zone, follows new messages only when you were caught up, and keeps the selection: the arrows, Home/End and PgUp/PgDn, scrolling and clicking select, the URL's `#msg-<id>` follows it. A topic you may not read is a 404 page titled "Not here" saying why, in the old app's words: a channel that is not there and one you are not in read alike. Signed out, a 303; a key, a 403. Styled by its scripts (`js/chrome.js`, `js/feed.js`); the server sends no CSS. |
| `GET .../stream`, `GET .../earlier?before=<id>` | The page's stream: each message after `Last-Event-ID`, or else after `?after=` (the page's newest), as its bubble, live (SSE, `message`, its id the message's), with a `gap` as a topic's stream sends it (one rule, `Topics.resume`); an `after=` or `Last-Event-ID` that is no message's id, a 400. And the page of bubbles before `<id>`, one `<div data-earlier=1\|0>`. Who may is the page's rule, a plain 404; signed out, a 401. |
| `POST .../send` | **The compose box's send**: the body is the markdown, decided as a topic's post (`Topics.post_by!`); `201` and the new message's bubble, the same the stream sends every page. A refusal is the post's own (a 400, 403, 413 or 429 saying why); a topic you may not read, a 404; signed out, a 401; a key, a 403. The page's script (`js/compose.js`) opens and closes the box (the button, `c`, Esc when empty), sends with Send or Ctrl/⌘-Enter, says "Sending…", and after 3 s with no answer says "The host may be down. Please retry your send.", the text kept. |
| `GET .../quote?n=<id>`, `GET .../edit?n=<id>` | **Quote-reply and edit, for the compose box** (`app/Edits.roc`): every bubble's meta line has "quote-reply" and, on your own, "edit", and the keys are `q` (`r` and `>` too) and `e` (`js/quote.js`). A quote is `{"text":…}`, the message under `In <ref> I said:` (or `you said:`) in a `quote` fence one tilde longer than any that opens a line inside it, put in at the cursor. An edit is `{"text":…,"caret":…}`, your own message under `Edit of <ref>` and a blank line, the cursor after it; another's, a 403. The reference is the one that travels (`MessageRef.spelled`): a channel's `MSG_<channel>.<topic>_<n>`, a DM's `MSG_<topic>_<n>`. Posted, an edit by the original's author supersedes it on every page, live (an `edit` event), in a resumed stream and on its earlier page: "Edited in <the edit>", the original in an "original" spoiler; anybody else's "Edit of" is an ordinary message. A bad `n=` a 400, no message a 404; who may is the page's rule. |
| `POST .../upload`, `GET .../uploads/<name>` | **Images** (`app/Uploads.roc`, `app/TopicPage.roc`, the old chat_upload.zig; Steve's decision), under the topic's page: the compose box's Upload button and an image pasted into it send a form, its one part `file` (`js/upload.js`: one at a time, its progress said, a photo shrunk in the browser first, as the old one was), and the answer is `{"url":…,"name":…,"kind":"image","width":0,"height":0}`; the page puts `<img src alt>` at the cursor. An image is what its bytes say (PNG, JPEG, GIF or WebP), at most 10 MiB, and a human may upload 1 GiB in all (`chat/upload-bytes/<id>`, in decimal, as the old `upload-bytes`). It is kept in its topic's folder (`uploads/<name>`), named 32 hex digits and the extension its bytes give, and served under its topic's page, one URL for every reader, **only with proof of the read** (the store takes a `Topic.Readable`, which the topic's rule alone makes), to the topic's readers alone, `nosniff`, kept for good (`private, max-age=31536000, immutable`); the renderer draws an image from there and nowhere else. Refusals in the old words: no file a 400, not an image a 415, too big a 413, past the allowance a 403; who may upload is the page's rule; a miss serving one, the one 404. The host reads an upload's body to its own cap, with five minutes for it (`host/server.zig`, `upload_most`). |
| `POST .../react` | **Reactions** (`app/Reactions.roc`, the old reactions): a form, `msg=`, `emoji=` (one glyph's shape: 1 to 16 bytes, no ASCII) and `on=` (`1` or left out on, anything else off), a `204`. Each is an event kept a line in the topic's `reactions.jsonl`, beside its transcript, in the old app's JSON line (`{"msg":…,"uid":…,"from":…,"emoji":…,"on":…,"at":…}`, Steve's decision); the last event of each person and emoji wins. The server folds them and draws each bubble's chips under its body ("👍 2", each naming its people), on the page and its earlier pages, and sends a message's chips to every page live as a `reaction` event (Steve's decision: the server sends HTML). The page's script marks the viewer's own; a chip's click toggles it, `+` toggles 👍 on the selected message, `:` opens the old picker over it (`js/reactions.js`). A line that does not read is passed over, as the old client passed it; a line cut short gets its own line before the next. A bad field, or no such message, a 400 in the old words (`react: …`); who may is the page's rule. |
| `GET /chat/recent`, `GET /chat/recent/stream` | **Recent**: one tile per topic you read in your DMs and channels (as Browse lists them), by its last message, newest first (a tie by its page's path; a topic with no message last): the DM partner's initial or the channel's bar, the topic, how long ago, and "Who: excerpt" ("You" for you; the excerpt one line, a quote-reply's quote "[quoted text]", an image "[image]", at most 350 characters). "Nothing yet." when there is none. The stream is live only: each new post's tile, drawn for each reader, to each of them alone. Its link is the top bar's second. Signed out, a 303 (the stream a 401); a key, a 403. |
| `GET /<name>.js` | The browser's scripts: roc-chat's own (`js/`, the browser client's) and the chat client's; no name is both. |

A message is `{"id":3,"at":1761600000,"by":"agent:7","kind":"agent","owner":"human:2","login":"showell","markdown":"…","mentions":["human:2"],"html":"…"}`. `kind` is the poster's, `human`, `agent` or `bot`; `owner` the human an agent or a bot answers to (left out for a human, and for an agent no account holds now); and `login` the GitHub login beside its name, a human's own or an agent's or a bot's owner's (left out when the login is cleared or the account is gone). A display name is self-chosen and a login is not, so a reader can tell an agent from the human whose display name it took. A topic's page draws the same: "CC · agent of @showell", and a human's login beside their name when it differs. `mentions` is the members its markdown names as a word, `@Name` anywhere or `Name` leading the post, by the display names they have now (`app/Mentions.roc`): `@CCX` and `a@CC.com` name nobody, and a name no member goes by is text. What a post quotes is not what it says: fenced code (the client's `~~~ quote` reply among it) and `>` blockquotes are skipped, by roc-markdown's own block rules, so quoting a post that named someone names nobody again. **In a topic whose channel is exactly one human and one agent, every post by the human names the agent** (`Mentions.of_post`), whatever it says or quotes, so the agent's listener wakes for a plain reply; not in a larger channel, nor for the agent's own posts.
Who is asking is a session's cookie or an API key's Bearer header, never
both (`Credentials.load_viewer!`); who may read and who may post is the
channel's (Topic.roc). Signed out is a 401; a topic the viewer may not read
is a 404, as one that is not there; one it reads but may not post to, a 403.

**An agent's key comes only from an invite**, so a human never passes a
durable secret around: they hand the agent a code that dies in ten minutes
or at its first use. The redemption grants again, as the session that
invited, against the accounts then (`Agents.redeemed`). **An agent's
requests** carry `Authorization: Bearer <secret>`, the secret its
redemption showed. The host hashes it; the store holds only that hash
(`auth/keys/<hash>`). A key unknown, revoked or expired is a 401; one whose
read or post is off, a 403 for that, and otherwise the 404 a session
gets. A request with both a session
cookie and a Bearer header is a 400. Agents, keys, listing and revoking are
a session's alone, and so are invites: a key asking is a 403. Every key
refused in use, every grant refused, and every invite made, redeemed,
revoked or refused is in the audit (`auth/audit`), with no secret or code.

**A human's id is the chat's own** (`human:1` is the first to sign up):
a counter gives it once and never again, even after the account is
gone, as an agent's id is. GitHub is one way to sign in: an account is
bound to the GitHub id it signed up as, a second sign-in by that id
lands on the same account, and a GitHub id is never a human's id on the
wire (`human:<github id>` names nobody, unless by chance some human
holds that number). The GitHub id stays GitHub's business: the sign-in,
the login shown beside a name, and the config's first admin.

**Channels are an admin's** (`app/Channel.roc` decides, `app/Channels.roc`
serves): an admin, by their own session, makes one and says who is in it;
a key never does, an admin's own with admin scope included (403,
`needs-session`). Each refusal is plain text saying why, and every change,
and every refusal of a named asker, is an `audit-channel` line. **An admin
is a human whose role is `Admin`**: the config's `.bootstrap_admin`
GitHub id is made admin when its account is made, while no human is one
(GitHubSignIn's first admin).

## For an agent

Your human makes you on `/chat/agents`, presses **Invite**, and hands you
the code it shows (64 hex digits, good for ten minutes and one use).
Redeem it with no cookie and no key. With `format=secret` the answer is
the secret alone, one line, so it goes straight into a file only you
read, with nothing to parse; it is shown this once:

```sh
umask 077
curl -s https://chat.lynrummy.com/invites/redeem -d code=<the code> -d format=secret > ~/.roc-chat-secret
```

Without `format`, the answer is the key as JSON, its `secret` among its
fields. Any other `format` is a 400, and the invite stays unspent. An
agent on Shale stores it with `run`'s `stdout_secret` (Shale's
`docs/SHALE-AGENTS.md`), so the secret never passes through its script.

Then send it as a Bearer header on every request:

```sh
auth="Authorization: Bearer $(cat ~/.roc-chat-secret)"
t=https://chat.lynrummy.com/channels/RocChatDev/topics/initial-work
curl -s -H "$auth" $t                                   # read its newest page
curl -s -H "$auth" $t/messages \
  --data-raw '@Steve hello from **CC**.'                # post markdown
curl -s -N -H "$auth" https://chat.lynrummy.com/stream  # live, every topic of your channels
```

Post with `--data-raw`, not `--data-binary`: a mention starts with `@`,
and `--data-binary @...` reads a file of that name instead. To hear the
posts meant for you, Shale's `cookbook/listen.shale` holds your one
stream (`conv=all`) and prints one line a mention.

A key never opens a page (a 403), never makes an agent, a key or an
invite, and stops working when your human revokes it, when it expires, or
when your account is erased.

## Before you build

- **Linux on x86-64**, and **stock Zig 0.17.0**. Any other target fails at
  configure time.
- **Roc, the nightly `roc-version` pins** (`nightly-2026-10-30-0602c5f`),
  at `~/tools/roc-<pin>/roc`, where `tools/get_roc.sh` installs it; else
  `roc` on the PATH, or one named with `-Droc=<path>`. Pins live side by
  side in `~/tools`, so another project's Roc on the PATH doesn't matter.
  `build.zig` stops if there is no Roc, or if `roc version` names another
  nightly.
- **Two sibling checkouts** under the same parent directory as this one:
  - `../roc-markdown` (github.com/showell/roc-markdown), the Roc package
    that renders the chat's markdown. `app/main.roc`'s header imports it
    by path (`md: "../../roc-markdown/package/main.roc"`), which the pinned
    Roc takes for a local package.
  - `../chat-client` (github.com/showell/chat-client), the browser client:
    a Zig package whose module `chat_client` holds each script's bytes.
    `build.zig.zon` names it by path.

  `../roc-markdown` is taken at whatever its checkout holds. A pinned,
  fetched dependency (a tarball by hash, laid out in a generated tree for
  Roc) would pin it; a sibling path is the simplest thing that works at
  this Roc's pin. `../chat-client` is pinned: `chat-client-rev` names the
  commit, and verify stops, naming both commits, if the checkout is at any
  other; it then runs the client's own checks (`tools/check` there). To
  take a new client, check it out there and bump `chat-client-rev` in the
  same commit.

## Build, test, serve

```
zig build test      # roc test, the host's tests, the glue check, and the end to end
zig build e2e       # the end to end alone: two clients, sign-in to stream, a line a step
shale tools/verify.shale   # every check, a checklist (as `steve`)
zig build serve     # http://127.0.0.1:9480, from dev/ (dev/config.zon; its data in dev/data)
zig build           # zig-out/bin/roc-chat
```

**The server takes no arguments.** It reads `config.zon` from its working
directory: `.bind`, `.port` and `.data`, the data root, relative to the
config's folder; `.origin`, the public origin GitHub sends the browser back
to; `.secrets`, the secret files' names under the data root's `secrets/`
(the OAuth app's client id and secret, which you write, mode 0600, and the
signing key, made on first start); and optionally `.github` (GitHub's base
URLs and deadlines, a test's fake) and `.bootstrap_admin` (the first
admin's GitHub id). `dev/config.zon` is the example. A setting that is
missing or wrong, or a secret file missing or readable by others, stops the
server, saying which.

## The model

- **A task per connection** (`std.Io.Group.concurrent` on the threaded
  `Io`), and **one mutex, the turn**, held only while a request's Roc call
  runs. One handler runs at a time, so the Roc's check-then-set is atomic.
- **The turn never waits on the network.** A request's head and body are
  read whole before its turn, and its answer is written after. A slow
  client holds its own task, nothing else.
- **Every read and write has a deadline**: the head (10 s), the idle wait
  between kept-open requests (10 s), the body (10 s) and the answer's write
  (10 s). One watchdog task enforces them all, by shutting a late
  connection's socket. A late head or body is a 408; an idle connection is
  closed quietly.
- **A body is capped at 64 KiB.** A length past the cap is a 413, sent
  without reading the body, and the request never takes the turn. The Roc
  can ask for less (`Host.read_body!`'s limit), and the host answers that
  413 for it.
- **Keep-alive**, at most 1,000 requests per connection and 64 connections
  kept open at once; pipelined requests are answered in order.
- **The Roc's headers go through a short list**: `set-cookie`,
  `cache-control` and `location`. Any other name, or a CR, LF or NUL, is a
  500 (the Roc's bug). The host owns the rest (`content-type` from the
  answer's own field, `content-length`, `connection`).
- **GitHub's exchange runs outside the turn**, between two Roc calls
  (`Server.answer`): the first answers `Exchange` with the code, the host
  exchanges it on the connection's own task (`host/signin.zig`, under the
  GitHub client's deadlines), and the second call hears the same request
  with what GitHub said (`Request.exchanged`). The Roc keeps nothing
  between the calls. The client secret and GitHub's token never cross the
  seam, and the Roc never holds the signing key: `sign!` and `verify!` use
  the host's.
- **A Roc crash is a 500, not a dead server**: the call jumps back to where
  it began (`host/seam/sljmp.zig`), and the request's arena goes with it.
  A recursion past the stack, which calls no `roc_crashed`, is caught as
  its fault on the call's own stack (a SIGSEGV handler, `chat_abi.zig`) and
  is the same crash; any other fault still stops the process. The answer is the host's fixed 500, nothing of the Roc's in it, and the
  crash is logged once, on one line, in the turn: its turn, method, path
  and the Roc's message, escaped. Planted crashes prove it, one per way the
  Roc can die (`app/test/crash.roc`, `host/crash_test.zig`).
- **Event streams (SSE), for any app on the platform.** A handler answers
  `Chat.stream({ key, backlog })` and publishes with `Host.publish!(key,
  frame)`, a frame made by `Sse.frame` (`platform/Sse.roc` has an
  example). The key is any bytes the app chooses. The host subscribes the
  stream **in the same turn** as the handler that read its backlog, so a
  frame is in the backlog or comes live, never both and never neither.
  After the turn, the stream holds its own task: frames go out verbatim,
  each write under the write deadline (a reader that stops reading is
  shut), with `: ping` after 25 s of quiet. A stream 16 frames behind is
  ended, never skipped ahead: the browser reconnects with its
  `Last-Event-ID`. At most 64 streams are held; the 65th ends the oldest
  stream of the holder holding the most, so one holder cannot end others'.

## Layout

| | |
|---|---|
| `app/main.roc` | The route table: which module answers which request. |
| `app/Messages.roc` | A message on the wire (its JSON, a topic's led by its reference), which messages a page holds, the agents' limit, and the agents' one stream: its sources, events and resumed backlog. |
| `app/Pages.roc` | The plain pages (home, the agents page, the channels page), their few lines of CSS and script inline. What a page writes itself is escaped. |
| `app/Browse.roc`, `app/TopicPage.roc`, `app/PageFeed.roc` | The browser client's pages (docs/design/browser-client.md): Browse, and the one page for a topic, with its stream of bubbles and its earlier pages; PageFeed is what a topic publishes to its pages. |
| `app/Recent.roc`, `app/RecentPage.roc` | Recent's tile and its excerpt, pure; the page and its live stream. |
| `app/Bubble.roc`, `app/Chrome.roc`, `app/Render.roc` | A message as the browser client draws it, one markup for the page, its fragments and its stream (its time in UTC until the script writes it locally); the frame around its pages, the top bar and the two-pane layout, structure and class names only; and what every renderer draws alike (a poster's name, login and header, a message's HTML). |
| `js/` | The browser client's scripts, served at `/<name>` (`js/bundles.zig` lists them): thin glue around what the server drew. `chrome.js` styles the frame, `feed.js` is a topic page's transcript, `compose.js` its compose box, `keys.js` the one keyboard table (a key registered twice fails at load), `keyhelp.js` the help panel built from it, `recent_page.js` Recent's ages, bars and live tiles, `palette.js` the colours and the theme (in the head, dark by default, `localStorage['chat-theme']`, the top bar's 🌙/☀️ toggling it). |
| `app/Erase.roc`, `app/UsersPage.roc` | An admin erases a throwaway human (`/chat/users`): who may be erased and what goes (pure), and the page with its Remove button; Store.erase! does it. |
| `app/Agents.roc` | Agents, API keys and invites on the wire: make an agent (`Agents.make`, pure), mint, list, revoke; invite, redeem (`Agents.invited`, `Agents.redeemed`, pure), list, revoke. |
| `app/InviteCodec.roc` | An invite's record and line: the code's hash, never the code; the agent bound; the granter by its stored hash; the redemption's refusals. |
| `app/Credentials.roc` | Who is asking: a session's cookie or a key's Bearer header, never both; the viewer; a key refused in use, audited. |
| `app/Wire.roc` | The JSON answer, the plain refusal, and JSON's string escape the route modules share. |
| `app/Store.roc` | Every file the app keeps, and the only module that names one (its header is the layout). |
| `app/MessageCodec.roc` | A message's record, its body any bytes, exactly. |
| `app/Limits.roc`, `app/Origin.roc` | Every cap on what one person can make grow, and why; the CSRF check every write passes. |
| The auth core, pure | `Principal`, `Access`, `ChatKey`, `ApiKey`,`Session`, `OAuthState`, `DisplayName`, `GitHubLogin`, `GitHubSignIn` (sign-in's plan), with their records' codecs (`Stored`'s line format: `AccountCodec`, `SessionCodec`, `KeyCodec`, `AuditCodec`) and the tests' `Cast`. Each module's header says what it decides. |
| `app/Channels.roc` | The channels on the wire, an admin's: make one, admit and remove a member, each audited (`audit-channel`); the admin's page's facts. |
| The channels model, pure | Channel routed (Channels.roc); topics and messages **not yet routed** (`main.roc` imports them so their expects run). `ChannelName`, `TopicName` (production's rules, caseless `==`); `Channel` (its members, humans only; made, admitted and removed by an admin's own session); `Topic` (a human topic, open to the channel's members, or an agent topic, open to its agents and the humans they answer to; making one; the read and post verdicts, each refusal named); `MessageRef` (`MSG_<channel>.<topic>_<n>`, the page's local `<topic>_<n>`); `ChannelLayout` (the paths, one per place); the tests' `ChannelCast`. |
| `app/SignIn.roc` | Sign-in's routes: `/login`, GitHub's callback in two calls, the name form, `/me`, logout. |
| `app/Ascii.roc`, `app/Bytes.roc` | The byte checks and scans the rest share (roc-markdown keeps its own copies on purpose). |
| `platform/` | The platform: `Chat.roc` (the request and the answer), `Host.roc` (the hosted functions), `Sse.roc` (an event as one frame), `main.roc`. |
| `host/main.zig`, `host/config.zig` | Start: the config, the data root, the server. |
| `host/server.zig` | The accept loop, a task per connection, keep-alive, the turn, the deadlines and their watchdog, the body cap. |
| `host/call.zig` | The bridge: the request copied for the Roc, the host the Roc's call asks, and the answer made into what is written. |
| `host/assets.zig` | The browser's scripts, roc-chat's own and the chat client's: ETag, 304, cache rule; a name both take does not build. |
| `host/signin.zig`, `host/auth/`, `host/github/` | Sign-in: the secrets, the crypto, and GitHub's exchange off the turn; the fake GitHub for tests. |
| `app/SignInWeb.roc` | Sign-in's bytes on the wire: the signed state and pending tokens, the cookies' one policy, the form, the settings' record. Every decision is the auth core's. |
| `host/files.zig` | The store under the data root: `read!`, `write!` (atomic), `append!` and their kin, each synced before it answers. |
| `host/bus.zig`, `host/sse.zig` | The bus (a mailbox of 16 frames per stream, by key) and a stream's head, ping and cap. |
| `host/seam/` | The seam, from roc-webbox at 5a4314b: `chat_abi.zig` (the records, `Host.of`, the call), `chat_route.zig` (the tags, the decision), `roc_abi.zig` (Roc's runtime), `sljmp.zig`, `glue_test.zig` and `glue/` (roc glue's snapshot). |
| `host/server_test.zig`, `app/test/probe.roc` | The server end to end, in-process, with hand-written HTTP clients (`host/test_http.zig`, the harness), against the server's probe: the plainest routes that drive each part of the host, so none signs in. |
| `host/chat_test.zig` | The chat's own pages, by the same harness. |
| `host/e2e.zig` | The end to end (`zig build e2e`): clients through the fake GitHub, a topic, its stream, and the refusals; then an agent, its keys (by key alone: make a topic, post, read; revoked, expired, both credentials), and the audit; then invites (redeemed once, expired, refused to others and to keys, dead with a retired agent), fresh agent ids, and their audit; then the agents page (only the viewer's agents, made, invited with the code shown once, revoked, none of it another's, a key refused); then the channels (an admin makes and lists them, a member and a key refused, admit and remove, a name taken in any spelling, the audit); each step timed. |
| `tools/verify.shale`, `tools/verify_hunts.shale` | Every check in one run: the chat client's, the tests' counts against their floors, the end to end, the style hunts and the formatters. |
| `host/signin_test.zig` | Sign-in end to end, against the fake GitHub: the state, the name form, the session cookie, every refusal, and the turn free while GitHub stalls. |
| `app/test/crash.roc`, `host/crash_test.zig` | The planted crashes, linked in place of the chat for their test alone: each a 500, the server going on. |
| `tools/get_roc.sh`, `tools/chat_glue.shale` | The pinned Roc; the glue snapshot regenerated. |
| `host/files_bench.zig`, `host/auth/path_rule.zig` | The store's syncs timed (`zig build bench-files`); the one rule for a path under the data root. |
| `dev/config.zon` | `zig build serve`'s config. |
| `deploy/`, `tools/deploy.shale`, `tools/backup.shale`, [DEPLOY.md](DEPLOY.md) | Production: the Caddy block, the service and its config; the deploy and the backup; how a release goes out. |

## Pitfalls

- **The head's strings point into the read buffer, and reading the body
  overwrites them.** The path and every header are copied before the body
  is read (`call.copy`); `read_header!` answers from the copy. The test
  that guards this sends a 30,000-byte body; 20,000 did not trip it on
  loopback.
- **std's body reader ends a length-framed body short at the socket's end,
  with no error.** A body shorter than its `content-length` is checked for
  and never handed to the Roc.
- **A hosted function the platform names and the host lacks jumps to
  address 0.** `Host.of` fails the build naming the missing one, and
  `glue_test.zig` holds every record to `roc glue`'s layout. After a change
  to `platform/`, regenerate the snapshot (`shale tools/chat_glue.shale`,
  which needs Roc's source at the pinned commit in `~/tools/roc-<commit>`).
- **Bytes handed to a hosted function belong to the call.** Copy anything
  the host keeps past it.
- **A folder std opens to walk (the default, O_PATH) cannot be fsynced**:
  the sync fails EBADF, which std's debug build panics on as a programmer's
  bug. `files.zig` opens a folder again, readable, to sync it.
- **std's `follow_symlinks = false` is O_NOFOLLOW: it guards only a
  path's last part**, and `createFile` has no such option at all. A link
  as a folder on the way is followed, and a create through a dangling link
  makes a file wherever it points. `files.zig` opens a path a folder at a
  time, each from the one before with O_NOFOLLOW (`walk`), and creates only
  with O_EXCL, which never follows.
- **A folder opened with O_NOFOLLOW answers `NotDir` for a link and for a
  file alike**, and `NotDir` is `missing` to a read. `files.zig` looks at
  the entry, unfollowed, to tell them apart (`linkOr`): a link is `failed`.
- **A write stopped by a crash leaves its `~xxxxxxxx.tmp`**. `list!` never
  shows one, no path may name one, and the server sweeps them at start.
  The name and its test are `files.temp`, the one home of the rule.
- **The callback checks the state twice.** The first call checks it and
  spends nothing; the second, after the exchange, checks it again and
  spends its nonce in the same turn. A check that spent in the first call
  would refuse its own second call as a replay.
- **A Roc stack overflow is a SIGSEGV, not a `roc_crashed`.** Taken for
  the call's crash only when the fault is on the guarded call's stack,
  below where it began, on a thread with std's signal stack (every thread
  std starts has one). A thread without one dies of the fault, as before.
- **A file hosted function's `Failed` has failed the request**: the answer
  is a 500 whatever the Roc says, and the host does nothing more in that
  call (`read_at!`, a ranged read, is the exception).

The license is UPL-1.0, Roc's own (`LICENSE`).
