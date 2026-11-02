## **EVERY WAY A TRANSCRIPT IS REFUSED, AND THE WORDS FOR EACH**: the tags
## the demo's door (main's `conversation`: the conversation's URL path,
## then its transcript) and the server's read of a
## transcript file meet, each module's tags under the step that met them,
## and the one place they become a sentence. `Transcript.decode` answers
## its refusals as these tags itself, so a reader of a file passes them on
## and never maps them.
import Message
import Name

TranscriptRefusal :: [].{

	## What `words` takes. A handler's input, so each reader's own error
	## stays inferred from its body.
	Why : [
		PathNotUtf8,
		TranscriptNotUtf8,
		Path(
			[
				NotAConversationPath,
				BadName,
				NoSuchChannel,
				NoSuchHuman,
			],
		),
		Transcript(
			[
				NotPrefixedProperly,
				BadHead(Message.Id),
				Author(Message.Id, [Empty, TooLong, ForbiddenCharacter, BadSpacing]),
				DateTime(Message.Id, [WrongShape, OutOfRange]),
				BadBody(Message.Id),
				Backdated(Message.Id),
				Full,
			],
		),
	]

	## **WHY A TRANSCRIPT IS REFUSED, IN WORDS**.
	words : TranscriptRefusal.Why -> Str
	words = |why|
		match why {
			PathNotUtf8 => "its conversation's path is not UTF-8"
			TranscriptNotUtf8 => "it is not UTF-8"
			Path(NotAConversationPath) => "its path is not a conversation's, /chat/channel/<channel>/<topic> or /chat/dm/<pair>/<topic>"
			Path(BadName) => "its path holds a channel, a pair or a topic that is no name"
			Path(NoSuchChannel) => "its path names no channel the directory holds"
			Path(NoSuchHuman) => "its path names a DM whose member is no human the directory holds"
			Transcript(NotPrefixedProperly) => "a transcript starts with the separator and ends with an empty line"
			Transcript(Full) => "it holds more messages than a conversation can"
			Transcript(BadHead(id)) => "message ${id.to_str()} does not open with its reference, `from:`, `date:` and an empty line"
			Transcript(BadBody(id)) => "message ${id.to_str()} holds the separator, unescaped, on a line of its own"
			Transcript(Backdated(id)) => "message ${id.to_str()} is dated before the message above it"
			Transcript(Author(id, fault)) => {
				said =
					match fault {
						Empty => " has no author"
						TooLong => "'s author is longer than ${Name.longest.to_str()} characters"
						ForbiddenCharacter => "'s author holds a character that is no letter or space"
						BadSpacing => "'s author has a space at either end, or two together"
					}
				"message ${id.to_str()}${said}"
			}
			Transcript(DateTime(id, fault)) => {
				said =
					match fault {
						WrongShape => "is not YYYY-MM-DDTHH:MM:SSZ"
						OutOfRange => "is no time a calendar and clock show"
					}
				"message ${id.to_str()}'s date ${said}"
			}
		}
}

# ── tests
# The one test of the wording: every refusal, in words.
expect {
	second = Message.Id.first.next() ?? crash "TranscriptRefusal's tests: the first id has a next"
	[
		PathNotUtf8,
		TranscriptNotUtf8,
		Path(NotAConversationPath),
		Path(BadName),
		Path(NoSuchChannel),
		Path(NoSuchHuman),
		Transcript(NotPrefixedProperly),
		Transcript(BadHead(second)),
		Transcript(Author(second, Empty)),
		Transcript(Author(second, TooLong)),
		Transcript(Author(second, ForbiddenCharacter)),
		Transcript(Author(second, BadSpacing)),
		Transcript(DateTime(second, WrongShape)),
		Transcript(DateTime(second, OutOfRange)),
		Transcript(BadBody(second)),
		Transcript(Backdated(second)),
		Transcript(Full),
	].map(TranscriptRefusal.words)
		== [
			"its conversation's path is not UTF-8",
			"it is not UTF-8",
			"its path is not a conversation's, /chat/channel/<channel>/<topic> or /chat/dm/<pair>/<topic>",
			"its path holds a channel, a pair or a topic that is no name",
			"its path names no channel the directory holds",
			"its path names a DM whose member is no human the directory holds",
			"a transcript starts with the separator and ends with an empty line",
			"message 2 does not open with its reference, `from:`, `date:` and an empty line",
			"message 2 has no author",
			"message 2's author is longer than 60 characters",
			"message 2's author holds a character that is no letter or space",
			"message 2's author has a space at either end, or two together",
			"message 2's date is not YYYY-MM-DDTHH:MM:SSZ",
			"message 2's date is no time a calendar and clock show",
			"message 2 holds the separator, unescaped, on a line of its own",
			"message 2 is dated before the message above it",
			"it holds more messages than a conversation can",
		]
}
