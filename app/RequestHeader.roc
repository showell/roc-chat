## This module reads one of a request's headers by its name. It is the one
## way the app reads a header, so every reader treats a header sent twice
## the same way: as naming no one value.
import pf.Http

RequestHeader :: [].{

	## The header `name`: its value when it was sent once, else `Unsent`, or
	## `Repeated` when it was sent more than once. A header's name is matched
	## without case, so `name` is written in lowercase, or this crashes: a
	## name with a capital letter would never match.
	header_value : List(Http.Header), Str -> [Sent(List(U8)), Unsent, Repeated]
	header_value = |headers, name|
		if name != name.with_ascii_lowercased() {
			crash "RequestHeader.header_value: the name ${name} is not written in lowercase"
		} else {
			matching = headers.keep_if(
				|header|
					match Str.from_utf8(header.name) {
						Ok(text) => text.with_ascii_lowercased() == name
						Err(_) => Bool.False
					},
			)
			match matching {
				[] => Unsent
				[only] => Sent(only.value)
				_ => Repeated
			}
		}
}

# ── tests
## The header `name` of `headers` (name, value), as a test reads it.
looked_up : List((Str, Str)), Str -> [Sent(Str), Unsent, Repeated]
looked_up = |headers, name|
	match RequestHeader.header_value(
		headers.map(|(n, v)| { name: n.to_utf8(), value: v.to_utf8() }),
		name,
	) {
		Sent(value) => Sent(Str.from_utf8_lossy(value))
		Unsent => Unsent
		Repeated => Repeated
	}

# Sent once, in any case, its value exactly as sent.
expect looked_up([("Last-Event-ID", "6")], "last-event-id") == Sent("6")
expect looked_up([("last-event-id", "")], "last-event-id") == Sent("")
expect looked_up(
	[("Host", "x"), ("Content-Type", "Text/HTML")],
	"content-type",
) == Sent("Text/HTML")
# Not sent: no headers, another header, or a name that is not UTF-8.
expect looked_up([("Host", "x")], "last-event-id") == Unsent
expect looked_up([], "last-event-id") == Unsent
expect RequestHeader.header_value([{ name: [0xFF], value: "x".to_utf8() }], "host") == Unsent
# Sent twice, in any case, even with the same value.
expect looked_up([("Last-Event-ID", "6"), ("last-event-id", "6")], "last-event-id") == Repeated
