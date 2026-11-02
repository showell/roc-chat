## **MARKUP THIS PROGRAM VOUCHES FOR**: a `TrustedHtml` is HTML that is
## already safe, and a `Str` is text, which is never markup. The type says
## which a value is, so the two pitfalls can't be written: text escaped
## nowhere, and markup escaped twice.
##
## **ONE TYPE, NOT TWO**: text needs no type of its own, because `Str`
## already says "text, not yet escaped". So the split is `Str` and this
## type, opaque (`::`), and a `Str` becomes one only through a named door:
## `text` (anything a person, an agent or a file supplied, escaped here,
## exactly once), `markdown` (a message's markdown, rendered by
## roc-markdown, the one HTML this chat does not write), and the fixed
## constants `doctype` and `style`. `tag` and `join` build only from what
## is already trusted, so they never escape it again.
##
## **THE WAY OUT IS BYTES**: `to_utf8`, for the host. There is no way back
## to a `Str`, so trusted markup can't be handed to `text` and escaped a
## second time without a deliberate, fallible `Str.from_utf8`.
import DateTime
import md.Md
import Message

TrustedHtml :: Str.{

	## **AN ELEMENT A PAGE USES**: a closed set, so a tag's name is never data.
	Name : [A, Article, Div, H1, Header, P, Span, Time, Title]

	## **A CLASS A PAGE USES**: a closed set, so a class is never data.
	Class : [Author, Body, Empty, Message, Ref]

	## **A PLACE ON A PAGE**: what an element's id names and a link goes
	## to, built only from a domain value, so no link leaves the page.
	Target : [Anchor(Message.Id)]

	## **AN ATTRIBUTE, ITS NAME BY ITS TAG**, so a name and its value can't
	## be swapped, and no value is ever text: a class from its closed set,
	## an id and a link from a `Target`, a time from a `DateTime`.
	Attribute : [
		Class(TrustedHtml.Class),
		Id(TrustedHtml.Target),
		Href(TrustedHtml.Target),
		DateTime(DateTime),
	]

	## **TEXT, ESCAPED ONCE, ON ITS WAY IN**: the door for every `Str` a
	## page shows.
	text : Str -> TrustedHtml
	text = |s| TrustedHtml.(escape(s))

	## **A MESSAGE'S MARKDOWN, RENDERED** by roc-markdown, which escapes the
	## text and allows only its own markup. No upload is known yet, so every
	## image is refused as one.
	markdown : Str -> TrustedHtml
	markdown = |md| {
		rendered = Md.render(md.to_utf8(), { uploads: |_| Bool.False })
		TrustedHtml.(Str.from_utf8(rendered) ?? crash "TrustedHtml.markdown: roc-markdown renders UTF-8 from UTF-8")
	}

	## **AN ELEMENT**: `<name a="v">inner</name>`, each attribute's value
	## escaped and quoted, so no value is ever spliced into a tag, and
	## `inner` as it is, already trusted.
	tag : {
		name : TrustedHtml.Name,
		attrs : List(TrustedHtml.Attribute),
		inner : TrustedHtml,
	} -> TrustedHtml
	tag = |
		{
			name,
			attrs,
			inner: TrustedHtml.(inner),
		},
	| {
		opened = Str.join_with(attrs.map(attribute), "")
		written = name_of(name)
		TrustedHtml.("<${written}${opened}>${inner}</${written}>")
	}

	## The pieces, in order, each as it is.
	join : List(TrustedHtml) -> TrustedHtml
	join = |pieces| TrustedHtml.(Str.join_with(pieces.map(|TrustedHtml.(s)| s), ""))

	## The doctype and the charset, which every page opens with.
	doctype : TrustedHtml
	doctype = TrustedHtml.("<!doctype html>\n<meta charset=utf-8>\n")

	## **THE STYLE SHEET EVERY PAGE CARRIES**: only enough to read, so a
	## client styles the rest. It lives beside `Class`, whose names it
	## styles.
	style : TrustedHtml
	style = TrustedHtml.("<style>\n${css}</style>\n")

	## The page's bytes, for the host: the one way out.
	to_utf8 : TrustedHtml -> List(U8)
	to_utf8 = |TrustedHtml.(s)| s.to_utf8()
}

## **THE ESCAPE**: `&`, `<`, `>`, `"` and `'` as entities, so no text is
## ever markup, in an element or an attribute. `&` goes first, so no
## entity this writes is escaped again.
escape : Str -> Str
escape = |s|
	s
		.replace_each("&", "&amp;")
		.replace_each("<", "&lt;")
		.replace_each(">", "&gt;")
		.replace_each("\"", "&quot;")
		.replace_each("'", "&#39;")

