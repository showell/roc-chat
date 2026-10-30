## **THE STORE'S LINE FORMAT**: every record the app stores (an account,
## a session, an API key, an invite, an audit entry, a conversation, a
## message) is one line of text a person reads with `cat`:
##
##     account v1 kind=human github=583231 login=octocat generation=3 role=admin name=Steve H.
##
## - **The record's kind and the format's version come first,** so a line
##   handed to the wrong decoder, or written by a later format, is refused
##   by name, never half read.
## - **Then `name=value` fields, each once, in one fixed order,** one space
##   between. A decoder reads exactly the fields it expects, in order, so a
##   field missing, doubled, out of order or unknown is refused, never
##   skipped or guessed.
## - **A value holds no space,** except a record's one free-text field (a
##   name), which comes last and runs to the end of the line: no text a
##   person chose can forge a field after it.
## - **The line ends in exactly one newline.** A record without it is a torn
##   write, and refused.
## - **Every value has one spelling** (a number without leading zeros, a hash
##   in lowercase hex), so a record's bytes round-trip, not only its value.
##
## Why lines: one record a line makes a store a file of lines (the audit log
## is appended to, an attempt a line), `grep` finds a record, a torn append
## is visible, and a reader needs no other tool. Why not JSON: it has many
## spellings of one value, and a decoder that accepts them all is a decoder
## that guesses. Each codec (AccountCodec, SessionCodec, KeyCodec,
## InviteCodec, AuditCodec, ConvCodec, MessageCodec) decodes into the core's types here, at the door. Pure.
import Ascii
import Bytes

