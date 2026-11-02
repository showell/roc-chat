## **THE CHAT'S PAGES, THE PLAINEST THAT WORK**: the viewer's agents and
## the channels, in a browser, and the home page's things below its
## conversations. Small, plain and replaceable: the browser client's
## pages, home and a topic's, are Home.roc's and TopicPage.roc's. Every decision is its routes' module's, on the viewer
## Credentials gives a session's cookie; here are the pages made of it. A key's Bearer header is a 403: a page is a
## browser's.
##
##     GET /chat/agents  the viewer's agents, a form to make one, and a button
##                       on each to invite it (its code shown once, by the
##                       script, from the invite's own answer); their live
##                       invites and the keys that still work, each with a
##                       button to revoke it
##     GET /chat/channels  an admin's: every channel, sorted by its key, with
##                       its members; a form to make one, and on each a form
##                       to admit a member and one to remove one (their
##                       routes Channels.roc's); a 403 to anyone else
##
## **A PAGE IS AN `Html`** (Html.roc), built only from escaped text (a
## name, an id, a title), numbers and markup written here. Signed out, a
## page sends the browser to `/login`.
##
## **THE AGENTS PAGE IS ITS OWN**, not a section of home: what it holds
## (agents, invites, keys) is the account's, and its
## script is the one place a page ever shows a code. **ITS WRITES ARE THE
## ROUTES' OWN** (Agents.roc): the script posts the forms `/agents`,
## `/invites` and the revokes take, and each decision stays theirs; the
## page adds no route. **A CODE IS SHOWN IN ONE RESPONSE**, the invite's: the
## page lists an invite by its id and its agent, and Store keeps no code to
## list.
import pf.Chat
import Access
import Account
import Agents
import Channel
import Channels
import ApiKey
import AgentInvite
import Messages
import Credentials
import Html
import Principal
import Render
import SignInWeb
import Stored
import Wire

Pages := [].{

	## What a page path asks.
	Route : [
		AgentList,
		ChannelList,
	]

	## **A PAGE OF ITS OWN**, for a visitor no page here knows (the redeem
	## page, HumanInvites'), in the pages' one frame and style.
	standalone : { title : Html, body : Html } -> Chat.Answer
	standalone = |{ title, body }| page({
		title,
		body_attrs: Html.join([]),
		body,
	})

	## Signed out: to `/login`, a 303, naming this page (`next`), so the
	## sign-in ends back on it (SignInWeb.landing).
	to_login : List(U8) -> Chat.Answer
	to_login = |path|
		Chat.respond(303, { content_type: Chat.text, body: [] })
			|> Chat.with_header(
				"location",
				"/login?next=".to_utf8().concat(SignInWeb.url_encode(path)),
			)
			|> Chat.with_header("cache-control", "no-store".to_utf8())

	## **A PAGE IS A BROWSER'S**: a key (an agent, which reads the JSON routes)
	## asking for one is a 403, whatever it may see.
	key_refused : Chat.Answer
	key_refused = Wire.refused(403, "a page is for a browser's session; a key reads a topic's JSON routes")

	## The page a path names, if it names one.
	route : List(U8) -> Try(Pages.Route, [NotAPage])
	route = |path|
		if path == root.concat("/agents".to_utf8()) {
			Ok(AgentList)
		} else if path == root.concat("/channels".to_utf8()) {
			Ok(ChannelList)
		} else {
			Err(NotAPage)
		}

	## **ANSWER A PAGE**, to a GET or a HEAD.
	answer! : Chat.Request, Pages.Route => Chat.Answer
	answer! = |req, r|
		if req.method != Get and req.method != Head {
			Chat.not_allowed(Get)
		} else {
			match r {
				AgentList => serve_agents_page!(req.path)
				ChannelList => serve_channels_page!(req.path)
			}
		}

	## **HOME'S OTHER THINGS**, below its conversations (Home.roc): the
	## form that invites someone without GitHub, the viewer's agents, and
	## the channels and the users for an admin alone (Channel says who
	## administers).
	home_extras : { viewer : Access.Viewer, accounts : List(Principal) } -> Html
	home_extras = |{ viewer, accounts }|
		Html.join([
			Html.markup(invite_form),
			Html.markup("<p><a href=\"/chat/agents\">Your agents, invites and keys</a></p>\n"),
			if (
				Channel.administers(
					viewer,
					accounts,
				).is_ok()
			) Html.markup("<p><a href=\"/chat/channels\">Channels (an admin's)</a></p>\n<p><a href=\"/chat/users\">Users (an admin's)</a></p>\n") else Html.join([]),
			Html.markup("\n<script>\n"),
			Html.markup(home_js),
			Html.markup("</script>\n"),
		])

}

root : List(U8)
root = "/chat".to_utf8()

## **/chat/agents**: the page, for a live session; signed out, to
## `/login`; a key, the 403 every page gives one.
serve_agents_page! : List(U8) => Chat.Answer
serve_agents_page! = |here|
	match Agents.load_owned!({}) {
		Ok(mine) => agents_page(mine)
		Err(SignedOut) => Pages.to_login(here)
		Err(ByKey) => Pages.key_refused
		Err(Answered(answer)) => answer
	}

