## An agent's stream: one connection carrying every message posted in every
## conversation the agent may read, which is each conversation of each
## channel it is a member of (`Access`), as design.md asks. A conversation's
## own stream (`ConversationStream`) serves a page; this one serves a
## script, so each message is one event of one line, a JSON object:
##
##     data: {"conversation":"/chat/dm/1_1/a","id":3,"from":"Steve","date":"...","markdown":"Hi"}
##
## then a blank line. `conversation` is the conversation's URL path, which
## also names its `/raw` transcript and where to post a reply; `id` its
## number there; `date` its time as the transcript writes it; `markdown`
## exactly as written.
##
## Without a query the stream is live only. With `?since=<date>`, a date
## written as the events write it, it first sends the messages of those
## conversations dated at or after it, oldest first, then the live ones: at
## most each conversation's newest 100 (`backlog_most_per_conversation`),
## so a stream's start is bounded however old its date. An agent further
## behind sees the gap in a conversation's ids, and reads the rest from its
## `/raw` transcript. An agent whose connection drops reconnects with the
## date of the last event it read: the messages of that one second may come
## twice, and each names its conversation and id, so a repeat is easy to
## drop.
##
## The host holds the stream on the agent's own bus key; each message
## posted is published to the key of every agent member of its channel
## (`publish!`), so the host knows nothing of channels.
import pf.Host
import pf.Http
import Author
import Conversation
import ConversationKey
import DateTime
import Directory
import HttpAnswer
import JsonOut
import Message
import Name
import Topic
import UnvalidatedString
import UserId
import UserPair

AgentStream :: [].{

	## Where the stream starts: live only, or with every message since a
	## date; unless the query is neither (`BadSince`).
	start : List(U8) -> Try([Live, Since(DateTime)], [BadSince])
	start = |query|
		if query.is_empty() {
			Ok(Live)
		} else if query.starts_with(since_prefix) {
			since_bytes = query.drop_first(since_prefix.len())
			unchecked = UnvalidatedString.from_utf8(since_bytes) ? |NotUtf8| BadSince
			date = unchecked.date_time() ? |_| BadSince
			Ok(Since(date))
		} else {
			Err(BadSince)
		}

	## Why a stream's start is refused, in words.
	words : [BadSince] -> Str
	words = |BadSince|
		"The stream's start is not one: none, or `?since=<date>`, a date as 2026-11-02T19:11:32Z."

	## One message of the conversation `key` as one event.
	frame : { key : ConversationKey, message : Message } -> List(U8)
	frame = |{ key, message }| {
		id =
			U64.from_str(message.id().to_str())
				?? crash "AgentStream.frame: a message's id is its digits"
		fields = JsonOut.json_object([
			("conversation", JsonOut.string(key.url_path(Page))),
			("id", JsonOut.number(id)),
			("from", JsonOut.string(message.author().to_str())),
			("date", JsonOut.string(message.time().to_str())),
			("markdown", JsonOut.string(message.markdown())),
		])
		"data: ".to_utf8().concat(fields.bytes()).concat("\n\n".to_utf8())
	}

	## The most messages of one conversation a backlog sends: its newest.
	backlog_most_per_conversation : U64
	backlog_most_per_conversation = 100

	## The events of the messages of `conversations` dated at or after
	## `since`, at most each conversation's newest
	## `backlog_most_per_conversation`, oldest first; messages of one second
	## in the order of `conversations`, then of their ids.
	backlog : {
		conversations : List({ key : ConversationKey, conversation : Conversation }),
		since : DateTime,
	} -> List(U8)
	backlog = |{ conversations, since }| {
		dated = conversations.map_with_index(
			|{ key, conversation }, place|
				conversation
					.messages()
					.map_with_index(|message, at| { key, message, place, at })
					.keep_if(|m| m.message.time().compare(since) != Before)
					.take_last(AgentStream.backlog_most_per_conversation),
		).join()
		dated
			.sort_with(by_time_then_place)
			.join_map(|m| AgentStream.frame({ key: m.key, message: m.message }))
	}

	## Who holds the agent `agent`'s stream, as the host counts streams:
	## the agent, under a name no user's id is.
	holder : UserId -> List(U8)
	holder = |agent| "agent-${agent.to_str()}".to_utf8()

	## The agent `agent`'s stream: `backlog` first, then every event
	## published to it.
	response : { agent : UserId, backlog : List(U8) } -> Http.Response
	response = |{ agent, backlog: events }|
		HttpAnswer.stream({
			key: bus_key(agent),
			holder: AgentStream.holder(agent),
			backlog: events,
		})

	## Sends a message just posted in the conversation `key` to the stream
	## of each of `agents`, its channel's agent members.
	publish! : {
		key : ConversationKey,
		message : Message,
		agents : List(UserId),
	} => {}
	publish! = |{ key, message, agents }| {
		event = AgentStream.frame({ key, message })
		for agent in agents {
			Host.publish_bytes_to_streams_on_key!(bus_key(agent), event)
		}
	}
}

