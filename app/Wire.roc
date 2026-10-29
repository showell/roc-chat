## **THE CHAT'S ANSWERS ON THE WIRE**, as every route's module spells them:
## a JSON answer (never sniffed), a refusal in plain text, and text as a
## JSON string. Conversations and Agents answer through here, so a JSON
## answer has one content type and one escape. Pure.
import pf.Chat

Wire := [].{

	## A JSON answer: its status, its body, never sniffed.
	json : U16, List(U8) -> Chat.Answer
	json = |status, body| {
		..Chat.respond(status, { content_type: Str.to_utf8("application/json; charset=utf-8"), body }),
		sniff: Forbid,
	}

	## A refusal: its status, and why, a line of plain text.
	refused : U16, Str -> Chat.Answer
	refused = |status, why| Chat.respond(status, { content_type: Chat.text, body: Str.to_utf8("${why}\n") })

	## **TEXT AS A JSON STRING**: quoted, its `"` and `\` escaped, and every
	## control byte as `\u00XX`, so the string is one line. The text is UTF-8
	## (a post's is checked; roc-markdown's html of it is too).
	json_string : List(U8) -> List(U8)
	json_string = |text|
		List.join([
			['"'],
			List.join_map(
				text,
				|b|
					if b == '"' {
						['\\', '"']
					} else if b == '\\' {
						['\\', '\\']
					} else if b == '\n' {
						['\\', 'n']
					} else if b < 0x20 or b == 0x7F {
						List.concat(Str.to_utf8("\\u00"), [hex_digit(b // 16), hex_digit(b % 16)])
					} else {
						[b]
					},
			),
			['"'],
		])

	## Each part, a comma between each two.
	commas : List(List(U8)) -> List(U8)
	commas = |parts| List.join(List.map_with_index(parts, |part, i| if i == 0 part else List.prepend(part, ',')))
}

hex_digit : U8 -> U8
hex_digit = |n| if n < 10 '0' + n else 'a' + n - 10

expect Wire.json_string(Str.to_utf8("a\"b\\c\nd\re\u(7f)é")) == Str.to_utf8("\"a\\\"b\\\\c\\nd\\u000de\\u007fé\"")
expect Wire.commas([Str.to_utf8("a"), Str.to_utf8("b")]) == Str.to_utf8("a,b")
