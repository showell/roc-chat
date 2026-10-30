## **JSON BUILT, NEVER SPLICED**: a value is made only by this module's
## builders (`text`, `string`, `number`, `signed`, `bool`, `array`,
## `object`), so every field of every answer is a whole value, escaped: no
## quote in a name ends a string, and no text becomes a field. Opaque
## (`::`); `bytes` is the only way out, and Wire.json the only taker of a
## whole answer. No spaces; fields and items in the order given. Pure.
JsonOut :: List(U8).{

	## **TEXT AS A JSON STRING**: quoted, its `"` and `\` escaped, a line
	## feed as `\n`, and every other control byte (and DEL) as `\u00XX`, so
	## the string is one line, as an SSE `data:` line needs. The text is
	## UTF-8 (a post's is checked; roc-markdown's html of it is too).
	text : List(U8) -> JsonOut
	text = |bytes|
		JsonOut.(
			[
				['"'],
				bytes.join_map(
					|b|
						if b == '"' {
							['\\', '"']
						} else if b == '\\' {
							['\\', '\\']
						} else if b == '\n' {
							['\\', 'n']
						} else if b < 0x20 or b == 0x7F {
							"\\u00".to_utf8().concat([hex_digit(b // 16), hex_digit(b % 16)])
						} else {
							[b]
						},
				),
				['"'],
			].join(),
		)

	## A `Str` as a JSON string, as `text` writes its bytes.
	string : Str -> JsonOut
	string = |s| JsonOut.text(s.to_utf8())

	## A whole number, in decimal.
	number : U64 -> JsonOut
	number = |n| JsonOut.(n.to_str().to_utf8())

	## A signed whole number (a time), in decimal.
	signed : I64 -> JsonOut
	signed = |n| JsonOut.(n.to_str().to_utf8())

	## `true` or `false`.
	bool : Bool -> JsonOut
	bool = |b| JsonOut.((if (b) "true" else "false").to_utf8())

	## The values in order: `[a,b]`.
	array : List(JsonOut) -> JsonOut
	array = |items|
		JsonOut.(
			[
				['['],
				commas(items.map(JsonOut.bytes)),
				[']'],
			].join(),
		)

	## The fields in order, each a name and a value: `{"name":value,...}`.
	## A name is escaped as text is.
	object : List((Str, JsonOut)) -> JsonOut
	object = |fields|
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
	bytes = |JsonOut.(b)| b
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

## Each part, a comma between each two.
commas : List(List(U8)) -> List(U8)
commas = |parts| parts.map_with_index(|part, i| if (i == 0) part else part.prepend(',')).join()

# A quote, a backslash, a line feed, a carriage return, DEL and a
# multi-byte character: each as the wire has always spelled it.
expect JsonOut.text("a\"b\\c\nd\re\u(7f)é".to_utf8()).bytes() == "\"a\\\"b\\\\c\\nd\\u000de\\u007fé\"".to_utf8()
# A name holding a quote, a backslash and a control byte stays one string.
expect
	JsonOut.object([
		("name", JsonOut.string("Bea \"B\" \\ \u(01)")),
		("n", JsonOut.number(3)),
	]).bytes()
		== "{\"name\":\"Bea \\\"B\\\" \\\\ \\u0001\",\"n\":3}".to_utf8()
expect JsonOut.object([]).bytes() == "{}".to_utf8()
expect JsonOut.array([]).bytes() == "[]".to_utf8()
expect JsonOut.array([JsonOut.bool(Bool.True), JsonOut.signed(-3)]).bytes() == "[true,-3]".to_utf8()
# A field's name is escaped too.
expect JsonOut.object([("a\"b", JsonOut.bool(Bool.False))]).bytes() == "{\"a\\\"b\":false}".to_utf8()
