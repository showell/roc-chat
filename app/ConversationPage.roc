## This module builds a conversation's page, which `ConversationRoute`
## serves, and each message on it, which `ConversationStream` sends as the
## page writes it, so the page and its stream can't disagree.
##
## A conversation's page has the top bar (`PageKit.top_bar`), and below it
## the sidebar of a human's page (`Sidebar`), then two panes. The first
## holds the messages, and the second is the compose box: a form that posts
## the field `markdown` to the conversation's own URL, and a line of help.
## The script sends the same form to the conversation's `/send` instead, so
## the page stays put. The page ends with its scripts. app/chrome.js styles
## the top bar and adds its theme toggle. app/sidebar.js styles the sidebar
## and collapses its places. app/compose.js lays the panes out, gives the compose box
## its keys and its Upload button, and sends a message without a reload.
## app/feed.js styles the messages, marks the viewer's own, writes each
## time in the viewer's time zone, appends each message the conversation's
## stream brings, and lets the reader select a message and move between
## them from the keyboard. They find what they need by `PageContract`'s
## names.
##
## A message's markdown goes in through `Markdown.message_html`, and
## everything else through `Escape.text` and `Html.element`.
import Browse
import Conversation
import ConversationKey
import Escape
import Html
import Markdown
import Message
import MsgAnchor
import PageContract
import PageKit
import Script
import Sidebar
import SignedIn
import Topic
import TrustedHtml
import UploadedImage
import UrlEncodedForm
import Users

ConversationPage :: [].{

	## The page of `conversation`, the conversation `key`, for `viewer`. Each
	## message of it is found among `users` by its author's name, to name its
	## author's id. A human's page has the sidebar of the places Browse lists
	## for them (`Sidebar`); a key's has none.
	conversation : {
		conversation : Conversation,
		key : ConversationKey,
		viewer : SignedIn,
		users : Users,
		sidebar : [NoSidebar, Sidebar(List(Browse.PlaceWithTopics))],
	} -> TrustedHtml
	conversation = |
		{
			conversation: thread,
			key,
			viewer,
			users,
			sidebar,
		},
	| {
		topic = thread.topic()
		messages =
			if thread.messages().is_empty() {
				TrustedHtml.join([
					Html.element({
						name: P,
						attrs: [PageContract.class(Empty)],
						inner: Escape.text("No messages yet."),
					}),
					PageKit.newline,
				])
			} else {
				TrustedHtml.join(
					thread.messages().map(
						|one_message|
							ConversationPage.message({
								conversation: thread,
								key,
								users,
								message: one_message,
							}),
					),
				)
			}
		stream_path = PageKit.site_path(key.url_path(Stream))
		shown_count = PageKit.token(thread.messages().len().to_str())
		{ toggle, nav, scripts } =
			match sidebar {
				NoSidebar => { toggle: [], nav: [], scripts: [] }
				Sidebar(places) => {
					toggle: [Sidebar.toggle],
					nav: [Sidebar.nav({ places, current: key })],
					scripts: [Script.Sidebar],
				}
			}
		PageKit.document({
			title: topic.to_str(),
			body: TrustedHtml.join([
				PageKit.top_bar({ title: topic.to_str(), viewer }),
				PageKit.newline,
				TrustedHtml.join(toggle),
				Html.element({
					name: Div,
					attrs: [PageContract.class(Layout)],
					inner: TrustedHtml.join([
						TrustedHtml.join(nav),
						Html.element({
							name: Div,
							attrs: [
								PageContract.class(Messages),
								PageContract.data_attribute(Stream(stream_path)),
								PageContract.data_attribute(After(shown_count)),
								PageContract.data_attribute(Viewer(user_id(viewer.user()))),
							],
							inner: TrustedHtml.join([PageKit.newline, messages]),
						}),
						PageKit.newline,
						compose_box(key),
						PageKit.newline,
					]),
				}),
				PageKit.newline,
				TrustedHtml.join(
					List.concat(
						List.concat([Script.Chrome], scripts),
						[Script.Compose, Script.Feed],
					).map(|chosen| TrustedHtml.join([PageKit.script(chosen), PageKit.newline])),
				),
			]),
		})
	}

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
			conversation: thread,
			key,
			users,
			message: one_message,
		},
	| {
		message_reference = thread.reference(one_message.id())
		author_attrs =
			match users.user_by_name(one_message.author().name()) {
				Ok(user) => [PageContract.data_attribute(Author(user_id(user)))]
				Err(NoSuchUser) => []
			}
		header = TrustedHtml.join([
			Html.element({
				name: Span,
				attrs: [PageContract.class(Author)],
				inner: Escape.text(one_message.author().to_str()),
			}),
			PageKit.space,
			Html.element({
				name: Time,
				attrs: [DateTime(one_message.time())],
				inner: Escape.text(one_message.time().to_str()),
			}),
			PageKit.space,
			Html.element({
				name: A,
				attrs: [PageContract.class(Ref), Href(anchor(message_reference))],
				inner: Escape.text(message_reference.to_str()),
			}),
		])
		article = Html.element({
			name: Article,
			attrs: List.concat(
				[PageContract.class(Message), Id(anchor(message_reference))],
				author_attrs,
			),
			inner: TrustedHtml.join([
				Html.element({ name: Header, attrs: [], inner: header }),
				PageKit.newline,
				Html.element({
					name: Div,
					attrs: [PageContract.class(Body)],
					inner: Markdown.message_html(one_message.markdown(), key),
				}),
			]),
		})
		TrustedHtml.join([article, PageKit.newline])
	}

}

