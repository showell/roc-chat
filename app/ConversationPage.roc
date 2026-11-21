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
## and collapses its groups and places, and app/sidebar-popups.js gives it
## its popups. app/compose.js lays the panes out, gives the compose box
## its keys and its Upload button, and sends a message without a reload.
## app/emoji.js autocompletes an emoji's `:name` in the compose box.
## app/feed.js styles the messages, marks the viewer's own, writes each
## time in the viewer's time zone, appends each message the conversation's
## stream brings, puts a message the stream sends again in place of the one
## shown, and lets the reader select a message and move between them from
## the keyboard. app/citation.js writes a citation of a message and marks one
## in a message. app/actions.js gives each message its actions: reacting,
## quoting, citing, and editing the viewer's own. They find what they need by
## `PageContract`'s names. The messages pane names the page's place as the
## viewer would (`place_of`) and its topic, for a citation's link and the
## compose box's placeholder.
##
## Each message is drawn with its notes (`MessageNotes`). An edited message
## says which message edited it, and keeps its markdown, as written, folded
## away under "original". A message with reactions ends with a strip of
## them, an emoji a button, each naming its reactors' ids for the script,
## and their names in its title, which a browser shows on hover.
##
## A message's markdown goes in through `Markdown.message_html`, and
## everything else through `Escape.text` and `Html.element`.
import ChannelName
import ChannelRoster
import Conversation
import ConversationKey
import Escape
import Html
import Markdown
import Message
import MessageAnchor
import MessageNotes
import PageContract
import PageKit
import Reactions
import Script
import Sidebar
import SidebarOrder
import SignedIn
import Topic
import TrustedHtml
import UploadedImage
import UrlEncodedForm
import UserId
import Users

