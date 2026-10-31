## **ONE STREAM PER AGENT** (`GET /stream`, for an agent's or a bot's key):
## every conversation the agent is in, and every channel topic that names
## it, live, each event naming where it is. Here is what the stream
## decides, pure; Conversations serves it.
##
## **AN EVENT'S ID IS ITS PLACE**, `<at>.<where>.<message>`: when the
## message was posted (the server's seconds), where (a conversation by its
## number, `3`; a channel's topic by its channel's and its own keys,
## `lobby/chitchat`: neither name holds a `.` or a `/`), and its id there.
## Ids within one conversation (or topic) rise; across them only the time
## orders them. A listener resumes with the last one it saw
## (`Last-Event-ID`), and is sent (`is_after`):
## - every message of a later second;
## - every later message of the conversation it saw last, whatever its
##   second;
## - every other conversation's message of that same second.
## So nothing posted after the last event is missed, and the only messages
## a resume may send twice are other conversations' of that one second;
## each event names its conversation and id, so a reader drops a repeat.
## Without a `Last-Event-ID` the stream is live only: no backlog.
## **THE BACKLOG IS AT MOST EACH CONVERSATION'S NEWEST PAGE**, as a
## conversation's own stream's is; one further behind is said by a `gap`
## event naming the conversation and the first message sent (`gap_of`).
import Stored

AgentStream := [].{

	## Where a message is: its second, its spot (a conversation's number,
	## or `<channel key>/<topic key>`), its id there.
	Place : {
		at : I64,
		spot : Str,
		id : U64,
	}

	## The event id a place is written as.
	id_text : AgentStream.Place -> Str
	id_text = |
		{
			at,
			spot,
			id,
		},
	| "${at.to_str()}.${spot}.${id.to_str()}"

	## **WHERE A RESUME STARTS**: the place a `Last-Event-ID` names; `Live`
	## for none, or for one that is not a place (a time, a where and a
	## count, dots between, as `id_text` writes them).
	cursor : List(List(U8)) -> [After(AgentStream.Place), Live]
	cursor = |values|
		match values {
			[only] =>
				match only.split_on('.') {
					[
						at,
						conv,
						id,
					] =>
						match (
							Stored.time(at, "at"),
							spot_of(conv),
							Stored.count(id, "id"),
						) {
							(
								Ok(a),
								Ok(w),
								Ok(i),
							) => After({
								at: a,
								spot: w,
								id: i,
							})
							_ => Live
						}
					_ => Live
				}
			_ => Live
		}

	## **WHETHER A RESUME SENDS A MESSAGE**: one after the cursor, as the
	## header says; never the cursor's own, nor one before it in its
	## conversation.
	is_after : AgentStream.Place, AgentStream.Place -> Bool
	is_after = |from, place|
		if place.spot == from.spot {
			place.id > from.id
		} else {
			place.at >= from.at
		}

	## **A CONVERSATION FURTHER BEHIND THAN ITS NEWEST PAGE**: the `gap`
	## event's `before`, the first message of the page, when the messages
	## before it may hold some after the cursor (the cursor's own
	## conversation, behind the page; another's, whose page starts past the
	## cursor's second and is not its first page).
	gap_of : AgentStream.Place,
	{
		spot : Str,
		first : U64,
		first_at : I64,
	} -> [Gap(U64), NoGap]
	gap_of = |
		from,
		{
			spot,
			first,
			first_at,
		},
	|
		if first <= 1 {
			NoGap
		} else if spot == from.spot {
			if (from.id + 1 < first) Gap(first) else NoGap
		} else if first_at > from.at {
			Gap(first)
		} else {
			NoGap
		}

	## The backlog's order: by second, then spot (its bytes), then id.
	before : AgentStream.Place,
	AgentStream.Place -> [
		Before,
		Same,
		After,
	]
	before = |a, b|
		if a.at != b.at {
			if (a.at < b.at) Before else After
		} else if a.spot != b.spot {
			if (bytes_before(a.spot.to_utf8(), b.spot.to_utf8())) Before else After
		} else if a.id != b.id {
			if (a.id < b.id) Before else After
		} else {
			Same
		}
}

## **A PLACE'S SPOT, READ BACK**: a conversation's number (a count, as
## Stored reads one), or two keys of letters, digits and hyphens (a
## channel's and a topic's, lowercase, 1 to 80 bytes each) with a `/`
## between; anything else is no place.
spot_of : List(U8) -> Try(Str, [NotAPlace])
spot_of = |bytes|
	match Stored.count(bytes, "spot") {
		Ok(n) => Ok(n.to_str())
		Err(_) =>
			match bytes.split_on('/') {
				[channel, topic] if is_key(channel) and is_key(topic) =>
					Str.from_utf8(bytes).map_err(|_| NotAPlace)
				_ => Err(NotAPlace)
			}
	}

## A channel's or a topic's key: 1 to 80 lowercase letters, digits and
## hyphens.
is_key : List(U8) -> Bool
is_key = |key|
	key != [] and key.len() <= 80 and key.all(|b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '-')

