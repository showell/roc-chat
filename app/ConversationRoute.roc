## This module moves data between the web interface and the file system.
## It doesn't do any heavy lifting itself. It mostly provides a clean
## boundary: `FileSystem` reads and writes the transcript, `Transcript`
## decodes and encodes it, and `Conversation` decides what may be added.
##
## A GET answers with a conversation's page. A POST takes a form whose
## field `markdown` holds a new message, adds the message to the
## conversation, sends it to the conversation's open pages
## (`ConversationStream`), and sends the browser back to the page (a 303).
## The page's script posts the same form to the conversation's `/send`,
## and is answered with a 201 and the message's HTML, or with why not in
## plain words, so the page stays put. A GET of the conversation's stream
## answers with the stream.
##
## Only a message's POST starts a conversation. A GET of the page or of the
## stream of a conversation with no transcript is a 404, as in the Zig
## chat. Every route words its refusals through `refusal_notice`.
import pf.Http
import Author
import Conversation
import ConversationKey
import ConversationStream
import DateTime
import Directory
import FileSystem
import HttpAnswer
import Message
import Name
import Page
import SignedIn
import Transcript
import TranscriptRefusal
import TrustedHtml
import UnvalidatedString
import UrlEncodedForm
import Users

ConversationRoute :: [].{

	## A GET of the conversation `key`: its page for `acting`, each
	## message's author found among `users`.
	show! : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
	} => Http.Response
	show! = |
		{
			key,
			acting,
			users,
		},
	|
		match load_existing_conversation!(key) {
			Ok(conversation) =>
				HttpAnswer.page(
					200,
					Page.conversation({
						conversation,
						key,
						viewer: acting,
						users,
					}),
				)
			Err(why) => refusal_page(why)
		}

	## A GET of the conversation's stream, for `acting`: the messages after
	## the count the request has seen (`query` and `headers`, read by
	## `ConversationStream.seen_count`), then each one added. Each message's
	## author is found among `users`.
	open_stream! : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
		query : List(U8),
		headers : List(Http.Header),
	} => Http.Response
	open_stream! = |
		{
			key,
			acting,
			users,
			query,
			headers,
		},
	|
		match ConversationStream.seen_count({ query, headers }) {
			Err(why) => refusal_page(why)
			Ok(seen) =>
				match load_existing_conversation!(key) {
					Ok(conversation) =>
						ConversationStream.response({
							key,
							acting,
							users,
							conversation,
							seen,
						})
					Err(why) => refusal_page(why)
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
				notice = refusal_notice(why)
				HttpAnswer.text(notice.status, notice.words.said)
			}
		}

	## A message's POST: the conversation `key`, the user `acting`, the
	## users each message's author is found among, the host's clock `now`
	## (seconds since the epoch), and the form in `body`.
	Post : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
		now : I64,
		body : List(U8),
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
	file = FileSystem.read_transcript!(key) ? |fault| FileSystem(fault)
	conversation =
		match file {
			File(utf8) => Transcript.decode(key.topic(), utf8) ? |why| Unreadable(why)
			NoFile => Conversation.empty(key.topic())
		}
	Ok({ conversation, file })
}

## The conversation `key` names, for a reader: a conversation with no
## transcript is `NoSuchConversation`, since only a message's POST starts
## one.
load_existing_conversation! : ConversationKey => Try(
	Conversation,
	[
		NoSuchConversation(ConversationKey),
		Unreadable(TranscriptRefusal.Why),
		FileSystem(_),
	],
)
load_existing_conversation! = |key| {
	loaded = load_conversation!(key)?
	match loaded.file {
		File(_) => Ok(loaded.conversation)
		NoFile => Err(NoSuchConversation(key))
	}
}

