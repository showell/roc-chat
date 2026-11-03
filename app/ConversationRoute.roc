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
import pf.Http
import Author
import Conversation
import ConversationKey
import ConversationStream
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

	## **GET**: the conversation's page for `acting`, each message's author
	## found among `users`; a 404 when it has no transcript.
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
		match FileSystem.read_transcript!(key) {
			Ok(utf8) =>
				match Transcript.decode(key.topic(), utf8) {
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
					Err(why) => unreadable_transcript_response(why)
				}
			Err(Missing) => HttpAnswer.notice(404, { title: "Not found", said: "No such conversation: ${key.url_path()}" })
			Err(fault) => file_system_failure_response(fault)
		}

	## **GET THE STREAM**: the conversation's stream for `acting`, after
	## the count of messages the request has seen (`query` and `headers`,
	## `ConversationStream.seen_count`); one with no transcript yet is
	## empty until its first message. Each message's author is found among
	## `users`.
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
			Err(why) => HttpAnswer.notice(400, { title: "Bad stream", said: ConversationStream.words(why) })
			Ok(seen) =>
				match FileSystem.read_transcript!(key) {
					Ok(utf8) =>
						match Transcript.decode(key.topic(), utf8) {
							Ok(conversation) =>
								ConversationStream.response({
									key,
									acting,
									users,
									conversation,
									seen,
								})
							Err(why) => unreadable_transcript_response(why)
						}
					Err(Missing) =>
						ConversationStream.response({
							key,
							acting,
							users,
							conversation: Conversation.empty(key.topic()),
							seen,
						})
					Err(fault) => file_system_failure_response(fault)
				}
		}

	## **POST**: the message in `body`'s field `markdown`, by `acting`, at
	## `now` (the host's clock, seconds since the epoch), appended to the
	## conversation; the first message of one with no transcript yet starts
	## it. Then a 303 to its page. The message goes to the conversation's
	## stream with its author found among `users`.
	post_sent_message! : ConversationRoute.Post => Http.Response
	post_sent_message! = |post|
		match append_posted_message!(post) {
			Ok(_) => HttpAnswer.see_other(post.key.url_path())
			Err(Unreadable(why)) => unreadable_transcript_response(why)
			Err(why) => {
				refused = refusal_notice(why)
				HttpAnswer.notice(refused.status, refused.words)
			}
		}

	## **POST FROM THE PAGE'S SCRIPT**: the message appended as
	## `post_sent_message!` appends it, then a 201 with the message's HTML,
	## as the stream writes it. A refusal is its status and its words in
	## plain text, which the compose box shows as they are.
	post_message_without_reload! : ConversationRoute.Post => Http.Response
	post_message_without_reload! = |post|
		match append_posted_message!(post) {
			Ok(sent) =>
				HttpAnswer.page(
					201,
					Page.message({
						conversation: sent.conversation,
						key: post.key,
						users: post.users,
						message: sent.message,
					}),
				)
			Err(why) => {
				refused = refusal_notice(why)
				HttpAnswer.text(refused.status, refused.words.said)
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

## **THE POSTED MESSAGE, APPENDED**: the message in `post`'s form, added to
## its conversation and to the transcript, then sent to the conversation's
## stream; the conversation it grew and the message; or why not.
append_posted_message! : ConversationRoute.Post => Try({ conversation : Conversation, message : Message }, _)
append_posted_message! = |post| {
	unnumbered_message = unnumbered_message_from_post({
		acting: post.acting,
		now: post.now,
		body: post.body,
	})?
	file =
		match FileSystem.read_transcript!(post.key) {
			Ok(utf8) => Ok(File(utf8))
			Err(Missing) => Ok(NoFile)
			Err(fault) => Err(FileSystem(fault))
		}?
	conversation =
		match file {
			File(utf8) => Transcript.decode(post.key.topic(), utf8) ? |why| Unreadable(why)
			NoFile => Conversation.empty(post.key.topic())
		}
	grown = conversation.append(unnumbered_message)?
	record = Transcript.message_record({
		conversation: grown.conversation,
		message: grown.message,
		file,
	})?
	FileSystem.append_message!(post.key, record) ? |fault| FileSystem(fault)
	ConversationStream.publish!({
		key: post.key,
		users: post.users,
		conversation: grown.conversation,
		message: grown.message,
	})
	Ok(grown)
}

## Every reason `append_posted_message!` refuses a message, as
## `refusal_notice` takes it.
Refusal : [
	MissingField,
	RepeatedField,
	BadEscape,
	NotUtf8,
	Blank,
	ClockOutOfRange,
	Unreadable(TranscriptRefusal.Why),
	FileSystem(
		[
			Missing,
			NotUtf8,
			PathRefused,
			MissingDirectory,
			Failed,
		],
	),
	Backdated,
	Full,
	FileFull,
]

## **A REFUSED MESSAGE, IN WORDS**: its status, a title for a page, and
## what is wrong. The form's faults are a 400, the conversation's refusals
## a 409, and the server's own a 500.
refusal_notice : Refusal -> { status : U16, words : { title : Str, said : Str } }
refusal_notice = |why|
	match why {
		MissingField => form_fault("The form has no field `markdown`.")
		RepeatedField => form_fault("The form has the field `markdown` more than once.")
		BadEscape => form_fault("The form's `markdown` holds a % that starts no two hex digits.")
		NotUtf8 => form_fault("The form's `markdown` is not UTF-8.")
		Blank => form_fault("The message is blank.")
		ClockOutOfRange => { status: 500, words: { title: "Message refused", said: "The server's clock is out of range." } }
		Unreadable(fault) => { status: 500, words: { title: "Not a transcript", said: "Not a transcript: ${TranscriptRefusal.words(fault)}." } }
		FileSystem(fault) => { status: 500, words: { title: "Failed", said: "The file system answered ${file_system_fault_name(fault)}." } }
		Backdated => conversation_refusal("The message is dated before the conversation's latest.")
		Full => conversation_refusal("The conversation holds as many messages as it can.")
		FileFull => conversation_refusal("The conversation's transcript holds as much as it can: ${(Transcript.most_bytes // 1024 // 1024).to_str()} MiB.")
	}

## A fault in the posted form, saying what: a 400.
form_fault : Str -> { status : U16, words : { title : Str, said : Str } }
form_fault = |said| { status: 400, words: { title: "Message refused", said } }

## A message the conversation refuses, saying why: a 409.
conversation_refusal : Str -> { status : U16, words : { title : Str, said : Str } }
conversation_refusal = |said| { status: 409, words: { title: "Message refused", said } }

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

## **A TRANSCRIPT FILE THAT WON'T DECODE**: the server's, a 500, saying
## why in `TranscriptRefusal`'s words.
unreadable_transcript_response : TranscriptRefusal.Why -> Http.Response
unreadable_transcript_response = |why| HttpAnswer.page(500, Page.refusal(TranscriptRefusal.words(why)))

## **THE FILE SYSTEM FAILED**: a 500, naming what the host answered (and
## the host's log says which file, and why).
file_system_failure_response : _ -> Http.Response
file_system_failure_response = |fault| HttpAnswer.notice(500, { title: "Failed", said: "The file system answered ${file_system_fault_name(fault)}." })

## A fault the host's file system answered, by its tag's name.
file_system_fault_name : [
	Missing,
	NotUtf8,
	PathRefused,
	MissingDirectory,
	Failed,
] -> Str
file_system_fault_name = |fault|
	match fault {
		Missing => "Missing"
		NotUtf8 => "NotUtf8"
		PathRefused => "PathRefused"
		MissingDirectory => "MissingDirectory"
		Failed => "Failed"
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
# Each refusal: the form's faults a 400, the conversation's a 409, the
# server's a 500, each in its own words.
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
		(Backdated, "The message is dated before the conversation's latest."),
		(Full, "The conversation holds as many messages as it can."),
		(FileFull, "The conversation's transcript holds as much as it can: 16 MiB."),
	].all(|(why, said)| refusal_notice(why) == { status: 409, words: { title: "Message refused", said } })
expect refusal_notice(ClockOutOfRange) == { status: 500, words: { title: "Message refused", said: "The server's clock is out of range." } }
expect refusal_notice(Unreadable(TranscriptNotUtf8)) == { status: 500, words: { title: "Not a transcript", said: "Not a transcript: it is not UTF-8." } }
expect
	[
		(Missing, "Missing"),
		(NotUtf8, "NotUtf8"),
		(PathRefused, "PathRefused"),
		(MissingDirectory, "MissingDirectory"),
		(Failed, "Failed"),
	].all(|(fault, name)| refusal_notice(FileSystem(fault)) == { status: 500, words: { title: "Failed", said: "The file system answered ${name}." } })
