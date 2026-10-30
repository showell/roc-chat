## **THE CHAT'S ANSWERS ON THE WIRE**, as every route's module spells them:
## a JSON answer (never sniffed), a refusal in plain text, and text as a
## JSON string; and the two sizes every route shares (a form's most, a
## secret's bytes). Conversations, Agents and SignIn answer through here, so
## a JSON answer has one content type and one escape. Pure.
import pf.Chat

Wire := [].{

	## The most of a form's body: a name, a `with=`, a grant's fields.
	form_most : U64
	form_most = 4 * 1024

	## A secret's bytes of the OS's entropy: a session's, a state's nonce, a
	## key's and an invite's code alike.
	secret_bytes : U64
	secret_bytes = 32

	## A JSON answer: its status, its body, never sniffed.
	json : U16, List(U8) -> Chat.Answer
	json = |status, body| {
		..Chat.respond(
			status,
			{ content_type: Str.to_utf8("application/json; charset=utf-8"), body },
		),
		sniff: Forbid,
	}

	## A secret alone, a line of plain text, never sniffed: what an agent
	## stores as it is, with nothing to parse.
	secret : U16, List(U8) -> Chat.Answer
	secret = |status, hex| {
		..Chat.respond(
			status,
			{ content_type: Chat.text, body: hex.concat(['\n']) },
		),
		sniff: Forbid,
	}

	## A refusal: its status, and why, a line of plain text.
	refused : U16, Str -> Chat.Answer
	refused = |status, why| Chat.respond(
		status,
		{ content_type: Chat.text, body: Str.to_utf8("${why}\n") },
	)

	## **TEXT AS A JSON STRING**: quoted, its `"` and `\` escaped, and every
	## control byte as `\u00XX`, so the string is one line. The text is UTF-8
	## (a post's is checked; roc-markdown's html of it is too).
	json_string : List(U8) -> List(U8)
	json_string = |text|
		[
			['"'],
			text.join_map(
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
		].join()

	## Each part, a comma between each two.
	commas : List(List(U8)) -> List(U8)
	commas = |parts| parts.map_with_index(|part, i| if (i == 0) part else part.prepend(',')).join()
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

expect Wire.json_string("a\"b\\c\nd\re\u(7f)é".to_utf8()) == "\"a\\\"b\\\\c\\nd\\u000de\\u007fé\"".to_utf8()
expect Wire.commas(["a".to_utf8(), "b".to_utf8()]) == "a,b".to_utf8()
