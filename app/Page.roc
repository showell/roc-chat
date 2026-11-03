## **THE PAGES**: a conversation's, and the one that says why there is
## none. Every page is the same skeleton (the doctype, its title, the style
## sheet, then its body); the page carries structure and class names, and
## only enough style to read, so a client can style the rest.
##
## **A CONVERSATION'S PAGE IS TWO PANES**: its messages (`messages`), then
## the compose box (`compose`): a plain form that posts the field
## `markdown` back to the conversation's own URL, so it works with no
## script, and a line of help: markdown, and the key that sends. The page's
## one script (`ComposeScript`, app/compose.js) lays the panes out (a wide
## window's compose box a rail on the right, with its keyboard help), gives
## the box its keys, and appends each message the conversation's stream brings; it
## finds them by the classes written here, and the stream by the messages
## pane's `data-stream` and `data-after`. A message on the stream is
## written by `message`, as the page writes it.
##
## **THE PAGE'S VOCABULARY LIVES HERE**: its classes (`Class`, a closed set,
## so no class is free text) and the CSS that styles them. How a message
## is named, its reference and its anchor, is `MsgAnchor`'s.
##
## **WHAT IS TRUSTED, AND WHO VOUCHES**: every `Str` a page shows goes in
## through `Escape.text`, a message's markdown through `Markdown.render`,
## and every element through `Html.element`. This module vouches
## (`TrustedHtml.dangerously_trust`) for two constants only: the doctype
## and the style sheet, both written here, the CSS holding no `<`.
import ComposeScript
import Conversation
import ConversationKey
import Escape
import Html
import Markdown
import Message
import MsgAnchor
import Topic
import TrustedHtml
import UrlEncodedForm

Page :: [].{

	## **A CLASS A PAGE USES**: a closed set, so a class is never data.
	Class : [
		Author,
		Body,
		Compose,
		Empty,
		Help,
		Message,
		Messages,
		Ref,
	]

	## The class attribute for `class`, its one spelling.
	class : Page.Class -> Html.Attribute
	class = |chosen| Class(token(class_name(chosen)))

	## **A CONVERSATION'S PAGE**: the topic, then each message under its
	## author and time, with its reference (`MsgAnchor`) as a link to
	## itself; then the compose box, posting to `key`'s URL; then the
	## script.
	conversation : Conversation, ConversationKey -> TrustedHtml
	conversation = |c, key| {
		topic = c.topic()
		heading = Html.element({
			name: H1,
			attrs: [],
			inner: Escape.text(topic.to_str()),
		})
		messages =
			if (c.messages().is_empty())
				TrustedHtml.join([
					Html.element({
						name: P,
						attrs: [Page.class(Empty)],
						inner: Escape.text("No messages yet."),
					}),
					newline,
				])
			else
				TrustedHtml.join(c.messages().map(|m| Page.message(c, m)))
		document({
			title: topic.to_str(),
			body: TrustedHtml.join([
				Html.element({
					name: Div,
					attrs: [
						Page.class(Messages),
						DataStream(site_path(key.stream_url_path())),
						DataAfter(token(c.messages().len().to_str())),
					],
					inner: TrustedHtml.join([
						heading,
						newline,
						messages,
					]),
				}),
				newline,
				compose_box(key),
				newline,
				Html.element({
					name: Script,
					attrs: [Src(site_path(ComposeScript.url_path))],
					inner: TrustedHtml.join([]),
				}),
				newline,
			]),
		})
	}

	## **THE PAGE FOR A REFUSED TRANSCRIPT**, saying why in `why`'s words.
	refusal : Str -> TrustedHtml
	refusal = |why|
		document({
			title: "Not a transcript",
			body: Html.element({
				name: P,
				attrs: [],
				inner: Escape.text("Not a transcript: ${why}."),
			}),
		})

	## **ONE MESSAGE OF `c`**, as its page and its stream write it: its
	## header, then its markdown rendered.
	message : Conversation, Message -> TrustedHtml
	message = |c, m| {
		named = c.reference(m.id())
		header = TrustedHtml.join([
			Html.element({
				name: Span,
				attrs: [Page.class(Author)],
				inner: Escape.text(m.author().to_str()),
			}),
			space,
			Html.element({
				name: Time,
				attrs: [DateTime(m.time())],
				inner: Escape.text(m.time().to_str()),
			}),
			space,
			Html.element({
				name: A,
				attrs: [Page.class(Ref), Href(anchor(named))],
				inner: Escape.text(named.to_str()),
			}),
		])
		article = Html.element({
			name: Article,
			attrs: [Page.class(Message), Id(anchor(named))],
			inner: TrustedHtml.join([
				Html.element({
					name: Header,
					attrs: [],
					inner: header,
				}),
				newline,
				Html.element({
					name: Div,
					attrs: [Page.class(Body)],
					inner: Markdown.render(m.markdown()),
				}),
			]),
		})
		TrustedHtml.join([article, newline])
	}

	## **A PAGE THAT SAYS ONE THING**: `title`, and `said` beneath it (no
	## such conversation, a refused message, a failure).
	notice : { title : Str, said : Str } -> TrustedHtml
	notice = |{ title, said }|
		document({
			title,
			body: Html.element({
				name: P,
				attrs: [],
				inner: Escape.text(said),
			}),
		})
}

