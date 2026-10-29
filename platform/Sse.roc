## **SERVER-SENT EVENTS, FOR ANY APP ON THIS PLATFORM**: an event made into
## the bytes of one SSE frame, which the host writes verbatim. Nothing here
## knows what the app is: a channel is an opaque bus key the app chooses,
## and an event is a name, its data and an optional id.
##
## A stream takes two routes and three calls:
##
## ```roc
## # GET /ticks: what is known now, then each event published to "ticks".
## Chat.stream({ key: Str.to_utf8("ticks"), backlog: [], holder: Str.to_utf8("human:2") })
##
## # Anywhere a handler runs (a POST, say): every stream on "ticks" gets it.
## match Sse.frame({ name: Str.to_utf8("tick"), data: Str.to_utf8("12:00:01"), id: [] }) {
##     Ok(frame) => Host.publish!(Str.to_utf8("ticks"), frame)
##     Err(LineBreak) => {}
## }
## ```
##
## The page listens with the browser's own `EventSource`:
## `new EventSource("/ticks").addEventListener("tick", e => show(e.data))`.
##
## **NO GAP, NO DUPLICATE**: the host subscribes a stream in the same turn
## as the handler that answered it, so a backlog read in that handler and
## the live frames after it meet exactly. A stream whose reader falls 16
## frames behind is ended, never skipped ahead; the browser reconnects,
## sending the last `id` it saw as `Last-Event-ID` (`Host.read_header!`),
## and the app resumes from there.
Sse := [].{

	## An event: `name` is its type (empty: the browser's `message`), `data`
	## any bytes (each line sent as a `data:` line, rejoined by the
	## browser), and `id` where a reconnect resumes (empty: none).
	Event : {
		name : List(U8),
		data : List(U8),
		id : List(U8),
	}

	## The event as one frame. `Err(LineBreak)` when a CR is anywhere in
	## it, or an LF in its name or id: the format has no way to say them.
	frame : Event -> Try(List(U8), [LineBreak])
	frame = |
		{
			name,
			data,
			id,
		},
	|
		if List.contains(data, '\r') or has_line_break(name) or has_line_break(id) {
			Err(LineBreak)
		} else {
			Ok(
				List.join([
					field("event", name),
					field("id", id),
					Str.to_utf8("data: "),
					List.join_map(
						data,
						|byte| if byte == '\n' {
							Str.to_utf8("\ndata: ")
						} else {
							[byte]
						},
					),
					Str.to_utf8("\n\n"),
				]),
			)
		}

	## `name: value` and a line end, or nothing when `value` is empty.
	field : Str, List(U8) -> List(U8)
	field = |name, value|
		if List.is_empty(value) {
			[]
		} else {
			List.join([
				Str.to_utf8("${name}: "),
				value,
				['\n'],
			])
		}

	has_line_break : List(U8) -> Bool
	has_line_break = |bytes| List.contains(bytes, '\n') or List.contains(bytes, '\r')
}

expect Sse.frame({
	name: [],
	data: Str.to_utf8("hi"),
	id: [],
}) == Ok(Str.to_utf8("data: hi\n\n"))
expect Sse.frame({
	name: Str.to_utf8("tick"),
	data: Str.to_utf8("a\nb"),
	id: Str.to_utf8("7"),
}) == Ok(Str.to_utf8("event: tick\nid: 7\ndata: a\ndata: b\n\n"))
expect Sse.frame({
	name: [],
	data: Str.to_utf8("a\r\nb"),
	id: [],
}) == Err(LineBreak)
expect Sse.frame({
	name: Str.to_utf8("a\nb"),
	data: [],
	id: [],
}) == Err(LineBreak)
