## **A MESSAGE AS THE BROWSER CLIENT DRAWS IT**: one bubble, the same
## markup on the topic page, in a page of earlier messages, and in the
## fragment each live viewer is sent, so the three never disagree. The
## shape is Gopher Chat's (chat-client's js/message.js, `render` and
## `buildMeta`): a `chat-msg` holding its meta line, `#<n> <name> · <time>`,
## then its body, roc-markdown's HTML, as is.
##
## **ONE FRAGMENT FOR EVERY VIEWER**: the bubble names its author
## (`data-by`, a principal's id) and the page names its viewer (`data-me`),
## and the page's script marks it `mine` or `theirs`; so the fragment a post
## publishes is built once, for every stream. Its time is machine-readable
## (`data-at`, unix seconds) and the script writes it in the viewer's zone,
## which the server does not know. Pure.
import Account
import Cast
import Html
import Transcript
import Principal
import Reactions
import Render
import UtcTime

Bubble := [].{

	## **THE BUBBLE**: its local reference (`data-ref`, `<topic>_<n>`, the
	## server's spelling, which the page's notices say), who posted it (Render.header_of, the rule
	## every renderer draws, so an agent named as a human says whose it is)
	## and when, then roc-markdown's HTML for it. Everything written here is
	## escaped; the body is the renderer's.
	##
	## **ITS META LINE'S LINKS** are the old ones (js/message.js `buildMeta`):
	## "quote-reply" (q), "edit" (e), which the page's script shows on the
	## viewer's own alone, so every viewer's bubble is the same. **ITS REACTIONS**
	## follow its body, a strip of chips (Reactions.strip), empty when it has
	## none. **AN EDITED MESSAGE** (`EditedIn`, Edits.roc) shows
	## "Edited in <the edit's reference>" and its markdown in an "original" spoiler,
	## in place of its body (js/message.js `markEdited`).
	of : List(Principal),
	{
		m : Transcript.Fields,
		ref : Str,
		edited : [NotEdited, EditedIn({ id : U64, ref : Str })],
		reactions : List(Reactions.Chip),
	} -> Html
	of = |
		accounts,
		{
			m,
			ref,
			edited,
			reactions,
		},
	|
		Html.join([
			Html.markup("<div class=chat-msg id=msg-"),
			Html.number(m.id),
			Html.markup(" data-id="),
			Html.number(m.id),
			Html.markup(" data-ref=\""),
			Html.text(ref),
			Html.markup("\" data-by=\""),
			Html.text(Account.id_text(m.by)),
			Html.markup("\"><div class=chat-meta>#"),
			Html.number(m.id),
			Html.markup(" "),
			Html.text(Render.header_of(accounts, m.by)),
			Html.markup(" · <time class=chat-time datetime="),
			Html.text(UtcTime.iso(m.at)),
			Html.markup(" data-at="),
			Html.signed(m.at),
			Html.markup(">"),
			Html.text(UtcTime.fallback(m.at)),
			Html.markup("</time> <button type=button class=msg-quote title=\"Quote this message in a reply (q)\">quote-reply</button> <button type=button class=msg-edit title=\"Load this message back into compose with an &quot;Edit of MSG_…&quot; backlink (e)\">edit</button>"),
			Html.markup("</div><div class=chat-body>"),
			match edited {
				NotEdited => Html.rendered(Render.html_of(m))
				EditedIn(e) =>
					Html.join([
						Html.markup("<div class=chat-edited-note>Edited in <a class=msg-ref href=\"#msg-"),
						Html.number(e.id),
						Html.markup("\">"),
						Html.text(e.ref),
						Html.markup("</a></div><details class=chat-edited-spoiler><summary>original</summary><div class=chat-edited-orig>"),
						Html.escape(m.body),
						Html.markup("</div></details>"),
					])
			},
			Html.markup("</div>"),
			Reactions.strip({ n: m.id, chips: reactions }),
			Html.markup("</div>\n"),
		])

	## **THE BUBBLE AS AN SSE EVENT'S DATA**: an event holds no CR (Sse.frame
	## refuses one), so a CR the markdown kept is written as its character
	## reference, which the browser reads back as the same character, in
	## text or in an attribute. An LF stays: each line is a `data:` line,
	## rejoined by the browser.
	data : Html -> List(U8)
	data = |bubble| bubble.bytes().join_map(|b| if (b == '\r') "&#13;".to_utf8() else [b])
}

# ── tests
human : Principal
human = Principal.Human({
	id: Cast.hid(9),
	sign_in: Cast.github(9),
	login: "h9",
	name: "<b>\"&'",
	role: Member,
	generation: Cast.gen(1),
})

