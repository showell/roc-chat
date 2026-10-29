## **THE CHAT'S PAGES, THE PLAINEST THAT WORK** (metal-vmm QUEUE 315): a list
## of the viewer's conversations, and a conversation to read live and post
## in, in a browser. Small, plain and replaceable: the real client is
## chat-client's, later. Every decision is step 6's (Conversations.roc,
## ConvAccess); here are the pages made of it.
##
##     GET /chat         the viewer's conversations, each a link, and a form to start one
##     GET /chat/<id>    a conversation: its messages, then each new one live (its
##                       stream, by the browser's EventSource, which resumes with
##                       Last-Event-ID by itself), and a box to post markdown in
##                       (Enter sends, Shift-Enter adds a line)
##
## **WHAT THE PAGE WRITES ITSELF IS ESCAPED** (`escape`): a name, an id, a
## title. **A MESSAGE'S HTML IS THE RENDERER'S OUTPUT, AND ONLY THAT**: the
## page holds roc-markdown's HTML for it (Conversations.html_of), as the
## transcript and the stream give it, and nothing else is ever put in as
## HTML. Signed out, a page sends the browser to `/login`; a conversation
## the viewer may not see is the 404 of one that is not there.
import pf.Chat
import Access
import AccountCodec
import ConvAccess
import Conversations
import MessageCodec
import Principal
import SignIn
import Store
import Stored

Pages := [].{

	## What a page path asks.
	Route : [List, Conversation(ConvAccess.ConvId)]

	## The page a path names, if it names one.
	route : List(U8) -> Try(Pages.Route, [NotAPage])
	route = |path|
		if path == root {
			Ok(List)
		} else if List.starts_with(path, List.append(root, '/')) {
			digits = List.drop_first(path, List.len(root) + 1)
			match Stored.count(digits, "id") {
				Err(_) => Err(NotAPage)
				Ok(n) =>
					match ConvAccess.ConvId.from_u64(n) {
						Ok(id) => Ok(Conversation(id))
						Err(NotAnId) => Err(NotAPage)
					}
			}
		} else {
			Err(NotAPage)
		}

	## **ANSWER A PAGE**, to a GET or a HEAD.
	answer! : Chat.Request, Pages.Route => Chat.Answer
	answer! = |req, r|
		if req.method != Get and req.method != Head {
			Chat.not_allowed(Get)
		} else {
			match SignIn.viewer!({}) {
				Err(Failed) => Chat.failed
				Ok({ viewer, accounts, now: _ }) =>
					match viewer.who() {
						SignedOut => to_login
						Session(me) | Key(me) =>
							match r {
								List => list!({ viewer, accounts, me: me.id })
								Conversation(id) => conversation!({ viewer, accounts, id })
							}
					}
			}
		}

	## **TEXT AS HTML TEXT**: its `&`, `<`, `>`, `"` and `'` as entities, so
	## no text the page writes (a name, an id) is ever markup, in an element
	## or an attribute.
	escape : List(U8) -> List(U8)
	escape = |text|
		List.join_map(
			text,
			|b|
				if b == '&' {
					Str.to_utf8("&amp;")
				} else if b == '<' {
					Str.to_utf8("&lt;")
				} else if b == '>' {
					Str.to_utf8("&gt;")
				} else if b == '"' {
					Str.to_utf8("&quot;")
				} else if b == '\'' {
					Str.to_utf8("&#39;")
				} else {
					[b]
				},
		)
}

root : List(U8)
root = Str.to_utf8("/chat")

## Signed out: to `/login`, a 303. (Back to this page after sign-in would
## need the page carried through the signed OAuth state, a change to the
## sign-in core: not built.)
to_login : Chat.Answer
to_login =
	Chat.respond(303, { content_type: Chat.text, body: [] })
		|> Chat.with_header("location", Str.to_utf8("/login"))
		|> Chat.with_header("cache-control", Str.to_utf8("no-store"))

