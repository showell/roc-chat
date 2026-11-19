## This module moves data between the web interface and the file system.
## It doesn't do any heavy lifting itself. It mostly provides a clean
## boundary: `TranscriptFiles` reads and writes the transcript, `Transcript`
## decodes and encodes it, and `Conversation` decides what may be added.
##
## A GET answers with a conversation's page, which for a human holds the
## sidebar of the places Browse lists for them, each with its topics
## (`BrowseRoute.load_place_topics!`), and records the conversation as the
## last they opened (`ResumeRoute`). A POST takes a form whose
## field `markdown` holds a new message, adds the message to the
## conversation, sends it to the conversation's open pages
## (`ConversationStream`), and sends the browser back to the page (a 303).
## The page's script posts the same form to the conversation's `/send`,
## and is answered with a 201 and the message's HTML, or with why not in
## plain words, so the page stays put. A GET of the conversation's stream
## answers with the stream.
##
## A message that is an edit (`Edit`) is refused unless it edits one of its
## author's own messages. Once it is appended, the stream sends the message
## it edits again, drawn as edited, so every open page shows the edit.
## Each message is drawn with its notes (`MessageNotes`): its edit and the
## reactions kept beside the transcript (`Reactions`).
##
## Only a message's POST starts a conversation. A conversation with no
## transcript has a page and a stream, both empty, so a reader can write its
## first message there, and its `/raw` is a 404. `/raw?message=<n>` is one
## message's markdown, which the page's script edits from. Every route
## words its refusals through `ConversationRefusal`.
import pf.Http
import AgentStream
import Author
import Browse
import BrowseRoute
import Clock
import Conversation
import ConversationKey
import ConversationPage
import ConversationRefusal
import ConversationStream
import DateTime
import Directory
import Edit
import HttpAnswer
import Message
import MessageNotes
import Name
import PageKit
import Presence
import PresenceNotices
import Reactions
import ResumeRoute
import SignedIn
import Timestamp
import Transcript
import TranscriptFiles
import TranscriptRefusal
import TrustedHtml
import UnvalidatedString
import UrlEncodedForm
import UserId
import Users

ConversationRoute :: [].{

	## A GET of the conversation `key`: its page for `acting`, each
	## message's author found among `directory`'s users, recorded as the
	## last conversation `acting` opened. A conversation with no transcript
	## shows no messages.
	show! : {
		key : ConversationKey,
		acting : SignedIn,
		directory : Directory,
	} => Http.Response
	show! = |{ key, acting, directory }|
		match load_page!({ key, acting, directory }) {
			Ok(page) => HttpAnswer.page(200, page)
			Err(why) => refusal_page(why)
		}

	## A GET of the conversation's `/raw`: its transcript file's bytes,
	## exactly as kept, as plain UTF-8 text; or, for `?message=<n>`, that
	## message's markdown, exactly as written. A conversation with no
	## transcript, or no such message, is a 404.
	serve_raw! : { key : ConversationKey, query : List(U8) } => Http.Response
	serve_raw! = |{ key, query }|
		match TranscriptFiles.read_transcript!(key) {
			Ok(File(utf8)) if query.is_empty() => HttpAnswer.plain_text_file(utf8.to_plain_text())
			Ok(File(utf8)) =>
				match (message_asked(query), Transcript.decode(key.topic(), utf8)) {
					(Err(NotAMessageId), _) => refusal_page(NotAMessageId)
					(_, Err(why)) => refusal_page(Unreadable(why))
					(Ok(id), Ok(conversation)) =>
						match conversation.messages().get(id.to_u64() - 1) {
							Ok(message) => HttpAnswer.plain_text_file(message.markdown().to_utf8())
							Err(OutOfBounds) => HttpAnswer.page(404, PageKit.not_found)
						}
				}
			Ok(NoFile) => refusal_page(NoSuchConversation(key))
			Err(fault) => refusal_page(FileSystem(fault))
		}

	## A GET of the conversation's stream, for `acting`: the messages after
	## the count the request has seen (`query` and `headers`, read by
	## `ConversationStream.request_seen_count`), then each one added. Each message's
	## author is found among `users`.
	open_stream! : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
		query : List(U8),
		headers : List(Http.Header),
	} => Http.Response
	open_stream! = |{ key, acting, users, query, headers }|
		match ConversationStream.request_seen_count({ query, headers }) {
			Err(why) => refusal_page(why)
			Ok(seen_count) =>
				match (load_conversation!(key), TranscriptFiles.read_reactions!(key)) {
					(Ok({ conversation, file: _ }), Ok(reactions)) =>
						ConversationStream.response({
							key,
							viewer_key: Presence.viewer_stream_key(acting.user().id()),
							acting,
							users,
							conversation,
							reactions,
							seen_count,
						})
					(Err(why), _) => refusal_page(why)
					(_, Err(fault)) => refusal_page(FileSystem(fault))
				}
		}

	## A POST of the message in `body`'s field `markdown`, by `acting`, at
	## `now` (the host's clock, seconds since the epoch): the message is
	## appended to the conversation, and the first message of a conversation
	## with no transcript yet starts it. Then a 303 to its page. The message
	## goes to the conversation's stream with its author found among
	## `users`.
	post_sent_message! : ConversationRoute.Post => Http.Response
	post_sent_message! = |post|
		match append_posted_message!(post) {
			Ok(_) => HttpAnswer.see_other(post.key.url_path(Page))
			Err(why) => refusal_page(why)
		}

	## A POST from the page's script: the message appended as
	## `post_sent_message!` appends it, then a 201 with the message's HTML,
	## as the stream writes it. A refusal is its status and its words in
	## plain text, which the compose box shows as they are.
	post_message_without_reload! : ConversationRoute.Post => Http.Response
	post_message_without_reload! = |post|
		match append_posted_message!(post) {
			Ok(html) => HttpAnswer.page(201, html)
			Err(why) => {
				notice = ConversationRefusal.notice(why)
				HttpAnswer.text(notice.status, notice.words.text)
			}
		}

	## A message's POST: the conversation `key`, the user `acting`, the
	## users each message's author is found among, the host's clock `now`
	## (seconds since the epoch), the form in `body`, and the agents who
	## hear each message on their own streams (`AgentStream`).
	Post : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
		now : Timestamp,
		body : List(U8),
		agents : List(UserId),
	}
}

