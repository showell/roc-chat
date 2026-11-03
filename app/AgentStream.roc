## An agent's stream: one connection carrying every message posted in every
## conversation the agent may read, which is each conversation of each
## channel it is a member of (`Access`), as design.md asks. A conversation's
## own stream (`ConversationStream`) serves a page; this one serves a
## script, so each message is one event of one line, a JSON object:
##
##     data: {"conversation":"/chat/channel/general/plans","id":3,"from":"Steve","date":"2026-11-02T19:11:32Z","markdown":"Hi"}
##
## then a blank line. `conversation` is the conversation's URL path, which
## also names its `/raw` transcript and where to post a reply; `id` its
## number there; `date` its time as the transcript writes it; `markdown`
## exactly as written.
##
## Without a query the stream is live only. With `?since=<date>`, a date
## written as the events write it, it first sends every message of those
## conversations dated at or after it, oldest first, then the live ones. An
## agent whose connection drops reconnects with the date of the last event
## it read: the messages of that one second may come twice, and each names
## its conversation and id, so a repeat is easy to drop.
##
## The host holds the stream on the agent's own bus key; each message
## posted is published to the key of every agent member of its channel
## (`publish!`), so the host knows nothing of channels.
import pf.Host
import pf.Http
import Conversation
import ConversationKey
import DateTime
import HttpAnswer
import JsonOut
import Message
import UnvalidatedString
import UserId

AgentStream :: [].{

	## Where the stream starts: live only, or with every message since a
	## date; unless the query is neither (`BadSince`).
	start : List(U8) -> Try([Live, Since(DateTime)], [BadSince])
	start = |query|
		if (query.is_empty())
			Ok(Live)
		else if query.starts_with(since_prefix) {
			unchecked = UnvalidatedString.from_utf8(query.drop_first(since_prefix.len())) ? |NotUtf8| BadSince
			date = unchecked.date_time() ? |_| BadSince
			Ok(Since(date))
		} else
			Err(BadSince)

	## Why a stream's start is refused, in words.
	words : [BadSince] -> Str
	words = |BadSince| "The stream's start is not one: none, or `?since=<date>`, a date as 2026-11-02T19:11:32Z."

	## One message of the conversation `key` as one event.
	frame : { key : ConversationKey, message : Message } -> List(U8)
	frame = |{ key, message }| {
		id = U64.from_str(message.id().to_str()) ?? crash "AgentStream.frame: a message's id is its digits"
		fields = JsonOut.json_object([
			("conversation", JsonOut.string(key.url_path(Page))),
			("id", JsonOut.number(id)),
			("from", JsonOut.string(message.author().to_str())),
			("date", JsonOut.string(message.time().to_str())),
			("markdown", JsonOut.string(message.markdown())),
		])
		"data: ".to_utf8().concat(fields.bytes()).concat("\n\n".to_utf8())
	}

	## The events of every message of `conversations` dated at or after
	## `since`, oldest first; messages of one second in the order of
	## `conversations`, then of their ids.
	backlog : {
		conversations : List({ key : ConversationKey, conversation : Conversation }),
		since : DateTime,
	} -> List(U8)
	backlog = |{ conversations, since }| {
		dated = conversations.map_with_index(
			|{ key, conversation }, place|
				conversation.messages().map_with_index(
					|message, at| {
						key,
						message,
						place,
						at,
					},
				),
		).join()
		dated
			.keep_if(|m| m.message.time().compare(since) != Before)
			.sort_with(by_time_then_place)
			.join_map(|m| AgentStream.frame({ key: m.key, message: m.message }))
	}

	## The agent `agent`'s stream: `backlog` first, then every event
	## published to it.
	response : { agent : UserId, backlog : List(U8) } -> Http.Response
	response = |{ agent, backlog: events }|
		HttpAnswer.stream({
			key: bus_key(agent),
			holder: "agent-${agent.to_str()}".to_utf8(),
			backlog: events,
		})

	## Sends a message just posted in the conversation `key` to the stream
	## of each of `agents`, its channel's agent members.
	publish! : {
		key : ConversationKey,
		message : Message,
		agents : List(UserId),
	} => {}
	publish! = |
		{
			key,
			message,
			agents,
		},
	| {
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
		Same => if (a.place != b.place) order_of(a.place, b.place) else order_of(a.at, b.at)
	}

## Which of two places comes first.
order_of : U64, U64 -> [Before, Same, After]
order_of = |a, b| if (a < b) Before else if (a == b) Same else After
