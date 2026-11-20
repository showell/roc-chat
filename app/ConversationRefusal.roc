## Every reason a conversation's routes refuse a request (`ConversationRoute`,
## `ReactionRoute`), and each one in words: its status, a title for a page,
## and what is wrong. A fault in the request (a form, a stream's count, a
## reaction's fields) is a 400, a conversation with no transcript a 404, the
## conversation's refusal of a message, an edit or a reaction a 409, a
## message past its author's rate (`MessageRate`) a 429, and the server's
## own failure a 500.
import ConversationKey
import ConversationStream
import Directory
import FileFacts
import MessageRate
import Name
import Transcript
import TranscriptRefusal
import UnvalidatedString
import UrlEncodedForm

ConversationRefusal :: [].{

	## Every reason a conversation's route refuses a request, as `notice`
	## takes it.
	Cause : [
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
		UnreadableLatest(ConversationKey),
		FileSystem(FileFacts.Fault),
		Backdated,
		Full,
		FileFull,
		EditOfNoSuchMessage,
		EditOfAnotherAuthorsMessage,
		ReactionField({ fault : [MissingField, RepeatedField, BadEscape, NotUtf8], name : Str }),
		NotAMessageId,
		NotAnEmoji,
		NotOnOrOff,
		NoSuchMessage,
		TooManyReactions,
		TooManyMessages,
	]

	## A refusal in words: its status, a title for a page, and what is wrong.
	notice : ConversationRefusal.Cause -> { status : U16, words : { title : Str, text : Str } }
	notice = |why|
		match why {
			MissingField => form_fault("The form has no field `markdown`.")
			RepeatedField => form_fault("The form has the field `markdown` more than once.")
			BadEscape => form_fault("The form's `markdown` holds a % that starts no two hex digits.")
			NotUtf8 => form_fault("The form's `markdown` is not UTF-8.")
			Blank => form_fault("The message is blank.")
			ClockOutOfRange => {
				status: 500,
				words: { title: "Message refused", text: "The server's clock is out of range." },
			}
			NoCount => {
				status: 400,
				words: {
					title: "Bad stream",
					text: ConversationStream.count_refusal_words(NoCount),
				},
			}
			BadCount => {
				status: 400,
				words: {
					title: "Bad stream",
					text: ConversationStream.count_refusal_words(BadCount),
				},
			}
			NoSuchConversation(key) => {
				status: 404,
				words: { title: "Not found", text: "No such conversation: ${key.url_path(Page)}" },
			}
			Unreadable(fault) => {
				status: 500,
				words: {
					title: "Not a transcript",
					text: "Not a transcript: ${TranscriptRefusal.words(fault)}.",
				},
			}
			UnreadableLatest(key) => {
				status: 500,
				words: {
					title: "Failed",
					text: "The last message of ${key.url_path(Page)} is not one this chat writes.",
				},
			}
			FileSystem(fault) => {
				status: 500,
				words: { title: "Failed", text: FileFacts.fault_words(fault) },
			}
			Backdated => conversation_refusal("The message is dated before the conversation's latest.")
			Full => conversation_refusal("The conversation holds as many messages as it can.")
			FileFull =>
				conversation_refusal("The conversation's transcript holds as much as it can: ${(Transcript.most_bytes // 1024 // 1024).to_str()} MiB.")
			EditOfNoSuchMessage => conversation_refusal("The edit names a message this conversation doesn't hold.")
			EditOfAnotherAuthorsMessage => conversation_refusal("Only a message's author may edit it.")
			ReactionField(field) => reaction_fault(UrlEncodedForm.fault_words(field))
			NotAMessageId => reaction_fault("The form's `msg` is no message's number.")
			NotAnEmoji => reaction_fault("The form's `emoji` is no emoji.")
			NotOnOrOff => reaction_fault("The form's `on` is neither 1 nor 0.")
			NoSuchMessage => {
				status: 409,
				words: {
					title: "Reaction refused",
					text: "The conversation holds no such message.",
				},
			}
			TooManyMessages => {
				status: 429,
				words: { title: "Message refused", text: MessageRate.too_many_words },
			}
			TooManyReactions => {
				status: 409,
				words: {
					title: "Reaction refused",
					text: "The conversation holds as many reactions as it can.",
				},
			}
		}
}

