## **THE DEMO**: a topic's name and its transcript in, its page out. The
## host (host/main.zig) reads the file and writes the page; everything
## else is the pure core. The door: the host's bytes become a Conversation
## or a refusal's tags here, and only here are the tags put into words.
app [page] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import Conversation
import Message
import Page
import Topic
import Transcript

## The page for `topic`'s transcript, or a page saying what is wrong with it.
page : List(U8), List(U8) -> List(U8)
page = |topic, transcript| {
	answer =
		match conversation({ topic, transcript }) {
			Ok(c) => Page.conversation(c)
			Err(why) => Page.refused(words(why))
		}
	answer.to_utf8()
}

## The conversation the host's bytes hold, decoded at the door.
conversation : { topic : List(U8), transcript : List(U8) } -> Try(Conversation, _)
conversation = |{ topic, transcript }| {
	name = Str.from_utf8(topic) ? |_| TopicNotUtf8
	text = Str.from_utf8(transcript) ? |_| TranscriptNotUtf8
	checked = Topic.from_str(name) ? |why| Topic(why)
	Transcript.read(checked, text).map_err(|why| Transcript(why))
}

## **EVERY WAY THE DOOR REFUSES**: what `words` takes, each module's tags
## under the step that met them. A handler's input, so `conversation`'s
## own error stays inferred from its body.
Refusal : [
	TopicNotUtf8,
	TranscriptNotUtf8,
	Topic([Empty, StartsWithNonLetter, TooLong, ForbiddenByte]),
	Transcript(
		[
			BadEnds,
			BadHead(Message.Id),
			Author(Message.Id, [Blank, ControlByte, FormatCharacter, Padded]),
			DateTime(Message.Id, [WrongShape, OutOfRange]),
			BadBody(Message.Id),
			Backdated(Message.Id),
			Full,
		],
	),
]

## **WHY A TRANSCRIPT IS REFUSED, IN WORDS**: the one place a refusal's
## tags become a sentence.
words : Refusal -> Str
words = |why|
	match why {
		TopicNotUtf8 => "its topic is not UTF-8"
		TranscriptNotUtf8 => "it is not UTF-8"
		Topic(Empty) => "its topic is empty"
		Topic(StartsWithNonLetter) => "its topic does not start with an ASCII letter"
		Topic(TooLong) => "its topic is longer than ${Topic.longest.to_str()} characters"
		Topic(ForbiddenByte) => "its topic holds more than ASCII letters, digits and -"
		Transcript(BadEnds) => "a transcript starts with the separator and ends with an empty line"
		Transcript(Full) => "it holds more messages than a conversation can"
		Transcript(BadHead(id)) => "message ${id.to_str()} does not open with its reference, `from:`, `date:` and an empty line"
		Transcript(BadBody(id)) => "message ${id.to_str()} holds the separator, unescaped, on a line of its own"
		Transcript(Backdated(id)) => "message ${id.to_str()} is dated before the message above it"
		Transcript(Author(id, fault)) => {
			said =
				match fault {
					Blank => " has no author"
					ControlByte => "'s author holds a control character"
					FormatCharacter => "'s author holds an invisible Unicode format character"
					Padded => "'s author starts or ends with a space"
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

# ── tests
plans : Topic
plans = Topic.from_str("plans") ?? crash "main's tests: a topic's name"

expect conversation({ topic: "plans".to_utf8(), transcript: [] }) == Ok(Conversation.empty(plans))
expect conversation({ topic: [0xff], transcript: [] }) == Err(TopicNotUtf8)
expect conversation({ topic: "plans".to_utf8(), transcript: [0xff] }) == Err(TranscriptNotUtf8)
# Each refusal of the topic, and of the transcript, through the door.
expect conversation({ topic: "".to_utf8(), transcript: [] }) == Err(Topic(Empty))
expect conversation({ topic: "1a".to_utf8(), transcript: [] }) == Err(Topic(StartsWithNonLetter))
expect conversation({ topic: "a".repeat(61).to_utf8(), transcript: [] }) == Err(Topic(TooLong))
expect conversation({ topic: "a b".to_utf8(), transcript: [] }) == Err(Topic(ForbiddenByte))
expect conversation({
	topic: "plans".to_utf8(),
	transcript: "\n".to_utf8(),
}) == Err(Transcript(BadEnds))
# The order: the topic's bytes, the transcript's, then the topic's name.
expect conversation({ topic: [0xff], transcript: [0xff] }) == Err(TopicNotUtf8)
expect conversation({ topic: "".to_utf8(), transcript: [0xff] }) == Err(TranscriptNotUtf8)
expect conversation({ topic: "".to_utf8(), transcript: "\n".to_utf8() }) == Err(Topic(Empty))
# The page, through the host's bytes: a conversation's, or the refusal's.
expect page(
	"plans".to_utf8(),
	[],
) == Page.conversation(Conversation.empty(plans)).to_utf8()
expect page("<b>".to_utf8(), [0xff]) == Page.refused("it is not UTF-8").to_utf8()
# The one test of the wording: every refusal, in words.
expect {
	second = Message.Id.first.next() ?? crash "main's tests: the first id has a next"
	[
		TopicNotUtf8,
		TranscriptNotUtf8,
		Topic(Empty),
		Topic(StartsWithNonLetter),
		Topic(TooLong),
		Topic(ForbiddenByte),
		Transcript(BadEnds),
		Transcript(BadHead(second)),
		Transcript(Author(second, Blank)),
		Transcript(Author(second, ControlByte)),
		Transcript(Author(second, FormatCharacter)),
		Transcript(Author(second, Padded)),
		Transcript(DateTime(second, WrongShape)),
		Transcript(DateTime(second, OutOfRange)),
		Transcript(BadBody(second)),
		Transcript(Backdated(second)),
		Transcript(Full),
	].map(words)
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
			"message 2's author holds a control character",
			"message 2's author holds an invisible Unicode format character",
			"message 2's author starts or ends with a space",
			"message 2's date is not YYYY-MM-DDTHH:MM:SSZ",
			"message 2's date is no time a calendar and clock show",
			"message 2 holds the separator, unescaped, on a line of its own",
			"message 2 is dated before the message above it",
			"it holds more messages than a conversation can",
		]
}
