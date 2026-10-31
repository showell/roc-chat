## **THE CHAT'S PAGES, THE PLAINEST THAT WORK**: a list of the viewer's
## conversations, and a conversation to read live and post in, in a
## browser. Small, plain and replaceable: the real client is chat-client's.
## Every decision is the conversations' (Conversations.roc, ConvAccess), on
## the viewer Credentials gives a session's cookie; here are the pages made
## of it. A key's Bearer header is a 403: a page is a
## browser's.
##
##     GET /chat         the viewer's conversations, each a link, and a form to
##                       start one: with any of the viewer's own agents, ticked,
##                       and anyone else by id
##     GET /chat/agents  the viewer's agents, a form to make one, and a button
##                       on each to invite it (its code shown once, by the
##                       script, from the invite's own answer); their live
##                       invites and the keys that still work, each with a
##                       button to revoke it
##     GET /chat/channels  an admin's: every channel, sorted by its key, with
##                       its members; a form to make one, and on each a form
##                       to admit a member and one to remove one (their
##                       routes Channels.roc's); a 403 to anyone else
##     GET /chat/<id>    a conversation: its newest page of messages (and a button
##                       for each page before it), then each new one live (its
##                       stream, by the browser's EventSource, which resumes with
##                       Last-Event-ID by itself, and reloads the page on a `gap`),
##                       and a box to post markdown in (Enter sends, Shift-Enter
##                       adds a line)
##
## **A PAGE IS AN `Html`** (Html.roc), built only from escaped text (a
## name, an id, a title), numbers and markup written here. **A MESSAGE'S
## HTML IS THE RENDERER'S OUTPUT, AND ONLY THAT**: the page holds
## roc-markdown's HTML for it (Conversations.html_of, through
## `Html.rendered`), as the transcript and the stream give it, and nothing
## else is ever put in as HTML. Signed out, a page sends the browser to `/login`; a conversation
## the viewer may not see is the 404 of one that is not there.
##
## **THE AGENTS PAGE IS ITS OWN**, not a section of `/chat`: what it holds
## (agents, invites, keys) is the account's, not a conversation's, and its
## script is the one place a page ever shows a code. **ITS WRITES ARE THE
## ROUTES' OWN** (Agents.roc): the script posts the forms `/agents`,
## `/invites` and the revokes take, and each decision stays theirs; the
## page adds no route. **A CODE IS SHOWN IN ONE RESPONSE**, the invite's: the
## page lists an invite by its id and its agent, and Store keeps no code to
## list.
import pf.Chat
import Access
import AccountCodec
import Agents
import Bytes
import Cast
import Channel
import Channels
import ConvKey
import InviteCodec
import KeyCodec
import ConvAccess
import Conversations
import Credentials
import Html
import MessageCodec
import Principal
import Store
import Stored
import Wire

Pages := [].{

	## What a page path asks.
	Route : [
		ConversationList,
		AgentList,
		ChannelList,
		Conversation(ConvAccess.ConvId),
	]

	## The page a path names, if it names one.
	route : List(U8) -> Try(Pages.Route, [NotAPage])
	route = |path|
		if path == root {
			Ok(ConversationList)
		} else if path == root.concat("/agents".to_utf8()) {
			Ok(AgentList)
		} else if path == root.concat("/channels".to_utf8()) {
			Ok(ChannelList)
		} else if path.starts_with(root.append('/')) {
			Conversations.id_of(
				List.drop_first(
					path,
					List.len(root) + 1,
				),
			).map_ok(|id| Conversation(id)).map_err(|_| NotAPage)
		} else {
			Err(NotAPage)
		}

	## **ANSWER A PAGE**, to a GET or a HEAD.
	answer! : Chat.Request, Pages.Route => Chat.Answer
	answer! = |req, r|
		if req.method != Get and req.method != Head {
			Chat.not_allowed(Get)
		} else if r == AgentList {
			serve_agents_page!({})
		} else if r == ChannelList {
			serve_channels_page!({})
		} else {
			use =
				match r {
					ConversationList | AgentList | ChannelList => ListConversations
					Conversation(id) => Read(id)
				}
			match Credentials.load_viewer!(use) {
				Err(answer) => answer
				Ok(
					{
						viewer,
						accounts,
						now: _,
						key: _,
					},
				) =>
					match viewer.who() {
						SignedOut => to_login
						Key(_) => key_refused
						Session(me) =>
							match r {
								ConversationList => list!({
									viewer,
									accounts,
									me: me.id,
								})
								AgentList => serve_agents_page!({})
								ChannelList => serve_channels_page!({})
								Conversation(id) => serve_conversation!({
									viewer,
									accounts,
									id,
								})
							}
					}
			}
		}

}

