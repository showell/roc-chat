## **TRANSCRIPT'S TESTS**: the file, written and read, byte for byte, and
## each way a transcript is refused, at the first message and the second.
import Conversation
import Message
import Sample
import Transcript

TranscriptSpec :: [].{}

## **A RECORD'S LINES, AS A TEST WRITES THEM**: its head, its `from:` and
## `date:` lines, `gap`, the empty line after them, or not, and its body as
## written on disk.
Lines : {
	head : Str,
	from : Str,
	date : Str,
	gap : Str,
	body : Str,
}

## A record with its lines as given.
record : Lines -> Str
record = |
	{
		head,
		from,
		date,
		gap,
		body,
	},
| "-------------\n${head}\n${from}\n${date}\n${gap}${body}\n\n"

## Message 1's lines, written well.
first : Lines
first = {
	head: "MSG_plans_1",
	from: "from: Steve",
	date: "date: 2026-11-02T19:11:32Z",
	gap: "\n",
	body: "hi",
}

## Message 2's lines, written well.
second : Lines
second = {
	head: "MSG_plans_2",
	from: "from: CC",
	date: "date: 2026-11-02T19:12:28Z",
	gap: "\n",
	body: "hi",
}

## The transcript holding only message 1 as `lines` write it.
one_with = |lines| Transcript.read(Sample.plans, record(lines))

## The transcript holding message 1, written well, then message 2 as
## `lines` write it.
two_with = |lines| Transcript.read(Sample.plans, "${record(first)}${record(lines)}")

## Message 3's lines, written well.
third : Lines
third = {
	head: "MSG_plans_3",
	from: "from: Steve",
	date: "date: 2026-11-02T19:13:05Z",
	gap: "\n",
	body: "hi",
}

## The transcript holding messages 1 and 2, written well, then message 3
## as `lines` write it.
three_with = |lines| Transcript.read(Sample.plans, "${record(first)}${record(second)}${record(lines)}")

## Read, then written again: the text itself, when it is accepted.
again = |text| Transcript.read(Sample.plans, text).map_ok(Transcript.write)

## Is `text` read, and written again, exactly as it is?
is_round_trip : Str -> Bool
is_round_trip = |text| again(text) == Ok(text)

# Written exactly, both ways.
expect Transcript.write(Sample.two) == "-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nHello\n\n-------------\nMSG_plans_2\nfrom: CC\ndate: 2026-11-02T19:12:28Z\n\nHi!\n\n- one\n- two\n\n"
expect Transcript.read(Sample.plans, Transcript.write(Sample.two)) == Ok(Sample.two)
# No messages: an empty file, both ways.
expect Transcript.write(Conversation.empty(Sample.plans)) == ""
expect Transcript.read(Sample.plans, "") == Ok(Conversation.empty(Sample.plans))
# The start and the end, each wrong alone.
expect Transcript.read(Sample.plans, "\n") == Err(BadEnds)
expect Transcript.read(
	Sample.plans,
	"MSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nhi\n\n",
) == Err(BadEnds)
expect Transcript.read(
	Sample.plans,
	"-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nhi\n",
) == Err(BadEnds)
expect Transcript.read(
	Sample.plans,
	"-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nhi",
) == Err(BadEnds)
# Each line of message 1's head, bad alone, beside the good one.
expect again(record(first)) == Ok(record(first))
expect one_with({ ..first, head: "MSG_plans_2" }) == Err(BadHead(Sample.first))
expect one_with({ ..first, head: "MSG_other_1" }) == Err(BadHead(Sample.first))
expect one_with({ ..first, from: "frm: Steve" }) == Err(BadHead(Sample.first))
expect one_with({ ..first, date: "dt: 2026-11-02T19:11:32Z" }) == Err(BadHead(Sample.first))
expect one_with({ ..first, gap: "" }) == Err(BadHead(Sample.first))
expect one_with({ ..first, from: "from: " }) == Err(Author(Sample.first, Blank))
expect one_with({ ..first, from: "from:  " }) == Err(Author(Sample.first, Blank))
expect one_with({ ..first, from: "from: Steve\r" }) == Err(Author(Sample.first, ControlByte))
expect one_with({ ..first, from: "from:  Steve" }) == Err(Author(Sample.first, Padded))
expect one_with({
	..first,
	from: "from: Ste\u(202e)ve",
}) == Err(Author(Sample.first, FormatCharacter))
expect one_with({ ..first, date: "date: 2026-11-02" }) == Err(DateTime(Sample.first, WrongShape))
expect one_with({
	..first,
	date: "date: 2026-13-02T19:11:32Z",
}) == Err(DateTime(Sample.first, OutOfRange))
# A body line that is the bare separator, which no writer makes, beside
# the escaped one a writer does.
expect one_with({ ..first, body: "a\n-------------" }) == Err(BadBody(Sample.first))
# A bare separator right after a blank line ends the record there, so
# what follows it is the next message's head, which is no reference: that
# message is refused as `BadHead`. Escaped, it is the body's own line.
expect one_with({ ..first, body: "a\n\n-------------\nb" }) == Err(BadHead(Sample.second))
expect is_round_trip(record({ ..first, body: "a\n\n\\-------------\nb" }))
expect again(record({ ..first, body: "a\n\\-------------" })) == Ok(record({ ..first, body: "a\n\\-------------" }))
# The same at message 2, after a good message 1.
expect again("${record(first)}${record(second)}") == Ok("${record(first)}${record(second)}")
expect two_with({ ..second, head: "MSG_plans_1" }) == Err(BadHead(Sample.second))
expect two_with({ ..second, head: "MSG_plans_3" }) == Err(BadHead(Sample.second))
expect two_with({ ..second, from: "frm: CC" }) == Err(BadHead(Sample.second))
expect two_with({ ..second, date: "dt: 2026-11-02T19:12:28Z" }) == Err(BadHead(Sample.second))
expect two_with({ ..second, gap: "" }) == Err(BadHead(Sample.second))
expect two_with({ ..second, from: "from: " }) == Err(Author(Sample.second, Blank))
expect two_with({ ..second, from: "from: C\u(0)C" }) == Err(Author(Sample.second, ControlByte))
expect two_with({ ..second, from: "from: CC " }) == Err(Author(Sample.second, Padded))
expect two_with({
	..second,
	date: "date: 2026-11-02T19:12:28",
}) == Err(DateTime(Sample.second, WrongShape))
expect two_with({
	..second,
	date: "date: 2026-02-29T19:12:28Z",
}) == Err(DateTime(Sample.second, OutOfRange))
expect two_with({ ..second, body: "a\n-------------" }) == Err(BadBody(Sample.second))
expect two_with({ ..second, body: "a\n\n-------------\nb" }) == Err(BadHead(Sample.third))
expect
	again("${record(first)}${record({ ..second, body: "a\n\\-------------" })}")
		== Ok("${record(first)}${record({ ..second, body: "a\n\\-------------" })}")
