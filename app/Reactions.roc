## **REACTIONS ON A TOPIC'S MESSAGES** (the old app's reactions, angry-gopher's
## reactions.zig and chat-client's js/chat_reactions.js): a reaction is an
## event, someone turning one emoji on or off on one message, kept one a
## line, appended, beside the topic's transcript (ChannelLayout's
## `reactions.jsonl`), so the transcript never changes. **THE LINE IS THE
## OLD APP'S** (angry-gopher's chat_store.zig `reactionLine`; Steve's
## decision, 2026-11-02), one JSON object, its six fields in the old order:
##
##     {"msg":5,"uid":"human:9","from":"Pip Q","emoji":"👍","on":true,"at":"2026-11-02T14:00:00Z"}
##
## - `msg` is the message's number, `uid` who (roc-chat's id, where the old
##   app's was its user's number), `from` their name when they reacted (the
##   name a chip shows), `on` true or false, `at` when (UtcTime.iso);
## - `emoji` is **one glyph's shape** (the old `validEmoji`): 1 to 16 bytes
##   and no ASCII byte at all, so no name, digit, space, quote or control is
##   one; which glyphs are offered is the page's list.
##
## **ONE SPELLING**, as every stored record has (Stored.roc): a line reads
## only if it is exactly the line its event writes (JsonOut's escaping, no
## space, the fields in order), so a line's bytes round-trip, and no
## reader guesses at another spelling of the same event.
##
## **THE FOLD** is the old client's (`apply`): for each message, the last
## event of each person and emoji wins; a chip is an emoji with someone on
## it, in the order its emoji first appeared, its people in the order they
## came, each by the name of their latest event. A line that does not read
## is passed over, as the old client dropped one it could not parse (a
## reaction cut short by a stop, given its own line by the next append,
## Store.append_reaction!). Here the server folds and draws the chips
## (`strip`), as it draws every bubble (Steve's decision: the server sends
## HTML, never JSON for the page to draw), the page's script only marking
## the viewer's own. Pure.
import Account
import Html
import JsonOut
import Principal
import Stored
import UtcTime