Stored := [].{

	## The format's version, written after every record's kind.
	version : Str
	version = "v1"

	## **WHY A STORED RECORD IS REFUSED**, one name each. A field's name is
	## the payload where one field is at fault. **ONE ALIAS ON PURPOSE**:
	## every codec reads its line through Reader, so each decoder can fail
	## with nearly all of these, and its callers pass the refusal on whole
	## (only the audit's decoder looks inside, trying the next kind on
	## `WrongRecord`); a decoder's tags listed in place would be this list
	## copied into each codec.
	Problem : [
		## No newline at the end: a torn write.
		Torn,

		## A newline before the end: more than one record.
		ExtraLine,

		## Bytes that are not UTF-8.
		NotUtf8,

		## Another kind of record (a session's line handed to the account
		## decoder).
		WrongRecord,

		## A version this decoder does not know.
		UnknownVersion,

		## The field expected next is not there: missing, out of order,
		## doubled, or another field in its place.
		MissingField(Str),

		## Bytes after the last field.
		Trailing,

		## A number that is not one spelling of one number (`007`, `+7`, `-0`,
		## empty, too big).
		BadNumber(Str),

		## A word outside the field's closed set.
		UnknownWord(Str),

		## A value its type refuses: an id of 0, a hash of the wrong length,
		## a name the name rule refuses, a login GitHub would not give.
		BadValue(Str),

		## A session seen before it was created (SessionCodec).
		SeenBeforeCreated,

		## A key acting as a bot with admin scope, which no grant makes
		## (KeyCodec).
		AdminForBot,
	]

	## **A STORED SECRET'S HASH**: 32 bytes, as SHA-256 gives them. What the
	## store keeps of an API key and of a session's cookie, never the secret
	## itself; the host hashes, and looks up by the hash. Opaque: made only
	## by `from_bytes`, which refuses any other length.
	SecretHash :: List(U8).{
		from_bytes : List(U8) -> Try(Stored.SecretHash, [NotAHash])
		from_bytes = |bytes|
			if bytes.len() == hash_bytes {
				Ok(Stored.SecretHash.(bytes))
			} else {
				Err(NotAHash)
			}

		bytes : Stored.SecretHash -> List(U8)
		bytes = |Stored.SecretHash.(b)| b

		is_eq : _
	}

	## **THE ONE LINE OF A RECORD**: its kind, the version, then each field
	## as `name=value`, a space before each, and the newline. Only the last
	## value may hold a space; no value holds a control byte. The codecs
	## make their values from types that hold neither (a free-text value is
	## checked by its rule first), so a value that does is a bug: a crash.
	line : Str, List((Str, Str)) -> List(U8)
	line = |kind, fields| {
		last = fields.len()
		parts = fields.map_with_index(
			|(name, value), i| {
				bytes = value.to_utf8()
				if bytes.any(Ascii.is_control) {
					crash "Stored.line: a value holds a control byte"
				} else if i + 1 < last and bytes.contains(' ') {
					crash "Stored.line: a value before the last holds a space"
				} else {
					" ${name}=${value}"
				}
			},
		)
		Str.to_utf8("${kind} ${Stored.version}${Str.join_with(parts, "")}\n")
	}

	## **THE FIELDS OF ONE RECORD, READ IN ORDER**: what is left of its line.
	## Opaque: made only by `open`, which has checked the line whole.
	Reader :: List(U8).{

		## A record of `kind`: one line, its newline at the end and nowhere
		## else, UTF-8, the kind and the version known.
		open : List(U8), Str -> Try(Stored.Reader, Stored.Problem)
		open = |raw, kind|
			match raw.split_last('\n') {
				Err(NotFound) => Err(Torn)
				Ok({ before, after }) =>
					if after != [] {
						Err(Torn)
					} else if before.contains('\n') {
						Err(ExtraLine)
					} else if Str.from_utf8(before).is_err() {
						Err(NotUtf8)
					} else {
						match Bytes.strip_prefix(before, Str.to_utf8("${kind} ")) {
							Err(NoMatch) => Err(WrongRecord)
							Ok(rest) => {
								version_end = Bytes.count_while(rest, |c| c != ' ')
								if rest.take_first(version_end) == Stored.version.to_utf8() {
									Ok(Stored.Reader.(rest.drop_first(version_end)))
								} else {
									Err(UnknownVersion)
								}
							}
						}
					}
			}

		## The value of the field `name`, which must come next, and the
		## fields after it.
		field : Stored.Reader,
		Str -> Try(
			{ value : List(U8), rest : Stored.Reader },
			Stored.Problem,
		)
		field = |Stored.Reader.(rest), name|
			match Bytes.strip_prefix(rest, Str.to_utf8(" ${name}=")) {
				Err(NoMatch) => Err(MissingField(name))
				Ok(after) => {
					end = Bytes.count_while(after, |c| c != ' ')
					Ok({
						value: after.take_first(end),
						rest: Stored.Reader.(after.drop_first(end)),
					})
				}
			}

		## The free-text field `name`, which must come next and is the last:
		## the rest of the line, spaces and all.
		text : Stored.Reader, Str -> Try(Str, Stored.Problem)
		text = |Stored.Reader.(rest), name|
			match Bytes.strip_prefix(rest, Str.to_utf8(" ${name}=")) {
				Err(NoMatch) => Err(MissingField(name))
				Ok(after) =>
					match Str.from_utf8(after) {
						Ok(value) => Ok(value)
						Err(_) => crash "Stored.Reader.text: `open` checked the line is UTF-8"
					}
			}

		## Nothing after the last field.
		close : Stored.Reader -> Try({}, Stored.Problem)
		close = |Stored.Reader.(rest)| if (rest == []) Ok({}) else Err(Trailing)
	}

	## **A COUNT OR AN ID**: decimal digits, the first not `0` unless it is
	## the only one, and it fits a U64. `U64.from_str` is not asked to
	## judge: it takes `+7`, `1_000` and `0x10` too.
	count : List(U8), Str -> Try(U64, Stored.Problem)
	count = |value, name|
		if is_canonical_digits(value) {
			U64.from_int_digits(List.map(value, |c| c - '0')).map_err(|_| BadNumber(name))
		} else {
			Err(BadNumber(name))
		}

	## **AN ID**: a count, made into its type by `make` (the id's own
	## `from_u64`, which refuses 0).
	id : List(U8), { name : Str, make : (U64 -> Try(a, [NotAnId])) } -> Try(a, Stored.Problem)
	id = |value, { name, make }| {
		n = Stored.count(value, name)?
		match make(n) {
			Ok(made) => Ok(made)
			Err(_) => Err(BadValue(name))
		}
	}

	## **THE LATEST TIME A RECORD MAY HOLD**: the last second of the year
	## 9999. A stored time is from the host's clock, so one before 1970 or
	## past this is no record the chat wrote; bounding it keeps every sum
	## and difference of two stored times far inside an I64.
	max_time : I64
	max_time = 253402300799

	## **A TIME**: unix seconds, as `count` spells a number, from 0 to
	## `max_time`; nothing before 1970 (no minus sign) and nothing past it.
	time : List(U8), Str -> Try(I64, Stored.Problem)
	time = |value, name| {
		n = Stored.count(value, name)?
		if n > Stored.max_time.to_u64_wrap() {
			Err(BadNumber(name))
		} else {
			Ok(n.to_i64_wrap())
		}
	}

	## A time as `time` reads it. A time outside `time`'s range is not one
	## the clock gave: a crash, as a control byte in a value is. No caller
	## reaches it: every time written is refused upstream when out of range
	## (a sign-in's and an admin decision's clock, ClockOutOfRange; a key's
	## creation and expiry, ApiKey's grant and KeyCodec.is_fitting_expiry; a
	## session's touch, Session.liveness), or was read back by `time`.
	time_text : I64 -> Str
	time_text = |t|
		if t < 0 or t > Stored.max_time {
			crash "Stored.time_text: a stored time is from 1970 to 9999"
		} else {
			t.to_str()
		}

	## **A WORD FROM A CLOSED SET**: the member of `all` whose `spell` it is.
	## `spell` is the one home of each member's word (an exhaustive match);
	## `all` lists the members, and each codec's round trips hold it whole.
	word : List(U8),
	{
		name : Str,
		all : List(a),
		spell : (a -> Str),
	} -> Try(a, Stored.Problem)
	word = |
		value,
		{
			name,
			all,
			spell,
		},
	|
		match all.find_first(|member| spell(member).to_utf8() == value) {
			Ok(member) => Ok(member)
			Err(NotFound) => Err(UnknownWord(name))
		}

	## **A HASH**: 64 lowercase hex digits, its 32 bytes.
	hash : List(U8), Str -> Try(Stored.SecretHash, Stored.Problem)
	hash = |value, name|
		if value.len() != hash_bytes * digits_per_byte {
			Err(BadValue(name))
		} else {
			nibbles = value.map_try(|c| hex_digits.find_first_index(|d| d == c))
			match nibbles {
				Err(NotFound) => Err(BadValue(name))
				Ok(ns) => {
					bytes = ns.chunks_of(digits_per_byte).map(
						|pair| match pair {
							[high, low] => high.to_u8_wrap() * nibble_base + low.to_u8_wrap()
							_ => crash "Stored.hash: an even count of nibbles chunks into pairs"
						},
					)
					match Stored.SecretHash.from_bytes(bytes) {
						Ok(h) => Ok(h)
						Err(NotAHash) => crash "Stored.hash: 64 nibbles are 32 bytes"
					}
				}
			}
		}

	## A hash as `hash` reads it: lowercase hex.
	hash_text : Stored.SecretHash -> Str
	hash_text = |h| {
		digits = h.bytes().join_map(
			|b| [
				hex_digit(b // nibble_base),
				hex_digit(b % nibble_base),
			],
		)
		match Str.from_utf8(digits) {
			Ok(text) => text
			Err(_) => crash "Stored.hash_text: hex digits are UTF-8"
		}
	}
}

## SHA-256's size, in bytes.
hash_bytes : U64
hash_bytes = 32

## A byte's two hex digits are its high and low halves, each below this.
nibble_base : U8
nibble_base = 16

## A byte is two hex digits.
digits_per_byte : U64
digits_per_byte = 2

## The hex digits, each at its own value: the one home of the spelling.
hex_digits : List(U8)
hex_digits = "0123456789abcdef".to_utf8()

hex_digit : U8 -> U8
hex_digit = |n|
	match hex_digits.get(n.to_u64()) {
		Ok(d) => d
		Err(_) => crash "Stored.hex_digit: a nibble is below 16"
	}

## Decimal digits, one spelling of their number: `0`, or no leading `0`.
is_canonical_digits : List(U8) -> Bool
is_canonical_digits = |value|
	match value {
		['0'] => Bool.True
		[first, ..] => first != '0' and value.all(Ascii.is_digit)
		[] => Bool.False
	}

# ── tests

## The fields of `raw`, a record of kind `t`.
reader : Str -> Stored.Reader
reader = |raw|
	match Stored.Reader.open(raw.to_utf8(), "t") {
		Ok(r) => r
		Err(_) => crash "reader: a test's line opens"
	}

# A line, made and read back.
expect
	Stored.line("t", [("a", "1"), ("b", "two words")])
		== "t v1 a=1 b=two words\n".to_utf8()
expect Stored.line("t", []) == "t v1\n".to_utf8()

two_fields : Str -> Try({ a : List(U8), b : Str }, Stored.Problem)
two_fields = |raw| {
	first = reader(raw).field("a")?
	b = first.rest.text("b")?
	Ok({ a: first.value, b })
}

expect two_fields("t v1 a=1 b=two words\n") == Ok({ a: "1".to_utf8(), b: "two words" })
expect two_fields("t v1 a=1 b=x a=2\n") == Ok({ a: "1".to_utf8(), b: "x a=2" })

# Opening: each malformed line, its problem.
opened : Str -> Try({}, Stored.Problem)
opened = |raw| Stored.Reader.open(raw.to_utf8(), "t").map_ok(|_| {})

expect opened("t v1\n") == Ok({})
expect opened("") == Err(Torn)
expect opened("t v1") == Err(Torn)
expect opened("t v1\nt v1\n") == Err(ExtraLine)
expect opened("u v1\n") == Err(WrongRecord)
expect opened("tt v1\n") == Err(WrongRecord)
expect opened("t v2\n") == Err(UnknownVersion)
expect opened("t v10\n") == Err(UnknownVersion)
expect opened("t\n") == Err(WrongRecord)
expect Stored.Reader.open(
	[
		0x74,
		0x20,
		0x76,
		0x31,
		0xff,
		'\n',
	],
	"t",
).map_ok(|_| {}) == Err(NotUtf8)

# Fields: the one expected, in its place, or its name.
field_a : Str -> Try(List(U8), Stored.Problem)
field_a = |raw| reader(raw).field("a").map_ok(|f| f.value)

expect field_a("t v1 a=7\n") == Ok("7".to_utf8())
expect field_a("t v1 a=\n") == Ok([])
expect field_a("t v1 b=7\n") == Err(MissingField("a"))
expect field_a("t v1  a=7\n") == Err(MissingField("a"))
expect field_a("t v1 A=7\n") == Err(MissingField("a"))
expect field_a("t v1\n") == Err(MissingField("a"))
expect reader("t v1\n").close() == Ok({})
expect reader("t v1 \n").close() == Err(Trailing)

# Numbers: one spelling each.
expect Stored.count("0".to_utf8(), "n") == Ok(0)
expect Stored.count("583231".to_utf8(), "n") == Ok(583231)
expect Stored.count("18446744073709551615".to_utf8(), "n") == Ok(18446744073709551615)
expect
	[
		"",
		"007",
		"+7",
		"-7",
		"1_000",
		"0x10",
		"7 ",
		"18446744073709551616",
	].all(|bad| Stored.count(bad.to_utf8(), "n") == Err(BadNumber("n")))
expect Stored.time("1761600000".to_utf8(), "t") == Ok(1761600000)
expect Stored.time("253402300799".to_utf8(), "t") == Ok(Stored.max_time)
# Before 1970, past 9999, and I64's ends (a session created at I64's
# minimum would overflow its liveness): refused.
expect
	[
		"",
		"-",
		"-0",
		"-5",
		"-05",
		"05",
		"+5",
		"253402300800",
		"9223372036854775807",
		"9223372036854775808",
		"-9223372036854775808",
	].all(|bad| Stored.time(bad.to_utf8(), "t") == Err(BadNumber("t")))
expect
	[
		0,
		1,
		1761600000,
		Stored.max_time,
	].all(|t| Stored.time(Stored.time_text(t).to_utf8(), "t") == Ok(t))

# Words: the closed set, and nothing near it.
Colour : [Red, Green]

spell_colour : Colour -> Str
spell_colour = |c|
	match c {
		Red => "red"
		Green => "green"
	}

colour : Str -> Try(Colour, Stored.Problem)
colour = |text| Stored.word(
	text.to_utf8(),
	{
		name: "c",
		all: [Red, Green],
		spell: spell_colour,
	},
)

expect colour("red") == Ok(Red)
expect colour("green") == Ok(Green)
expect colour("Red") == Err(UnknownWord("c"))
expect colour("") == Err(UnknownWord("c"))
expect colour("reds") == Err(UnknownWord("c"))

# Hashes: 64 lowercase hex digits, round trip both ways.
## A test's hash: byte `i` is `i` times `step`.
hash_stepping : U8 -> Stored.SecretHash
hash_stepping = |step|
	match Stored.SecretHash.from_bytes(
		Iter.fold(
			U8.to(0, 31),
			[],
			|acc, b| acc.append(b * step),
		),
	) {
		Ok(h) => h
		Err(NotAHash) => crash "hash_stepping: 32 bytes are a hash"
	}

some_hash : Stored.SecretHash
some_hash = hash_stepping(7)

expect Stored.hash_text(some_hash) == "00070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9"
expect Stored.hash(Stored.hash_text(some_hash).to_utf8(), "h") == Ok(some_hash)
expect Stored.hash(
	"00070E151C232A31383F464D545B626970777E858C939AA1A8AFB6BDC4CBD2D9".to_utf8(),
	"h",
) == Err(BadValue("h"))
expect Stored.hash("00070e".to_utf8(), "h") == Err(BadValue("h"))
expect Stored.hash(
	"g0070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9".to_utf8(),
	"h",
) == Err(BadValue("h"))
expect Stored.SecretHash.from_bytes([
	1,
	2,
	3,
]) == Err(NotAHash)
