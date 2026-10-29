## **A MESSAGE, STORED, AND A TRANSCRIPT OF THEM**: a message is one line in
## Stored's format, and a conversation's transcript is its messages' lines,
## appended in order:
##
##     message v1 id=3 at=1761600000 by=human:583231 body=two%0Alines, 100%25
##
## - `id` is the message's number in its conversation: 1, 2, 3, never a gap.
## - `by` is who posted it, as every record spells a principal's id.
## - `body` is the markdown as it was posted, **ANY BYTES, EXACTLY**: the
##   free-text field, last, escaped so the line stays one line of UTF-8.
##   `%` is `%25`; every control byte (below 0x20, and 0x7F), the newline
##   among them, is `%` and two uppercase hex digits; and in a body that is
##   not UTF-8, every byte from 0x80 up is too. Nothing else is escaped, so
##   text a person wrote reads as it was written. Each body has one
##   spelling: a line whose body is not the one `encode` writes (`%0a`, a
##   needless `%41`) is refused.
##
## `decode` gives a Line, an opaque value only this module makes. Pure.
import AccountCodec
import Cast
import Principal
import Stored

MessageCodec := [].{

	## **A MESSAGE'S STORED FIELDS.** `id` is never 0.
	Fields : {
		id : U64,
		at : I64,
		by : Principal.Id,
		body : List(U8),
	}

	## **A LINE THAT DECODED**: its fields, every one checked. Opaque: made
	## only by `decode` and `transcript`.
	Line :: MessageCodec.Fields.{

		fields : MessageCodec.Line -> MessageCodec.Fields
		fields = |MessageCodec.Line.(f)| f
	}

	## The message's line. An id of 0 is no message: a crash.
	encode : MessageCodec.Fields -> List(U8)
	encode = |m|
		if m.id == 0 {
			crash "MessageCodec.encode: a message's id is not 0"
		} else {
			# Stored.line refuses a control byte in a value, and the escape
			# leaves none: the body goes in after it, as its free text.
			head = Stored.line(
				"message",
				[
					("id", m.id.to_str()),
					("at", Stored.time_text(m.at)),
					("by", AccountCodec.id_text(m.by)),
				],
			)
			List.join([
				List.drop_last(head, 1),
				Str.to_utf8(" body="),
				escaped(m.body),
				['\n'],
			])
		}

	## The message a line holds.
	decode : List(U8) -> Try(MessageCodec.Line, Stored.Problem)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "message")?
		id_field = fields.field("id")?
		id = Stored.count(id_field.value, "id")?
		at_field = id_field.rest.field("at")?
		at = Stored.time(at_field.value, "at")?
		by_field = at_field.rest.field("by")?
		by = AccountCodec.id_from(by_field.value, "by")?
		text = by_field.rest.text("body")?
		body = unescaped(Str.to_utf8(text))?
		if id == 0 {
			Err(BadValue("id"))
		} else {
			Ok(
				MessageCodec.Line.(
					{
						id,
						at,
						by,
						body,
					},
				),
			)
		}
	}

	## **A TRANSCRIPT'S MESSAGES**, oldest first: every line a message, the
	## last ended by its newline (a torn append is `Torn`), and the ids 1,
	## 2, 3 in order (`BadValue("id")` for a gap, a repeat or a start past
	## 1). An empty transcript has none.
	transcript : List(U8) -> Try(List(MessageCodec.Line), Stored.Problem)
	transcript = |raw| MessageCodec.span(raw, 1)

	## **A RUN OF A TRANSCRIPT'S LINES**, read from where its message `first`
	## starts (Store.load_span!): the same rule, its ids `first`, `first`
	## plus one, and on.
	span : List(U8), U64 -> Try(List(MessageCodec.Line), Stored.Problem)
	span = |raw, first|
		if List.is_empty(raw) {
			Ok([])
		} else if List.last(raw) != Ok('\n') {
			Err(Torn)
		} else {
			lines = List.drop_last(List.split_on(raw, '\n'), 1)
			decoded = List.map_try(lines, |line| MessageCodec.decode(List.append(line, '\n')))?
			in_order = List.map_with_index(decoded, |m, i| m.fields().id == first + i)
			if List.all(in_order, |ok| ok) {
				Ok(decoded)
			} else {
				Err(BadValue("id"))
			}
		}

	## The id the next message of a transcript of `count` messages takes.
	next_id : U64 -> U64
	next_id = |count| count + 1
}

