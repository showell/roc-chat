## **AN `Html` IS SAFE BY CONSTRUCTION**: opaque (`::`), so outside this
## module nothing makes one from a `Str`. The ways in: `text` (anything a
## person, an agent or a file supplied, escaped), `markdown` (a message's
## markdown, rendered by roc-markdown, the one HTML this chat does not
## write), `tag` (an element the pages use, its attributes typed and their
## values escaped), `doctype` and `style` (the page's head, fixed) and
## `join`. `to_str` is the one way out.
import md.Md
import Timestamp

Html :: Str.{

	## **AN ELEMENT A PAGE USES**: a closed set, so a tag's name is never data.
	Name : [A, Article, Div, H1, Header, P, Span, Time, Title]

	## **AN ATTRIBUTE, ITS NAME BY ITS TAG**, so a name and its value can't
	## be swapped, and a time is a `Timestamp`, never any text.
	Attribute : [
		Class(Str),
		Id(Str),
		Href(Str),
		Datetime(Timestamp),
	]

	## **TEXT AS HTML TEXT**: its `&`, `<`, `>`, `"` and `'` as entities, so
	## no text a page writes is ever markup, in an element or an attribute.
	## `&` goes first, so no entity this writes is escaped again.
	text : Str -> Html
	text = |s|
		Html.(
			s
				.replace_each("&", "&amp;")
				.replace_each("<", "&lt;")
				.replace_each(">", "&gt;")
				.replace_each("\"", "&quot;")
				.replace_each("'", "&#39;"),
		)

	## **A MESSAGE'S MARKDOWN, RENDERED** by roc-markdown, which escapes the
	## text and allows only its own markup. No upload is known yet, so every
	## image is refused as one.
	markdown : Str -> Html
	markdown = |md| {
		rendered = Md.render(md.to_utf8(), { uploads: |_| Bool.False })
		Html.(Str.from_utf8(rendered) ?? crash "Html.markdown: roc-markdown renders UTF-8 from UTF-8")
	}

	## **AN ELEMENT**: `<name a="v">inner</name>`, each attribute's value
	## escaped as text and quoted, so no value is ever spliced into a tag.
	tag : {
		name : Html.Name,
		attrs : List(Html.Attribute),
		inner : Html,
	} -> Html
	tag = |
		{
			name,
			attrs,
			inner,
		},
	| {
		opened = Str.join_with(attrs.map(attribute), "")
		written = name_of(name)
		Html.("<${written}${opened}>${inner.to_str()}</${written}>")
	}

	## The pieces, in order.
	join : List(Html) -> Html
	join = |pieces| Html.(Str.join_with(pieces.map(Html.to_str), ""))

	## The doctype and the charset, which every page opens with.
	doctype : Html
	doctype = Html.("<!doctype html>\n<meta charset=utf-8>\n")

	## **A STYLE SHEET**: `css` in a `<style>` element. CSS is code, never
	## data, and holds no `<`, so it can't close its element early.
	style : Str -> Html
	style = |css|
		if (css.contains("<"))
			crash "Html.style: a style sheet holds no `<`"
		else
			Html.("<style>\n${css}</style>\n")

	## The page's text, once, for the host.
	to_str : Html -> Str
	to_str = |Html.(s)| s
}

name_of : Html.Name -> Str
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

## One attribute as an element's open tag writes it, space first.
attribute : Html.Attribute -> Str
attribute = |attr| {
	(name, value) =
		match attr {
			Class(v) => ("class", v)
			Id(v) => ("id", v)
			Href(v) => ("href", v)
			Datetime(t) => ("datetime", t.to_str())
		}
	" ${name}=\"${Html.text(value).to_str()}\""
}

# ── tests
expect Html.text("Bea <i>x</i> & \"co\" 'q'").to_str() == "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot; &#39;q&#39;"
expect Html.text("&lt;").to_str() == "&amp;lt;"
expect Html.text("café 🎉").to_str() == "café 🎉"
# A value holding a quote and a script is text inside its attribute.
expect
	Html.tag({
		name: Span,
		attrs: [Class("<script>\"")],
		inner: Html.text("<i>"),
	}).to_str()
		== "<span class=\"&lt;script&gt;&quot;\">&lt;i&gt;</span>"
expect
	Html.tag({
		name: A,
		attrs: [Id("x"), Href("#y")],
		inner: Html.join([]),
	}).to_str()
		== "<a id=\"x\" href=\"#y\"></a>"
expect
	Html.tag({
		name: P,
		attrs: [],
		inner: Html.text("hi"),
	}).to_str()
		== "<p>hi</p>"
expect
	Timestamp.from_str("2026-11-02T19:11:32Z").map_ok(
		|t|
			Html.tag({
				name: Time,
				attrs: [Datetime(t)],
				inner: Html.join([]),
			}).to_str(),
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
expect Html.join([
	Html.text("a&b"),
	Html.text("<"),
]).to_str() == "a&amp;b&lt;"
# The markdown's own markup kept, its text escaped.
expect Html.markdown("**hi** <b>").to_str() == "<p><strong>hi</strong> &lt;b&gt;</p>\n"
expect Html.doctype.to_str() == "<!doctype html>\n<meta charset=utf-8>\n"
expect Html.style("p{x:y}\n").to_str() == "<style>\np{x:y}\n</style>\n"