## An agent's or bot's number, as its rename route names it.
agent_number : Principal.Id -> U64
agent_number = |id|
	match id {
		Agent(a) | Bot(a) => a.to_u64()
		Human(h) => h.to_u64()
	}

## The agents page: the viewer's agents, each with its invite button and
## its rename form, the
## form to make one, the box the script shows a code in, then the live
## invites and the keys, each with its revoke button. Everything written
## here is escaped; no code, secret or hash is in what it is made of.
agents_page : Agents.Mine -> Chat.Answer
agents_page = |mine| {
	name = |id| Html.text(Render.name_of(mine.accounts, id))
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
								Html.markup("\">Invite</button> <form class=rename data-path=\"/agents/"),
								Html.number(agent_number(id)),
								Html.markup("/rename\"><label>Rename to <input name=name required maxlength=64 value=\""),
								name(id),
								Html.markup("\"></label> <button>Rename</button></form></li>\n"),
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
			Html.markup("<h1>Your agents</h1>\n<p class=quiet><a href=\"/chat\">Home</a></p>\n<p>An agent talks in the chat as itself, and answers to you. Invite one to give it a key of its own: it gets a code to redeem, and never needs yours.</p>\n"),
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
serve_channels_page! : List(U8) => Chat.Answer
serve_channels_page! = |here|
	match Channels.load_listing!({}) {
		Ok(listing) => channels_page(listing)
		Err(SignedOut) => Pages.to_login(here)
		Err(ByKey) => Pages.key_refused
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
		Html.text(Render.name_of(listing.accounts, b.id)),
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
			Html.markup("<h1>Channels</h1>\n<p class=quiet><a href=\"/chat\">Home</a></p>\n<p>An admin makes a channel and says who is in it. Its members are humans, agents and bots, by id (<code>human:2</code>, <code>agent:7</code>), and each member takes part in every topic in it.</p>\n"),
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
id_html = |id| Html.text(Account.id_text(id))

## One key: its id, who it acts as, what it may read and post, how long it
## lives, and its revoke button; never its secret or its hash.
key_html : (Principal.Id -> Html), ApiKey.Key -> Html
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
		Html.text(ApiKey.reach_text(r.scope.read)),
		Html.markup("</code>, posts <code>"),
		Html.text(ApiKey.reach_text(r.scope.post)),
		Html.markup("</code>; until <time data-at="),
		Html.signed(r.expires),
		Html.markup("></time> <button type=button class=revoke data-path=\"/keys/"),
		Html.number(id),
		Html.markup("/revoke\">Revoke</button></li>\n"),
	])
}

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

## The home page's script: the invite form posts the name, and the link,
## from the invite's own answer, is set as text.
home_js : Str
home_js =
	\\const invite = document.getElementById("invite"), invited = document.getElementById("invited");
	\\const link = document.getElementById("link"), inviteSaid = document.getElementById("invite-said");
	\\invite.addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  const r = await fetch("/human-invites", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "name=" + encodeURIComponent(invite.elements.name.value.trim()) });
	\\  if (!r.ok) { inviteSaid.textContent = await r.text(); return; }
	\\  link.textContent = location.origin + (await r.json()).link;
	\\  invited.hidden = false;
	\\  inviteSaid.textContent = "";
	\\});
	\\document.getElementById("copy-link").addEventListener("click", async () => {
	\\  await navigator.clipboard.writeText(link.textContent);
	\\  inviteSaid.textContent = "Copied.";
	\\});
	\\

## **THE FORM THAT INVITES SOMEONE** without GitHub (HumanInvites): a
## name, and the link shown once, from the invite's own answer.
invite_form : Str
invite_form =
	\\<h2>Invite someone</h2>
	\\<form id=invite><label>Their name <input name=name required maxlength=40></label> <button>Invite</button></form>
	\\<p id=invited hidden>Send them this link, which works once, for 7 days: <code id=link></code> <button id=copy-link type=button>Copy</button></p>
	\\<p id=invite-said></p>
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
	\\for (const f of document.querySelectorAll("form.rename")) f.addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  const r = await post(f.dataset.path, "name=" + encodeURIComponent(f.elements.name.value.trim()));
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

expect Pages.route("/chat".to_utf8()).is_err()
expect Pages.route("/chat/7".to_utf8()).is_err()
expect Pages.route("/chatx".to_utf8()).is_err()
expect Pages.route("/chat/agents".to_utf8()) == Ok(AgentList)
expect Pages.route("/chat/agents/x".to_utf8()).is_err()
expect Pages.route("/chat/channels".to_utf8()) == Ok(ChannelList)
expect Pages.route("/chat/channels/x".to_utf8()).is_err()
# No page's script here sets anything as HTML.
expect !home_js.contains("innerHTML") and !agents_js.contains("innerHTML") and !channels_js.contains("innerHTML")