## The message in `post`'s form, added to its conversation and to the
## transcript, then sent to the conversation's stream: the message's HTML,
## as the page and the stream write it, made once for both; or why not.
append_posted_message! : ConversationRoute.Post => Try(TrustedHtml, _)
append_posted_message! = |post| {
	unnumbered_message = unnumbered_message_from_post({
		acting: post.acting,
		now: post.now,
		body: post.body,
	})?
	loaded = load_conversation!(post.key)?
	grown = loaded.conversation.append(unnumbered_message)?
	record = Transcript.message_record({
		conversation: grown.conversation,
		message: grown.message,
		file: loaded.file,
	})?
	FileSystem.append_message!(post.key, record) ? |fault| FileSystem(fault)
	html = Page.message({
		conversation: grown.conversation,
		key: post.key,
		users: post.users,
		message: grown.message,
	})
	ConversationStream.publish!({
		key: post.key,
		id: grown.message.id(),
		html,
	})
	Ok(html)
}

## Every reason a route refuses a request, as `refusal_notice` takes it.
Refusal : [
	MissingField,
	RepeatedField,
	BadEscape,
	NotUtf8,
	Blank,
	ClockOutOfRange,
	NoCount,
	BadCount,
	NoSuchConversation(ConversationKey),
	Unreadable(TranscriptRefusal.Why),
	FileSystem(FileSystem.Fault),
	Backdated,
	Full,
	FileFull,
]

## A refusal in words: its status, a title for a page, and what is wrong.
## A fault in the request (the form or the stream's count) is a 400, a
## conversation with no transcript a 404, the conversation's refusal of a
## message a 409, and the server's own failure a 500.
refusal_notice : Refusal -> { status : U16, words : { title : Str, said : Str } }
refusal_notice = |why|
	match why {
		MissingField => form_fault("The form has no field `markdown`.")
		RepeatedField => form_fault("The form has the field `markdown` more than once.")
		BadEscape => form_fault("The form's `markdown` holds a % that starts no two hex digits.")
		NotUtf8 => form_fault("The form's `markdown` is not UTF-8.")
		Blank => form_fault("The message is blank.")
		ClockOutOfRange => { status: 500, words: { title: "Message refused", said: "The server's clock is out of range." } }
		NoCount => { status: 400, words: { title: "Bad stream", said: ConversationStream.words(NoCount) } }
		BadCount => { status: 400, words: { title: "Bad stream", said: ConversationStream.words(BadCount) } }
		NoSuchConversation(key) => { status: 404, words: { title: "Not found", said: "No such conversation: ${key.url_path(Page)}" } }
		Unreadable(fault) => { status: 500, words: { title: "Not a transcript", said: "Not a transcript: ${TranscriptRefusal.words(fault)}." } }
		FileSystem(fault) => { status: 500, words: { title: "Failed", said: FileSystem.fault_words(fault) } }
		Backdated => conversation_refusal("The message is dated before the conversation's latest.")
		Full => conversation_refusal("The conversation holds as many messages as it can.")
		FileFull => conversation_refusal("The conversation's transcript holds as much as it can: ${(Transcript.most_bytes // 1024 // 1024).to_str()} MiB.")
	}

## A refusal as a page, with its status.
refusal_page : Refusal -> Http.Response
refusal_page = |why| {
	notice = refusal_notice(why)
	HttpAnswer.page(notice.status, Page.notice(notice.words))
}

## A fault in the posted form, saying what: a 400.
form_fault : Str -> { status : U16, words : { title : Str, said : Str } }
form_fault = |said| { status: 400, words: { title: "Message refused", said } }

## A message the conversation refuses, saying why: a 409.
conversation_refusal : Str -> { status : U16, words : { title : Str, said : Str } }
conversation_refusal = |said| { status: 409, words: { title: "Message refused", said } }

