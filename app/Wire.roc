## **THE CHAT'S ANSWERS ON THE WIRE**, as every route's module spells them:
## a JSON answer (never sniffed, and only ever a JsonOut, so built, never
## spliced) and a refusal in plain text; and the two sizes every route
## shares (a form's most, a secret's bytes). Conversations, Agents and
## SignIn answer through here, so a JSON answer has one content type and
## one escape. Pure.
import pf.Chat
import JsonOut

Wire := [].{

	## The most of a form's body: a name, a `with=`, a grant's fields.
	form_most : U64
	form_most = 4 * 1024

	## A secret's bytes of the OS's entropy: a session's, a state's nonce, a
	## key's and an invite's code alike.
	secret_bytes : U64
	secret_bytes = 32

	## A JSON answer: its status, its value, never sniffed.
	json : U16, JsonOut -> Chat.Answer
	json = |status, value| {
		..Chat.respond(
			status,
			{ content_type: Str.to_utf8("application/json; charset=utf-8"), body: value.bytes() },
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
}
