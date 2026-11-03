## This module builds the chat's pages: a conversation's page, a page that
## says why a transcript was refused, and a page that says one thing. The
## server sends structure and class names only. Every page loads
## app/palette.js in its head (`PaletteScript`), which sets the colours and
## the theme before the first paint, and a conversation's page ends with
## its three scripts, which style what they find and add behaviour. The
## page reads top to bottom without them, and its form still posts.
##
## A conversation's page has a top bar, with the topic and the viewer's
## name, and below it two panes. The first holds the messages, and the
## second is the compose box: a form that posts the field `markdown` back
## to the conversation's own URL, and a line of help. app/chrome.js
## (`ChromeScript`) styles the top bar and adds its theme toggle.
## app/compose.js (`ComposeScript`) lays the panes out and gives the
## compose box its keys and its Upload button. app/feed.js (`FeedScript`)
## styles the messages, marks the viewer's own, writes each time in the
## viewer's time zone, and appends each message the conversation's stream
## brings, which `message` writes as the page does.
##
## The scripts find what they need by the classes in `Class` and by
## attributes. The messages pane names its stream (`data-stream`), how
## many messages it shows (`data-after`) and the viewer's id
## (`data-viewer`). A message names its author's id (`data-author`) when
## its author is a user of the chat. The form names where to upload an
## image (`data-upload`) and the most an image may be (`data-image-most`).
##
## Every `Str` a page shows goes in through `Escape.text`, a message's
## markdown through `Markdown.render`, and every element through
## `Html.element`. This module vouches (`TrustedHtml.dangerously_trust`)
## for one constant: the doctype and the head's two `<meta>` elements.
import ChromeScript
import ComposeScript
import Conversation
import ConversationKey
import Escape
import FeedScript
import Html
import Markdown
import Message
import MsgAnchor
import PaletteScript
import SignedIn
import Topic
import TrustedHtml
import UploadedImage
import UrlEncodedForm
import Users

Page :: [].{

	## A class a page uses: a closed set, so a class is never data.
	Class : [
		Author,
		Body,
		Compose,
		Empty,
		Help,
		Layout,
		Message,
		Messages,
		Ref,
		TopBar,
		TopTitle,
		TopUser,
		Viewer,
	]

	## The class attribute for `class`, its one spelling.
	class : Page.Class -> Html.Attribute
	class = |chosen| Class(token(class_name(chosen)))

	## The page of `conversation`, the conversation `key`, for `viewer`. Each
	## message of it is found among `users` by its author's name, to name its
	## author's id.
	conversation : {
		conversation : Conversation,
		key : ConversationKey,
		viewer : SignedIn,
		users : Users,
	} -> TrustedHtml
	conversation = |
		{
			conversation: c,
			key,
			viewer,
			users,
		},
	| {
		topic = c.topic()
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
				TrustedHtml.join(
					c.messages().map(
						|m|
							Page.message({
								conversation: c,
								key,
								users,
								message: m,
							}),
					),
				)
		document({
			title: topic.to_str(),
			body: TrustedHtml.join([
				top_bar({ title: topic.to_str(), viewer }),
				newline,
				Html.element({
					name: Div,
					attrs: [Page.class(Layout)],
					inner: TrustedHtml.join([
						Html.element({
							name: Div,
							attrs: [
								Page.class(Messages),
								DataStream(site_path(key.stream_url_path())),
								DataAfter(token(c.messages().len().to_str())),
								DataViewer(user_id(viewer.user())),
							],
							inner: TrustedHtml.join([newline, messages]),
						}),
						newline,
						compose_box(key),
						newline,
					]),
				}),
				newline,
				TrustedHtml.join(
					[
						ChromeScript.url_path,
						ComposeScript.url_path,
						FeedScript.url_path,
					].map(|url_path| TrustedHtml.join([script(url_path), newline])),
				),
			]),
		})
	}

	## The page for a refused transcript, saying why in `why`'s words.
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

	## One message of `conversation`, the conversation `key`, as its page
	## and its stream write it: its header, then its markdown rendered. Its
	## author's id is named when `users` holds a user of its author's name.
	message : {
		conversation : Conversation,
		key : ConversationKey,
		users : Users,
		message : Message,
	} -> TrustedHtml
	message = |
		{
			conversation: c,
			key,
			users,
			message: m,
		},
	| {
		message_reference = c.reference(m.id())
		author_attrs =
			match users.user_by_name(m.author().name()) {
				Ok(user) => [DataAuthor(user_id(user))]
				Err(NoSuchUser) => []
			}
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
				attrs: [Page.class(Ref), Href(anchor(message_reference))],
				inner: Escape.text(message_reference.to_str()),
			}),
		])
		article = Html.element({
			name: Article,
			attrs: [Page.class(Message), Id(anchor(message_reference))].concat(author_attrs),
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
					inner: Markdown.render(m.markdown(), key),
				}),
			]),
		})
		TrustedHtml.join([article, newline])
	}

	## A page that says one thing: `title`, and `said` beneath it (no such
	## conversation, a refused message, a failure).
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

## The compose box: a form posting its one field, a message's markdown
## (`UrlEncodedForm.markdown_name`), to `key`'s page, as
## `ConversationRoute.post_sent_message!` takes it, and naming for the
## script where an image is uploaded and the most it may be
## (`UploadRoute`); then its help line.
compose_box : ConversationKey -> TrustedHtml
compose_box = |key|
	Html.element({
		name: Div,
		attrs: [Page.class(Compose)],
		inner: TrustedHtml.join([
			Html.element({
				name: Form,
				attrs: [
					MethodPost,
					Action(site_path(key.url_path())),
					DataUpload(site_path(key.upload_url_path())),
					DataImageMost(token(UploadedImage.most_bytes.to_str())),
				],
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
				inner: Escape.text("Markdown supported · attach an image · Ctrl/⌘-Enter to send"),
			}),
		]),
	})

