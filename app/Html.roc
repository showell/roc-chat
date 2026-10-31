## **A PAGE IS AN `Html`, AND AN `Html` IS SAFE BY CONSTRUCTION**: opaque
## (`::`), so outside this module nothing makes one from bytes. The ways in:
## `text` and `escape` (anything a person, an agent or the store supplied:
## a name, an id), `number` and `signed`, `markup` (markup written in the
## code, a string literal, holding no `${...}`), and `rendered`
## (roc-markdown's HTML for a message, the one HTML this chat did not
## write). `join` puts pieces together; `respond` is the one way out, a page
## as an answer, never cached. Pure.
import pf.Chat

Html :: List(U8).{

	## **TEXT AS HTML TEXT**: its `&`, `<`, `>`, `"` and `'` as entities, so
	## no text a page writes is ever markup, in an element or an attribute.
	escape : List(U8) -> Html
	escape = |text|
		Html.(
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
			),
		)

	## A `Str` as HTML text, escaped as `escape` escapes its bytes.
	text : Str -> Html
	text = |s| Html.escape(s.to_utf8())

	## A whole number, in decimal: nothing to escape.
	number : U64 -> Html
	number = |n| Html.(n.to_str().to_utf8())

	## A signed whole number (a time), in decimal.
	signed : I64 -> Html
	signed = |n| Html.(n.to_str().to_utf8())

	## **MARKUP WRITTEN IN THE CODE**: a string literal, never one built from
	## data (anything computed goes through `text`, `escape` or `number`).
	markup : Str -> Html
	markup = |literal| Html.(literal.to_utf8())

	## **roc-markdown's HTML FOR A MESSAGE**, as is: the renderer's output
	## (Conversations.html_of) and
	## nothing else.
	rendered : List(U8) -> Html
	rendered = |html| Html.(html)

	## The pieces, in order.
	join : List(Html) -> Html
	join = |pieces| Html.(pieces.join_map(Html.bytes))

	## The page's bytes.
	bytes : Html -> List(U8)
	bytes = |Html.(b)| b

	## **A PAGE AS AN ANSWER**: its status, `text/html`, never cached.
	respond : U16, Html -> Chat.Answer
	respond = |status, page|
		Chat.respond(status, { content_type: Chat.html, body: page.bytes() })
			|> Chat.with_header("cache-control", "no-store".to_utf8())
}

expect Html.text("Bea <i>x</i> & \"co\" 'q'").bytes() == "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot; &#39;q&#39;".to_utf8()
expect Html.text("Zoë 🎉").bytes() == "Zoë 🎉".to_utf8()
# A name holding a script is text, in an element or an attribute.
expect
	Html.join([
		Html.markup("<b data-name=\""),
		Html.text("<script>alert(1)</script>\""),
		Html.markup("\">"),
	]).bytes()
		== "<b data-name=\"&lt;script&gt;alert(1)&lt;/script&gt;&quot;\">".to_utf8()
expect Html.join([
	Html.number(7),
	Html.markup(" "),
	Html.signed(-2),
]).bytes() == "7 -2".to_utf8()