root : List(U8)
root = "/chat".to_utf8()

## Signed out: to `/login`, a 303. Sign-in lands on the hello page, not
## back here: returning would mean carrying the page through the signed
## OAuth state, which the sign-in core does not do.
to_login : Chat.Answer
to_login =
	Chat.respond(303, { content_type: Chat.text, body: [] })
		|> Chat.with_header("location", "/login".to_utf8())
		|> Chat.with_header("cache-control", "no-store".to_utf8())

## **A PAGE IS A BROWSER'S**: a key (an agent, which reads the JSON routes)
## asking for one is a 403, whatever it may see.
key_refused : Chat.Answer
key_refused = Wire.refused(403, "a page is for a browser's session; a key reads /conversations")

## The list: the viewer's conversations (Conversations.load_mine!), each its
## people's names and a link, and the form that starts one.
list! : {
	viewer : Access.Viewer(ConvAccess.ConvId),
	accounts : List(Principal),
	me : Principal.Id,
} => Chat.Answer
list! = |
	{
		viewer,
		accounts,
		me,
	},
|
	match Conversations.load_mine!(viewer, accounts) {
		Err(Failed) => Chat.failed
		Ok(convs) => {
			items =
				if convs.is_empty() {
					Html.markup("<p>None yet.</p>\n")
				} else {
					Html.join([
						Html.markup("<ul id=conversations>\n"),
						Html.join(
							convs.map(
								|conv| Html.join([
									Html.markup("<li><a href=\"/chat/"),
									Html.number(conv.id().to_u64()),
									Html.markup("\">"),
									names(accounts, conv),
									Html.markup("</a></li>\n"),
								]),
							),
						),
						Html.markup("</ul>\n"),
					])
				}
			page({
				title: Html.markup("Conversations"),
				body_attrs: Html.join([]),
				body: Html.join([
					Html.markup("<h1>Your conversations</h1>\n"),
					items,
					start_form(accounts, me),
					Html.markup("<p><a href=\"/chat/agents\">Your agents, invites and keys</a></p>\n"),
					# The channels page's link, for an admin alone: Channel
					# says who administers.
					if (
						Channel.administers(
							viewer,
							accounts,
						).is_ok()
					) Html.markup("<p><a href=\"/chat/channels\">Channels (an admin's)</a></p>\n") else Html.join([]),
					Html.markup("<p class=quiet>Signed in as "),
					Html.text(Conversations.name_of(accounts, me)),
					Html.markup(" ("),
					id_html(me),
					Html.markup(").</p>\n<script>\n"),
					Html.markup(list_js),
					Html.markup("</script>\n"),
				]),
			})
		}
	}

## **THE FORM THAT STARTS A CONVERSATION**: a box to tick for each of the
## viewer's own agents (Agents.agents_of), and anyone else by id, typed;
## the script sends them all as `with=`, which decides who may be named.
start_form : List(Principal), Principal.Id -> Html
start_form = |accounts, me| {
	mine =
		match me {
			Human(human) => Agents.agents_of(accounts, human)
			Agent(_) | Bot(_) => []
		}
	ticks =
		Html.join(
			mine.map(
				|a| Html.join([
					Html.markup("<label class=pick><input type=checkbox name=agent value=\""),
					id_html(a.id()),
					Html.markup("\"> "),
					Html.text(Conversations.name_of(accounts, a.id())),
					Html.markup("</label>\n"),
				]),
			),
		)
	Html.join([
		Html.markup("<form id=start><p>Start one with:</p>\n"),
		ticks,
		Html.markup("<label>Anyone else, by id <input name=with placeholder=\"human:2, agent:7\"></label> <button>Start</button> <span id=said></span></form>\n"),
	])
}

## **/chat/agents**: the page, for a live session; signed out, to
## `/login`; a key, the 403 every page gives one.
serve_agents_page! : {} => Chat.Answer
serve_agents_page! = |{}|
	match Agents.load_owned!({}) {
		Ok(mine) => agents_page(mine)
		Err(SignedOut) => to_login
		Err(ByKey) => key_refused
		Err(Answered(answer)) => answer
	}