## A fault in the posted form, saying what: a 400.
form_fault : Str -> { status : U16, words : { title : Str, text : Str } }
form_fault = |text| { status: 400, words: { title: "Message refused", text } }

## A message the conversation refuses, saying why: a 409.
conversation_refusal : Str -> { status : U16, words : { title : Str, text : Str } }
conversation_refusal = |text| { status: 409, words: { title: "Message refused", text } }

## A fault in a reaction's form, saying what: a 400.
reaction_fault : Str -> { status : U16, words : { title : Str, text : Str } }
reaction_fault = |text| { status: 400, words: { title: "Reaction refused", text } }

# ── tests
## `plans` in Steve's own DM.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
		?? crash "ConversationRefusal's tests: a path is UTF-8",
	directory: Directory.with_founder(Name.from_str("Steve") ?? crash "ConversationRefusal's tests: a name"),
}).map_ok(|found| found.key) ?? crash "ConversationRefusal's tests: Steve's own DM is a place"

# Each refusal: the request's faults a 400, no transcript a 404, the
# conversation's refusals a 409, the server's a 500, each in its own words.
expect
	[
		(MissingField, "The form has no field `markdown`."),
		(RepeatedField, "The form has the field `markdown` more than once."),
		(BadEscape, "The form's `markdown` holds a % that starts no two hex digits."),
		(NotUtf8, "The form's `markdown` is not UTF-8."),
		(Blank, "The message is blank."),
	].all(
		|(why, text)| ConversationRefusal.notice(why) == {
			status: 400,
			words: { title: "Message refused", text },
		},
	)
expect
	[
		(
			NoCount,
			"The stream names no count of the messages seen: `?after=<count>`, or a Last-Event-ID.",
		),
		(
			BadCount,
			"The stream's count of the messages seen is not one: the digits of 0 to 65535, with no leading 0.",
		),
	].all(
		|(why, text)| ConversationRefusal.notice(why) == {
			status: 400,
			words: { title: "Bad stream", text },
		},
	)
expect ConversationRefusal.notice(NoSuchConversation(plans_key)) == {
	status: 404,
	words: { title: "Not found", text: "No such conversation: /chat/dm/1_1/plans" },
}
expect
	[
		(Backdated, "The message is dated before the conversation's latest."),
		(Full, "The conversation holds as many messages as it can."),
		(FileFull, "The conversation's transcript holds as much as it can: 16 MiB."),
		(EditOfNoSuchMessage, "The edit names a message this conversation doesn't hold."),
		(EditOfAnotherAuthorsMessage, "Only a message's author may edit it."),
	].all(
		|(why, text)| ConversationRefusal.notice(why) == {
			status: 409,
			words: { title: "Message refused", text },
		},
	)
expect
	[
		(ReactionField({ fault: MissingField, name: "emoji" }), "The form has no field `emoji`."),
		(NotAMessageId, "The form's `msg` is no message's number."),
		(NotAnEmoji, "The form's `emoji` is no emoji."),
		(NotOnOrOff, "The form's `on` is neither 1 nor 0."),
	].all(
		|(why, text)| ConversationRefusal.notice(why) == {
			status: 400,
			words: { title: "Reaction refused", text },
		},
	)
expect
	[
		(NoSuchMessage, "The conversation holds no such message."),
		(TooManyReactions, "The conversation holds as many reactions as it can."),
	].all(
		|(why, text)| ConversationRefusal.notice(why) == {
			status: 409,
			words: { title: "Reaction refused", text },
		},
	)
expect ConversationRefusal.notice(ClockOutOfRange) == {
	status: 500,
	words: { title: "Message refused", text: "The server's clock is out of range." },
}
expect ConversationRefusal.notice(Unreadable(TranscriptNotUtf8)) == {
	status: 500,
	words: { title: "Not a transcript", text: "Not a transcript: it is not UTF-8." },
}
expect ConversationRefusal.notice(FileSystem(PathRefused)) == {
	status: 500,
	words: { title: "Failed", text: "The file system answered PathRefused." },
}
