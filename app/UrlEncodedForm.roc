## **A FORM'S BODY, AS A BROWSER SENDS IT** (`application/x-www-form-urlencoded`):
## `name=value` fields joined by `&`, each `+` a space and each `%XX` a byte.
## Parsing at the door, so it works in bytes; the one field a caller asks
## for comes out as an `UnvalidatedString`, as unchecked as the rest of the
## request, or a refusal's tag.
import UnvalidatedString

UrlEncodedForm :: [].{

	## **THE FIELD `markdown` OF `body`**, a message's form, decoded, as
	## `field` reads it.
	markdown_field : List(U8) -> Try(
		UnvalidatedString,
		[
			MissingField,
			RepeatedField,
			BadEscape,
			NotUtf8,
		],
	)
	markdown_field = |body| field({ body, name: UrlEncodedForm.markdown_name })

	## **THE NAME OF A MESSAGE'S FIELD**, `markdown`: its one home, which
	## `markdown_field` reads and the compose box's textarea is named
	## (`Page`).
	markdown_name : Str
	markdown_name = "markdown"
}

## **THE FIELD `name` OF `body`**, decoded, still unchecked; unless the
## body has no such field (`MissingField`), has it more than once
## (`RepeatedField`), a `%` starts no two hex digits there (`BadEscape`),
## or the decoded value is not UTF-8 (`NotUtf8`).
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
			bytes = decoded(value)?
			UnvalidatedString.from_utf8(bytes)
		}
		_ => Err(RepeatedField)
	}
}

## A field's name: its bytes before the first `=` (all of them when there
## is none). Names are compared undecoded: the ones asked for need no
## escape.
field_name : List(U8) -> List(U8)
field_name = |pair|
	match pair.split_first('=') {
		Ok({ before, after: _ }) => before
		Err(NotFound) => pair
	}

## A field's value: its bytes after the first `=` (none when there is none).
field_value : List(U8) -> List(U8)
field_value = |pair|
	match pair.split_first('=') {
		Ok({ before: _, after }) => after
		Err(NotFound) => []
	}

## `value` decoded: `+` a space, `%XX` the byte XX (hex, either case).
decoded : List(U8) -> Try(List(U8), [BadEscape])
decoded = |value| decoded_onto([], value)

decoded_onto : List(U8), List(U8) -> Try(List(U8), [BadEscape])
decoded_onto = |so_far, rest|
	match rest {
		[] => Ok(so_far)
		[
			'%',
			high,
			low,
			.. as after,
		] =>
			match (hex(high), hex(low)) {
				(Ok(h), Ok(l)) => decoded_onto(so_far.append(h * 16 + l), after)
				_ => Err(BadEscape)
			}
		['%', ..] => Err(BadEscape)
		['+', .. as after] => decoded_onto(so_far.append(' '), after)
		[byte, .. as after] => decoded_onto(so_far.append(byte), after)
	}

## The value of one hex digit.
hex : U8 -> Try(U8, [NotHex])
hex = |digit|
	if (digit >= '0' and digit <= '9')
		Ok(digit - '0')
	else if (digit >= 'a' and digit <= 'f')
		Ok(digit - 'a' + 10)
	else if (digit >= 'A' and digit <= 'F')
		Ok(digit - 'A' + 10)
	else
		Err(NotHex)

# ── tests
## The field `name` of `body`, as a test reads it: its markdown, or why not.
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
expect markdown_of("markdown=a&markdown=b") == Err(RepeatedField)
expect markdown_of("markdown=%") == Err(BadEscape)
expect markdown_of("markdown=%4") == Err(BadEscape)
expect markdown_of("markdown=%G1") == Err(BadEscape)
expect markdown_of("markdown=%FF") == Err(NotUtf8)
expect markdown_of("markdown=") == Err(Blank)
expect markdown_of("markdown") == Err(Blank)
expect markdown_of("markdown=+%0A") == Err(Blank)
