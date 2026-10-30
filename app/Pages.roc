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
##     GET /chat/<id>    a conversation: its newest page of messages (and a button
##                       for each page before it), then each new one live (its
##                       stream, by the browser's EventSource, which resumes with
##                       Last-Event-ID by itself, and reloads the page on a `gap`),
##                       and a box to post markdown in (Enter sends, Shift-Enter
##                       adds a line)
##
## **WHAT THE PAGE WRITES ITSELF IS ESCAPED** (`escape`): a name, an id, a
## title. **A MESSAGE'S HTML IS THE RENDERER'S OUTPUT, AND ONLY THAT**: the
## page holds roc-markdown's HTML for it (Conversations.html_of), as the
## transcript and the stream give it, and nothing else is ever put in as
## HTML. Signed out, a page sends the browser to `/login`; a conversation
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
import ConvKey
import InviteCodec
import KeyCodec
import ConvAccess
import Conversations
import Credentials
import MessageCodec
import Principal
import Store
import Stored
import Wire

Pages := [].{

	## What a page path asks.
	Route : [ConversationList, AgentList, Conversation(ConvAccess.ConvId)]

	## The page a path names, if it names one.
	route : List(U8) -> Try(Pages.Route, [NotAPage])
	route = |path|
		if path == root {
			Ok(ConversationList)
		} else if path == root.concat("/agents".to_utf8()) {
			Ok(AgentList)
		} else if path.starts_with(root.append('/')) {
			Conversations.id_of(List.drop_first(path, List.len(root) + 1)).map_ok(|id| Conversation(id)).map_err(|_| NotAPage)
		} else {
			Err(NotAPage)
		}

	## **ANSWER A PAGE**, to a GET or a HEAD.
	answer! : Chat.Request, Pages.Route => Chat.Answer
	answer! = |req, r|
		if req.method != Get and req.method != Head {
			Chat.not_allowed(Get)
		} else if r == AgentList {
			agents_answer!({})
		} else {
			use =
				match r {
					ConversationList | AgentList => ListConversations
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
								AgentList => agents_answer!({})
								Conversation(id) => serve_conversation!({
									viewer,
									accounts,
									id,
								})
							}
					}
			}
		}

	## **TEXT AS HTML TEXT**: its `&`, `<`, `>`, `"` and `'` as entities, so
	## no text the page writes (a name, an id) is ever markup, in an element
	## or an attribute.
	escape : List(U8) -> List(U8)
	escape = |text|
		text.join_map(
			|b|
				if b == '&' {
					"&amp;".to_utf8()
				} else if b == '<' {
					"&lt;".to_utf8()
				} else if b == '>' {
					"&gt;".to_utf8()
				} else if b == '"' {
					"&quot;".to_utf8()
				} else if b == '\'' {
					"&#39;".to_utf8()
				} else {
					[b]
				},
		)
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
					"<p>None yet.</p>\n".to_utf8()
				} else {
					[
						"<ul id=conversations>\n".to_utf8(),
						convs.join_map(
							|conv| [
								"<li><a href=\"/chat/${conv.id().to_u64().to_str()}\">".to_utf8(),
								names(accounts, conv),
								"</a></li>\n".to_utf8(),
							].join(),
						),
						"</ul>\n".to_utf8(),
					].join()
				}
			page({
				title: "Conversations".to_utf8(),
				body_attrs: [],
				body: List.join([
					"<h1>Your conversations</h1>\n".to_utf8(),
					items,
					start_form(accounts, me),
					"<p><a href=\"/chat/agents\">Your agents, invites and keys</a></p>\n<p class=quiet>Signed in as ".to_utf8(),
					Pages.escape(Str.to_utf8(Conversations.name_of(accounts, me))),
					" (".to_utf8(),
					Pages.escape(Str.to_utf8(AccountCodec.id_text(me))),
					").</p>\n<script>\n".to_utf8(),
					list_js.to_utf8(),
					"</script>\n".to_utf8(),
				]),
			})
		}
	}

## **THE FORM THAT STARTS A CONVERSATION**: a box to tick for each of the
## viewer's own agents (Agents.agents_of), and anyone else by id, typed;
## the script sends them all as `with=`, which decides who may be named.
start_form : List(Principal), Principal.Id -> List(U8)
start_form = |accounts, me| {
	mine =
		match me {
			Human(human) => Agents.agents_of(accounts, human)
			Agent(_) | Bot(_) => []
		}
	ticks =
		List.join_map(
			mine,
			|a| List.join([
				"<label class=pick><input type=checkbox name=agent value=\"".to_utf8(),
				Pages.escape(Str.to_utf8(AccountCodec.id_text(Principal.id(a)))),
				"\"> ".to_utf8(),
				Pages.escape(Str.to_utf8(Conversations.name_of(accounts, Principal.id(a)))),
				"</label>\n".to_utf8(),
			]),
		)
	[
		"<form id=start><p>Start one with:</p>\n".to_utf8(),
		ticks,
		"<label>Anyone else, by id <input name=with placeholder=\"human:2, agent:7\"></label> <button>Start</button> <span id=said></span></form>\n".to_utf8(),
	].join()
}

