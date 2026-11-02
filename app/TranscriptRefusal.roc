## **EVERY WAY A TRANSCRIPT IS REFUSED, AND THE WORDS FOR EACH**: the tags
## the demo's door (main's `conversation`) and the server's read of a
## transcript file meet, each module's tags under the step that met them,
## and the one place they become a sentence. `Transcript.decode` answers
## its refusals as these tags itself, so a reader of a file passes them on
## and never maps them.
import Message
import Name
import StrictName

TranscriptRefusal :: [].{

	## What `words` takes. A handler's input, so each reader's own error
	## stays inferred from its body.
	Why : [
		TopicNotUtf8,
		TranscriptNotUtf8,
		Topic([Empty, StartsWithNonLetter, TooLong, ForbiddenByte]),
		Transcript(
			[
				BadEnds,
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
			TopicNotUtf8 => "its topic is not UTF-8"
			TranscriptNotUtf8 => "it is not UTF-8"
			Topic(Empty) => "its topic is empty"
			Topic(StartsWithNonLetter) => "its topic does not start with an ASCII letter"
			Topic(TooLong) => "its topic is longer than ${StrictName.longest.to_str()} characters"
			Topic(ForbiddenByte) => "its topic holds more than ASCII letters, digits and -"
			Transcript(BadEnds) => "a transcript starts with the separator and ends with an empty line"
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
		TopicNotUtf8,
		TranscriptNotUtf8,
		Topic(Empty),
		Topic(StartsWithNonLetter),
		Topic(TooLong),
		Topic(ForbiddenByte),
		Transcript(BadEnds),
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
			"its topic is not UTF-8",
			"it is not UTF-8",
			"its topic is empty",
			"its topic does not start with an ASCII letter",
			"its topic is longer than 60 characters",
			"its topic holds more than ASCII letters, digits and -",
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