## The compose box: a form posting its one field, a message's markdown
## (`UrlEncodedForm.markdown_name`), to `key`'s page, as
## `ConversationRoute.post_sent_message!` takes it, and naming for the
## script where an image is uploaded and the most it may be
## (`UploadRoute`), and where the script sends the same field
## (`ConversationRoute.post_message_without_reload!`); then its help line.
compose_box : ConversationKey -> TrustedHtml
compose_box = |key| {
	byte_limit = PageKit.token(UploadedImage.most_bytes.to_str())
	Html.element({
		name: Div,
		attrs: [PageContract.class(Compose)],
		inner: TrustedHtml.join([
			Html.element({
				name: Form,
				attrs: [
					MethodPost,
					Action(PageKit.site_path(key.url_path(Page))),
					PageContract.data_attribute(Send(PageKit.site_path(key.url_path(Send)))),
					PageContract.data_attribute(Upload(PageKit.site_path(key.url_path(Upload)))),
					PageContract.data_attribute(ImageByteLimit(byte_limit)),
				],
				inner: TrustedHtml.join([
					Html.element({
						name: Textarea,
						attrs: [FieldName(PageKit.token(UrlEncodedForm.markdown_name)), Required],
						inner: TrustedHtml.join([]),
					}),
					PageKit.newline,
					Html.element({
						name: Button,
						attrs: [],
						inner: Escape.text("Send"),
					}),
				]),
			}),
			PageKit.newline,
			Html.element({
				name: P,
				attrs: [PageContract.class(Help)],
				inner: Escape.text("Markdown supported · attach an image · Ctrl/⌘-Enter to send"),
			}),
		]),
	})
}

## A user's id, which the scripts compare: a message's author's with the
## viewer's.
user_id : Users.User -> Html.Token
user_id = |user| PageKit.token(user.id().to_str())

## A message's anchor, as a token: `MsgAnchor.page_anchor`'s spelling,
## which an element's id and a link's `#` both write.
anchor : MsgAnchor -> Html.Token
anchor = |message_reference| PageKit.token(message_reference.page_anchor())

# ── tests
# A message's anchor as an id and as a link, at the first id and the next.
expect {
	second = Message.Id.first.next() ?? crash "ConversationPage's tests: the first id has a next"
	plans = Topic.from_str("plans") ?? crash "ConversationPage's tests: a topic"
	first_named = MsgAnchor.of({ topic: plans, id: Message.Id.first })
	second_named = MsgAnchor.of({ topic: plans, id: second })
	[
		(Id(anchor(first_named)), "<p id=\"msg-1\"></p>"),
		(Href(anchor(first_named)), "<p href=\"#msg-1\"></p>"),
		(Id(anchor(second_named)), "<p id=\"msg-2\"></p>"),
		(Href(anchor(second_named)), "<p href=\"#msg-2\"></p>"),
	].all(|(attr, expected)| PageContract.empty_paragraph([attr]) == expected.to_utf8())
}