## The top bar: `title` on the left, and the name of `viewer`, the user
## viewing the page, on the right.
top_bar : { title : Str, viewer : SignedIn } -> TrustedHtml
top_bar = |{ title, viewer }|
	Html.element({
		name: Header,
		attrs: [Page.class(TopBar)],
		inner: TrustedHtml.join([
			Html.element({
				name: Span,
				attrs: [Page.class(TopTitle)],
				inner: Escape.text(title),
			}),
			space,
			Html.element({
				name: Div,
				attrs: [Page.class(TopUser)],
				inner: Html.element({
					name: Span,
					attrs: [Page.class(Viewer)],
					inner: Escape.text(viewer.user().name().to_str()),
				}),
			}),
		]),
	})

## A user's id, which the scripts compare: a message's author's with the
## viewer's.
user_id : Users.User -> Html.Token
user_id = |user| token(user.id().to_str())

## The script at `url_path`, one of this server's.
script : Str -> TrustedHtml
script = |url_path|
	Html.element({
		name: Script,
		attrs: [Src(site_path(url_path))],
		inner: TrustedHtml.join([]),
	})

## A page's whole document, the same for every page: the doctype and the
## head's `<meta>` elements, `title` as its title, the colour script, then
## `body`.
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
		script(PaletteScript.url_path),
		newline,
		body,
	])

## The doctype, the charset, and the viewport a phone lays the page out
## in, which every page opens with: a constant, vouched for here.
doctype : TrustedHtml
doctype = TrustedHtml.dangerously_trust(doctype_text)

doctype_text : Str
doctype_text =
	\\<!doctype html>
	\\<meta charset=utf-8>
	\\<meta name=viewport content="width=device-width, initial-scale=1">
	\\

class_name : Page.Class -> Str
class_name = |chosen|
	match chosen {
		Author => "author"
		Body => "body"
		Compose => "compose"
		Empty => "empty"
		Help => "help"
		Layout => "layout"
		Message => "message"
		Messages => "messages"
		Ref => "ref"
		TopBar => "top-bar"
		TopTitle => "top-title"
		TopUser => "top-user"
		Viewer => "viewer"
	}

## A message's anchor, as a token: `MsgAnchor.page_anchor`'s spelling,
## which an element's id and a link's `#` both write.
anchor : MsgAnchor -> Html.Token
anchor = |message_reference| token(message_reference.page_anchor())

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
empty_paragraph : List(Html.Attribute) -> List(U8)
empty_paragraph = |attrs|
	Html.element({
		name: P,
		attrs,
		inner: TrustedHtml.join([]),
	}).to_utf8()

# Every class, each its one spelling.
expect
	[
		(Author, "author"),
		(Body, "body"),
		(Compose, "compose"),
		(Empty, "empty"),
		(Help, "help"),
		(Layout, "layout"),
		(Message, "message"),
		(Messages, "messages"),
		(Ref, "ref"),
		(TopBar, "top-bar"),
		(TopTitle, "top-title"),
		(TopUser, "top-user"),
		(Viewer, "viewer"),
	].all(|(chosen, spelled)| empty_paragraph([Page.class(chosen)]) == "<p class=\"${spelled}\"></p>".to_utf8())

## Whether the script `bytes` finds the class `chosen` by its selector.
is_found_by : List(U8), Page.Class -> Bool
is_found_by = |bytes, chosen| Str.from_utf8_lossy(bytes).contains("'.${class_name(chosen)}'")

## Whether the script `bytes` reads the attribute `name`.
is_read_by : List(U8), Str -> Bool
is_read_by = |bytes, name| Str.from_utf8_lossy(bytes).contains("'${name}'")

# Each script finds the elements it works on by the classes this module
# writes, and reads the attributes `Html` writes for it; a class or an
# attribute it leaves to another script is not in it.
expect [TopBar, TopUser].all(|chosen| is_found_by(ChromeScript.bytes, chosen))
expect
	[
		Layout,
		Messages,
		Compose,
		Help,
	].all(|chosen| is_found_by(ComposeScript.bytes, chosen))
expect
	[
		Messages,
		Compose,
		Message,
		Empty,
	].all(|chosen| is_found_by(FeedScript.bytes, chosen))
expect !is_found_by(ComposeScript.bytes, Message) and !is_found_by(ComposeScript.bytes, Empty)
expect !is_found_by(FeedScript.bytes, Help) and !is_found_by(ChromeScript.bytes, Messages)
expect
	[
		"data-stream",
		"data-after",
		"data-viewer",
		"data-author",
	].all(|name| is_read_by(FeedScript.bytes, name) and !is_read_by(ComposeScript.bytes, name))
expect ["data-upload", "data-image-most"].all(|name| is_read_by(ComposeScript.bytes, name) and !is_read_by(FeedScript.bytes, name))
# The classes only styled are styled by the script that owns them.
expect [TopTitle, Viewer].all(|chosen| Str.from_utf8_lossy(ChromeScript.bytes).contains(".${class_name(chosen)} {"))
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
	].all(|(attr, expected)| empty_paragraph([attr]) == expected.to_utf8())
}
expect doctype.to_utf8() == "<!doctype html>\n<meta charset=utf-8>\n<meta name=viewport content=\"width=device-width, initial-scale=1\">\n".to_utf8()
# A notice: its title and its words, each escaped, under the colour script.
expect Page.notice({ title: "a<b", said: "x & y" }).to_utf8() == "${doctype_text}<title>a&lt;b</title>\n<script src=\"/chat/assets/palette.js\"></script>\n<p>x &amp; y</p>".to_utf8()