## The agents page: the viewer's agents, each with its invite button, the
## form to make one, the box the script shows a code in, then the live
## invites and the keys, each with its revoke button. Everything written
## here is escaped; no code, secret or hash is in what it is made of.
agents_page : Agents.Mine -> Chat.Answer
agents_page = |mine| {
	name = |id| Html.text(Conversations.name_of(mine.accounts, id))
	agents =
		if mine.agents.is_empty() {
			Html.markup("<p>None yet. Make one below.</p>\n")
		} else {
			Html.join([
				Html.markup("<ul id=agents>\n"),
				Html.join(
					mine.agents.map(
						|a| {
							id = a.id()
							Html.join([
								Html.markup("<li data-id=\""),
								id_html(id),
								Html.markup("\"><b>"),
								name(id),
								Html.markup("</b> <code>"),
								id_html(id),
								Html.markup("</code> <button type=button class=invite data-for=\""),
								id_html(id),
								Html.markup("\" data-name=\""),
								name(id),
								Html.markup("\">Invite</button></li>\n"),
							])
						},
					),
				),
				Html.markup("</ul>\n"),
			])
		}
	invites =
		if mine.invites.is_empty() {
			Html.markup("<p>None waiting.</p>\n")
		} else {
			Html.join([
				Html.markup("<ul id=invites>\n"),
				Html.join(
					mine.invites.map(
						|i| Html.join([
							Html.markup("<li data-invite="),
							Html.number(i.id.to_u64()),
							Html.markup(">For "),
							name(i.bound.id),
							Html.markup(" (<code>"),
							id_html(i.bound.id),
							Html.markup("</code>), until <time data-at="),
							Html.signed(i.expires),
							Html.markup("></time> <button type=button class=revoke data-path=\"/invites/"),
							Html.number(i.id.to_u64()),
							Html.markup("/revoke\">Revoke</button></li>\n"),
						]),
					),
				),
				Html.markup("</ul>\n"),
			])
		}
	keys =
		if mine.keys.is_empty() {
			Html.markup("<p>None.</p>\n")
		} else {
			Html.join([
				Html.markup("<ul id=keys>\n"),
				Html.join(mine.keys.map(|k| key_html(name, k))),
				Html.markup("</ul>\n"),
			])
		}
	page({
		title: Html.markup("Agents"),
		body_attrs: Html.join([]),
		body: Html.join([
			Html.markup("<h1>Your agents</h1>\n<p class=quiet><a href=\"/chat\">All conversations</a></p>\n<p>An agent talks in the chat as itself, and answers to you. Invite one to give it a key of its own: it gets a code to redeem, and never needs yours.</p>\n"),
			agents,
			Html.markup("<form id=make><label>Make an agent named <input name=name required maxlength=64></label> <button>Make</button></form>\n<div id=code hidden><p><b>The invite code for <span id=code-for></span>, shown only now:</b></p>\n<p><code id=code-text></code> <button type=button id=copy>Copy</button></p>\n<p>Give it to the agent within ten minutes (until <time id=code-until></time>). It works once: the agent sends it to <code>POST /invites/redeem</code> as <code>code=</code> and gets its own key back. Reload this page and the code is gone; the invite is listed below until it is redeemed or revoked.</p></div>\n<h2>Invites waiting</h2>\n"),
			invites,
			Html.markup("<h2>Keys that work</h2>\n"),
			keys,
			Html.markup("<p id=said></p>\n<script>\n"),
			Html.markup(agents_js),
			Html.markup("</script>\n"),
		]),
	})
}

## **/chat/channels**: the page, for an admin by their own session; signed
## out, to `/login`; a key, the 403 every page gives one; anyone else, a
## 403 that says why.
serve_channels_page! : {} => Chat.Answer
serve_channels_page! = |{}|
	match Channels.load_listing!({}) {
		Ok(listing) => channels_page(listing)
		Err(SignedOut) => to_login
		Err(ByKey) => key_refused
		Err(NotAdmin) => Wire.refused(403, "the channels page is an admin's")
		Err(Answered(answer)) => answer
	}

