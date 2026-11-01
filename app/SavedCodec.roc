## **A SAVED MESSAGE, STORED** (a human's reading list, Store's
## `chat/saved/<id>`): one line in Stored's format, a line each, oldest
## save first:
##
##     saved v1 id=2 saved=1761600300 channel=Orchard topic=Banana n=5 by=human:9 at=1761600000 note=read%20later body=two%0Alines
##
## - `id` is the save's number on its list, from 1, never given twice.
## - `saved` is when it was saved (or saved again, its note changed).
## - `channel`, `topic` and `n` are where the message is: its topic's
##   names as made, and its number there.
## - `by` and `at` are its author and when it was posted, and `body` its
##   markdown, as it was when saved: the saver's own copy, kept if the
##   message's topic is ever closed to them, as the old reading list's
##   blocks were.
## - `note` is the saver's line about it (ReadingList's rule: one line of
##   text), with `%`, a space and every control byte as `%` and two
##   uppercase hex digits, so it is one value; `body` is the last, any
##   bytes, as a message's body is stored (MessageCodec). Pure.
import AccountCodec
import ChannelName
import MessageCodec
import Principal
import Stored
import Topic
import TopicName

SavedCodec := [].{

	## **A SAVE'S STORED FIELDS.**
	Fields : {
		id : U64,
		saved : I64,
		place : Topic.At,
		n : U64,
		by : Principal.Id,
		at : I64,
		note : Str,
		body : List(U8),
	}

	## The save's line. An id or a number of 0 is no save: a crash.
	encode : SavedCodec.Fields -> List(U8)
	encode = |e|
		if e.id == 0 or e.n == 0 {
			crash "SavedCodec.encode: a save's id and its message's number are not 0"
		} else {
			head = Stored.line(
				"saved",
				[
					("id", e.id.to_str()),
					("saved", Stored.time_text(e.saved)),
					("channel", e.place.channel.to_str()),
					("topic", e.place.topic.to_str()),
					("n", e.n.to_str()),
					("by", AccountCodec.id_text(e.by)),
					("at", Stored.time_text(e.at)),
					(
						"note",
						Str.from_utf8(spaced(e.note.to_utf8())) ?? crash "SavedCodec.encode: an escape is ASCII",
					),
				],
			)
			[
				head.drop_last(1),
				" body=".to_utf8(),
				MessageCodec.escape(e.body),
				['\n'],
			].join()
		}

	## The save a line holds.
	decode : List(U8) -> Try(SavedCodec.Fields, _)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "saved")?
		id_field = fields.field("id")?
		id = Stored.count(id_field.value, "id")?
		saved_field = id_field.rest.field("saved")?
		saved = Stored.time(saved_field.value, "saved")?
		channel_field = saved_field.rest.field("channel")?
		channel = ChannelName.from_str(text_of(channel_field.value)).map_err(|_| BadValue("channel"))?
		topic_field = channel_field.rest.field("topic")?
		topic = TopicName.from_str(text_of(topic_field.value)).map_err(|_| BadValue("topic"))?
		n_field = topic_field.rest.field("n")?
		n = Stored.count(n_field.value, "n")?
		by_field = n_field.rest.field("by")?
		by = AccountCodec.id_from(by_field.value, "by")?
		at_field = by_field.rest.field("at")?
		at = Stored.time(at_field.value, "at")?
		note_field = at_field.rest.field("note")?
		note_bytes = unspaced(note_field.value)?
		note = Str.from_utf8(note_bytes).map_err(|_| BadValue("note"))?
		body_text = note_field.rest.text("body")?
		body = MessageCodec.unescape(body_text.to_utf8())?
		if id == 0 or n == 0 {
			Err(BadValue(if (id == 0) "id" else "n"))
		} else {
			Ok({
				id,
				saved,
				place: { channel, topic },
				n,
				by,
				at,
				note,
				body,
			})
		}
	}

	## **A READING LIST'S SAVES**, oldest first: every line a save, the last
	## ended by its newline (a torn write is `Torn`). None, an empty list.
	list : List(U8) -> Try(List(SavedCodec.Fields), _)
	list = |raw|
		if raw.is_empty() {
			Ok([])
		} else if raw.last() != Ok('\n') {
			Err(Torn)
		} else {
			raw.split_on('\n').drop_last(1).map_try(|line| SavedCodec.decode(line.append('\n')))
		}

	## The list's bytes: each save's line, in order.
	file : List(SavedCodec.Fields) -> List(U8)
	file = |saves| saves.map(SavedCodec.encode).join()
}

