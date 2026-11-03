## This module reads a form's body as a browser sends it, encoded as
## `application/x-www-form-urlencoded`: `name=value` fields joined by `&`,
## in which each `+` is a space and each `%XX` is the byte XX. A form is
## read in bytes, because the decoding happens before the text is known to
## be UTF-8. The field a caller asks for comes out as an
## `UnvalidatedString`, as unchecked as the rest of the request, or as a
## refusal.
import UnvalidatedString

UrlEncodedForm :: [].{

	## The field that holds a message's markdown, decoded, from a message
	## form's `body`; or why there is none (see `field`).
	markdown_field : List(U8) -> Try(
		UnvalidatedString,
		[
			MissingField,
			RepeatedField,
			BadEscape,
			NotUtf8,
		],
	)
	markdown_field = |body| UrlEncodedForm.field({ body, name: UrlEncodedForm.markdown_name })

	## The name of the field that holds a message's markdown. The compose
	## box's textarea takes this name (`Page`).
	markdown_name : Str
	markdown_name = "markdown"

	## The field `name` of `body`, decoded and still unchecked; unless the body
	## has no such field (`MissingField`), has it more than once
	## (`RepeatedField`), has a `%` in it that is not followed by two hex digits
	## (`BadEscape`), or its decoded value is not UTF-8 (`NotUtf8`).
	field : { body : List(U8), name : Str } -> Try(
		UnvalidatedString,
		[
			MissingField,
			RepeatedField,
			BadEscape,
			NotUtf8,
		],
	)
	field = |{ body, name }| {
		wanted = name.to_utf8()
		values = body.split_on('&').keep_if(|pair| field_name(pair) == wanted).map(field_value)
		match values {
			[] => Err(MissingField)
			[value] => {
				bytes = decode_value(value)?
				UnvalidatedString.from_utf8(bytes)
			}
			_ => Err(RepeatedField)
		}
	}
}

## A field's name: its bytes before the first `=`, or all of them when
## there is none. Names are compared undecoded, since the one a caller asks
## for needs no escape.
field_name : List(U8) -> List(U8)
field_name = |pair|
	match pair.split_first('=') {
		Ok({ before, after: _ }) => before
		Err(NotFound) => pair
	}

## A field's value: its bytes after the first `=`, or none when there is
## none.
field_value : List(U8) -> List(U8)
field_value = |pair|
	match pair.split_first('=') {
		Ok({ before: _, after }) => after
		Err(NotFound) => []
	}

## `value` decoded: each `+` a space, and each `%XX` the byte XX, its hex
## digits in either case.
decode_value : List(U8) -> Try(List(U8), [BadEscape])
decode_value = |value| decode_value_onto({ out: [], rest: value })

decode_value_onto : { out : List(U8), rest : List(U8) } -> Try(List(U8), [BadEscape])
decode_value_onto = |{ out, rest }|
	match rest {
		[] => Ok(out)
		[
			'%',
			high,
			low,
			.. as after,
		] =>
			match (hex_value(high), hex_value(low)) {
				(Ok(h), Ok(l)) => decode_value_onto({ out: out.append(h * 16 + l), rest: after })
				_ => Err(BadEscape)
			}
		['%', ..] => Err(BadEscape)
		['+', .. as after] => decode_value_onto({ out: out.append(' '), rest: after })
		[byte, .. as after] => decode_value_onto({ out: out.append(byte), rest: after })
	}

## The value of one hex digit, in either case.
hex_value : U8 -> Try(U8, [NotHex])
hex_value = |digit|
	if (digit >= '0' and digit <= '9')
		Ok(digit - '0')
	else if (digit >= 'a' and digit <= 'f')
		Ok(digit - 'a' + 10)
	else if (digit >= 'A' and digit <= 'F')
		Ok(digit - 'A' + 10)
	else
		Err(NotHex)

# ── tests
# Each range's ends, and the byte just outside each.
expect
	[
		('0', Ok(0)),
		('9', Ok(9)),
		('a', Ok(10)),
		('f', Ok(15)),
		('A', Ok(10)),
		('F', Ok(15)),
		('/', Err(NotHex)),
		(':', Err(NotHex)),
		('`', Err(NotHex)),
		('g', Err(NotHex)),
		('@', Err(NotHex)),
		('G', Err(NotHex)),
	].all(|(digit, expected)| hex_value(digit) == expected)

## The markdown of a message form's `body`, as a test reads it, or why
## there is none.
markdown_of : Str -> Try(Str, [MissingField, RepeatedField, BadEscape, NotUtf8, Blank])
markdown_of = |body| {
	value = UrlEncodedForm.markdown_field(body.to_utf8())?
	value.markdown()
}

expect markdown_of("markdown=Hello+there%21") == Ok("Hello there!")
expect markdown_of("x=1&markdown=a%0D%0Ab&y=2") == Ok("a\nb")
expect markdown_of("markdown=Zo%C3%AB+%F0%9F%8E%89") == Ok("Zoë 🎉")
expect markdown_of("markdown=%2B%26%3D%25") == Ok("+&=%")
expect markdown_of("markdown=a=b") == Ok("a=b")
expect markdown_of("markdown=%2a%2A") == Ok("**")
# Both sides of each refusal.
expect markdown_of("") == Err(MissingField)
expect markdown_of("markdowns=x&mark=y") == Err(MissingField)
expect markdown_of("mark%64own=x") == Err(MissingField)
expect markdown_of("markdown=a&markdown=b") == Err(RepeatedField)
expect markdown_of("markdown=%") == Err(BadEscape)
expect markdown_of("markdown=%4") == Err(BadEscape)
expect markdown_of("markdown=%G1") == Err(BadEscape)
expect markdown_of("markdown=%1G") == Err(BadEscape)
expect markdown_of("markdown=%FF") == Err(NotUtf8)
expect markdown_of("markdown=") == Err(Blank)
expect markdown_of("markdown") == Err(Blank)
expect markdown_of("markdown=+%0A") == Err(Blank)
