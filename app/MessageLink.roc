## This module is a link to a message, as Gopher Chat's `/chat/msg/<id>`
## named one (angry-gopher's zig-server/src/chat_paths.zig, `parseMsgRef`):
## the path `path_prefix` and the message's reference without its `MSG_`.
## A topic's reference, `<topic>_<n>`, names the message in every place
## with a topic of that name; a channel's, `<channel>.<topic>_<n>`, in that
## channel alone. Neither a channel's name nor a topic holds a `.` or a `_`
## (`StrictName`), so a link reads one way only: the channel before the
## first `.`, the number after the first `_` that follows it.
## `MessageLinkRoute` follows one.
import ChannelName
import Message
import MessageAnchor
import Topic

MessageLink :: [
	InTopic({ topic : Topic, id : Message.Id }),
	InChannel(
		{
			channel : ChannelName,
			topic : Topic,
			id : Message.Id,
		},
	),
].{

	## The path every link to a message starts with.
	path_prefix : Str
	path_prefix = "/chat/msg/"

	## The link `text` spells, the part of its path after `path_prefix`;
	## unless it spells neither reference (`NotAMessageLink`).
	from_str : Str -> Try(MessageLink, [NotAMessageLink])
	from_str = |text|
		match text.split_first(".") {
			Ok({ before, after }) => {
				channel = ChannelName.from_str(before) ? |_| NotAMessageLink
				named = topic_reference(after)?
				Ok(MessageLink.(InChannel({ channel, topic: named.topic, id: named.id })))
			}
			Err(_) => topic_reference(text).map_ok(|named| MessageLink.(InTopic(named)))
		}

	## Which reference it is: a topic's, or a channel's topic's.
	which : MessageLink -> [
		InTopic({ topic : Topic, id : Message.Id }),
		InChannel(
			{
				channel : ChannelName,
				topic : Topic,
				id : Message.Id,
			},
		),
	]
	which = |MessageLink.(link)| link

	## The message it names, by its topic and its id.
	anchor : MessageLink -> MessageAnchor
	anchor = |MessageLink.(link)|
		match link {
			InTopic({ topic, id }) => MessageAnchor.of({ topic, id })
			InChannel({ channel: _, topic, id }) => MessageAnchor.of({ topic, id })
		}

	## Its path: `path_prefix`, then the reference without its `MSG_`.
	url_path : MessageLink -> Str
	url_path = |MessageLink.(link)|
		match link {
			InTopic({ topic, id }) => "${MessageLink.path_prefix}${topic.to_str()}_${id.to_str()}"
			InChannel({ channel, topic, id }) =>
				"${MessageLink.path_prefix}${channel.to_str()}.${topic.to_str()}_${id.to_str()}"
		}

	is_eq : _
}

## The topic and the id `text`, `<topic>_<n>`, spells; unless it spells
## no such pair.
topic_reference : Str -> Try({ topic : Topic, id : Message.Id }, [NotAMessageLink])
topic_reference = |text| {
	parts = text.split_first("_") ? |_| NotAMessageLink
	topic = Topic.from_str(parts.before) ? |_| NotAMessageLink
	id = Message.Id.from_digits(parts.after.to_utf8()) ? |_| NotAMessageLink
	Ok({ topic, id })
}

# ── tests
## The path the link `text` spells is read back as, or why not.
read_back : Str -> Try(Str, [NotAMessageLink])
read_back = |text| MessageLink.from_str(text).map_ok(MessageLink.url_path)

# Each reference, read and written back as given: a topic's and a channel's.
expect
	["plans_3", "road-trip-2_12", "Cobblestone.ChitChat_5", "general.plans_1", "a.b_65535"].all(
		|text| read_back(text) == Ok("/chat/msg/${text}"),
	)
expect
	MessageLink.from_str("general.plans_2").map_ok(|link| link.anchor().page_anchor()) == Ok("msg-2")
# Gopher's shapes that are no reference, and the ones no strict name or
# message id holds: a digit first, a `.` too many, no number, a number off
# its shape.
expect
	[
		"",
		"plans",
		"plans_",
		"_5",
		"plans_5x",
		"plans_5_6",
		"plans_0",
		"plans_07",
		"plans_65536",
		"1st.plans_1",
		"x.y",
		"x.y_",
		".plans_5",
		"a._5",
		"a.b.c_5",
		"-a.plans_5",
		"2026-05-28_5",
		"plans%5F1",
	].all(|text| read_back(text) == Err(NotAMessageLink))