# **A NAME HOLDING A SCRIPT IS TEXT ON THE PAGE**, escaped in the meta line.
expect {
	scripted = Principal.Human({
		id: Cast.hid(9),
		sign_in: Cast.github(9),
		login: "h9",
		name: "<script>alert(1)</script>",
		role: Member,
		generation: Cast.gen(1),
	})
	html = Str.from_utf8(
		Bubble.of(
			[scripted],
			{
				m: {
					id: 3,
					at: 5,
					by: scripted.id(),
					body: [],
				},
				ref: "4_3",
				edited: NotEdited,
				reactions: [],
			},
		).bytes(),
	) ?? ""
	html.contains("<div class=chat-meta>#3 &lt;script&gt;alert(1)&lt;/script&gt; · @h9 · <time") and !html.contains("<script>")
}

# **AN AGENT NAMED AS A HUMAN SAYS WHOSE IT IS**: the meta line names its
# kind and its owner's login (Render.header_of).
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
	html = Str.from_utf8(
		Bubble.of(
			[owner, posing],
			{
				m: {
					id: 3,
					at: 5,
					by: posing.id(),
					body: [],
				},
				ref: "4_3",
				edited: NotEdited,
				reactions: [],
			},
		).bytes(),
	) ?? ""
	html.contains("<div class=chat-meta>#3 Steve Howell · agent of @showell · <time")
}

# **A NAME IS TEXT**: the meta line holds the poster's header escaped, and
# the author's id as an attribute; the body is roc-markdown's.
expect {
	m = {
		id: 3,
		at: 5,
		by: human.id(),
		body: "*hi*".to_utf8(),
	}
	html = Bubble.of(
		[human],
		{
			m,
			ref: "<T>_3",
			edited: NotEdited,
			reactions: [],
		},
	).bytes()
	html == "<div class=chat-msg id=msg-3 data-id=3 data-ref=\"&lt;T&gt;_3\" data-by=\"human:9\"><div class=chat-meta>#3 &lt;b&gt;&quot;&amp;&#39; · @h9 · <time class=chat-time datetime=1970-01-01T00:00:05Z data-at=5>1970-01-01 00:00 UTC</time> <button type=button class=msg-quote title=\"Quote this message in a reply (q)\">quote-reply</button> <button type=button class=msg-edit title=\"Load this message back into compose with an &quot;Edit of MSG_…&quot; backlink (e)\">edit</button></div><div class=chat-body><p><em>hi</em></p>\n</div><div class=chat-reactions data-n=3></div></div>\n".to_utf8()
}

# A poster no account holds is its id, which says its kind.
expect {
	m = {
		id: 1,
		at: 0,
		by: human.id(),
		body: [],
	}
	Bubble.of(
		[],
		{
			m,
			ref: "T_1",
			edited: NotEdited,
			reactions: [],
		},
	).bytes().starts_with("<div class=chat-msg id=msg-1 data-id=1 data-ref=\"T_1\" data-by=\"human:9\"><div class=chat-meta>#1 human:9 · ".to_utf8())
}

# An edited message shows where it was edited and its original, escaped,
# in place of its body.
expect {
	m = {
		id: 2,
		at: 5,
		by: human.id(),
		body: "<i>old</i>".to_utf8(),
	}
	html = Str.from_utf8(
		Bubble.of(
			[human],
			{
				m,
				ref: "T_2",
				edited: EditedIn({ id: 7, ref: "MSG_T_7" }),
				reactions: [],
			},
		).bytes(),
	) ?? ""
	html.contains("<div class=chat-body><div class=chat-edited-note>Edited in <a class=msg-ref href=\"#msg-7\">MSG_T_7</a></div><details class=chat-edited-spoiler><summary>original</summary><div class=chat-edited-orig>&lt;i&gt;old&lt;/i&gt;</div></details></div>") and !html.contains("<i>")
}

# A CR becomes its character reference; an LF stays; nothing else changes.
expect Bubble.data(Html.markup("a\r\nb")) == "a&#13;\nb".to_utf8()
expect Bubble.data(Html.markup("<p>x</p>\n")) == "<p>x</p>\n".to_utf8()

# The meta line's links: quote-reply and edit, and no save (saves are gone).
expect {
	m = {
		id: 2,
		at: 5,
		by: human.id(),
		body: "x".to_utf8(),
	}
	html = Str.from_utf8(
		Bubble.of(
			[human],
			{
				m,
				ref: "4_2",
				edited: NotEdited,
				reactions: [],
			},
		).bytes(),
	) ?? ""
	html.contains("backlink (e)\">edit</button></div><div class=chat-body>") and !html.contains("msg-save")
}