## The channels page: each channel, its members by name and id, and its
## admit and remove forms; then the form that makes one. Everything
## written here is escaped.
channels_page : Channels.Listing -> Chat.Answer
channels_page = |listing| {
	member = |b| Html.join([
		Html.markup("<li>"),
		Html.text(Conversations.name_of(listing.accounts, b.id)),
		Html.markup(" (<code>"),
		id_html(b.id),
		Html.markup("</code>)</li>\n"),
	])
	channel = |c| {
		name = Html.text(c.name().to_str())
		members = c.members(listing.accounts)
		Html.join([
			Html.markup("<li data-channel=\""),
			name,
			Html.markup("\"><h2>"),
			name,
			Html.markup("</h2>\n"),
			if (members.is_empty()) Html.markup("<p>No members.</p>\n") else Html.join([
				Html.markup("<ul class=members>\n"),
				Html.join(members.map(member)),
				Html.markup("</ul>\n"),
			]),
			Html.markup("<form class=admit data-path=\"/channels/"),
			name,
			Html.markup("/admit\"><label>Admit <input name=member required placeholder=\"human:2\"></label> <button>Admit</button></form>\n<form class=remove data-path=\"/channels/"),
			name,
			Html.markup("/remove\"><label>Remove <input name=member required placeholder=\"human:2\"></label> <button>Remove</button></form></li>\n"),
		])
	}
	channels =
		if listing.channels.is_empty() {
			Html.markup("<p>None yet. Make one below.</p>\n")
		} else {
			Html.join([
				Html.markup("<ul id=channels>\n"),
				Html.join(listing.channels.map(channel)),
				Html.markup("</ul>\n"),
			])
		}
	damaged =
		if listing.damaged == 0 {
			Html.join([])
		} else {
			Html.join([
				Html.markup("<p id=damaged>"),
				Html.number(listing.damaged),
				Html.markup(" channel records do not read, and are not listed.</p>\n"),
			])
		}
	page({
		title: Html.markup("Channels"),
		body_attrs: Html.join([]),
		body: Html.join([
			Html.markup("<h1>Channels</h1>\n<p class=quiet><a href=\"/chat\">All conversations</a></p>\n<p>An admin makes a channel and says who is in it. Its members are humans, by id (<code>human:2</code>); an agent reaches a channel only through a topic that names it.</p>\n"),
			damaged,
			channels,
			Html.markup("<form id=make><label>Make a channel named <input name=name required maxlength=40></label> <label>with members <input name=members placeholder=\"human:2, human:7\"></label> <button>Make</button></form>\n<p id=said></p>\n<script>\n"),
			Html.markup(channels_js),
			Html.markup("</script>\n"),
		]),
	})
}

## An id as the page writes it, escaped.
id_html : Principal.Id -> Html
id_html = |id| Html.text(AccountCodec.id_text(id))

## One key: its id, who it acts as, what it may read and post, how long it
## lives, and its revoke button; never its secret or its hash.
key_html : (Principal.Id -> Html), ConvKey.Key -> Html
key_html = |name, key| {
	r = key.record()
	id = r.id.to_u64()
	Html.join([
		Html.markup("<li data-key="),
		Html.number(id),
		Html.markup(">Key "),
		Html.number(id),
		Html.markup(" acts as "),
		name(r.acts_as),
		Html.markup(" (<code>"),
		id_html(r.acts_as),
		Html.markup("</code>); reads <code>"),
		Html.text(KeyCodec.reach_text(r.scope.read, ConvAccess.ConvId.to_u64)),
		Html.markup("</code>, posts <code>"),
		Html.text(KeyCodec.reach_text(r.scope.post, ConvAccess.ConvId.to_u64)),
		Html.markup("</code>; until <time data-at="),
		Html.signed(r.expires),
		Html.markup("></time> <button type=button class=revoke data-path=\"/keys/"),
		Html.number(id),
		Html.markup("/revoke\">Revoke</button></li>\n"),
	])
}

## A conversation: its people, its messages, each with roc-markdown's HTML
## for it, and the box to post in; a 404 to a viewer ConvAccess will not let
## see it.
serve_conversation! : {
	viewer : Access.Viewer(ConvAccess.ConvId),
	accounts : List(Principal),
	id : ConvAccess.ConvId,
} => Chat.Answer
serve_conversation! = |
	{
		viewer,
		accounts,
		id,
	},