ConversationPage :: [].{

	## A human's page has the sidebar of the places Browse lists for them,
	## with who of the humans is online, what the top bar's notices' line
	## says as it is drawn (a DM's says where the other human is,
	## `Presence.presence_words`), and each channel's members, by
	## participation (`ChannelRoster`); a key's has none.
	SidebarShown : [
		NoSidebar,
		Sidebar(
			{
				places : List(SidebarOrder.TimedPlace),
				online_humans : List(UserId),
				notice : [NoNotice, Notice(Str)],
				rosters : List(ChannelRoster.Roster),
			},
		),
	]

	## The page of `conversation`, the conversation `key`, for `viewer`, each
	## message drawn with its notes, its `reactions` among them. Each
	## message of it is found among `users` by its author's name, to name its
	## author's id. A human's page has the sidebar of the places Browse lists
	## for them (`Sidebar`); a key's has none.
	conversation : {
		conversation : Conversation,
		reactions : Reactions,
		key : ConversationKey,
		viewer : SignedIn,
		users : Users,
		sidebar : ConversationPage.SidebarShown,
	} -> TrustedHtml
	conversation = |
		{
			conversation: thread,
			reactions,
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
						attributes: [PageContract.class(Empty)],
						inner: Escape.text("No messages yet."),
					}),
					PageKit.newline,
				])
			} else {
				TrustedHtml.join(
					List.map2(
						thread.messages(),
						MessageNotes.notes_of_messages({ conversation: thread, reactions }),
						|one_message, notes|
							ConversationPage.message({
								conversation: thread,
								key,
								users,
								message: one_message,
								notes,
							}),
					),
				)
			}
		stream_path = PageKit.site_path(key.url_path(Stream))
		react_path = PageKit.site_path(key.url_path(React))
		raw_path = PageKit.site_path(key.url_path(Raw))
		download_path = PageKit.site_path(key.url_path(Download))
		shown_count = PageKit.token(thread.messages().len().to_str())
		place =
			match place_of({ key, viewer: viewer.user(), users }) {
				Channel(name) => Channel(PageKit.token(name.to_str()))
				Person(person) => Person(person.name())
			}
		{ toggle, notices, nav, scripts } =
			match sidebar {
				NoSidebar => {
					toggle: [],
					notices: NoNotices,
					nav: [],
					scripts: Script.conversation_scripts(Alone),
				}
				Sidebar({ places, online_humans, notice, rosters }) => {
					toggle: [Sidebar.toggle],
					notices: Notices(notice),
					nav: [
						Sidebar.nav({
							places,
							current: key,
							viewer,
							online_humans,
							rosters,
						}),
					],
					scripts: Script.conversation_scripts(WithSidebar),
				}
			}
		PageKit.document({
			title: topic.to_str(),
			body: TrustedHtml.join([
				PageKit.linked_top_bar({
					title: top_title({ key, viewer: viewer.user(), users }),
					link: PageKit.site_path(key.url_path(Page)),
					viewer,
					notices,
				}),
				PageKit.newline,
				TrustedHtml.join(toggle),
				Html.element({
					name: Div,
					attributes: [PageContract.class(Layout)],
					inner: TrustedHtml.join([
						TrustedHtml.join(nav),
						Html.element({
							name: Div,
							attributes: [
								PageContract.class(Messages),
								PageContract.data_attribute(Stream(stream_path)),
								PageContract.data_attribute(After(shown_count)),
								PageContract.data_attribute(Viewer(user_id(viewer.user()))),
								PageContract.data_attribute(React(react_path)),
								PageContract.data_attribute(Raw(raw_path)),
								PageContract.data_attribute(Download(download_path)),
								PageContract.data_attribute(Place(place)),
								PageContract.data_attribute(Topic(PageKit.token(topic.to_str()))),
							],
							inner: TrustedHtml.join([PageKit.newline, messages]),
						}),
						PageKit.newline,
						compose_box(key),
						PageKit.newline,
					]),
				}),
				PageKit.newline,
				PageKit.scripts(scripts),
			]),
		})
	}

	## One message of `conversation`, the conversation `key`, as its page
	## and its stream write it, with its `notes`: its header, then its
	## markdown rendered, or what edited it, then its reactions. Its
	## author's id is named when `users` holds a user of its author's name.
	message : {
		conversation : Conversation,
		key : ConversationKey,
		users : Users,
		message : Message,
		notes : MessageNotes,
	} -> TrustedHtml
	message = |
		{
			conversation: thread,
			key,
			users,
			message: one_message,
			notes,
		},
	| {
		message_reference = thread.reference(one_message.id())
		author_attributes =
			match users.user_by_name(one_message.author().name()) {
				Ok(user) => [PageContract.data_attribute(Author(user_id(user)))]
				Err(NoSuchUser) => []
			}
		header = TrustedHtml.join([
			Html.element({
				name: Span,
				attributes: [PageContract.class(Author)],
				inner: Escape.text(one_message.author().to_str()),
			}),
			PageKit.space,
			Html.element({
				name: Time,
				attributes: [DateTime(one_message.time())],
				inner: Escape.text(one_message.time().to_str()),
			}),
			PageKit.space,
			Html.element({
				name: A,
				attributes: [PageContract.class(MessageReference), Href(anchor(message_reference))],
				inner: Escape.text(message_reference.to_str()),
			}),
		])
		body =
			match notes.edit_state() {
				NotEdited => Markdown.message_html(one_message.markdown(), key)
				EditedIn(edit_id) =>
					edited_body({
						edit_reference: thread.reference(edit_id),
						markdown: one_message.markdown(),
					})
			}
		article = Html.element({
			name: Article,
			attributes: List.concat(
				[PageContract.class(Message), Id(anchor(message_reference))],
				author_attributes,
			),
			inner: TrustedHtml.join([
				Html.element({ name: Header, attributes: [], inner: header }),
				PageKit.newline,
				Html.element({
					name: Div,
					attributes: [PageContract.class(Body)],
					inner: body,
				}),
				reaction_strip(notes.chips(), users),
			]),
		})
		TrustedHtml.join([article, PageKit.newline])
	}

}

## An edited message's body: a line naming the edit, `edit_reference`,
## linked, then its `markdown`, as written, folded away.
edited_body : { edit_reference : MessageAnchor, markdown : Str } -> TrustedHtml
edited_body = |{ edit_reference, markdown }|
	TrustedHtml.join([
		Html.element({
			name: P,
			attributes: [PageContract.class(EditedNote)],
			inner: TrustedHtml.join([
				Escape.text("Edited in "),
				Html.element({
					name: A,
					attributes: [
						PageContract.class(MessageReference),
						Href(anchor(edit_reference)),
					],
					inner: Escape.text(edit_reference.to_str()),
				}),
			]),
		}),
		Html.element({
			name: Details,
			attributes: [PageContract.class(EditedOriginal)],
			inner: TrustedHtml.join([
				Html.element({
					name: Summary,
					attributes: [],
					inner: Escape.text("original"),
				}),
				Html.element({
					name: Div,
					attributes: [PageContract.class(EditedMarkdown)],
					inner: Escape.text(markdown),
				}),
			]),
		}),
	])

