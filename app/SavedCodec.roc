## **A READING LIST, STORED** (Store's `chat/saved/<id>`): its mark,
## then one line a save, in the list's order (newest last):
##
##     reading v1 next=4
##     saved v1 id=2 saved=1761600300 channel=Orchard topic=Banana n=5 by=human:9 from=Pip%20Q at=1761600000 note=read%20later body=two%0Alines
##
## - `next` is the id the next save takes: one past every id the list has
##   ever given, kept so that an id is **never given twice**, even after its
##   save is removed (a stale page's form can never act on another save).
##   Every save's id is below it, and no two are the same.
## - `id` is the save's number on its list, from 1.
## - `saved` is when it was saved (or saved again).
## - `channel`, `topic` and `n` are where the message is: its topic's
##   names as made, and its number there.
## - `by`, `from` and `at` are its author, the author's name and when it
##   was posted, and `body` its markdown, all as they were when it was
##   saved: the saver's own copy, kept if the message's topic is ever
##   closed to them, its author's name frozen as the old block froze its
##   `from`.
## - `from` and `note` (the saver's line about it, ReadingList's rule) are
##   text with `%`, a space and every control byte as `%` and two uppercase
##   hex digits, so each is one value; `body` is the last, any bytes, as a
##   message's body is stored (MessageCodec). An empty file, or none, is the
##   empty list, its `next` 1. Pure.
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
		from : Str,
		at : I64,
		note : Str,
		body : List(U8),
	}

	## **A WHOLE LIST**: the id the next save takes, and its saves in order.
	Book : { next : U64, saves : List(SavedCodec.Fields) }

	## The empty list: no saves, the next id 1.
	empty : SavedCodec.Book
	empty = { next: 1, saves: [] }

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
					("from", spaced_text(e.from)),
					("at", Stored.time_text(e.at)),
					("note", spaced_text(e.note)),
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
		channel = ChannelName.from_stored(text_of(channel_field.value)).map_err(|_| BadValue("channel"))?
		topic_field = channel_field.rest.field("topic")?
		topic = TopicName.from_str(text_of(topic_field.value)).map_err(|_| BadValue("topic"))?
		n_field = topic_field.rest.field("n")?
		n = Stored.count(n_field.value, "n")?
		by_field = n_field.rest.field("by")?
		by = AccountCodec.id_from(by_field.value, "by")?
		from_field = by_field.rest.field("from")?
		from = unspaced_text(from_field.value, "from")?
		at_field = from_field.rest.field("at")?
		at = Stored.time(at_field.value, "at")?
		note_field = at_field.rest.field("note")?
		note = unspaced_text(note_field.value, "note")?
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
				from,
				at,
				note,
				body,
			})
		}
	}

	## **A LIST AS STORED**: its mark, then every line a save, the last
	## ended by its newline (a torn write is `Torn`); every id below `next`
	## and none twice. Empty, the empty list.
	book : List(U8) -> Try(SavedCodec.Book, _)
	book = |raw|
		if raw.is_empty() {
			Ok(SavedCodec.empty)
		} else if raw.last() != Ok('\n') {
			Err(Torn)
		} else {
			match raw.split_on('\n').drop_last(1) {
				[] => Err(Torn)
				[mark, .. as lines] => {
					fields = Stored.Reader.open(mark.append('\n'), "reading")?
					next_field = fields.field("next")?
					next = Stored.count(next_field.value, "next")?
					next_field.rest.close()?
					saves = lines.map_try(|line| SavedCodec.decode(line.append('\n')))?
					ids = saves.map(|e| e.id).sort_with(
						|
							a,
							b,
						| if (a < b) Before else if (a > b) After else Same,
					)
					if next == 0 or saves.any(|e| e.id >= next) {
						Err(BadValue("next"))
					} else if ids.map_with_index(
						|
							id,
							i,
						| ids.get(i + 1) == Ok(id),
					).any(|twice| twice) {
						Err(BadValue("id"))
					} else {
						Ok({ next, saves })
					}
				}
			}
		}

	## The list's bytes: its mark, then each save's line, in order.
	file : SavedCodec.Book -> List(U8)
	file = |{ next, saves }|
		Stored.line(
			"reading",
			[("next", next.to_str())],
		).concat(saves.map(SavedCodec.encode).join())
}

## A free-text value as one Stored value (`spaced`).
spaced_text : Str -> Str
spaced_text = |text| Str.from_utf8(spaced(text.to_utf8())) ?? crash "SavedCodec.spaced_text: an escape is ASCII"

## The text a `spaced` value spelled, in the field `name`.
unspaced_text : List(U8), Str -> Try(Str, [BadValue(Str)])
unspaced_text = |value, name| {
	bytes = unspaced(value).map_err(|_| BadValue(name))?
	Str.from_utf8(bytes).map_err(|_| BadValue(name))
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
	from: "Pip Q",
	at: 1761600000,
	note: "read later, 100%",
	body: "two\nlines %".to_utf8(),
}

expect SavedCodec.encode(one) == "saved v1 id=2 saved=1761600300 channel=Orchard topic=Banana n=5 by=human:9 from=Pip%20Q at=1761600000 note=read%20later,%20100%25 body=two%0Alines %25\n".to_utf8()
expect SavedCodec.decode(SavedCodec.encode(one)) == Ok(one)
expect {
	book = {
		next: 4,
		saves: [
			one,
			{
				..one,
				id: 3,
				note: "",
			},
		],
	}
	SavedCodec.book(SavedCodec.file(book)) == Ok(book)
}
expect SavedCodec.file({
	next: 4,
	saves: [one],
}).starts_with("reading v1 next=4\nsaved v1 id=2 ".to_utf8())
expect SavedCodec.book([]) == Ok(SavedCodec.empty)
expect SavedCodec.book(SavedCodec.file(SavedCodec.empty)) == Ok(SavedCodec.empty)
# One spelling of a note; a torn list; no id 0.
expect SavedCodec.decode("saved v1 id=2 saved=1 channel=Orchard topic=Banana n=5 by=human:9 from=P at=1 note=read%20later%2 body=x\n".to_utf8()).is_err()
expect SavedCodec.decode("saved v1 id=2 saved=1 channel=Orchard topic=Banana n=5 by=human:9 from=P at=1 note=a%41 body=x\n".to_utf8()).is_err()
expect SavedCodec.decode("saved v1 id=0 saved=1 channel=Orchard topic=Banana n=5 by=human:9 from=P at=1 note=a body=x\n".to_utf8()).is_err()
expect SavedCodec.decode("saved v1 id=1 saved=1 channel=Or.chard topic=Banana n=5 by=human:9 from=P at=1 note=a body=x\n".to_utf8()).is_err()
expect SavedCodec.book(SavedCodec.file({ next: 4, saves: [one] }).drop_last(1)) == Err(Torn)
# The mark is kept: an id at or past `next`, or one given twice, is refused.
expect SavedCodec.book(SavedCodec.file({ next: 2, saves: [one] })).is_err()
expect SavedCodec.book(SavedCodec.file({ next: 9, saves: [one, one] })).is_err()
expect SavedCodec.book(SavedCodec.encode(one)).is_err()