|
	match Store.load_conversation!(id) {
		Err(Failed) => Chat.failed
		Err(Missing) => Conversations.no_such
		Ok(conv) =>
			if !ConvAccess.can_see(viewer, { conv, accounts }) {
				Conversations.no_such
			} else {
				match Conversations.load_page!(id, Newest) {
					Err(Failed) => Chat.failed
					Ok({ messages, earlier }) =>
						page({
							title: names(accounts, conv),
							body_attrs: Html.join([
								Html.markup(" data-conv=\""),
								Html.number(id.to_u64()),
								Html.markup("\""),
							]),
							body: Html.join([
								Html.markup("<h1>"),
								names(accounts, conv),
								Html.markup("</h1>\n<p class=quiet><a href=\"/chat\">All conversations</a></p>\n<ul id=people hidden>\n"),
								Html.join(
									posters(accounts, conv).map(
										|poster| Html.join([
											Html.markup("<li data-id=\""),
											id_html(poster),
											Html.markup("\">"),
											Html.text(Conversations.header_of(accounts, poster)),
											Html.markup("</li>\n"),
										]),
									),
								),
								Html.markup("</ul>\n<p><button id=earlier type=button"),
								if (earlier) Html.join([]) else Html.markup(" hidden"),
								Html.markup(">Earlier messages</button></p>\n<div id=messages>\n"),
								Html.join(messages.map(|m| message_html(accounts, m))),
								Html.markup("</div>\n<form id=post><textarea name=body rows=3 required placeholder=\"Markdown. Enter sends, Shift-Enter adds a line.\"></textarea> <span id=said></span></form>\n<script>\n"),
								Html.markup(conversation_js),
								Html.markup("</script>\n"),
							]),
						})
				}
			}
	}

## One message on the page: who (Conversations.header_of: the name, and
## the login beside it) and when (escaped; the time made local by the
## page's script), then roc-markdown's HTML for it, as is.
message_html : List(Principal), MessageCodec.Fields -> Html
message_html = |accounts, m|
	Html.join([
		Html.markup("<article id=m"),
		Html.number(m.id),
		Html.markup("><header>"),
		Html.text(Conversations.header_of(accounts, m.by)),
		Html.markup(" · <time data-at="),
		Html.signed(m.at),
		Html.markup("></time></header><div class=body>"),
		Html.rendered(Conversations.html_of(m)),
		Html.markup("</div></article>\n"),
	])

## **WHO CAN POST IN A CONVERSATION**: its participants, then the humans
## its agents and bots answer to who are not participants themselves. The
## page's people list holds each one's header (Conversations.header_of),
## which its script draws on a live message: the same text the server drew.
posters : List(Principal), ConvAccess.Conv -> List(Principal.Id)
posters = |accounts, conv| {
	ids = conv.participants().map(|b| b.id)
	owners = conv.involved(accounts).map(|h| Principal.Id.Human(h)).keep_if(|id| !ids.contains(id))
	ids.concat(owners)
}

## A conversation's people, by name, escaped, a comma between.
names : List(Principal), ConvAccess.Conv -> Html
names = |accounts, conv|
	Html.join(
		conv.participants().map_with_index(
			|b, i| Html.join([
				if (i == 0) Html.join([]) else Html.markup(", "),
				Html.text(Conversations.name_of(accounts, b.id)),
			]),
		),
	)

## The page around a body: its title (escaped already), the few lines of
## CSS, never cached.
page : {
	title : Html,
	body_attrs : Html,
	body : Html,
} -> Chat.Answer
page = |
	{
		title,
		body_attrs,
		body,
	},
|
	Html.respond(
		200,
		Html.join([
			Html.markup("<!doctype html>\n<html lang=en>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n<title>"),
			title,
			Html.markup(" · roc-chat</title>\n<style>\n"),
			Html.markup(css),
			Html.markup("</style>\n<body"),
			body_attrs,
			Html.markup(">\n"),
			body,
		]),
	)