## Whether `a`'s bytes sort before `b`'s.
bytes_before : List(U8), List(U8) -> Bool
bytes_before = |a, b|
	match (a, b) {
		([], []) => Bool.False
		([], _) => Bool.True
		(_, []) => Bool.False
		([x, .. as xs], [y, .. as ys]) => if (x != y) x < y else bytes_before(xs, ys)
	}

## A place, for a test.
place_at : I64, { conv : U64, id : U64 } -> AgentStream.Place
place_at = |t, { conv, id }| {
	at: t,
	spot: conv.to_str(),
	id,
}

expect AgentStream.id_text(place_at(1761600000, { conv: 3, id: 12 })) == "1761600000.3.12"
expect AgentStream.cursor(["1761600000.3.12".to_utf8()]) == After(
	place_at(
		1761600000,
		{ conv: 3, id: 12 },
	),
)
expect AgentStream.cursor([]) == Live
expect AgentStream.cursor(["12".to_utf8()]) == Live
expect AgentStream.cursor(["1.2".to_utf8()]) == Live
expect AgentStream.cursor(["1.2.3.4".to_utf8()]) == Live
expect AgentStream.cursor(["01.2.3".to_utf8()]) == Live
expect AgentStream.cursor(["1.2.x".to_utf8()]) == Live
expect AgentStream.cursor(["-1.2.3".to_utf8()]) == Live
expect AgentStream.cursor(["1.2.3".to_utf8(), "1.2.3".to_utf8()]) == Live

# **NOTHING AFTER THE CURSOR IS MISSED**: a later second anywhere; a later
# id in its conversation, even of an earlier second (a clock set back);
# another conversation's of the same second (sent again, at worst).
cur : AgentStream.Place
cur = place_at(100, { conv: 3, id: 12 })

expect AgentStream.is_after(cur, place_at(101, { conv: 5, id: 1 }))
expect AgentStream.is_after(cur, place_at(100, { conv: 3, id: 13 }))
expect AgentStream.is_after(cur, place_at(99, { conv: 3, id: 13 }))
expect AgentStream.is_after(cur, place_at(100, { conv: 5, id: 1 }))
expect !AgentStream.is_after(cur, place_at(100, { conv: 3, id: 12 }))
expect !AgentStream.is_after(cur, place_at(100, { conv: 3, id: 11 }))
expect !AgentStream.is_after(cur, place_at(99, { conv: 5, id: 40 }))

# A gap when the page may not hold all that is after the cursor.
expect AgentStream.gap_of(
	cur,
	{
		spot: "3",
		first: 20,
		first_at: 90,
	},
) == Gap(20)
expect AgentStream.gap_of(
	cur,
	{
		spot: "3",
		first: 13,
		first_at: 90,
	},
) == NoGap
expect AgentStream.gap_of(
	cur,
	{
		spot: "5",
		first: 7,
		first_at: 101,
	},
) == Gap(7)
expect AgentStream.gap_of(
	cur,
	{
		spot: "5",
		first: 7,
		first_at: 100,
	},
) == NoGap
expect AgentStream.gap_of(
	cur,
	{
		spot: "5",
		first: 1,
		first_at: 500,
	},
) == NoGap

expect AgentStream.before(
	place_at(1, { conv: 9, id: 9 }),
	place_at(2, { conv: 1, id: 1 }),
) == Before
expect AgentStream.before(
	place_at(2, { conv: 1, id: 5 }),
	place_at(2, { conv: 2, id: 1 }),
) == Before
expect AgentStream.before(place_at(2, { conv: 2, id: 5 }), place_at(2, { conv: 2, id: 1 })) == After
expect AgentStream.before(cur, cur) == Same

# **A TOPIC'S PLACE**: its channel's and its own keys; refused, a name's
# own spelling (not its key), a key past 80 bytes, a third part.
expect AgentStream.id_text({
	at: 7,
	spot: "lobby/chitchat",
	id: 2,
}) == "7.lobby/chitchat.2"
expect AgentStream.cursor(["7.lobby/chitchat.2".to_utf8()]) == After({
	at: 7,
	spot: "lobby/chitchat",
	id: 2,
})
expect AgentStream.cursor(["7.Lobby/ChitChat.2".to_utf8()]) == Live
expect AgentStream.cursor(["7.lobby/chit_chat.2".to_utf8()]) == Live
expect AgentStream.cursor(["7.lobby/a/b.2".to_utf8()]) == Live
expect AgentStream.cursor(["7.lobby/.2".to_utf8()]) == Live
expect AgentStream.cursor(["7.${Str.repeat("a", 81)}/x.2".to_utf8()]) == Live
expect AgentStream.is_after(
	{
		at: 7,
		spot: "lobby/chitchat",
		id: 2,
	},
	{
		at: 3,
		spot: "lobby/chitchat",
		id: 3,
	},
)
expect !AgentStream.is_after(
	{
		at: 7,
		spot: "lobby/chitchat",
		id: 2,
	},
	{
		at: 6,
		spot: "3",
		id: 9,
	},
)
expect AgentStream.before(
	{
		at: 7,
		spot: "3",
		id: 9,
	},
	{
		at: 7,
		spot: "lobby/chitchat",
		id: 1,
	},
) == Before
