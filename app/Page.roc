## **THE PAGES**: a conversation's, and the one that says why there is
## none. Every page is the same skeleton (the doctype, its title, the style,
## then its body); the page carries structure and class names, and only
## enough style to read, so a client can style the rest.
import Conversation
import Html
import Message
import Topic

Page :: [].{

	## **A CONVERSATION'S PAGE**: the topic, then each message under its
	## author and time, with its reference (`Message.reference`) as a link to
	## itself.
	conversation : Conversation -> Html
	conversation = |c| {
		topic = c.topic()
		heading = Html.tag({
			name: H1,
			attrs: [],
			inner: Html.text(topic.to_str()),
		})
		messages =
			if (c.messages().is_empty())
				Html.join([
					Html.tag({
						name: P,
						attrs: [Class("empty")],
						inner: Html.text("No messages yet."),
					}),
					newline,
				])
			else
				Html.join(c.messages().map(|m| message({ topic, message: m })))
		whole({
			title: topic.to_str(),
			body: Html.join([
				heading,
				newline,
				messages,
			]),
		})
	}

	## **THE PAGE FOR A REFUSED TRANSCRIPT**, saying why in `why`'s words.
	refused : Str -> Html
	refused = |why|
		whole({
			title: "Not a transcript",
			body: Html.tag({
				name: P,
				attrs: [],
				inner: Html.text("Not a transcript: ${why}."),
			}),
		})
}

## One message: its header, then its markdown rendered.
message : { topic : Topic, message : Message } -> Html
message = |{ topic, message: m }| {
	id = m.id()
	anchor = "msg-${id.to_str()}"
	header = Html.join([
		Html.tag({
			name: Span,
			attrs: [Class("author")],
			inner: Html.text(m.author().to_str()),
		}),
		space,
		Html.tag({
			name: Time,
			attrs: [Datetime(m.time())],
			inner: Html.text(m.time().to_str()),
		}),
		space,
		Html.tag({
			name: A,
			attrs: [Class("ref"), Href("#${anchor}")],
			inner: Html.text(Message.reference(topic, id)),
		}),
	])
	article = Html.tag({
		name: Article,
		attrs: [Class("message"), Id(anchor)],
		inner: Html.join([
			Html.tag({
				name: Header,
				attrs: [],
				inner: header,
			}),
			newline,
			Html.tag({
				name: Div,
				attrs: [Class("body")],
				inner: Html.markdown(m.markdown()),
			}),
		]),
	})
	Html.join([article, newline])
}

## **THE SKELETON EVERY PAGE SHARES**: the doctype and charset, `title` as
## its title, the style, then `body`.
whole : { title : Str, body : Html } -> Html
whole = |{ title, body }|
	Html.join([
		Html.doctype,
		Html.tag({
			name: Title,
			attrs: [],
			inner: Html.text(title),
		}),
		newline,
		Html.style(style),
		body,
	])

newline : Html
newline = Html.text("\n")

space : Html
space = Html.text(" ")

## Only enough style to read; a client styles the rest.
style : Str
style =
	\\body{font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}
	\\.message{border-top:1px solid #ccc;padding:.5rem 0}
	\\.author{font-weight:600}
	\\time,.ref{color:#777;font-size:.85em}
	\\.ref{float:right}
	\\

# ── tests
expect
	Page.refused("it <is> not UTF-8").to_str()
		== "<!doctype html>\n<meta charset=utf-8>\n<title>Not a transcript</title>\n<style>\n${style}</style>\n<p>Not a transcript: it &lt;is&gt; not UTF-8.</p>"