css : Str
css =
	\\body { font: 16px/1.4 system-ui, sans-serif; max-width: 46rem; margin: 1rem auto; padding: 0 1rem; }
	\\article { border-top: 1px solid #ddd; padding: .4rem 0; }
	\\article header { color: #555; font-size: .85rem; }
	\\.body table { border-collapse: collapse; } .body td, .body th { border: 1px solid #ccc; padding: 0 .4rem; }
	\\textarea { width: 100%; box-sizing: border-box; font: inherit; }
	\\.quiet { color: #666; font-size: .9rem; }
	\\#said { color: #a00; }
	\\.pick { margin-right: 1rem; }
	\\#code { border: 2px solid #c80; padding: 0 .8rem; }
	\\

list_js : Str
list_js =
	\\const form = document.getElementById("start"), said = document.getElementById("said");
	\\form.addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  const ticked = [...form.querySelectorAll("input[name=agent]:checked")].map((i) => i.value);
	\\  const typed = form.elements.with.value.split(",").map((s) => s.trim()).filter((s) => s);
	\\  const all = ticked.concat(typed);
	\\  if (!all.length) { said.textContent = "Tick an agent or type someone's id."; return; }
	\\  const r = await fetch("/conversations", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "with=" + encodeURIComponent(all.join(",")) });
	\\  if (r.ok) location = "/chat/" + (await r.json()).id; else said.textContent = await r.text();
	\\});
	\\

## The agents page's script: each button posts the form its route takes,
## and reloads to show what changed; an invite's code, from the invite's
## own answer, is set as text, and is in no page a reload gives.
agents_js : Str
agents_js =
	\\const said = document.getElementById("said");
	\\const when = (t) => new Date(t * 1000).toLocaleString();
	\\for (const t of document.querySelectorAll("time[data-at]")) t.textContent = when(+t.dataset.at);
	\\const post = (path, body) => fetch(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body });
	\\document.getElementById("make").addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  const r = await post("/agents", "name=" + encodeURIComponent(e.target.elements.name.value.trim()));
	\\  if (r.ok) location.reload(); else said.textContent = await r.text();
	\\});
	\\for (const b of document.querySelectorAll("button.invite")) b.addEventListener("click", async () => {
	\\  const r = await post("/invites", "as=" + encodeURIComponent(b.dataset.for));
	\\  if (!r.ok) { said.textContent = await r.text(); return; }
	\\  const invite = await r.json();
	\\  document.getElementById("code-for").textContent = b.dataset.name;
	\\  document.getElementById("code-text").textContent = invite.code;
	\\  document.getElementById("code-until").textContent = when(invite.expires);
	\\  document.getElementById("code").hidden = false;
	\\  said.textContent = "";
	\\});
	\\document.getElementById("copy").addEventListener("click", async () => {
	\\  await navigator.clipboard.writeText(document.getElementById("code-text").textContent);
	\\  said.textContent = "Copied.";
	\\});
	\\for (const b of document.querySelectorAll("button.revoke")) b.addEventListener("click", async () => {
	\\  const r = await post(b.dataset.path, "");
	\\  if (r.ok) location.reload(); else said.textContent = await r.text();
	\\});
	\\

## The channels page's script: each form posts what its route takes, and
## reloads to show what changed, or says the refusal as text.
channels_js : Str
channels_js =
	\\const said = document.getElementById("said");
	\\const post = (path, body) => fetch(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body });
	\\const sent = async (r) => { if (r.ok) location.reload(); else said.textContent = await r.text(); };
	\\document.getElementById("make").addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  const f = e.target.elements;
	\\  const members = f.members.value.split(",").map((s) => s.trim()).filter((s) => s).join(",");
	\\  sent(await post("/channels", "name=" + encodeURIComponent(f.name.value.trim()) + "&members=" + encodeURIComponent(members)));
	\\});
	\\for (const form of document.querySelectorAll("form[data-path]")) form.addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  sent(await post(form.dataset.path, "member=" + encodeURIComponent(form.elements.member.value.trim())));
	\\});
	\\