Reactions := [].{

	## **ONE EVENT**: who turned which emoji on or off on message `n`, and when.
	Event : {
		n : U64,
		by : Principal.Id,
		from : Str,
		emoji : Str,
		on : Bool,
		at : I64,
	}

	## **ONE CHIP**: an emoji someone has on a message, and who, in order,
	## each with the name they last reacted under.
	Chip : { emoji : Str, by : List({ id : Principal.Id, name : Str }) }

	## The most bytes one glyph's shape holds (a base and a variation
	## selector is 7; 16 leaves room without admitting a sentence).
	emoji_most : U64
	emoji_most = 16

	## **WHETHER `text` HAS ONE GLYPH'S SHAPE**: 1 to `emoji_most` bytes, none
	## of them ASCII.
	is_emoji : Str -> Bool
	is_emoji = |text| {
		bytes = text.to_utf8()
		!bytes.is_empty() and bytes.len() <= Reactions.emoji_most and bytes.all(|b| b >= 0x80)
	}

	## The event's line. An emoji that is not one glyph's shape, or a
	## message number of 0, is no event: a crash.
	encode : Reactions.Event -> List(U8)
	encode = |e|
		if e.n == 0 or !Reactions.is_emoji(e.emoji) {
			crash "Reactions.encode: an event's message is not 0 and its emoji is a glyph"
		} else {
			JsonOut.object([
				("msg", JsonOut.number(e.n)),
				("uid", JsonOut.string(Account.id_text(e.by))),
				("from", JsonOut.string(e.from)),
				("emoji", JsonOut.string(e.emoji)),
				("on", JsonOut.bool(e.on)),
				("at", JsonOut.string(UtcTime.iso(e.at))),
			])
				.bytes()
				.append('\n')
		}

	## **THE EVENT A LINE HOLDS**: the six fields read in order, then the
	## line its event writes compared with it, byte for byte (one spelling).
	decode : List(U8) -> Try(Reactions.Event, [NotAReaction])
	decode = |raw| {
		msg = after(raw, "{\"msg\":")?
		n_digits = up_to(msg, ',')
		n = Stored.count(n_digits, "msg").map_err(|_| NotAReaction)?
		uid_at = after(msg.drop_first(n_digits.len()), ",\"uid\":")?
		uid = json_string(uid_at)?
		by = Account.id_from(uid.text, "uid").map_err(|_| NotAReaction)?
		from = json_string(after(uid.rest, ",\"from\":")?)?
		emoji = json_string(after(from.rest, ",\"emoji\":")?)?
		on_rest = after(emoji.rest, ",\"on\":")?
		on = if (on_rest.starts_with("true".to_utf8())) Bool.True else Bool.False
		at = json_string(after(on_rest.drop_first(if (on) 4 else 5), ",\"at\":")?)?
		event = {
			n,
			by,
			from: Str.from_utf8(from.text).map_err(|_| NotAReaction)?,
			emoji: Str.from_utf8(emoji.text).map_err(|_| NotAReaction)?,
			on,
			at: UtcTime.from_iso(at.text).map_err(|_| NotAReaction)?,
		}
		if n == 0 or !Reactions.is_emoji(event.emoji) {
			Err(NotAReaction)
		} else if Reactions.encode(event) != raw {
			Err(NotAReaction)
		} else {
			Ok(event)
		}
	}

	## **A TOPIC'S EVENTS AS STORED**, oldest first; a line that does not
	## read passed over, as the old client passed it.
	list : List(U8) -> List(Reactions.Event)
	list = |raw|
		raw.split_on('\n').keep_oks(|line| Reactions.decode(line.append('\n')))

	## **MESSAGE `n`'S CHIPS**, by the fold above.
	chips_of : List(Reactions.Event), U64 -> List(Reactions.Chip)
	chips_of = |events, n|
		events
			.keep_if(|e| e.n == n)
			.fold(
				[],
				|chips, e|
					if chips.any(|c| c.emoji == e.emoji) {
						chips.map(|c| if (c.emoji == e.emoji) { ..c, by: turned(c.by, e) } else c)
					} else {
						chips.append({ emoji: e.emoji, by: turned([], e) })
					},
			)
			.keep_if(|c| !c.by.is_empty())

	## **A MESSAGE'S STRIP**, every viewer's: each chip a button, its emoji
	## and count, the people on it (`data-by`, for the page's script to mark
	## the viewer's own) and their names in its title, as the old chip's;
	## no chip, an empty strip, there to be filled.
	strip : { n : U64, chips : List(Reactions.Chip) } -> Html
	strip = |{ n, chips }|
		Html.join([
			Html.markup("<div class=chat-reactions data-n="),
			Html.number(n),
			Html.markup(">"),
			Html.join(
				chips.map(
					|c| Html.join([
						Html.markup("<button type=button class=chat-react-chip data-emoji=\""),
						Html.text(c.emoji),
						Html.markup("\" data-by=\""),
						Html.text(Str.join_with(c.by.map(|who| Account.id_text(who.id)), " ")),
						Html.markup("\" data-names=\""),
						Html.text(Str.join_with(c.by.map(|who| who.name), ", ")),
						Html.markup("\">"),
						Html.text(c.emoji),
						Html.markup(" "),
						Html.number(c.by.len()),
						Html.markup("</button>"),
					]),
				),
			),
			Html.markup("</div>"),
		])
}

## What follows `prefix`, where the bytes start with it.
after : List(U8), Str -> Try(List(U8), [NotAReaction])
after = |bytes, prefix|
	if bytes.starts_with(prefix.to_utf8()) {
		Ok(bytes.drop_first(prefix.to_utf8().len()))
	} else {
		Err(NotAReaction)
	}

## The bytes before the first `stop`, or all of them.
up_to : List(U8), U8 -> List(U8)
up_to = |bytes, stop|
	match bytes.find_first_index(|b| b == stop) {
		Ok(i) => bytes.take_first(i)
		Err(NotFound) => bytes
	}

## **A JSON STRING AT THE START**: its text, the escapes JsonOut writes
## (`\"`, `\\`, `\n`, `\u00XX`) read back, and what follows its closing
## quote. Any other escape is no reaction's.
json_string : List(U8) -> Try({ text : List(U8), rest : List(U8) }, [NotAReaction])
json_string = |bytes|
	match bytes {
		['"', .. as rest] => string_body(rest, [])
		_ => Err(NotAReaction)
	}

