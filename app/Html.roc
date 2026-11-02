## **A PAGE IS AN `Html`, AND AN `Html` IS SAFE BY CONSTRUCTION**: opaque
## (`::`), so outside this module nothing makes one from a `Str`. The ways
## in: `text` (anything a person, an agent or a file supplied: a topic, a
## name, a time), `markup` (markup written in the code, a string literal,
## holding no `${...}`), `rendered` (roc-markdown's HTML for a message, the
## one HTML this chat does not write), `element` (a tag, its attributes
## escaped as they go in) and `page` (the skeleton every page shares).
## `to_str` is the one way out.
Html :: Str.{

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

	## **MARKUP WRITTEN IN THE CODE**: a string literal, never one built from
	## data (anything computed goes through `text` or `element`).
	markup : Str -> Html
	markup = |literal| Html.(literal)

	## **roc-markdown's HTML FOR A MESSAGE**, as is: the renderer's output and
	## nothing else.
	rendered : Str -> Html
	rendered = |html| Html.(html)

	## **AN ELEMENT**: `<name a="v">inner</name>`, each attribute's value
	## escaped as text and quoted, so no value is ever spliced into a tag.
	## Names are code: lowercase letters, digits and `-`.
	element : {
		name : Str,
		attrs : List([Attr(Str, Str)]),
		inner : Html,
	} -> Html
	element = |
		{
			name,
			attrs,
			inner,
		},
	| {
		open = Str.join_with(
			attrs.map(
				|Attr(attr, value)| {
					quoted = Html.text(value).to_str()
					" ${code_name(attr)}=\"${quoted}\""
				},
			),
			"",
		)
		tag = code_name(name)
		Html.("<${tag}${open}>${inner.to_str()}</${tag}>")
	}

	## The pieces, in order.
	join : List(Html) -> Html
	join = |pieces| Html.(Str.join_with(pieces.map(Html.to_str), ""))

	## **A WHOLE PAGE**: the doctype, the charset, `title` as its title, the
	## style every page shares, then `body`.
	page : { title : Str, body : Html } -> Html
	page = |{ title, body }|
		Html.join([
			Html.markup(
				\\<!doctype html>
				\\<meta charset=utf-8>
				\\
			),
			Html.element({
				name: "title",
				attrs: [],
				inner: Html.text(title),
			}),
			Html.markup("\n"),
			Html.markup(style),
			body,
		])

	## The page's text, once, for the host.
	to_str : Html -> Str
	to_str = |Html.(s)| s

	is_eq : _
}

## A tag's or an attribute's name, which the code writes: lowercase letters,
## digits and `-`, never data.
code_name : Str -> Str
code_name = |name|
	if (!name.is_empty() and name.to_utf8().all(|b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '-'))
		name
	else
		crash "Html.code_name: a tag or attribute name is code"

## Only enough style to read; a client styles the rest.
style : Str
style =
	\\<style>
	\\body{font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}
	\\.message{border-top:1px solid #ccc;padding:.5rem 0}
	\\.author{font-weight:600}
	\\time,.ref{color:#777;font-size:.85em}
	\\.ref{float:right}
	\\</style>
	\\

# ── tests
expect Html.text("Bea <i>x</i> & \"co\" 'q'").to_str() == "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot; &#39;q&#39;"
expect Html.text("&lt;").to_str() == "&amp;lt;"
expect Html.text("café 🎉").to_str() == "café 🎉"
# A value holding a quote and a script is text inside its attribute.
expect
	Html.element({
		name: "b",
		attrs: [Attr("data-name", "<script>\"")],
		inner: Html.text("<i>"),
	}).to_str()
		== "<b data-name=\"&lt;script&gt;&quot;\">&lt;i&gt;</b>"
expect
	Html.element({
		name: "time",
		attrs: [Attr("datetime", "1"), Attr("class", "x")],
		inner: Html.markup(""),
	}).to_str()
		== "<time datetime=\"1\" class=\"x\"></time>"
expect Html.join([
	Html.markup("<p>"),
	Html.text("a&b"),
	Html.markup("</p>"),
]).to_str() == "<p>a&amp;b</p>"
expect Html.page({
	title: "<T>",
	body: Html.markup("<p>hi</p>\n"),
}).to_str() == "<!doctype html>\n<meta charset=utf-8>\n<title>&lt;T&gt;</title>\n${style}<p>hi</p>\n"
expect code_name("h1") == "h1"
expect code_name("data-name") == "data-name"