since_prefix : List(U8)
since_prefix = "since=".to_utf8()

## An agent's bus key, which no conversation's (a URL under `/chat`) is.
bus_key : UserId -> List(U8)
bus_key = |agent| "/agents/${agent.to_str()}/stream".to_utf8()

## A message of a backlog, with its conversation's key, the conversation's
## place in the list, and its own place in the conversation.
Dated : {
	key : ConversationKey,
	message : Message,
	place : U64,
	at : U64,
}

## The order of a backlog: by time, then by the conversation's place in the
## list, then by the message's.
by_time_then_place : Dated, Dated -> [Before, Same, After]
by_time_then_place = |a, b|
	match a.message.time().compare(b.message.time()) {
		Before => Before
		After => After
		Same => if a.place != b.place {
			order_of(a.place, b.place)
		} else {
			order_of(a.at, b.at)
		}
	}

## Which of two places comes first.
order_of : U64, U64 -> [Before, Same, After]
order_of = |a, b| if a < b {
	Before
} else if a == b {
	Same
} else {
	After
}

# ── tests
## The time `text` writes.
time_of : Str -> DateTime
time_of = |text| DateTime.from_str(text) ?? crash "AgentStream's tests: a time"

## The key of `topic` in Steve's own DM.
key_of : Str -> ConversationKey
key_of = |topic| {
	directory =
		Directory.with_founder(Name.from_str("Steve") ?? crash "AgentStream's tests: a name")
	place = directory.place(
		Dm(UserPair.of({ a: UserId.chat_owner, b: UserId.chat_owner })),
	) ?? crash "AgentStream's tests: Steve's own DM"
	ConversationKey.of({
		place,
		topic: Topic.from_str(topic) ?? crash "AgentStream's tests: a topic",
	})
}

## `topic`'s conversation of Steve's messages, each a time and its markdown.
conversation_of : Str, List((Str, Str)) -> { key : ConversationKey, conversation : Conversation }
conversation_of = |topic, messages| {
	key = key_of(topic)
	author = Author.from_str("Steve") ?? crash "AgentStream's tests: a name"
	conversation = messages.fold(
		Conversation.empty(key.topic()),
		|so_far, (time, markdown)| (
			so_far.append({
				payload: { author, markdown },
				time: time_of(time),
			}) ?? crash "AgentStream's tests: a message joins"
		).conversation,
	)
	{ key, conversation }
}

## The markdown an event of a test's carries, which holds no quote.
markdown_in : Str -> Str
markdown_in = |event|
	match event.split_on("\"markdown\":\"") {
		[_, after] => after.drop_suffix("\"}")
		_ => crash "AgentStream's tests: an event names its markdown once"
	}

## The events `bytes` hold, one line of JSON each, as a test reads them.
events_of : List(U8) -> List(Str)
events_of = |bytes| Str.from_utf8_lossy(bytes).split_on("\n\n").drop_if(Str.is_empty)

# A start: live with no query; since a date; anything else refused.
expect AgentStream.start([]) == Ok(Live)
expect
	AgentStream.start("since=2026-11-02T19:11:32Z".to_utf8())
		== Ok(Since(time_of("2026-11-02T19:11:32Z")))
expect
	[
		"since=",
		"since=2026-11-02",
		"after=3",
		"since=2026-11-02T19:11:32Z&x=1",
		"Since=2026-11-02T19:11:32Z",
	].all(|query| AgentStream.start(query.to_utf8()) == Err(BadSince))