string_body : List(U8), List(U8) -> Try({ text : List(U8), rest : List(U8) }, [NotAReaction])
string_body = |bytes, text|
	match bytes {
		['"', .. as rest] => Ok({ text, rest })
		['\\', '"', .. as rest] => string_body(rest, text.append('"'))
		['\\', '\\', .. as rest] => string_body(rest, text.append('\\'))
		['\\', 'n', .. as rest] => string_body(rest, text.append('\n'))
		[
			'\\',
			'u',
			'0',
			'0',
			high,
			low,
			.. as rest,
		] =>
			match (hex_value(high), hex_value(low)) {
				(Ok(h), Ok(l)) => string_body(rest, text.append(h * 16 + l))
				_ => Err(NotAReaction)
			}
		['\\', ..] => Err(NotAReaction)
		[b, .. as rest] => string_body(rest, text.append(b))
		[] => Err(NotAReaction)
	}

## A lowercase hex digit's value, as JsonOut writes one.
hex_value : U8 -> Try(U8, [NotAReaction])
hex_value = |c|
	if c >= '0' and c <= '9' {
		Ok(c - '0')
	} else if c >= 'a' and c <= 'f' {
		Ok(c - 'a' + 10)
	} else {
		Err(NotAReaction)
	}

## The people on a chip after `e`: on, added at the end if not there (its
## name the event's, as the old fold's `who.set`); off, taken out.
turned : List(
	{
		id : Principal.Id,
		name : Str,
	},
),
Reactions.Event -> List({ id : Principal.Id, name : Str })
turned = |by, e|
	if e.on {
		if by.any(|who| who.id == e.by) {
			by.map(|who| if (who.id == e.by) { ..who, name: e.from } else who)
		} else {
			by.append({ id: e.by, name: e.from })
		}
	} else {
		by.drop_if(|who| who.id == e.by)
	}

# ── tests
ann : Principal.Id
ann = Principal.Id.Human(Principal.HumanId.from_u64(9) ?? crash "a test's id")

bob : Principal.Id
bob = Principal.Id.Human(Principal.HumanId.from_u64(10) ?? crash "a test's id")

ev : {
	n : U64,
	by : Principal.Id,
	on : Bool,
	emoji : Str,
} -> Reactions.Event
ev = |
	{
		n,
		by,
		on,
		emoji,
	},
| {
	n,
	by,
	at: 100,
	on,
	emoji,
	from: if (by == ann) "Ann B" else "Bob",
}

## Ann's 👍 on message 5, on or off.
ann_thumb : Bool -> Reactions.Event
ann_thumb = |on|
	ev({
		n: 5,
		by: ann,
		on,
		emoji: "👍",
	})

## The line `ann_thumb` writes.
ann_line : Str -> List(U8)
ann_line = |on| "{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":${on},\"at\":\"1970-01-01T00:01:40Z\"}\n".to_utf8()

# The old app's line: one JSON object, its six fields in the old order.
expect Reactions.encode(
	ev({
		n: 5,
		by: ann,
		on: Bool.True,
		emoji: "👍",
	}),
) == ann_line("true")
expect Reactions.decode(ann_line("true")) == Ok(ann_thumb(Bool.True))
expect Reactions.decode(ann_line("false")) == Ok(ann_thumb(Bool.False))
# A name holding a quote, a backslash, a newline or a control byte is
# escaped as JsonOut escapes it, one line, and reads back the same.
expect {
	e = { ..ann_thumb(Bool.True), from: "A \"q\" \\ b\nc\u(1)" }
	line = Reactions.encode(e)
	line == "{\"msg\":5,\"uid\":\"human:9\",\"from\":\"A \\\"q\\\" \\\\ b\\nc\\u0001\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n".to_utf8()
		and Reactions.decode(line) == Ok(e)
}
# One spelling: any other spelling of the same event is no reaction.
expect
	[
		# a space after a colon; the fields in another order; an extra field
		"{\"msg\": 5,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"uid\":\"human:9\",\"msg\":5,\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\",\"x\":1}\n",
		# `on` as a number; `msg` with a leading zero, or 0; a time in another spelling
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":1,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":05,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":0,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40+00:00\"}\n",
		# an escape JsonOut never writes: `\/`, an uppercase hex digit, `\t`
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann\\/B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann\\u001F\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann\\tB\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		# an emoji that is no glyph's shape; no such id; no newline (torn)
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"x\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":5,\"uid\":\"user:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}\n",
		"{\"msg\":5,\"uid\":\"human:9\",\"from\":\"Ann B\",\"emoji\":\"👍\",\"on\":true,\"at\":\"1970-01-01T00:01:40Z\"}",
	].all(|line| Reactions.decode(line.to_utf8()) == Err(NotAReaction))