## A message's reactions, an emoji a button, each naming its reactors'
## ids, joined by `-`, their names among `users` in its title, in the
## order they reacted, and how many they are; nothing when there are none.
## A reactor `users` doesn't hold is left out of the title, as an author
## it doesn't hold has no id named.
reaction_strip : List(Reactions.Chip), Users -> TrustedHtml
reaction_strip = |chips, users|
	if chips.is_empty() {
		TrustedHtml.join([])
	} else {
		Html.element({
			name: Div,
			attributes: [PageContract.class(ReactionStrip)],
			inner: TrustedHtml.join(
				chips.map(
					|chip|
						Html.element({
							name: Button,
							attributes: [
								PageContract.class(ReactionChip),
								PageContract.data_attribute(Reactors(reactors_token(chip))),
								NamesTitle(chip.reactors.keep_oks(|id| users.user(id)).map(Users.User.name)),
							],
							inner: TrustedHtml.join([
								Html.element({
									name: Span,
									attributes: [PageContract.class(ReactionEmoji)],
									inner: Escape.text(chip.emoji.to_str()),
								}),
								PageKit.space,
								Escape.text(chip.reactors.len().to_str()),
							]),
						}),
				),
			),
		})
	}

## A chip's reactors' ids, joined by `-`, as a token.
reactors_token : Reactions.Chip -> Html.Token
reactors_token = |chip| PageKit.token(Str.join_with(chip.reactors.map(UserId.to_str), "-"))

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
		attributes: [PageContract.class(Compose)],
		inner: TrustedHtml.join([
			Html.element({
				name: Form,
				attributes: [
					MethodPost,
					Action(PageKit.site_path(key.url_path(Page))),
					PageContract.data_attribute(Send(PageKit.site_path(key.url_path(Send)))),
					PageContract.data_attribute(Upload(PageKit.site_path(key.url_path(Upload)))),
					PageContract.data_attribute(ImageByteLimit(byte_limit)),
				],
				inner: TrustedHtml.join([
					Html.element({
						name: Textarea,
						attributes: [FieldName(PageKit.token(UrlEncodedForm.markdown_name))],
						inner: TrustedHtml.join([]),
					}),
					PageKit.newline,
					Html.element({
						name: Button,
						attributes: [],
						inner: Escape.text("Send"),
					}),
				]),
			}),
			PageKit.newline,
			Html.element({
				name: P,
				attributes: [PageContract.class(Help)],
				inner: Escape.text("Markdown supported · :emoji: autocompletes · paste or Upload an image · Ctrl/⌘-Enter to send"),
			}),
		]),
	})
}

## The top bar's title of the conversation `key`, on `viewer`'s page: a DM
## names the other human, then "on" and the topic ("Apoorva on ChitChat",
## where Gopher Chat said "Chat w/Apoorva: ChitChat"), and the viewer's own
## DM names the viewer, as Gopher Chat did; a channel's is Gopher Chat's
## "#general: roc-chat".
top_title : {
	key : ConversationKey,
	viewer : Users.User,
	users : Users,
} -> Str
top_title = |{ key, viewer, users }| {
	topic = key.topic().to_str()
	match place_of({ key, viewer, users }) {
		Channel(name) => "#${name.to_str()}: ${topic}"
		Person(person) => "${person.name().to_str()} on ${topic}"
	}
}

## Where the conversation `key` is, as `viewer` names it: its channel, or a
## DM's other human, or for the viewer's own DM, the viewer.
place_of : {
	key : ConversationKey,
	viewer : Users.User,
	users : Users,
} -> [Channel(ChannelName), Person(Users.User)]
place_of = |{ key, viewer, users }|
	match key.place().which() {
		Channel(name) => Channel(name)
		Dm(pair) =>
			match pair.members().drop_if(|id| id == viewer.id()) {
				[other] =>
					Person(
						users.user(other)
							?? crash "ConversationPage.place_of: a DM is between users the directory holds",
					)
				_ => Person(viewer)
			}
	}

## A user's id, which the scripts compare: a message's author's with the
## viewer's.
user_id : Users.User -> Html.Token
user_id = |user| PageKit.token(user.id().to_str())

## A message's anchor, as a token: `MessageAnchor.page_anchor`'s spelling,
## which an element's id and a link's `#` both write.
anchor : MessageAnchor -> Html.Token
anchor = |message_reference| PageKit.token(message_reference.page_anchor())

# ── tests
# A message's anchor as an id and as a link, at the first id and the next.
expect {
	second = Message.Id.first.next() ?? crash "ConversationPage's tests: the first id has a next"
	plans = Topic.from_str("plans") ?? crash "ConversationPage's tests: a topic"
	first_named = MessageAnchor.of({ topic: plans, id: Message.Id.first })
	second_named = MessageAnchor.of({ topic: plans, id: second })
	[
		(Id(anchor(first_named)), "<p id=\"msg-1\"></p>"),
		(Href(anchor(first_named)), "<p href=\"#msg-1\"></p>"),
		(Id(anchor(second_named)), "<p id=\"msg-2\"></p>"),
		(Href(anchor(second_named)), "<p href=\"#msg-2\"></p>"),
	].all(|(attribute, expected)| PageContract.empty_paragraph([attribute]) == expected.to_utf8())
}