## The body as `body=` spells it.
escaped : List(U8) -> List(U8)
escaped = |body| {
	is_text = Str.from_utf8(body).is_ok()
	List.join_map(
		body,
		|b|
			if b == '%' or b < 0x20 or b == 0x7F or (b >= 0x80 and !is_text) {
				[
					'%',
					hex_digit(b // 16),
					hex_digit(b % 16),
				]
			} else {
				[b]
			},
	)
}

## The body `escaped` spelled, and only that spelling.
unescaped : List(U8) -> Try(List(U8), Stored.Problem)
unescaped = |text| {
	len = List.len(text)
	var $out = []
	var $i = 0
	while $i < len {
		b = List.get(text, $i) ?? 0
		if b == '%' {
			high = List.get(text, $i + 1) ?? 0
			low = List.get(text, $i + 2) ?? 0
			match (hex_value(high), hex_value(low)) {
				(Ok(h), Ok(l)) => {
					$out = List.append($out, h * 16 + l)
					$i = $i + 3
				}
				_ => return Err(BadValue("body"))
			}
		} else {
			$out = List.append($out, b)
			$i = $i + 1
		}
	}
	if escaped($out) == text Ok($out) else Err(BadValue("body"))
}

hex_digits : List(U8)
hex_digits = Str.to_utf8("0123456789ABCDEF")

hex_digit : U8 -> U8
hex_digit = |n| List.get(hex_digits, n.to_u64()) ?? '0'

hex_value : U8 -> Try(U8, [NotHex])
hex_value = |c|
	match List.find_first_index(hex_digits, |d| d == c) {
		Ok(i) => Ok(i.to_u8_wrap())
		Err(NotFound) => Err(NotHex)
	}

# ── tests

ann : Principal.Id
ann = Principal.Id.Human(Cast.gid(583231))

said : List(U8) -> MessageCodec.Fields
said = |body| {
	id: 3,
	at: 1761600000,
	by: ann,
	body,
}

## The message numbered `id`, of `body`.
numbered : U64, List(U8) -> MessageCodec.Fields
numbered = |id, body| {
	id,
	at: 1761600000,
	by: ann,
	body,
}

read_back : List(U8) -> Try(MessageCodec.Fields, Stored.Problem)
read_back = |raw| MessageCodec.decode(raw).map_ok(MessageCodec.Line.fields)

expect MessageCodec.encode(said(Str.to_utf8("two\nlines, 100%"))) == Str.to_utf8("message v1 id=3 at=1761600000 by=human:583231 body=two%0Alines, 100%25\n")
expect MessageCodec.encode(said(Str.to_utf8("é and 🎉"))) == Str.to_utf8("message v1 id=3 at=1761600000 by=human:583231 body=é and 🎉\n")
expect MessageCodec.encode(
	said([
		0xFF,
		'a',
	]),
) == Str.to_utf8("message v1 id=3 at=1761600000 by=human:583231 body=%FFa\n")

# **ANY BODY ROUND-TRIPS EXACTLY**: empty; every byte from 0 to 255, alone
# and all together; CRs and LFs; a `%` before hex digits; text and a stray
# byte in one body; spaces at the ends; a markdown table.
every_byte : List(U8)
every_byte = bytes_below(256)

bytes_below : U64 -> List(U8)
bytes_below = |n| {
	var $bytes = []
	var $b = 0
	while $b < n {
		$bytes = List.append($bytes, $b.to_u8_wrap())
		$b = $b + 1
	}
	$bytes
}

bodies : List(List(U8))
bodies = List.concat(
	[
		[],
		every_byte,
		Str.to_utf8("a\r\nb\rc\n\n"),
		Str.to_utf8("%41 is not A, %%"),
		List.concat(Str.to_utf8("é"), [0xC3]),
		Str.to_utf8("  ends with spaces  "),
		Str.to_utf8("| a | b |\n| - | - |\n| `x` | **y** |"),
	],
	List.map(every_byte, |b| [b]),
)

expect List.all(bodies, |body| read_back(MessageCodec.encode(said(body))) == Ok(said(body)))

# One spelling: lowercase hex, a needless escape, a bad escape, a raw
# control byte (Stored refuses the line: it is two).
expect read_back(Str.to_utf8("message v1 id=3 at=1 by=human:1 body=a%0ab\n")) == Err(BadValue("body"))
expect read_back(Str.to_utf8("message v1 id=3 at=1 by=human:1 body=%41\n")) == Err(BadValue("body"))
expect read_back(Str.to_utf8("message v1 id=3 at=1 by=human:1 body=%4\n")) == Err(BadValue("body"))
expect read_back(Str.to_utf8("message v1 id=3 at=1 by=human:1 body=%C3%A9\n")) == Err(BadValue("body"))
expect read_back(Str.to_utf8("message v1 id=0 at=1 by=human:1 body=x\n")) == Err(BadValue("id"))
expect read_back(Str.to_utf8("message v1 id=3 at=1 by=nobody:1 body=x\n")) == Err(UnknownWord("by"))

# Transcripts: none, in order, torn, out of order.
transcript_of : List(MessageCodec.Fields) -> List(U8)
transcript_of = |ms| List.join_map(ms, MessageCodec.encode)

expect MessageCodec.transcript([]).map_ok(|ls| List.len(ls)) == Ok(0)
three : List(MessageCodec.Fields)
three = [
	numbered(1, Str.to_utf8("a\nb")),
	numbered(2, []),
	numbered(3, Str.to_utf8("c")),
]

expect MessageCodec.transcript(transcript_of(three)).map_ok(
	|ls| List.map(
		ls,
		MessageCodec.Line.fields,
	),
) == Ok(three)
expect MessageCodec.transcript(
	List.drop_last(
		transcript_of([numbered(1, [])]),
		1,
	),
).map_ok(|ls| List.len(ls)) == Err(Torn)
expect MessageCodec.transcript(
	transcript_of([
		numbered(
			2,
			[],
		),
	]),
).map_ok(|ls| List.len(ls)) == Err(BadValue("id"))
expect MessageCodec.transcript(
	transcript_of([
		numbered(1, []),
		numbered(1, []),
	]),
).map_ok(|ls| List.len(ls)) == Err(BadValue("id"))
# A span: the ids from its first, as a slice of a transcript holds them.
expect MessageCodec.span(transcript_of(List.drop_first(three, 1)), 2).map_ok(|ls| List.map(ls, MessageCodec.Line.fields)) == Ok(List.drop_first(three, 1))
expect MessageCodec.span(transcript_of(List.drop_first(three, 1)), 1).map_ok(|ls| List.len(ls)) == Err(BadValue("id"))
