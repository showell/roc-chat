## **A CONVERSATION'S TWO ROUTES**: its page (GET), and a message added to
## it (POST, a form whose field `markdown` is the message). Each reads the
## transcript through `FileSystem`, decodes it with `Transcript`, and
## answers; the POST appends one record and sends the browser back to the
## page (303).
##
## **TIMES NEVER GO BACKWARDS**: a POST's time is the host's clock, and a
## message dated before the conversation's latest is refused (`Backdated`,
## a 409), as `Conversation.append` refuses it.
##
## **A TRANSCRIPT NEVER OUTGROWS ITS READ**: a message whose record would
## grow the file past `Transcript.most_bytes` is refused (`FileFull`, a
## 409), so no conversation is ever too big for the host to read again.
##
## **EVERY FAILURE IS LOUD**: a transcript that won't decode, or a file the
## host could not read or write, is a 500 naming what went wrong.
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
					Err(why) => unreadable(why)
				}
			Err(Missing) => HttpAnswer.notice(404, { title: "Not found", said: "No such conversation: ${key.url_path()}" })
			Err(fault) => failed(fault)
		}

	## **POST**: the message in `body`'s field `markdown`, by `acting`, at
	## `now` (the host's clock, seconds since the epoch), appended to the
	## conversation; the first message of one with no transcript yet starts
	## it. Then a 303 to its page.
	append! : {
		key : ConversationKey,
		acting : SignedIn,
		now : I64,
		body : List(U8),
	} => Http.Response
	append! = |
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
			Err(why) => refused(why)
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
							Err(why) => unreadable(why)
						}
					Err(Missing) =>
						append_unnumbered_message!({
							key,
							conversation: Conversation.empty(key.topic()),
							file: NoFile,
							unnumbered_message,
						})
					Err(fault) => failed(fault)
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
						Err(fault) => failed(fault)
					}
				Err(FileFull) => refused_by_conversation("The conversation's transcript holds as much as it can: ${(Transcript.most_bytes // 1024 // 1024).to_str()} MiB.")
			}
		Err(Backdated) => refused_by_conversation("The message is dated before the conversation's latest.")
		Err(Full) => refused_by_conversation("The conversation holds as many messages as it can.")
	}

## **A MESSAGE THE CONVERSATION REFUSES**, saying why: a 409.
refused_by_conversation : Str -> Http.Response
refused_by_conversation = |said| HttpAnswer.notice(409, { title: "Message refused", said })

## **A REFUSED MESSAGE, IN WORDS**: a 400, but a clock out of range, which
## is the server's (a 500).
refused : [
	MissingField,
	RepeatedField,
	BadEscape,
	NotUtf8,
	Blank,
	ClockOutOfRange,
] -> Http.Response
refused = |why| {
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
unreadable : TranscriptRefusal.Why -> Http.Response
unreadable = |why| HttpAnswer.page(500, Page.refusal(TranscriptRefusal.words(why)))

## **THE FILE SYSTEM FAILED**: a 500, naming what the host answered (and
## the host's log says which file, and why).
failed : _ -> Http.Response
failed = |fault| {
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
expect refused(MissingField).status == 400
expect refused(Blank).status == 400
expect refused(ClockOutOfRange).status == 500
