## This module writes the events of a stream, in the event-stream format a
## browser's `EventSource` reads: an event's optional `id:` or `event:`
## line, its data as one `data:` line a line, and the blank line that ends
## it. `ConversationStream` writes a conversation's messages with it, and
## `Presence` the notices it sends a viewer.
import Escape
import TrustedHtml

ServerSentEvent :: [].{

	## An event with the id `id` and the data `html`: the browser keeps the
	## id as the last it saw, and says it when it reconnects.
	numbered_event : { id : Str, html : TrustedHtml } -> List(U8)
	numbered_event = |{ id, html }|
		List.concat("id: ${id}\n".to_utf8(), data_lines(html)).append('\n')

	## An event named `name`, with no id, so the last id a browser saw stays
	## as it was, and the data `html`; a page listens for it by its name.
	named_event : { name : Str, html : TrustedHtml } -> List(U8)
	named_event = |{ name, html }|
		List.concat("event: ${name}\n".to_utf8(), data_lines(html)).append('\n')
}

## The `html` as an event's data: a `data:` line a line.
data_lines : TrustedHtml -> List(U8)
data_lines = |html|
	line_feeds_only(html.to_utf8()).split_on('\n').join_map(
		|line| List.concat("data: ".to_utf8(), line).append('\n'),
	)

## The bytes with each CR LF and each lone CR made an LF: an event's data
## can't hold a CR, and an HTML parser reads both as an LF, so the page shows the same.
line_feeds_only : List(U8) -> List(U8)
line_feeds_only = |bytes|
	bytes.fold(
		{ written: [], previous: 0 },
		|so_far, byte|
			if byte == '\r' {
				{ written: so_far.written.append('\n'), previous: byte }
			} else if byte == '\n' and so_far.previous == '\r' {
				{ ..so_far, previous: byte }
			} else {
				{ written: so_far.written.append(byte), previous: byte }
			},
	).written

# ── tests
# A CR LF and a lone CR each one LF; an LF alone kept.
expect line_feeds_only("a\r\nb\rc\nd\r\r\n".to_utf8()) == "a\nb\nc\nd\n\n".to_utf8()
expect line_feeds_only("a\n\nb".to_utf8()) == "a\n\nb".to_utf8()
expect line_feeds_only([]) == []

# An event with an id, and a named one: each line of the data its own
# `data:` line, and the blank line that ends it.
expect
	ServerSentEvent.numbered_event({ id: "3", html: Escape.text("a & b\r\nc") })
		== "id: 3\ndata: a &amp; b\ndata: c\n\n".to_utf8()
expect
	ServerSentEvent.named_event({ name: "online", html: Escape.text("2") })
		== "event: online\ndata: 2\n\n".to_utf8()
