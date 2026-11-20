## This module builds JSON; nothing else writes it. A value is made only by
## its builders (`string`, `zero`, `number`, `array`, `json_object`), so every field of every
## answer is a whole value, escaped: no quote in a name ends a string, and
## no text becomes a field. The type is opaque, and `bytes` is its only way
## out; `HttpAnswer.json` is the only taker of a whole answer. It writes no
## spaces, and fields in the order given.
import Hex

JsonOut :: List(U8).{

	## Text as a JSON string: quoted, its `"` and `\` escaped, a line feed
	## as `\n`, and every other control byte (and DEL) as `\u00XX`, so the
	## string is one line.
	string : Str -> JsonOut
	string = |text|
		JsonOut.(
			[
				['"'],
				text.to_utf8().join_map(
					|byte|
						if byte == '"' {
							['\\', '"']
						} else if byte == '\\' {
							['\\', '\\']
						} else if byte == '\n' {
							['\\', 'n']
						} else if byte < 0x20 or byte == 0x7F {
							"\\u00${Hex.to_hex([byte])}".to_utf8()
						} else {
							[byte]
						},
				),
				['"'],
			].join(),
		)

	## The number 0: an upload's answer gives its image no size.
	zero : JsonOut
	zero = JsonOut.("0".to_utf8())

	## A number, its decimal digits: a message's id in an agent's stream.
	number : U64 -> JsonOut
	number = |value| JsonOut.(value.to_str().to_utf8())

	## The values in order: `[value,...]`, as search's answers list words
	## and messages.
	array : List(JsonOut) -> JsonOut
	array = |values| JsonOut.([['['], commas(values.map(JsonOut.bytes)), [']']].join())

	## The fields in order, each a name and a value: `{"name":value,...}`.
	## A name is escaped as a string is.
	json_object : List((Str, JsonOut)) -> JsonOut
	json_object = |fields|
		JsonOut.(
			[
				['{'],
				commas(
					fields.map(
						|(name, value)| [
							JsonOut.bytes(JsonOut.string(name)),
							[':'],
							JsonOut.bytes(value),
						].join(),
					),
				),
				['}'],
			].join(),
		)

	## The value's bytes.
	bytes : JsonOut -> List(U8)
	bytes = |JsonOut.(written)| written
}

## Each part, a comma between each two.
commas : List(List(U8)) -> List(U8)
commas = |parts| parts.map_with_index(
	|part, index|
		if index == 0 {
			part
		} else {
			part.prepend(',')
		},
).join()

# ── tests
# A quote, a backslash, a line feed, a carriage return, DEL and a
# multi-byte character: each as the wire spells it.
expect
	JsonOut.string("a\"b\\c\nd\re\u(7f)é").bytes()
		== "\"a\\\"b\\\\c\\nd\\u000de\\u007fé\"".to_utf8()
expect JsonOut.string("").bytes() == "\"\"".to_utf8()
# Each edge of the escaped bytes: 0x1F escaped and 0x20, a space, kept;
# 0x7E kept and 0x7F, DEL, escaped.
expect JsonOut.string("\u(1f) ~\u(7f)").bytes() == "\"\\u001f ~\\u007f\"".to_utf8()
expect JsonOut.zero.bytes() == "0".to_utf8()
expect
	[
		(0, "0"),
		(7, "7"),
		(18446744073709551615, "18446744073709551615"),
	].all(|(n, digits)| JsonOut.number(n).bytes() == digits.to_utf8())
# A name holding a quote, a backslash and a control byte stays one string.
expect
	JsonOut.json_object([
		("name", JsonOut.string("Bea \"B\" \\ \u(01)")),
		("n", JsonOut.zero),
	]).bytes()
		== "{\"name\":\"Bea \\\"B\\\" \\\\ \\u0001\",\"n\":0}".to_utf8()
expect JsonOut.json_object([]).bytes() == "{}".to_utf8()
expect JsonOut.array([]).bytes() == "[]".to_utf8()
expect JsonOut.array([JsonOut.zero, JsonOut.string("a")]).bytes() == "[0,\"a\"]".to_utf8()
# A field's name is escaped too, and an object nests.
expect
	JsonOut.json_object([("a\"b", JsonOut.json_object([("c", JsonOut.zero)]))]).bytes()
		== "{\"a\\\"b\":{\"c\":0}}".to_utf8()