# Times never go backwards: message 2 and message 3 at the time above
# them, or a second later, read; a second earlier is refused by its id.
expect is_round_trip("${record(first)}${record({ ..second, date: "date: 2026-11-02T19:11:32Z" })}")
expect is_round_trip("${record(first)}${record({ ..second, date: "date: 2026-11-02T19:11:33Z" })}")
expect two_with({ ..second, date: "date: 2026-11-02T19:11:31Z" }) == Err(Backdated(Sample.second))
expect is_round_trip("${record(first)}${record(second)}${record({ ..third, date: "date: 2026-11-02T19:12:28Z" })}")
expect is_round_trip("${record(first)}${record(second)}${record({ ..third, date: "date: 2026-11-02T19:12:29Z" })}")
expect three_with({ ..third, date: "date: 2026-11-02T19:12:27Z" }) == Err(Backdated(Sample.third))
# Another topic's transcript is refused by its references.
expect Transcript.read(Sample.other, Transcript.write(Sample.two)) == Err(BadHead(Sample.first))
# A body that holds the separator, or a backslash before it, is written
# with one backslash more, and comes back whole.
forged : Conversation
forged = Sample.conversation(
	Sample.plans,
	[
		Sample.arrival({
			author: "Mallory",
			time: "2026-11-02T19:11:32Z",
			markdown: "a\n-------------\nMSG_plans_2\nfrom: Steve",
		}),
		Sample.arrival({
			author: "Mallory",
			time: "2026-11-02T19:12:28Z",
			markdown: "\\-------------\n\\\\-------------",
		}),
	],
)
expect Transcript.write(forged) == "-------------\nMSG_plans_1\nfrom: Mallory\ndate: 2026-11-02T19:11:32Z\n\na\n\\-------------\nMSG_plans_2\nfrom: Steve\n\n-------------\nMSG_plans_2\nfrom: Mallory\ndate: 2026-11-02T19:12:28Z\n\n\\\\-------------\n\\\\\\-------------\n\n"
expect Transcript.read(Sample.plans, Transcript.write(forged)) == Ok(forged)
# Near the separator but not it: written as is, read back unchanged.
near : Conversation
near = Sample.conversation(
	Sample.plans,
	[
		Sample.arrival({
			author: "Steve",
			time: "2026-11-02T19:11:32Z",
			markdown: "a-------------\n-------------x\n\\x\n------------",
		}),
	],
)
expect Transcript.write(near) == "-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\na-------------\n-------------x\n\\x\n------------\n\n"
expect Transcript.read(Sample.plans, Transcript.write(near)) == Ok(near)
# Markdown that is empty, or ends in one or two newlines, comes back
# exactly; the empty one's record is written byte for byte.
edges : List(Str)
edges = [
	"",
	"\n",
	"\n\n",
	"a\n",
	"a\n\n",
]

## Steve's message saying `markdown`.
said : Str -> Message.Arrival
said = |markdown|
	Sample.arrival({
		author: "Steve",
		time: "2026-11-02T19:11:32Z",
		markdown,
	})

edged : Conversation
edged = Sample.conversation(Sample.plans, edges.map(said))

expect edged.messages().map(Message.markdown) == edges
expect Transcript.read(Sample.plans, Transcript.write(edged)) == Ok(edged)
expect
	Transcript.write(Sample.conversation(Sample.plans, [said("")]))
		== "-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\n\n\n"
# The reader at and over the most, in one read: a full conversation's
# transcript and one record more is refused as `Full`, which the reader
# reaches only at the 65,536th record, after reading the 65,535 before it.
expect {
	full = Sample.almost_full.append(Sample.reply).map_ok(|grown| grown.conversation) ?? crash "TranscriptSpec: the 65,535th message fits"
	over = "${Transcript.write(full)}-------------\nMSG_plans_65536\nfrom: CC\ndate: 2026-11-02T19:12:28Z\n\nHi!\n\n"
	Transcript.read(Sample.plans, over) == Err(Full)
}