expect Reactions.decode(
	Reactions.encode(
		ev({
			n: 5,
			by: ann,
			on: Bool.False,
			emoji: "❤️",
		}),
	),
) == Ok(
	ev({
		n: 5,
		by: ann,
		on: Bool.False,
		emoji: "❤️",
	}),
)
# One glyph's shape: no ASCII, at most 16 bytes, not empty.
expect Reactions.is_emoji("👍") and Reactions.is_emoji("❤️") and Reactions.is_emoji("💯")
expect !Reactions.is_emoji("") and !Reactions.is_emoji("thumbsup") and !Reactions.is_emoji(":100:") and !Reactions.is_emoji("👍 ") and !Reactions.is_emoji("\"👍\"")
expect !Reactions.is_emoji("👍👍👍👍👍")
# A line that does not read is passed over, wherever it is: a cut one, or
# one gone wrong in the middle.
expect {
	one = Reactions.encode(
		ev({
			n: 1,
			by: ann,
			on: Bool.True,
			emoji: "👍",
		}),
	)
	two = Reactions.encode(
		ev({
			n: 2,
			by: bob,
			on: Bool.True,
			emoji: "🎉",
		}),
	)
	raw = one.concat("{\"msg\":2,\"uid\":\"hu\nnonsense\n".to_utf8()).concat(two).concat("{\"msg\":3".to_utf8())
	Reactions.list(raw) == [
		ev({
			n: 1,
			by: ann,
			on: Bool.True,
			emoji: "👍",
		}),
		ev({
			n: 2,
			by: bob,
			on: Bool.True,
			emoji: "🎉",
		}),
	]
}
expect Reactions.list([]) == []

# The fold: the last event of each person and emoji wins; chips in the
# order their emoji first came, people in the order they came, each by
# the name of their latest event; an emoji with no one left, no chip;
# another message's events are not this one's.
expect {
	events = [
		ev({
			n: 1,
			by: ann,
			on: Bool.True,
			emoji: "👍",
		}),
		ev({
			n: 1,
			by: bob,
			on: Bool.True,
			emoji: "🎉",
		}),
		ev({
			n: 1,
			by: bob,
			on: Bool.True,
			emoji: "👍",
		}),
		{ ..ev({
			n: 1,
			by: ann,
			on: Bool.True,
			emoji: "👍",
		}), from: "Ann C" },
		ev({
			n: 2,
			by: ann,
			on: Bool.True,
			emoji: "🔥",
		}),
		ev({
			n: 1,
			by: bob,
			on: Bool.False,
			emoji: "🎉",
		}),
	]
	Reactions.chips_of(events, 1) == [
		{
			emoji: "👍",
			by: [{ id: ann, name: "Ann C" }, { id: bob, name: "Bob" }],
		},
	]
		and Reactions.chips_of(events, 2) == [{ emoji: "🔥", by: [{ id: ann, name: "Ann B" }] }]
		and Reactions.chips_of(events, 3) == []
}
expect {
	events = [
		ev({
			n: 1,
			by: ann,
			on: Bool.True,
			emoji: "👍",
		}),
		ev({
			n: 1,
			by: ann,
			on: Bool.False,
			emoji: "👍",
		}),
		ev({
			n: 1,
			by: bob,
			on: Bool.True,
			emoji: "👍",
		}),
	]
	Reactions.chips_of(events, 1) == [{ emoji: "👍", by: [{ id: bob, name: "Bob" }] }]
}
# The strip: a chip a button, its people's ids and names, all escaped.
expect Reactions.strip({
	n: 3,
	chips: [],
}).bytes() == "<div class=chat-reactions data-n=3></div>".to_utf8()
expect Reactions.strip({
	n: 3,
	chips: [{ emoji: "👍", by: [{ id: ann, name: "A<b>" }, { id: bob, name: "Bob" }] }],
}).bytes() == "<div class=chat-reactions data-n=3><button type=button class=chat-react-chip data-emoji=\"👍\" data-by=\"human:9 human:10\" data-names=\"A&lt;b&gt;, Bob\">👍 2</button></div>".to_utf8()
