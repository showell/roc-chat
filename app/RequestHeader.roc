## A request's header, by its name: the one way the app reads a header, so
## every reader treats a header sent twice alike.
import pf.Http

RequestHeader :: [].{

	## **THE HEADER `name`** (written in lowercase; a header's name is
	## matched without case): its value when sent once, else `Unsent` or
	## `Repeated`, which names no one value.
	sent : List(Http.Header),
	Str -> [
		Sent(List(U8)),
		Unsent,
		Repeated,
	]
	sent = |headers, name| {
		named = headers.keep_if(
			|header|
				match Str.from_utf8(header.name) {
					Ok(text) => text.with_ascii_lowercased() == name
					Err(_) => Bool.False
				},
		)
		match named {
			[] => Unsent
			[only] => Sent(only.value)
			_ => Repeated
		}
	}
}

# ── tests
## The header `name` of `headers` (name, value), as a test reads it.
looked_up : List((Str, Str)),
Str -> [
	Sent(Str),
	Unsent,
	Repeated,
]
looked_up = |headers, name|
	match RequestHeader.sent(headers.map(|(n, v)| { name: n.to_utf8(), value: v.to_utf8() }), name) {
		Sent(value) => Sent(Str.from_utf8_lossy(value))
		Unsent => Unsent
		Repeated => Repeated
	}

expect looked_up([("Last-Event-ID", "6")], "last-event-id") == Sent("6")
expect looked_up([("last-event-id", "")], "last-event-id") == Sent("")
expect looked_up([("Host", "x")], "last-event-id") == Unsent
expect looked_up([], "last-event-id") == Unsent
expect looked_up([("Last-Event-ID", "6"), ("last-event-id", "6")], "last-event-id") == Repeated
