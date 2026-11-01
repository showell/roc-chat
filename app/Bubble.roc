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

	## **THE BUBBLE**: who posted it (Conversations.header_of, the rule
	## every renderer draws, so an agent named as a human says whose it is)
	## and when, then roc-markdown's HTML for it. Everything written here is
	## escaped; the body is the renderer's.
	of : List(Principal), MessageCodec.Fields -> Html
	of = |accounts, m|
		Html.join([
			Html.markup("<div class=chat-msg id=msg-"),
			Html.number(m.id),
			Html.markup(" data-id="),
			Html.number(m.id),
			Html.markup(" data-by=\""),
			Html.text(AccountCodec.id_text(m.by)),
			Html.markup("\"><div class=chat-meta>#"),
			Html.number(m.id),
			Html.markup(" "),
			Html.text(Conversations.header_of(accounts, m.by)),
			Html.markup(" · <time class=chat-time data-at="),
			Html.signed(m.at),
			Html.markup("></time></div><div class=chat-body>"),
			Html.rendered(Conversations.html_of(m)),
			Html.markup("</div></div>\n"),
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

# **A NAME IS TEXT**: the meta line holds the poster's header escaped, and
# the author's id as an attribute; the body is roc-markdown's.
expect {
	html = Bubble.of(
		[human],
		{
			id: 3,
			at: 5,
			by: human.id(),
			body: "*hi*".to_utf8(),
		},
	).bytes()
	html == "<div class=chat-msg id=msg-3 data-id=3 data-by=\"human:9\"><div class=chat-meta>#3 &lt;b&gt;&quot;&amp;&#39; · @h9 · <time class=chat-time data-at=5></time></div><div class=chat-body><p><em>hi</em></p>\n</div></div>\n".to_utf8()
}

# A poster no account holds is its id, which says its kind.
expect Bubble.of(
	[],
	{
		id: 1,
		at: 0,
		by: human.id(),
		body: [],
	},
).bytes().starts_with("<div class=chat-msg id=msg-1 data-id=1 data-by=\"human:9\"><div class=chat-meta>#1 human:9 · ".to_utf8())

# A CR becomes its character reference; an LF stays; nothing else changes.
expect Bubble.data(Html.markup("a\r\nb")) == "a&#13;\nb".to_utf8()
expect Bubble.data(Html.markup("<p>x</p>\n")) == "<p>x</p>\n".to_utf8()
