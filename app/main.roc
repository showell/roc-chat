## **THE DEMO**: a topic's name and its transcript in, its page out. The
## host (host/main.zig) reads the file and writes the page; everything
## else is the pure core.
app [page] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import Conversation
import Html
import Topic

## The page for `topic`'s transcript, or a page saying what is wrong with it.
page : List(U8), List(U8) -> List(U8)
page = |topic, transcript| {
	answer =
		match conversation({ topic, transcript }) {
			Ok(c) => c.html()
			Err(Malformed(why)) =>
				Html.page({
					title: "Not a transcript",
					body: Html.element({
						name: "p",
						attrs: [],
						inner: Html.text("Not a transcript: ${why}."),
					}),
				})
		}
	answer.to_str().to_utf8()
}

## The conversation the host's bytes hold, decoded at the door.
conversation : { topic : List(U8), transcript : List(U8) } -> Try(Conversation, [Malformed(Str)])
conversation = |{ topic, transcript }| {
	name = Str.from_utf8(topic) ? |_| Malformed("its topic is not UTF-8")
	text = Str.from_utf8(transcript) ? |_| Malformed("it is not UTF-8")
	checked = Topic.from_str(name) ? |why| Malformed(topic_refused(why))
	Conversation.read(checked, text)
}

## Why a topic's name is refused, in words.
topic_refused : [Empty, TooLong, StartsWithNonLetter, ForbiddenByte] -> Str
topic_refused = |why|
	match why {
		Empty => "its topic is empty"
		TooLong => "its topic is longer than 60 characters"
		StartsWithNonLetter => "its topic does not start with an ASCII letter"
		ForbiddenByte => "its topic holds more than ASCII letters, digits and -"
	}

# ── tests
expect page("plans".to_utf8(), "".to_utf8()) == Html.page({
	title: "plans",
	body: Html.markup("<h1>plans</h1>\n<p class=\"empty\">No messages yet.</p>\n"),
}).to_str().to_utf8()
expect conversation({ topic: [0xff], transcript: [] }) == Err(Malformed("its topic is not UTF-8"))
expect conversation({
	topic: "plans".to_utf8(),
	transcript: [0xff],
}) == Err(Malformed("it is not UTF-8"))
expect conversation({
	topic: [0xff],
	transcript: [0xff],
}) == Err(Malformed("its topic is not UTF-8"))
expect conversation({ topic: "plans".to_utf8(), transcript: [] }).is_ok()
expect conversation({ topic: "".to_utf8(), transcript: [] }) == Err(Malformed("its topic is empty"))
expect conversation({
	topic: "a".repeat(61).to_utf8(),
	transcript: [],
}) == Err(Malformed("its topic is longer than 60 characters"))
expect conversation({
	topic: "1a".to_utf8(),
	transcript: [],
}) == Err(Malformed("its topic does not start with an ASCII letter"))
expect conversation({
	topic: "a b".to_utf8(),
	transcript: [],
}) == Err(Malformed("its topic holds more than ASCII letters, digits and -"))
expect conversation({
	topic: "plans".to_utf8(),
	transcript: "\n".to_utf8(),
}) == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
expect page("<b>".to_utf8(), [0xff]) == Html.page({
	title: "Not a transcript",
	body: Html.markup("<p>Not a transcript: it is not UTF-8.</p>"),
}).to_str().to_utf8()