## **THE COMPOSE BOX**: a form posting its one field, a message's
## markdown (`UrlEncodedForm.markdown_name`), to `key`'s page, as
## `ConversationRoute.post_sent_message!` takes it; then its help line.
compose_box : ConversationKey -> TrustedHtml
compose_box = |key|
	Html.element({
		name: Div,
		attrs: [Page.class(Compose)],
		inner: TrustedHtml.join([
			Html.element({
				name: Form,
				attrs: [MethodPost, Action(site_path(key.url_path()))],
				inner: TrustedHtml.join([
					Html.element({
						name: Textarea,
						attrs: [FieldName(token(UrlEncodedForm.markdown_name)), Required],
						inner: TrustedHtml.join([]),
					}),
					newline,
					Html.element({
						name: Button,
						attrs: [],
						inner: Escape.text("Send"),
					}),
				]),
			}),
			newline,
			Html.element({
				name: P,
				attrs: [Page.class(Help)],
				inner: Escape.text("Markdown supported · Ctrl/⌘-Enter to send"),
			}),
		]),
	})

## **A PAGE'S WHOLE DOCUMENT**, the same for every page: the doctype and charset, `title` as
## its title, the style sheet, then `body`.
document : { title : Str, body : TrustedHtml } -> TrustedHtml
document = |{ title, body }|
	TrustedHtml.join([
		doctype,
		Html.element({
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
		Compose => "compose"
		Empty => "empty"
		Help => "help"
		Message => "message"
		Messages => "messages"
		Ref => "ref"
	}

## **A MESSAGE'S ANCHOR**, as a token: `MsgAnchor.page_anchor`'s
## spelling, which an element's id and a link's `#` both write.
anchor : MsgAnchor -> Html.Token
anchor = |named| token(named.page_anchor())

## The token `text` spells, for a name this module writes: one that isn't
## is this module's bug.
token : Str -> Html.Token
token = |text| Html.Token.from_str(text) ?? crash "Page.token: \"${text}\" is a name this module writes, and not a token"

## The site path `text` spells, for a path this server answers (a
## conversation's, its script's): one that isn't is a bug in its writer.
site_path : Str -> Html.SitePath
site_path = |text| Html.SitePath.from_str(text) ?? crash "Page.site_path: \"${text}\" is a path this server answers, and not a site path"

newline : TrustedHtml
newline = Escape.text("\n")

space : TrustedHtml
space = Escape.text(" ")

# ── tests
## An element `attrs` alone opens, as a test reads it.
opened : List(Html.Attribute) -> List(U8)
opened = |attrs|
	Html.element({
		name: P,
		attrs,
		inner: TrustedHtml.join([]),
	}).to_utf8()

# Every class, each its one spelling.
expect opened([Page.class(Author)]) == "<p class=\"author\"></p>".to_utf8()
expect opened([Page.class(Body)]) == "<p class=\"body\"></p>".to_utf8()
expect opened([Page.class(Compose)]) == "<p class=\"compose\"></p>".to_utf8()
expect opened([Page.class(Empty)]) == "<p class=\"empty\"></p>".to_utf8()
expect opened([Page.class(Help)]) == "<p class=\"help\"></p>".to_utf8()
expect opened([Page.class(Message)]) == "<p class=\"message\"></p>".to_utf8()
expect opened([Page.class(Messages)]) == "<p class=\"messages\"></p>".to_utf8()
expect opened([Page.class(Ref)]) == "<p class=\"ref\"></p>".to_utf8()
# The script finds the panes by the classes this module writes, each
# spelled as a selector there; a class it doesn't use is not.
expect
	[
		Messages,
		Compose,
		Help,
		Empty,
	].all(|chosen| Str.from_utf8_lossy(ComposeScript.bytes).contains("'.${class_name(chosen)}'"))
expect !Str.from_utf8_lossy(ComposeScript.bytes).contains("'.${class_name(Message)}'")
# The script finds the stream by the attributes `Html` writes for it.
expect ["data-stream", "data-after"].all(|name| Str.from_utf8_lossy(ComposeScript.bytes).contains("'${name}'"))
# A message's anchor as an id and as a link, at the first id and the next.
expect {
	second = Message.Id.first.next() ?? crash "Page's tests: the first id has a next"
	plans = Topic.from_str("plans") ?? crash "Page's tests: a topic"
	first_named = MsgAnchor.of({ topic: plans, id: Message.Id.first })
	second_named = MsgAnchor.of({ topic: plans, id: second })
	[
		(Id(anchor(first_named)), "<p id=\"msg-1\"></p>"),
		(Href(anchor(first_named)), "<p href=\"#msg-1\"></p>"),
		(Id(anchor(second_named)), "<p id=\"msg-2\"></p>"),
		(Href(anchor(second_named)), "<p href=\"#msg-2\"></p>"),
	].all(|(attr, expected)| opened([attr]) == expected.to_utf8())
}
expect doctype.to_utf8() == "<!doctype html>\n<meta charset=utf-8>\n".to_utf8()
expect stylesheet.to_utf8() == "<style>\n${css}</style>\n".to_utf8()
expect !css.contains("<")
# A notice: its title and its words, each escaped.
expect Page.notice({ title: "a<b", said: "x & y" }).to_utf8() == "<!doctype html>\n<meta charset=utf-8>\n<title>a&lt;b</title>\n<style>\n${css}</style>\n<p>x &amp; y</p>".to_utf8()
