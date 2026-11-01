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
import AccountCodec
import Cast
import Conversations
import Html
import MessageCodec
import Principal

Bubble := [].{

	## **THE BUBBLE**: its local reference (`data-ref`, `<topic>_<n>`, the
	## server's spelling, which the page's notices say), who posted it (Conversations.header_of, the rule
	## every renderer draws, so an agent named as a human says whose it is)
	## and when, then roc-markdown's HTML for it. Everything written here is
	## escaped; the body is the renderer's.
	##
	## **ITS META LINE'S LINKS** are the old ones (js/message.js `buildMeta`):
	## "quote-reply" (q), "edit" (e), which the page's script shows on the
	## viewer's own alone, and "save" (s), which it marks "✓ saved" for a
	## message on the viewer's reading list. **AN EDITED MESSAGE** (`EditedIn`, Edits.roc) shows
	## "Edited in <the edit's reference>" and its markdown in an "original" spoiler,
	## in place of its body (js/message.js `markEdited`).
	of : List(Principal),
	{
		m : MessageCodec.Fields,
		ref : Str,
		edited : [NotEdited, EditedIn({ id : U64, ref : Str })],
	} -> Html
	of = |
		accounts,
		{
			m,
			ref,
			edited,
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
			Html.text(AccountCodec.id_text(m.by)),
			Html.markup("\"><div class=chat-meta>#"),
			Html.number(m.id),
			Html.markup(" "),
			Html.text(Conversations.header_of(accounts, m.by)),
			Html.markup(" · <time class=chat-time datetime="),
			Html.text(Bubble.iso(m.at)),
			Html.markup(" data-at="),
			Html.signed(m.at),
			Html.markup(">"),
			Html.text(Bubble.fallback(m.at)),
			Html.markup("</time> <button type=button class=msg-quote title=\"Quote this message in a reply (q)\">quote-reply</button> <button type=button class=msg-edit title=\"Load this message back into compose with an &quot;Edit of MSG_…&quot; backlink (e)\">edit</button> <button type=button class=msg-save title=\"Save this message to your reading list (s)\">save</button></div><div class=chat-body>"),
			match edited {
				NotEdited => Html.rendered(Conversations.html_of(m))
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
			Html.markup("</div></div>\n"),
		])

	## **A TIME AS HTML NAMES IT**, `2026-11-01T12:54:30Z`: the `datetime` a
	## `<time>` carries, in UTC.
	iso : I64 -> Str
	iso = |at| {
		t = utc(at)
		"${t.date}T${t.clock}:${t.second}Z"
	}

	## **A TIME WITH NO SCRIPT TO SHOW IT**, `2026-11-01 12:54 UTC`: the
	## text a `<time>` holds until the page's script writes it in the
	## viewer's zone, so a page without JavaScript still says when.
	fallback : I64 -> Str
	fallback = |at| {
		t = utc(at)
		"${t.date} ${t.clock} UTC"
	}

	## **THE BUBBLE AS AN SSE EVENT'S DATA**: an event holds no CR (Sse.frame
	## refuses one), so a CR the markdown kept is written as its character
	## reference, which the browser reads back as the same character, in
	## text or in an attribute. An LF stays: each line is a `data:` line,
	## rejoined by the browser.
	data : Html -> List(U8)
	data = |bubble| bubble.bytes().join_map(|b| if (b == '\r') "&#13;".to_utf8() else [b])
}

## **UNIX SECONDS AS A UTC DATE AND CLOCK**, by the proleptic Gregorian
## calendar (Howard Hinnant's `civil_from_days`): its date, its hour and
## minute, its seconds, each zero-padded.
utc : I64 -> {
	date : Str,
	clock : Str,
	second : Str,
}
utc = |at| {
	days = if (at >= 0) at // 86400 else (at - 86399) // 86400
	rest = at - days * 86400
	z = days + 719468
	era = if (z >= 0) z // 146097 else (z - 146096) // 146097
	doe = z - era * 146097
	yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	mp = (5 * doy + 2) // 153
	d = doy - (153 * mp + 2) // 5 + 1
	m = if (mp < 10) mp + 3 else mp - 9
	y = yoe + era * 400 + (if (m <= 2) 1 else 0)
	{
		date: "${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}",
		clock: "${pad(rest // 3600, 2)}:${pad((rest % 3600) // 60, 2)}",
		second: pad(rest % 60, 2),
	}
}

## A whole number in decimal, zeros before it to `width` digits.
pad : I64, U64 -> Str
pad = |n, width| {
	digits = n.to_str()
	zeros = if (digits.to_utf8().len() < width) width - digits.to_utf8().len() else 0
	Str.concat(Str.repeat("0", zeros), digits)
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
		},
	).bytes()
	html == "<div class=chat-msg id=msg-3 data-id=3 data-ref=\"&lt;T&gt;_3\" data-by=\"human:9\"><div class=chat-meta>#3 &lt;b&gt;&quot;&amp;&#39; · @h9 · <time class=chat-time datetime=1970-01-01T00:00:05Z data-at=5>1970-01-01 00:00 UTC</time> <button type=button class=msg-quote title=\"Quote this message in a reply (q)\">quote-reply</button> <button type=button class=msg-edit title=\"Load this message back into compose with an &quot;Edit of MSG_…&quot; backlink (e)\">edit</button> <button type=button class=msg-save title=\"Save this message to your reading list (s)\">save</button></div><div class=chat-body><p><em>hi</em></p>\n</div></div>\n".to_utf8()
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
		},
	).bytes().starts_with("<div class=chat-msg id=msg-1 data-id=1 data-ref=\"T_1\" data-by=\"human:9\"><div class=chat-meta>#1 human:9 · ".to_utf8())
}

expect Bubble.iso(0) == "1970-01-01T00:00:00Z"
expect Bubble.iso(1793537670) == "2026-11-01T12:54:30Z"
expect Bubble.iso(951782400) == "2000-02-29T00:00:00Z"
expect Bubble.iso(-1) == "1969-12-31T23:59:59Z"
expect Bubble.fallback(1793537670) == "2026-11-01 12:54 UTC"

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
			},
		).bytes(),
	) ?? ""
	html.contains("<div class=chat-body><div class=chat-edited-note>Edited in <a class=msg-ref href=\"#msg-7\">MSG_T_7</a></div><details class=chat-edited-spoiler><summary>original</summary><div class=chat-edited-orig>&lt;i&gt;old&lt;/i&gt;</div></details></div>") and !html.contains("<i>")
}

# A CR becomes its character reference; an LF stays; nothing else changes.
expect Bubble.data(Html.markup("a\r\nb")) == "a&#13;\nb".to_utf8()
expect Bubble.data(Html.markup("<p>x</p>\n")) == "<p>x</p>\n".to_utf8()