## A value Stored's reader read, as text: `open` checked the line is UTF-8.
text_of : List(U8) -> Str
text_of = |value| Str.from_utf8(value) ?? crash "SavedCodec.text_of: Stored.Reader.open checked the line is UTF-8"

## The note as `note=` spells it: `%`, a space and the control bytes
## escaped, nothing else.
spaced : List(U8) -> List(U8)
spaced = |bytes|
	bytes.join_map(
		|b|
			if b == '%' or b == ' ' or b < 0x20 or b == 0x7F {
				[
					'%',
					hex_digit(b // 16),
					hex_digit(b % 16),
				]
			} else {
				[b]
			},
	)

## The note `spaced` spelled, and only that spelling.
unspaced : List(U8) -> Try(List(U8), [BadValue(Str)])
unspaced = |text| {
	out = unspaced_from(text, [])?
	if (spaced(out) == text) Ok(out) else Err(BadValue("note"))
}

unspaced_from : List(U8), List(U8) -> Try(List(U8), [BadValue(Str)])
unspaced_from = |text, out|
	match text {
		[] => Ok(out)
		[
			'%',
			high,
			low,
			.. as rest,
		] =>
			match (hex_value(high), hex_value(low)) {
				(Ok(h), Ok(l)) => unspaced_from(rest, out.append(h * 16 + l))
				_ => Err(BadValue("note"))
			}
		['%', ..] => Err(BadValue("note"))
		[b, .. as rest] => unspaced_from(rest, out.append(b))
	}

hex_digit : U8 -> U8
hex_digit = |d| if (d < 10) '0' + d else 'A' + d - 10

hex_value : U8 -> Try(U8, [NotHex])
hex_value = |c|
	if c >= '0' and c <= '9' {
		Ok(c - '0')
	} else if c >= 'A' and c <= 'F' {
		Ok(c - 'A' + 10)
	} else {
		Err(NotHex)
	}

# ── tests
place_of : Str, Str -> Topic.At
place_of = |c, t|
	match (ChannelName.from_str(c), TopicName.from_str(t)) {
		(Ok(channel), Ok(topic)) => { channel, topic }
		_ => crash "place_of: a test's names are names"
	}

one : SavedCodec.Fields
one = {
	id: 2,
	saved: 1761600300,
	place: place_of("Orchard", "Banana"),
	n: 5,
	by: Principal.Id.Human(Principal.HumanId.from_u64(9) ?? crash "a test's id"),
	at: 1761600000,
	note: "read later, 100%",
	body: "two\nlines %".to_utf8(),
}

expect SavedCodec.encode(one) == "saved v1 id=2 saved=1761600300 channel=Orchard topic=Banana n=5 by=human:9 at=1761600000 note=read%20later,%20100%25 body=two%0Alines %25\n".to_utf8()
expect SavedCodec.decode(SavedCodec.encode(one)) == Ok(one)
expect SavedCodec.list(
	SavedCodec.file([
		one,
		{
			..one,
			id: 3,
			note: "",
		},
	]),
) == Ok([
	one,
	{
		..one,
		id: 3,
		note: "",
	},
])
expect SavedCodec.list([]) == Ok([])
# One spelling of a note; a torn list; no id 0.
expect SavedCodec.decode("saved v1 id=2 saved=1 channel=Orchard topic=Banana n=5 by=human:9 at=1 note=read%20later%2 body=x\n".to_utf8()).is_err()
expect SavedCodec.decode("saved v1 id=2 saved=1 channel=Orchard topic=Banana n=5 by=human:9 at=1 note=a%41 body=x\n".to_utf8()).is_err()
expect SavedCodec.decode("saved v1 id=0 saved=1 channel=Orchard topic=Banana n=5 by=human:9 at=1 note=a body=x\n".to_utf8()).is_err()
expect SavedCodec.decode("saved v1 id=1 saved=1 channel=Or.chard topic=Banana n=5 by=human:9 at=1 note=a body=x\n".to_utf8()).is_err()
expect SavedCodec.list(SavedCodec.encode(one).drop_last(1)) == Err(Torn)