## **/chat/agents**: the page, for a live session; signed out, to
## `/login`; a key, the 403 every page gives one.
agents_answer! : {} => Chat.Answer
agents_answer! = |{}|
	match Agents.mine!({}) {
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
	name = |id| Pages.escape(Str.to_utf8(Conversations.name_of(mine.accounts, id)))
	agents =
		if mine.agents.is_empty() {
			"<p>None yet. Make one below.</p>\n".to_utf8()
		} else {
			[
				"<ul id=agents>\n".to_utf8(),
				mine.agents.join_map(
					|a| {
						id = a.id()
						[
							"<li data-id=\"".to_utf8(),
							id_html(id),
							"\"><b>".to_utf8(),
							name(id),
							"</b> <code>".to_utf8(),
							id_html(id),
							"</code> <button type=button class=invite data-for=\"".to_utf8(),
							id_html(id),
							"\" data-name=\"".to_utf8(),
							name(id),
							"\">Invite</button></li>\n".to_utf8(),
						].join()
					},
				),
				"</ul>\n".to_utf8(),
			].join()
		}
	invites =
		if mine.invites.is_empty() {
			"<p>None waiting.</p>\n".to_utf8()
		} else {
			[
				"<ul id=invites>\n".to_utf8(),
				mine.invites.join_map(
					|i| [
						"<li data-invite=${i.id.to_u64().to_str()}>For ".to_utf8(),
						name(i.bound.id),
						" (<code>".to_utf8(),
						id_html(i.bound.id),
						"</code>), until <time data-at=${i.expires.to_str()}></time> <button type=button class=revoke data-path=\"/invites/${i.id.to_u64().to_str()}/revoke\">Revoke</button></li>\n".to_utf8(),
					].join(),
				),
				"</ul>\n".to_utf8(),
			].join()
		}
	keys =
		if mine.keys.is_empty() {
			"<p>None.</p>\n".to_utf8()
		} else {
			[
				"<ul id=keys>\n".to_utf8(),
				mine.keys.join_map(|k| key_html(name, k)),
				"</ul>\n".to_utf8(),
			].join()
		}
	page({
		title: "Agents".to_utf8(),
		body_attrs: [],
		body: [
			"<h1>Your agents</h1>\n<p class=quiet><a href=\"/chat\">All conversations</a></p>\n<p>An agent talks in the chat as itself, and answers to you. Invite one to give it a key of its own: it gets a code to redeem, and never needs yours.</p>\n".to_utf8(),
			agents,
			"<form id=make><label>Make an agent named <input name=name required maxlength=64></label> <button>Make</button></form>\n<div id=code hidden><p><b>The invite code for <span id=code-for></span>, shown only now:</b></p>\n<p><code id=code-text></code> <button type=button id=copy>Copy</button></p>\n<p>Give it to the agent within ten minutes (until <time id=code-until></time>). It works once: the agent sends it to <code>POST /invites/redeem</code> as <code>code=</code> and gets its own key back. Reload this page and the code is gone; the invite is listed below until it is redeemed or revoked.</p></div>\n<h2>Invites waiting</h2>\n".to_utf8(),
			invites,
			"<h2>Keys that work</h2>\n".to_utf8(),
			keys,
			"<p id=said></p>\n<script>\n".to_utf8(),
			agents_js.to_utf8(),
			"</script>\n".to_utf8(),
		].join(),
	})
}

## An id as the page writes it, escaped.
id_html : Principal.Id -> List(U8)
id_html = |id| Pages.escape(Str.to_utf8(AccountCodec.id_text(id)))

