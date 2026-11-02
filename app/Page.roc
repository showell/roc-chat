## **THE PAGES**: a conversation's, and the one that says why there is
## none. Every page is the same skeleton (the doctype, its title, the style
## sheet, then its body); the page carries structure and class names, and
## only enough style to read, so a client can style the rest.
##
## **THE PAGE'S VOCABULARY LIVES HERE**: its classes (`Class`, a closed set,
## so no class is free text) and the CSS that styles them. How a message
## is named, its reference and its anchor, is `MsgAnchor`'s.
##
## **WHAT IS TRUSTED, AND WHO VOUCHES**: every `Str` a page shows goes in
## through `Escape.text`, a message's markdown through `Markdown.render`,
## and every element through `HtmlElement.tag`. This module vouches
## (`TrustedHtml.dangerously_trust`) for two constants only: the doctype
## and the style sheet, both written here, the CSS holding no `<`.
import Conversation
import HtmlElement
import Escape
import Markdown
import Message
import MsgAnchor
import Topic
import TrustedHtml

Page :: [].{

	## **A CLASS A PAGE USES**: a closed set, so a class is never data.
	Class : [Author, Body, Empty, Message, Ref]

	## The class attribute for `class`, its one spelling.
	class : Page.Class -> HtmlElement.Attribute
	class = |chosen| Class(token(class_name(chosen)))

	## **A CONVERSATION'S PAGE**: the topic, then each message under its
	## author and time, with its reference (`MsgAnchor`) as a link to
	## itself.
	conversation : Conversation -> TrustedHtml
	conversation = |c| {
		topic = c.topic()
		heading = HtmlElement.tag({
			name: H1,
			attrs: [],
			inner: Escape.text(topic.to_str()),
		})
		messages =
			if (c.messages().is_empty())
				TrustedHtml.join([
					HtmlElement.tag({
						name: P,
						attrs: [Page.class(Empty)],
						inner: Escape.text("No messages yet."),
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
			body: HtmlElement.tag({
				name: P,
				attrs: [],
				inner: Escape.text("Not a transcript: ${why}."),
			}),
		})
}

## One message: its header, then its markdown rendered.
message : Conversation, Message -> TrustedHtml
message = |c, m| {
	named = c.reference(m.id())
	header = TrustedHtml.join([
		HtmlElement.tag({
			name: Span,
			attrs: [Page.class(Author)],
			inner: Escape.text(m.author().to_str()),
		}),
		space,
		HtmlElement.tag({
			name: Time,
			attrs: [DateTime(m.time())],
			inner: Escape.text(m.time().to_str()),
		}),
		space,
		HtmlElement.tag({
			name: A,
			attrs: [Page.class(Ref), Href(anchor(named))],
			inner: Escape.text(named.to_str()),
		}),
	])
	article = HtmlElement.tag({
		name: Article,
		attrs: [Page.class(Message), Id(anchor(named))],
		inner: TrustedHtml.join([
			HtmlElement.tag({
				name: Header,
				attrs: [],
				inner: header,
			}),
			newline,
			HtmlElement.tag({
				name: Div,
				attrs: [Page.class(Body)],
				inner: Markdown.render(m.markdown()),
			}),
		]),
	})
	TrustedHtml.join([article, newline])
}

## **THE SKELETON EVERY PAGE SHARES**: the doctype and charset, `title` as
## its title, the style sheet, then `body`.
whole : { title : Str, body : TrustedHtml } -> TrustedHtml
whole = |{ title, body }|
	TrustedHtml.join([
		doctype,
		HtmlElement.tag({
			name: Title,
			attrs: [],
			inner: Escape.text(title),
		}),
		newline,
		stylesheet,
		body,
	])

## The doctype and the charset, which every page opens with: a constant,
## vouched for here.
doctype : TrustedHtml
doctype = TrustedHtml.dangerously_trust("<!doctype html>\n<meta charset=utf-8>\n")

## **THE STYLE SHEET EVERY PAGE CARRIES**: only enough to read, so a client
## styles the rest. Vouched for here: `css` is this module's constant, and
## holds no `<`, so it can't close its element early.
stylesheet : TrustedHtml
stylesheet = TrustedHtml.dangerously_trust("<style>\n${css}</style>\n")

## The style sheet's rules, for the classes in `Class`. CSS is code, never
## data.
css : Str
css =
	\\body{font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}
	\\.message{border-top:1px solid #ccc;padding:.5rem 0}
	\\.author{font-weight:600}
	\\time,.ref{color:#777;font-size:.85em}
	\\.ref{float:right}
	\\

class_name : Page.Class -> Str
class_name = |chosen|
	match chosen {
		Author => "author"
		Body => "body"
		Empty => "empty"
		Message => "message"
		Ref => "ref"
	}

## **A MESSAGE'S ANCHOR**, as a token: `MsgAnchor.page_anchor`'s
## spelling, which an element's id and a link's `#` both write.
anchor : MsgAnchor -> HtmlElement.Token
anchor = |named| token(named.page_anchor())

## The token `text` spells, for a name this module writes: one that isn't
## is this module's bug.
token : Str -> HtmlElement.Token
token = |text| HtmlElement.Token.from_str(text) ?? crash "Page.token: \"${text}\" is a name this module writes, and not a token"

newline : TrustedHtml
newline = Escape.text("\n")

space : TrustedHtml
space = Escape.text(" ")

# ── tests
## An element `attrs` alone opens, as a test reads it.
opened : List(HtmlElement.Attribute) -> List(U8)
opened = |attrs|
	HtmlElement.tag({
		name: P,
		attrs,
		inner: TrustedHtml.join([]),
	}).to_utf8()

# Every class, each its one spelling.
expect [Author, Body, Empty, Message, Ref].map(|chosen| opened([Page.class(chosen)])) == [
	"<p class=\"author\"></p>".to_utf8(),
	"<p class=\"body\"></p>".to_utf8(),
	"<p class=\"empty\"></p>".to_utf8(),
	"<p class=\"message\"></p>".to_utf8(),
	"<p class=\"ref\"></p>".to_utf8(),
]
# A message's anchor as an id and as a link, at the first id and the next.
expect {
	second = Message.Id.first.next() ?? crash "Page's tests: the first id has a next"
	plans = Topic.from_str("plans") ?? crash "Page's tests: a topic"
	first_named = MsgAnchor.of({ topic: plans, id: Message.Id.first })
	second_named = MsgAnchor.of({ topic: plans, id: second })
	[
		opened([Id(anchor(first_named))]),
		opened([Href(anchor(first_named))]),
		opened([Id(anchor(second_named))]),
		opened([Href(anchor(second_named))]),
	]
		== [
			"<p id=\"msg-1\"></p>".to_utf8(),
			"<p href=\"#msg-1\"></p>".to_utf8(),
			"<p id=\"msg-2\"></p>".to_utf8(),
			"<p href=\"#msg-2\"></p>".to_utf8(),
		]
}
expect doctype.to_utf8() == "<!doctype html>\n<meta charset=utf-8>\n".to_utf8()
expect stylesheet.to_utf8() == "<style>\n${css}</style>\n".to_utf8()
expect !css.contains("<")
