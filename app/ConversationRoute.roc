## This module moves data between the web interface and the file system.
## It doesn't do any heavy lifting itself. It mostly provides a clean
## boundary: `FileSystem` reads and writes the transcript, `Transcript`
## decodes and encodes it, and `Conversation` decides what may be added.
##
## A GET answers with a conversation's page. A POST takes a form whose
## field `markdown` holds a new message, adds the message to the
## conversation, and sends the browser back to the page (a 303).
import pf.Http
import Author
import Conversation
import ConversationKey
import DateTime
import FileSystem
import HttpAnswer
import Message
import Name
import Page
import SignedIn
import Transcript
import TranscriptRefusal
import UrlEncodedForm
import Users

ConversationRoute :: [].{

	## **GET**: the conversation's page; a 404 when it has no transcript.
	show! : ConversationKey => Http.Response
	show! = |key|
		match FileSystem.read_transcript!(key) {
			Ok(utf8) =>
				match Transcript.decode(key.topic(), utf8) {
					Ok(conversation) => HttpAnswer.page(200, Page.conversation(conversation, key))
					Err(why) => unreadable_transcript_response(why)
				}
			Err(Missing) => HttpAnswer.notice(404, { title: "Not found", said: "No such conversation: ${key.url_path()}" })
			Err(fault) => file_system_failure_response(fault)
		}

	## **POST**: the message in `body`'s field `markdown`, by `acting`, at
	## `now` (the host's clock, seconds since the epoch), appended to the
	## conversation; the first message of one with no transcript yet starts
	## it. Then a 303 to its page.
	post_sent_message! : {
		key : ConversationKey,
		acting : SignedIn,
		now : I64,
		body : List(U8),
	} => Http.Response
	post_sent_message! = |
		{
			key,
			acting,
			now,
			body,
		},
	|
		match unnumbered_message_from_post({
			acting,
			now,
			body,
		}) {
			Err(why) => post_refusal_response(why)
			Ok(unnumbered_message) =>
				match FileSystem.read_transcript!(key) {
					Ok(utf8) =>
						match Transcript.decode(key.topic(), utf8) {
							Ok(conversation) =>
								append_unnumbered_message!({
									key,
									conversation,
									file: File(utf8),
									unnumbered_message,
								})
							Err(why) => unreadable_transcript_response(why)
						}
					Err(Missing) =>
						append_unnumbered_message!({
							key,
							conversation: Conversation.empty(key.topic()),
							file: NoFile,
							unnumbered_message,
						})
					Err(fault) => file_system_failure_response(fault)
				}
		}
}

## **THE POST'S UNNUMBERED MESSAGE**: the markdown in `body`'s field
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

## `unnumbered_message` appended to `conversation`, its record appended to
## `file` (the transcript `conversation` was read from, or `NoFile`), and a
## 303 to the page; or why not.
append_unnumbered_message! : {
	key : ConversationKey,
	conversation : Conversation,
	file : [NoFile, File(Transcript.Utf8Transcript)],
	unnumbered_message : Message.Unnumbered(Author),
} => Http.Response
append_unnumbered_message! = |
	{
		key,
		conversation,
		file,
		unnumbered_message,
	},
|
	match conversation.append(unnumbered_message) {
		Ok(grown) =>
			match Transcript.message_record({
				conversation: grown.conversation,
				message: grown.message,
				file,
			}) {
				Ok(record) =>
					match FileSystem.append_message!(key, record) {
						Ok({}) => HttpAnswer.see_other(key.url_path())
						Err(fault) => file_system_failure_response(fault)
					}
				Err(FileFull) => conversation_refusal_response("The conversation's transcript holds as much as it can: ${(Transcript.most_bytes // 1024 // 1024).to_str()} MiB.")
			}
		Err(Backdated) => conversation_refusal_response("The message is dated before the conversation's latest.")
		Err(Full) => conversation_refusal_response("The conversation holds as many messages as it can.")
	}

## **A MESSAGE THE CONVERSATION REFUSES**, saying why: a 409.
conversation_refusal_response : Str -> Http.Response
conversation_refusal_response = |said| HttpAnswer.notice(409, { title: "Message refused", said })

## **A REFUSED MESSAGE, IN WORDS**: a 400, but a clock out of range, which
## is the server's (a 500).
post_refusal_response : [
	MissingField,
	RepeatedField,
	BadEscape,
	NotUtf8,
	Blank,
	ClockOutOfRange,
] -> Http.Response
post_refusal_response = |why| {
	said =
		match why {
			MissingField => "The form has no field `markdown`."
			RepeatedField => "The form has the field `markdown` more than once."
			BadEscape => "The form's `markdown` holds a % that starts no two hex digits."
			NotUtf8 => "The form's `markdown` is not UTF-8."
			Blank => "The message is blank."
			ClockOutOfRange => "The server's clock is out of range."
		}
	status = if (why == ClockOutOfRange) 500 else 400
	HttpAnswer.notice(status, { title: "Message refused", said })
}

## **A TRANSCRIPT FILE THAT WON'T DECODE**: the server's, a 500, saying
## why in `TranscriptRefusal`'s words.
unreadable_transcript_response : TranscriptRefusal.Why -> Http.Response
unreadable_transcript_response = |why| HttpAnswer.page(500, Page.refusal(TranscriptRefusal.words(why)))

## **THE FILE SYSTEM FAILED**: a 500, naming what the host answered (and
## the host's log says which file, and why).
file_system_failure_response : _ -> Http.Response
file_system_failure_response = |fault| {
	said =
		match fault {
			Missing => "Missing"
			NotUtf8 => "NotUtf8"
			PathRefused => "PathRefused"
			MissingDirectory => "MissingDirectory"
			Failed => "Failed"
		}
	HttpAnswer.notice(500, { title: "Failed", said: "The file system answered ${said}." })
}

# ── tests
## Steve, signed in, as a test assumes him.
steve : SignedIn
steve = {
	founded = Users.founded_by(Name.from_str("Steve") ?? crash "ConversationRoute's tests: a name")
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
expect post_refusal_response(MissingField).status == 400
expect post_refusal_response(Blank).status == 400
expect post_refusal_response(ClockOutOfRange).status == 500