## The conversation's script. A live message's HTML is roc-markdown's, from
## the stream, the one thing set as HTML; its author and time are text.
conversation_js : Str
conversation_js =
	\\const conv = document.body.dataset.conv, box = document.getElementById("messages");
	\\const heads = {};
	\\for (const li of document.querySelectorAll("#people li")) heads[li.dataset.id] = li.textContent;
	\\const when = (t) => new Date(t * 1000).toLocaleString();
	\\for (const t of document.querySelectorAll("time[data-at]")) t.textContent = when(+t.dataset.at);
	\\function article(m) {
	\\  const a = document.createElement("article"), h = document.createElement("header"), b = document.createElement("div");
	\\  a.id = "m" + m.id;
	\\  h.textContent = (heads[m.by] || m.by) + " · " + when(m.at);
	\\  b.className = "body";
	\\  b.innerHTML = m.html;
	\\  a.append(h, b);
	\\  return a;
	\\}
	\\function add(m) {
	\\  if (document.getElementById("m" + m.id)) return;
	\\  const a = article(m);
	\\  box.append(a);
	\\  a.scrollIntoView({ block: "end" });
	\\}
	\\const earlier = document.getElementById("earlier");
	\\earlier.addEventListener("click", async () => {
	\\  const first = box.querySelector("article");
	\\  const r = await fetch("/conversations/" + conv + "?before=" + first.id.slice(1));
	\\  if (!r.ok) return;
	\\  const page = await r.json();
	\\  for (const m of page.messages.reverse()) if (!document.getElementById("m" + m.id)) box.prepend(article(m));
	\\  earlier.hidden = !page.earlier;
	\\});
	\\const stream = new EventSource("/conversations/" + conv + "/stream");
	\\stream.addEventListener("message", (e) => add(JSON.parse(e.data)));
	\\stream.addEventListener("gap", () => location.reload());
	\\const form = document.getElementById("post"), text = form.elements.body, said = document.getElementById("said");
	\\text.addEventListener("keydown", (e) => {
	\\  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); form.requestSubmit(); }
	\\});
	\\form.addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  if (!text.value.trim()) return;
	\\  const r = await fetch("/conversations/" + conv + "/messages", { method: "POST", body: text.value });
	\\  if (r.ok) { add(await r.json()); text.value = ""; said.textContent = ""; } else said.textContent = await r.text();
	\\});
	\\

expect Pages.route("/chat".to_utf8()) == Ok(ConversationList)
expect Pages.route("/chat/7".to_utf8()).is_ok()
expect Pages.route("/chat/0".to_utf8()).is_err()
expect Pages.route("/chat/07".to_utf8()).is_err()
expect Pages.route("/chat/7/x".to_utf8()).is_err()
expect Pages.route("/chatx".to_utf8()).is_err()
expect Pages.route("/chat/agents".to_utf8()) == Ok(AgentList)
expect Pages.route("/chat/agents/x".to_utf8()).is_err()
expect Pages.route("/chat/channels".to_utf8()) == Ok(ChannelList)
expect Pages.route("/chat/channels/x".to_utf8()).is_err()
# The one thing a page's script sets as HTML is a message's, from the stream.
expect conversation_js.contains("b.innerHTML = m.html;") and !list_js.contains("innerHTML") and !agents_js.contains("innerHTML") and !channels_js.contains("innerHTML")

# **A NAME HOLDING A SCRIPT IS TEXT ON THE PAGE**: a message's author named
# `<script>`, as message_html writes the header, escaped.
expect {
	scripted = Principal.Human({
		id: Cast.hid(9),
		sign_in: Cast.github(9),
		login: "h9",
		name: "<script>alert(1)</script>",
		role: Member,
		generation: Cast.gen(1),
	})
	html = message_html(
		[scripted],
		{
			id: 3,
			at: 5,
			by: scripted.id(),
			body: [],
		},
	).bytes()
	html.starts_with("<article id=m3><header>&lt;script&gt;alert(1)&lt;/script&gt; · @h9 · <time data-at=5>".to_utf8()) and Bytes.find(
		html,
		{ needle: "<script>".to_utf8(), at: 0 },
	) == Err(NotFound)
}

# **AN AGENT NAMED AS A HUMAN SAYS WHOSE IT IS**: the header names its kind
# and its owner's login (Conversations.header_of), as the script draws it
# from the people list.
expect {
	owner = Principal.Human({
		id: Cast.hid(4),
		sign_in: Cast.github(4),
		login: "showell",
		name: "Steve Howell",
		role: Member,
		generation: Cast.gen(1),
	})
	posing = Principal.Agent({
		id: Cast.aid(5),
		name: "Steve Howell",
		owner: Cast.hid(4),
		generation: Cast.gen(1),
	})
	html = message_html(
		[owner, posing],
		{
			id: 3,
			at: 5,
			by: posing.id(),
			body: [],
		},
	).bytes()
	html.starts_with("<article id=m3><header>Steve Howell · agent of @showell · <time data-at=5>".to_utf8())
}
expect conversation_js.contains("heads[li.dataset.id] = li.textContent;") and conversation_js.contains("(heads[m.by] || m.by)")
