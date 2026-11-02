## **THE PAGES**: a conversation's, and the one that says why there is
## none. Every page is the same skeleton (the doctype, its title, the style,
## then its body); the page carries structure and class names, and only
## enough style to read (`TrustedHtml.style`), so a client can style the
## rest. Every `Str` a page shows goes in through `TrustedHtml.text`.
import Conversation
import Message
import Topic
import TrustedHtml

Page :: [].{

	## **A CONVERSATION'S PAGE**: the topic, then each message under its
	## author and time, with its reference (`Conversation.reference`) as a link to
	## itself.
	conversation : Conversation -> TrustedHtml
	conversation = |c| {
		topic = c.topic()
		heading = TrustedHtml.tag({
			name: H1,
			attrs: [],
			inner: TrustedHtml.text(topic.to_str()),
		})
		messages =
			if (c.messages().is_empty())
				TrustedHtml.join([
					TrustedHtml.tag({
						name: P,
						attrs: [Class(Empty)],
						inner: TrustedHtml.text("No messages yet."),
					}),
					newline,
				])
			else
				TrustedHtml.join(c.messages().map(|m| message(c, m)))
		whole({
			title: topic.to_str(),
			body: TrustedHtml.join([
				heading,
				newline,
				messages,
			]),
		})
	}

	## **THE PAGE FOR A REFUSED TRANSCRIPT**, saying why in `why`'s words.
	refused : Str -> TrustedHtml
	refused = |why|
		whole({
			title: "Not a transcript",
			body: TrustedHtml.tag({
				name: P,
				attrs: [],
				inner: TrustedHtml.text("Not a transcript: ${why}."),
			}),
		})
}

## One message: its header, then its markdown rendered.
message : Conversation, Message -> TrustedHtml
message = |c, m| {
	id = m.id()
	header = TrustedHtml.join([
		TrustedHtml.tag({
			name: Span,
			attrs: [Class(Author)],
			inner: TrustedHtml.text(m.author().to_str()),
		}),
		space,
		TrustedHtml.tag({
			name: Time,
			attrs: [DateTime(m.time())],
			inner: TrustedHtml.text(m.time().to_str()),
		}),
		space,
		TrustedHtml.tag({
			name: A,
			attrs: [Class(Ref), Href(Anchor(id))],
			inner: TrustedHtml.text(c.reference(id)),
		}),
	])
	article = TrustedHtml.tag({
		name: Article,
		attrs: [Class(Message), Id(Anchor(id))],
		inner: TrustedHtml.join([
			TrustedHtml.tag({
				name: Header,
				attrs: [],
				inner: header,
			}),
			newline,
			TrustedHtml.tag({
				name: Div,
				attrs: [Class(Body)],
				inner: TrustedHtml.markdown(m.markdown()),
			}),
		]),
	})
	TrustedHtml.join([article, newline])
}

## **THE SKELETON EVERY PAGE SHARES**: the doctype and charset, `title` as
## its title, the style, then `body`.
whole : { title : Str, body : TrustedHtml } -> TrustedHtml
whole = |{ title, body }|
	TrustedHtml.join([
		TrustedHtml.doctype,
		TrustedHtml.tag({
			name: Title,
			attrs: [],
			inner: TrustedHtml.text(title),
		}),
		newline,
		TrustedHtml.style,
		body,
	])

newline : TrustedHtml
newline = TrustedHtml.text("\n")

space : TrustedHtml
space = TrustedHtml.text(" ")