## The conversation `key` names, as its transcript holds it, and the
## transcript file it was read from. A conversation with no transcript yet
## is empty, and its file is `NoFile`.
load_conversation! : ConversationKey => Try(
	{ conversation : Conversation, file : [NoFile, File(Transcript.Utf8Transcript)] },
	[Unreadable(TranscriptRefusal.Why), FileSystem(_)],
)
load_conversation! = |key| {
	file = TranscriptFiles.read_transcript!(key) ? |fault| FileSystem(fault)
	conversation =
		match file {
			File(utf8) => Transcript.decode(key.topic(), utf8) ? |why| Unreadable(why)
			NoFile => Conversation.empty(key.topic())
		}
	Ok({ conversation, file })
}

## The page of the conversation `key` for `acting`, with a human's sidebar,
## once the conversation is recorded as the last they opened.
load_page! : {
	key : ConversationKey,
	acting : SignedIn,
	directory : Directory,
} => Try(TrustedHtml, [Unreadable(TranscriptRefusal.Why), FileSystem(_)])
load_page! = |{ key, acting, directory }| {
	loaded = load_conversation!(key)?
	reactions = TranscriptFiles.read_reactions!(key) ? |fault| FileSystem(fault)
	sidebar =
		match Browse.places_for({ acting, directory }) {
			Err(ByApiKey) => NoSidebar
			Err(Agent(_)) => NoSidebar
			Ok(listed) => {
				places = BrowseRoute.load_place_topics!(listed) ? |fault| FileSystem(fault)
				humans = directory.users().to_list().keep_oks(|user| user.as_human())
				online_humans = PresenceNotices.load_online_humans!({
					humans: humans.map(|human| human.id()),
					now: Clock.read_clock!({}),
				})
				Sidebar({ places, online_humans })
			}
		}
	ResumeRoute.record_opened!({ key, acting })?
	Ok(
		ConversationPage.conversation({
			conversation: loaded.conversation,
			reactions,
			key,
			viewer: acting,
			users: directory.users(),
			sidebar,
		}),
	)
}

## The message in `post`'s form, added to its conversation and to the
## transcript, then sent to the conversation's stream: the message's HTML,
## as the page and the stream write it, made once for both; or why not. An
## edit sends the message it edits again, drawn as edited.
append_posted_message! : ConversationRoute.Post => Try(TrustedHtml, _)
append_posted_message! = |post| {
	unnumbered_message = unnumbered_message_from_post({
		acting: post.acting,
		now: post.now,
		body: post.body,
	})?
	loaded = load_conversation!(post.key)?
	edit = Edit.judge({
		conversation: loaded.conversation,
		author: unnumbered_message.payload.author,
		markdown: unnumbered_message.payload.markdown,
	})?
	reactions =
		match edit {
			EditOf(_) => TranscriptFiles.read_reactions!(post.key) ? |fault| FileSystem(fault)
			NotAnEdit => Reactions.empty
		}
	grown = loaded.conversation.append(unnumbered_message)?
	record = Transcript.message_record({ grown, file: loaded.file })?
	TranscriptFiles.append_message!(post.key, record) ? |fault| FileSystem(fault)
	html = ConversationPage.message({
		conversation: grown.conversation,
		key: post.key,
		users: post.users,
		message: grown.message,
		notes: MessageNotes.fresh,
	})
	ConversationStream.publish!({ key: post.key, id: grown.message.id(), html })
	match edit {
		EditOf(id) =>
			ConversationStream.publish_again!({
				key: post.key,
				conversation: grown.conversation,
				reactions,
				users: post.users,
				id,
			})
		NotAnEdit => {}
	}
	AgentStream.publish!({
		key: post.key,
		message: grown.message,
		agents: post.agents,
	})
	Ok(html)
}

## A refusal as a page, with its status.
refusal_page : ConversationRefusal.Cause -> Http.Response
refusal_page = |why| {
	notice = ConversationRefusal.notice(why)
	HttpAnswer.page(notice.status, PageKit.notice(notice.words))
}