## The list: the viewer's conversations (Conversations.mine!), each its
## people's names and a link, and the form that starts one.
list! : { viewer : Access.Viewer(ConvAccess.ConvId), accounts : List(Principal), me : Principal.Id } => Chat.Answer
list! = |{ viewer, accounts, me }|
	match Conversations.mine!(viewer, accounts) {
		Err(Failed) => Chat.failed
		Ok(convs) => {
			items =
				if List.is_empty(convs) {
					Str.to_utf8("<p>None yet.</p>\n")
				} else {
					List.join([
						Str.to_utf8("<ul id=conversations>\n"),
						List.join_map(
							convs,
							|conv| List.join([
								Str.to_utf8("<li><a href=\"/chat/${conv.id().to_u64().to_str()}\">"),
								names(accounts, conv),
								Str.to_utf8("</a></li>\n"),
							]),
						),
						Str.to_utf8("</ul>\n"),
					])
				}
			page({
				title: Str.to_utf8("Conversations"),
				body_attrs: [],
				body: List.join([
					Str.to_utf8("<h1>Your conversations</h1>\n"),
					items,
					Str.to_utf8("<form id=start><label>Start one with <input name=with placeholder=\"human:2,agent:7\" required></label> <button>Start</button> <span id=said></span></form>\n<p class=quiet>Signed in as "),
					Pages.escape(Str.to_utf8(Conversations.name_of(accounts, me))),
					Str.to_utf8(" ("),
					Pages.escape(Str.to_utf8(AccountCodec.id_text(me))),
					Str.to_utf8(").</p>\n<script>\n"),
					Str.to_utf8(list_js),
					Str.to_utf8("</script>\n"),
				]),
			})
		}
	}