## One key: its id, who it acts as, what it may read and post, how long it
## lives, and its revoke button; never its secret or its hash.
key_html : (Principal.Id -> List(U8)), ConvKey.Key -> List(U8)
key_html = |name, key| {
	r = key.record()
	List.join([
		"<li data-key=${r.id.to_u64().to_str()}>Key ${r.id.to_u64().to_str()} acts as ".to_utf8(),
		name(r.acts_as),
		" (<code>".to_utf8(),
		id_html(r.acts_as),
		Str.to_utf8("</code>); reads <code>${KeyCodec.reach_text(r.scope.read, ConvAccess.ConvId.to_u64)}</code>, posts <code>${KeyCodec.reach_text(r.scope.post, ConvAccess.ConvId.to_u64)}</code>; until <time data-at=${r.expires.to_str()}></time> <button type=button class=revoke data-path=\"/keys/${r.id.to_u64().to_str()}/revoke\">Revoke</button></li>\n"),
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
							body_attrs: " data-conv=\"${id.to_u64().to_str()}\"".to_utf8(),
							body: List.join([
								"<h1>".to_utf8(),
								names(accounts, conv),
								"</h1>\n<p class=quiet><a href=\"/chat\">All conversations</a></p>\n<ul id=people hidden>\n".to_utf8(),
								List.join_map(
									conv.participants(),
									|b| List.join([
										"<li data-id=\"".to_utf8(),
										Pages.escape(Str.to_utf8(AccountCodec.id_text(b.id))),
										"\">".to_utf8(),
										Pages.escape(
											Str.to_utf8(
												Conversations.name_of(
													accounts,
													b.id,
												),
											),
										),
										"</li>\n".to_utf8(),
									]),
								),
								"</ul>\n<p><button id=earlier type=button${if (earlier) "" else " hidden"}>Earlier messages</button></p>\n<div id=messages>\n".to_utf8(),
								messages.join_map(|m| message_html(accounts, m)),
								"</div>\n<form id=post><textarea name=body rows=3 required placeholder=\"Markdown. Enter sends, Shift-Enter adds a line.\"></textarea> <span id=said></span></form>\n<script>\n".to_utf8(),
								conversation_js.to_utf8(),
								"</script>\n".to_utf8(),
							]),
						})
				}
			}
	}

## One message on the page: who and when (escaped; the time made local by
## the page's script), then roc-markdown's HTML for it, as is.
message_html : List(Principal), MessageCodec.Fields -> List(U8)
message_html = |accounts, m|
	List.join([
		"<article id=m${m.id.to_str()}><header>".to_utf8(),
		Pages.escape(Str.to_utf8(Conversations.name_of(accounts, m.by))),
		" · <time data-at=${m.at.to_str()}></time></header><div class=body>".to_utf8(),
		Conversations.html_of(m),
		"</div></article>\n".to_utf8(),
	])

## A conversation's people, by name, escaped, a comma between.
names : List(Principal), ConvAccess.Conv -> List(U8)
names = |accounts, conv|
	List.join(
		List.map_with_index(
			conv.participants(),
			|b, i| {
				name = Conversations.name_of(accounts, b.id)
				(if (i == 0) [] else ", ".to_utf8()).concat(Pages.escape(name.to_utf8()))
			},
		),
	)

## The page around a body: its title (escaped already), the few lines of
## CSS, never cached.
page : {
	title : List(U8),
	body_attrs : List(U8),
	body : List(U8),
} -> Chat.Answer
page = |
	{
		title,
		body_attrs,
		body,
	},
|
	Chat.respond(
		200,
		{
			content_type: Chat.html,
			body: [
				"<!doctype html>\n<html lang=en>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n<title>".to_utf8(),
				title,
				" · roc-chat</title>\n<style>\n".to_utf8(),
				css.to_utf8(),
				"</style>\n<body".to_utf8(),
				body_attrs,
				">\n".to_utf8(),
				body,
			].join(),
		},
	)
		|> Chat.with_header("cache-control", "no-store".to_utf8())

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

## The conversation's script. A live message's HTML is roc-markdown's, from
## the stream, the one thing set as HTML; its author and time are text.
conversation_js : Str
conversation_js =
	\\const conv = document.body.dataset.conv, box = document.getElementById("messages");
	\\const names = {};
	\\for (const li of document.querySelectorAll("#people li")) names[li.dataset.id] = li.textContent;
	\\const when = (t) => new Date(t * 1000).toLocaleString();
	\\for (const t of document.querySelectorAll("time[data-at]")) t.textContent = when(+t.dataset.at);
	\\function article(m) {
	\\  const a = document.createElement("article"), h = document.createElement("header"), b = document.createElement("div");
	\\  a.id = "m" + m.id;
	\\  h.textContent = (names[m.by] || m.by) + " · " + when(m.at);
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

expect Pages.escape("Bea <i>x</i> & \"co\" 'q'".to_utf8()) == "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot; &#39;q&#39;".to_utf8()
expect Pages.escape("Zoë 🎉".to_utf8()) == "Zoë 🎉".to_utf8()
expect Pages.route("/chat".to_utf8()) == Ok(ConversationList)
expect Pages.route("/chat/7".to_utf8()).is_ok()
expect Pages.route("/chat/0".to_utf8()).is_err()
expect Pages.route("/chat/07".to_utf8()).is_err()
expect Pages.route("/chat/7/x".to_utf8()).is_err()
expect Pages.route("/chatx".to_utf8()).is_err()
expect Pages.route("/chat/agents".to_utf8()) == Ok(AgentList)
expect Pages.route("/chat/agents/x".to_utf8()).is_err()
# The one thing a page's script sets as HTML is a message's, from the stream.
expect conversation_js.contains("b.innerHTML = m.html;") and !list_js.contains("innerHTML") and !agents_js.contains("innerHTML")