## The style sheet's rules. CSS is code, never data, and holds no `<`, so
## it can't close its element early.
css : Str
css =
	\\body{font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}
	\\.message{border-top:1px solid #ccc;padding:.5rem 0}
	\\.author{font-weight:600}
	\\time,.ref{color:#777;font-size:.85em}
	\\.ref{float:right}
	\\

name_of : TrustedHtml.Name -> Str
name_of = |name|
	match name {
		A => "a"
		Article => "article"
		Div => "div"
		H1 => "h1"
		Header => "header"
		P => "p"
		Span => "span"
		Time => "time"
		Title => "title"
	}

class_name : TrustedHtml.Class -> Str
class_name = |class|
	match class {
		Author => "author"
		Body => "body"
		Empty => "empty"
		Message => "message"
		Ref => "ref"
	}

## **A TARGET'S NAME**, `msg-<n>` for a message: the one home of its
## spelling, which an element's id and a link's `#` both write.
anchor_name : TrustedHtml.Target -> Str
anchor_name = |target|
	match target {
		Anchor(id) => "msg-${id.to_str()}"
	}

## One attribute as an element's open tag writes it, space first. Each
## value is escaped too, so a value added to a set later can still never
## close its quote.
attribute : TrustedHtml.Attribute -> Str
attribute = |attr| {
	(name, value) =
		match attr {
			Class(class) => ("class", class_name(class))
			Id(target) => ("id", anchor_name(target))
			Href(target) => ("href", "#${anchor_name(target)}")
			DateTime(t) => ("datetime", t.to_str())
		}
	" ${name}=\"${escape(value)}\""
}

# ── tests
## The markup, as a test reads it.
shown : TrustedHtml -> Str
shown = |TrustedHtml.(s)| s

expect shown(TrustedHtml.text("Bea <i>x</i> & \"co\" 'q'")) == "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot; &#39;q&#39;"
expect shown(TrustedHtml.text("café 🎉")) == "café 🎉"
# Text is escaped exactly once: `&amp;` as text is `&amp;amp;`, and that
# fragment, joined into another or put in an element, comes out unchanged.
expect {
	once = TrustedHtml.text("&amp;")
	[
		shown(once),
		shown(TrustedHtml.join([once])),
		shown(TrustedHtml.join([TrustedHtml.join([once]), once])),
		shown(
			TrustedHtml.tag({
				name: P,
				attrs: [],
				inner: once,
			}),
		),
	]
		== [
			"&amp;amp;",
			"&amp;amp;",
			"&amp;amp;&amp;amp;",
			"<p>&amp;amp;</p>",
		]
}
# Rendered markdown is trusted as it is: joined, its entities stay single.
expect {
	rendered = TrustedHtml.markdown("a & <b>")
	[
		shown(rendered),
		shown(TrustedHtml.join([TrustedHtml.text("&"), rendered])),
	]
		== [
			"<p>a &amp; &lt;b&gt;</p>\n",
			"&amp;<p>a &amp; &lt;b&gt;</p>\n",
		]
}
# Every attribute a page can write: each class, and a message's anchor as
# an id and as a link, at the first id and the next. No other value can be
# written, so no `href` leaves the page.
expect [Author, Body, Empty, Message, Ref].map(|class| attribute(Class(class))) == [
	" class=\"author\"",
	" class=\"body\"",
	" class=\"empty\"",
	" class=\"message\"",
	" class=\"ref\"",
]
expect {
	second = Message.Id.first.next() ?? crash "TrustedHtml's tests: the first id has a next"
	[
		Id(Anchor(Message.Id.first)),
		Href(Anchor(Message.Id.first)),
		Id(Anchor(second)),
		Href(Anchor(second)),
	].map(attribute)
		== [
			" id=\"msg-1\"",
			" href=\"#msg-1\"",
			" id=\"msg-2\"",
			" href=\"#msg-2\"",
		]
}
expect
	shown(
		TrustedHtml.tag({
			name: A,
			attrs: [Class(Ref), Href(Anchor(Message.Id.first))],
			inner: TrustedHtml.text("<i>"),
		}),
	)
		== "<a class=\"ref\" href=\"#msg-1\">&lt;i&gt;</a>"
expect
	shown(
		TrustedHtml.tag({
			name: P,
			attrs: [],
			inner: TrustedHtml.text("hi"),
		}),
	)
		== "<p>hi</p>"
expect
	DateTime.from_str("2026-11-02T19:11:32Z").map_ok(
		|t|
			shown(
				TrustedHtml.tag({
					name: Time,
					attrs: [DateTime(t)],
					inner: TrustedHtml.join([]),
				}),
			),
	)
		== Ok("<time datetime=\"2026-11-02T19:11:32Z\"></time>")
expect [A, Article, Div, H1, Header, P, Span, Time, Title].map(name_of) == [
	"a",
	"article",
	"div",
	"h1",
	"header",
	"p",
	"span",
	"time",
	"title",
]
expect shown(
	TrustedHtml.join([
		TrustedHtml.text("a&b"),
		TrustedHtml.text("<"),
	]),
) == "a&amp;b&lt;"
# The markdown's own markup kept, its text escaped.
expect shown(TrustedHtml.markdown("**hi** <b>")) == "<p><strong>hi</strong> &lt;b&gt;</p>\n"
# No upload is known, so an image is its link; a `javascript:` link is text.
expect shown(TrustedHtml.markdown("![x](a.png)")) == "<p><a href=\"a.png\">x</a></p>\n"
expect shown(TrustedHtml.markdown("[x](javascript:alert(1))")) == "<p>[x](javascript:alert(1))</p>\n"
expect shown(TrustedHtml.doctype) == "<!doctype html>\n<meta charset=utf-8>\n"
expect shown(TrustedHtml.style) == "<style>\n${css}</style>\n"
expect !css.contains("<")
expect TrustedHtml.text("é<").to_utf8() == "é&lt;".to_utf8()