## The message a `/raw` query names, `message=<n>`, or `NotAMessageId`.
message_asked : List(U8) -> Try(Message.Id, [NotAMessageId])
message_asked = |query|
	if query.starts_with("message=".to_utf8()) {
		Message.Id.from_digits(query.drop_first(8))
	} else {
		Err(NotAMessageId)
	}

## The unnumbered message a POST holds: the markdown in `body`'s field
## `markdown`, by the acting user, at `now`; or why it is refused.
unnumbered_message_from_post : {
	acting : SignedIn,
	now : Timestamp,
	body : List(U8),
} -> Try(
	Message.Unnumbered(Author),
	[
		MissingField,
		RepeatedField,
		BadEscape,
		NotUtf8,
		Blank,
		ClockOutOfRange,
	],
)
unnumbered_message_from_post = |{ acting, now, body }| {
	markdown_text = UrlEncodedForm.markdown_field(body)?
	markdown = markdown_text.markdown()?
	time = DateTime.from_timestamp(now) ? |OutOfRange| ClockOutOfRange
	Ok({ payload: { author: acting.user().author(), markdown }, time })
}

# ── tests
## Steve, signed in, as a test assumes him.
steve : SignedIn
steve = {
	founded =
		Users.with_founder(Name.from_str("Steve") ?? crash "ConversationRoute's tests: a name")
	SignedIn.dangerously_assume(founded.to_list().first() ?? crash "ConversationRoute's tests: Steve is the first user")
}

## An unnumbered message's parts, as a test reads them.
UnnumberedMessageText : {
	author : Str,
	time : Str,
	markdown : Str,
}

## The unnumbered message posted as `body` at `now`, as a test reads it.
unnumbered_message_at : Timestamp, Str -> Try(UnnumberedMessageText, _)
unnumbered_message_at = |now, body|
	unnumbered_message_from_post({ acting: steve, now, body: body.to_utf8() }).map_ok(
		|unnumbered| {
			author: unnumbered.payload.author.to_str(),
			time: unnumbered.time.to_str(),
			markdown: unnumbered.payload.markdown,
		},
	)

## The unnumbered message posted as `body` at 2026-11-02T19:11:32Z.
unnumbered_message_at_the_sample_time : Str -> Try(UnnumberedMessageText, _)
unnumbered_message_at_the_sample_time = |body| unnumbered_message_at(
	Timestamp.at_second(1793646692),
	body,
)

## `plans` in Steve's own DM.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
		?? crash "ConversationRoute's tests: a path is UTF-8",
	directory: Directory.with_founder(Name.from_str("Steve") ?? crash "ConversationRoute's tests: a name"),
}).map_ok(|found| found.key) ?? crash "ConversationRoute's tests: Steve's own DM is a place"

expect
	unnumbered_message_at_the_sample_time("markdown=Hi+there%0D%0Aall")
		== Ok({
			author: "Steve",
			time: "2026-11-02T19:11:32Z",
			markdown: "Hi there\nall",
		})
expect unnumbered_message_at_the_sample_time("") == Err(MissingField)
expect unnumbered_message_at_the_sample_time("markdown=a&markdown=b") == Err(RepeatedField)
expect unnumbered_message_at_the_sample_time("markdown=%G0") == Err(BadEscape)
expect unnumbered_message_at_the_sample_time("markdown=%FF") == Err(NotUtf8)
expect unnumbered_message_at_the_sample_time("markdown=+") == Err(Blank)
expect unnumbered_message_at(
	Timestamp.at_second(-1),
	"markdown=x",
).map_ok(|_| {}) == Err(ClockOutOfRange)
# The clock at its first second, the edge of its range: a message then.
expect
	unnumbered_message_at(Timestamp.at_second(0), "markdown=x")
		== Ok({
			author: "Steve",
			time: "1970-01-01T00:00:00Z",
			markdown: "x",
		})
# The message a `/raw` query names, and every other query refused.
expect message_asked("message=3".to_utf8()).map_ok(Message.Id.to_str) == Ok("3")
expect
	["", "message=", "message=0", "message=3&x=1", "msg=3", "message=65536"].all(
		|query| message_asked(query.to_utf8()) == Err(NotAMessageId),
	)
# A refusal's page: its notice's status passed through, and its title and
# words; for each kind of status.
expect
	[
		NoSuchConversation(plans_key),
		Blank,
		Backdated,
		FileSystem(Failed),
	].all(
		|why| {
			refusal_response = refusal_page(why)
			notice = ConversationRefusal.notice(why)
			refusal_response.status
				== notice.status and refusal_response.body == PageKit.notice(notice.words).to_utf8()
		},
	)
expect refusal_page(NoSuchConversation(plans_key)).status == 404
expect refusal_page(Blank).status == 400
expect refusal_page(Backdated).status == 409
expect refusal_page(FileSystem(Failed)).status == 500
expect refusal_page(NoSuchConversation(plans_key)).body == PageKit.notice({
	title: "Not found",
	text: "No such conversation: /chat/dm/1_1/plans",
}).to_utf8()