## A conversation: its people, its messages, each with roc-markdown's HTML
## for it, and the box to post in; a 404 to a viewer ConvAccess will not let
## see it.
conversation! : { viewer : Access.Viewer(ConvAccess.ConvId), accounts : List(Principal), id : ConvAccess.ConvId } => Chat.Answer
conversation! = |{ viewer, accounts, id }|
	match Store.conversation!(id) {
		Err(Failed) => Chat.failed
		Err(Missing) => no_such
		Ok(conv) =>
			if !ConvAccess.can_see(viewer, { conv, accounts }) {
				no_such
			} else {
				match Store.transcript!(id) {
					Err(Failed) => Chat.failed
					Ok(messages) =>
						page({
							title: names(accounts, conv),
							body_attrs: Str.to_utf8(" data-conv=\"${id.to_u64().to_str()}\""),
							body: List.join([
								Str.to_utf8("<h1>"),
								names(accounts, conv),
								Str.to_utf8("</h1>\n<p class=quiet><a href=\"/chat\">All conversations</a></p>\n<ul id=people hidden>\n"),
								List.join_map(
									conv.participants(),
									|b| List.join([
										Str.to_utf8("<li data-id=\""),
										Pages.escape(Str.to_utf8(AccountCodec.id_text(b.id))),
										Str.to_utf8("\">"),
										Pages.escape(Str.to_utf8(Conversations.name_of(accounts, b.id))),
										Str.to_utf8("</li>\n"),
									]),
								),
								Str.to_utf8("</ul>\n<div id=messages>\n"),
								List.join_map(messages, |m| message_html(accounts, m)),
								Str.to_utf8("</div>\n<form id=post><textarea name=body rows=3 required placeholder=\"Markdown. Enter sends, Shift-Enter adds a line.\"></textarea> <span id=said></span></form>\n<script>\n"),
								Str.to_utf8(conversation_js),
								Str.to_utf8("</script>\n"),
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
		Str.to_utf8("<article id=m${m.id.to_str()}><header>"),
		Pages.escape(Str.to_utf8(Conversations.name_of(accounts, m.by))),
		Str.to_utf8(" · <time data-at=${m.at.to_str()}></time></header><div class=body>"),
		Conversations.html_of(m),
		Str.to_utf8("</div></article>\n"),
	])

## A conversation's people, by name, escaped, a comma between.
names : List(Principal), ConvAccess.Conv -> List(U8)
names = |accounts, conv|
	List.join(
		List.map_with_index(
			conv.participants(),
			|b, i| List.concat(if i == 0 [] else Str.to_utf8(", "), Pages.escape(Str.to_utf8(Conversations.name_of(accounts, b.id)))),
		),
	)

## The page around a body: its title (escaped already), the few lines of
## CSS, never cached.
page : { title : List(U8), body_attrs : List(U8), body : List(U8) } -> Chat.Answer
page = |{ title, body_attrs, body }|
	Chat.respond(
		200,
		{
			content_type: Chat.html,
			body: List.join([
				Str.to_utf8("<!doctype html>\n<html lang=en>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n<title>"),
				title,
				Str.to_utf8(" · roc-chat</title>\n<style>\n"),
				Str.to_utf8(css),
				Str.to_utf8("</style>\n<body"),
				body_attrs,
				Str.to_utf8(">\n"),
				body,
			]),
		},
	)
		|> Chat.with_header("cache-control", Str.to_utf8("no-store"))

no_such : Chat.Answer
no_such = Chat.respond(404, { content_type: Chat.text, body: Str.to_utf8("no such conversation\n") })

css : Str
css =
	\\body { font: 16px/1.4 system-ui, sans-serif; max-width: 46rem; margin: 1rem auto; padding: 0 1rem; }
	\\article { border-top: 1px solid #ddd; padding: .4rem 0; }
	\\article header { color: #555; font-size: .85rem; }
	\\.body table { border-collapse: collapse; } .body td, .body th { border: 1px solid #ccc; padding: 0 .4rem; }
	\\textarea { width: 100%; box-sizing: border-box; font: inherit; }
	\\.quiet { color: #666; font-size: .9rem; }
	\\#said { color: #a00; }
	\\

list_js : Str
list_js =
	\\const form = document.getElementById("start"), said = document.getElementById("said");
	\\form.addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  const r = await fetch("/conversations", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "with=" + encodeURIComponent(form.elements.with.value.trim()) });
	\\  if (r.ok) location = "/chat/" + (await r.json()).id; else said.textContent = await r.text();
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
	\\function add(m) {
	\\  if (document.getElementById("m" + m.id)) return;
	\\  const a = document.createElement("article"), h = document.createElement("header"), b = document.createElement("div");
	\\  a.id = "m" + m.id;
	\\  h.textContent = (names[m.by] || m.by) + " · " + when(m.at);
	\\  b.className = "body";
	\\  b.innerHTML = m.html;
	\\  a.append(h, b);
	\\  box.append(a);
	\\  a.scrollIntoView({ block: "end" });
	\\}
	\\new EventSource("/conversations/" + conv + "/stream").addEventListener("message", (e) => add(JSON.parse(e.data)));
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

expect Pages.escape(Str.to_utf8("Bea <i>x</i> & \"co\" 'q'")) == Str.to_utf8("Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot; &#39;q&#39;")
expect Pages.escape(Str.to_utf8("Zoë 🎉")) == Str.to_utf8("Zoë 🎉")
expect Pages.route(Str.to_utf8("/chat")) == Ok(List)
expect Pages.route(Str.to_utf8("/chat/7")).is_ok()
expect Pages.route(Str.to_utf8("/chat/0")).is_err()
expect Pages.route(Str.to_utf8("/chat/07")).is_err()
expect Pages.route(Str.to_utf8("/chat/7/x")).is_err()
expect Pages.route(Str.to_utf8("/chatx")).is_err()
# The one thing a page's script sets as HTML is a message's, from the stream.
expect Str.count_utf8_bytes(conversation_js) > 0 and Str.contains(conversation_js, "b.innerHTML = m.html;") and !Str.contains(list_js, "innerHTML")