expect AgentStream.start([0x73, 0x69, 0x6e, 0x63, 0x65, 0x3d, 0xff]) == Err(BadSince)
# One message, one event: one line of JSON, its markdown's line ends and
# quotes escaped, then a blank line.
expect {
	held = conversation_of("plans", [("2026-11-02T19:11:32Z", "Hi \"all\"\nsecond line")])
	message = held.conversation.messages().first() ?? crash "AgentStream's tests: one message"
	AgentStream.frame({ key: held.key, message })
		== "data: {\"conversation\":\"/chat/dm/1_1/plans\",\"id\":1,\"from\":\"Steve\",\"date\":\"2026-11-02T19:11:32Z\",\"markdown\":\"Hi \\\"all\\\"\\nsecond line\"}\n\n".to_utf8()
}
# A backlog: every message at or after its date, oldest first across the
# conversations; one second's messages in the conversations' order, then
# their own.
expect {
	plans = conversation_of(
		"plans",
		[
			("2026-11-02T19:00:00Z", "p1"),
			("2026-11-02T19:00:05Z", "p2"),
			("2026-11-02T19:00:09Z", "p3"),
		],
	)
	other = conversation_of(
		"other",
		[
			("2026-11-02T19:00:01Z", "o1"),
			("2026-11-02T19:00:05Z", "o2"),
			("2026-11-02T19:00:05Z", "o3"),
		],
	)
	events = events_of(
		AgentStream.backlog({
			conversations: [plans, other],
			since: time_of("2026-11-02T19:00:01Z"),
		}),
	)
	events.map(markdown_in) == ["o1", "p2", "o2", "o3", "p3"]
}
# A backlog sends at most each conversation's newest 100: of 101 at or after
# the date, the last 100; of 100, all; and each conversation is capped on
# its own.
## `topic`'s conversation of `count` messages of Steve's, all at one time,
## the markdown of each its number from 1.
conversation_of_count : Str, U64 -> { key : ConversationKey, conversation : Conversation }
conversation_of_count = |topic, count| conversation_of(
	topic,
	List.from_iter(U64.to(1, count)).map(|n| ("2026-11-02T19:00:00Z", n.to_str())),
)

## The markdown of each event of the backlog of `conversations` since the
## time of their messages.
backlog_markdown : List({ key : ConversationKey, conversation : Conversation }) -> List(Str)
backlog_markdown = |conversations| events_of(
	AgentStream.backlog({ conversations, since: time_of("2026-11-02T19:00:00Z") }),
).map(markdown_in)

expect backlog_markdown([
	conversation_of_count("plans", 101),
]) == List.from_iter(U64.to(2, 101)).map(U64.to_str)
expect backlog_markdown([
	conversation_of_count("plans", 100),
]) == List.from_iter(U64.to(1, 100)).map(U64.to_str)
expect backlog_markdown([conversation_of_count("plans", 99)]).len() == 99
expect backlog_markdown([
	conversation_of_count("plans", 101),
	conversation_of_count("other", 3),
]).len() == 103
expect AgentStream.holder(UserId.chat_owner) == "agent-1".to_utf8()
# A date past every message, none; before every message, all.
expect AgentStream.backlog({
	conversations: [conversation_of("plans", [("2026-11-02T19:00:00Z", "p1")])],
	since: time_of("2026-11-02T19:00:01Z"),
}) == []
expect events_of(
	AgentStream.backlog({
		conversations: [conversation_of("plans", [("2026-11-02T19:00:00Z", "p1")])],
		since: time_of("2026-11-02T19:00:00Z"),
	}),
).len() == 1
# The stream: on the agent's own key, held by the agent, its backlog first.
expect {
	answered = AgentStream.response({ agent: UserId.chat_owner, backlog: "data: x\n\n".to_utf8() })
	answered.kind == Stream
		and answered.stream_key == "/agents/1/stream".to_utf8()
		and answered.stream_holder == "agent-1".to_utf8()
		and answered.body == "data: x\n\n".to_utf8()
}
expect
	AgentStream.words(BadSince)
		== "The stream's start is not one: none, or `?since=<date>`, a date as 2026-11-02T19:11:32Z."