## The unnumbered message a POST holds: the markdown in `body`'s field
## `markdown`, by the acting user, at `now`; or why it is refused.
unnumbered_message_from_post : {
	acting : SignedIn,
	now : I64,
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
unnumbered_message_from_post = |
	{
		acting,
		now,
		body,
	},
| {
	unchecked = UrlEncodedForm.markdown_field(body)?
	markdown = unchecked.markdown()?
	time = DateTime.from_seconds_since_epoch(now) ? |OutOfRange| ClockOutOfRange
	Ok({ payload: { author: acting.user().author(), markdown }, time })
}

# ── tests
## Steve, signed in, as a test assumes him.
steve : SignedIn
steve = {
	founded = Users.with_founder(Name.from_str("Steve") ?? crash "ConversationRoute's tests: a name")
	SignedIn.dangerously_assume(founded.to_list().first() ?? crash "ConversationRoute's tests: Steve is the first user")
}

## An unnumbered message's parts, as a test reads them.
UnnumberedMessageText : {
	author : Str,
	time : Str,
	markdown : Str,
}

## The unnumbered message posted as `body` at `now`, as a test reads it.
unnumbered_message_at : I64, Str -> Try(UnnumberedMessageText, _)
unnumbered_message_at = |now, body|
	unnumbered_message_from_post({
		acting: steve,
		now,
		body: body.to_utf8(),
	}).map_ok(
		|a| {
			author: a.payload.author.to_str(),
			time: a.time.to_str(),
			markdown: a.payload.markdown,
		},
	)

## The unnumbered message posted as `body` at 2026-11-02T19:11:32Z.
unnumbered_message_at_the_sample_time : Str -> Try(UnnumberedMessageText, _)
unnumbered_message_at_the_sample_time = |body| unnumbered_message_at(1793646692, body)

## `plans` in Steve's own DM.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8()) ?? crash "ConversationRoute's tests: a path is UTF-8",
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
expect unnumbered_message_at(-1, "markdown=x").map_ok(|_| {}) == Err(ClockOutOfRange)
# Each refusal: the request's faults a 400, no transcript a 404, the
# conversation's refusals a 409, the server's a 500, each in its own words.
expect
	[
		(MissingField, "The form has no field `markdown`."),
		(RepeatedField, "The form has the field `markdown` more than once."),
		(BadEscape, "The form's `markdown` holds a % that starts no two hex digits."),
		(NotUtf8, "The form's `markdown` is not UTF-8."),
		(Blank, "The message is blank."),
	].all(|(why, said)| refusal_notice(why) == { status: 400, words: { title: "Message refused", said } })
expect
	[
		(NoCount, "The stream names no count of the messages seen: `?after=<count>`, or a Last-Event-ID."),
		(BadCount, "The stream's count of the messages seen is not one: the digits of 0 to 65535, with no leading 0."),
	].all(|(why, said)| refusal_notice(why) == { status: 400, words: { title: "Bad stream", said } })
expect refusal_notice(NoSuchConversation(plans_key)) == { status: 404, words: { title: "Not found", said: "No such conversation: /chat/dm/1_1/plans" } }
expect
	[
		(Backdated, "The message is dated before the conversation's latest."),
		(Full, "The conversation holds as many messages as it can."),
		(FileFull, "The conversation's transcript holds as much as it can: 16 MiB."),
	].all(|(why, said)| refusal_notice(why) == { status: 409, words: { title: "Message refused", said } })
expect refusal_notice(ClockOutOfRange) == { status: 500, words: { title: "Message refused", said: "The server's clock is out of range." } }
expect refusal_notice(Unreadable(TranscriptNotUtf8)) == { status: 500, words: { title: "Not a transcript", said: "Not a transcript: it is not UTF-8." } }
expect refusal_notice(FileSystem(PathRefused)) == { status: 500, words: { title: "Failed", said: "The file system answered PathRefused." } }
# A refusal's page: its status, and its notice's title and words.
expect {
	answered = refusal_page(NoSuchConversation(plans_key))
	answered.status == 404 and answered.body == Page.notice({ title: "Not found", said: "No such conversation: /chat/dm/1_1/plans" }).to_utf8()
}
