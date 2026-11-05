## This module names one message, from its topic and its id, in two ways.
## Its reference, `MSG_plans_1`, is what a transcript's reference line and a
## page's link write. Its page anchor, `msg-1`, is what an element's id and a
## link's `#` write. roc-markdown also reads references in a message's
## text, with its own copy of the reference's spelling.
##
## A topic is unique only within its channel or DM (`Place`), so
## `MSG_plans_1` names a message in every place that has a topic `plans`,
## and a page anchor names one only on its own page. Pages and links pair a
## reference with its place.
import Message
import Topic

MsgAnchor :: { topic : Topic, id : Message.Id }.{

	## The message `id` of `topic`'s conversation.
	of : { topic : Topic, id : Message.Id } -> MsgAnchor
	of = |named| MsgAnchor.(named)

	## The message's reference, `MSG_<topic>_<id>`.
	to_str : MsgAnchor -> Str
	to_str = |MsgAnchor.({ topic, id })| "MSG_${topic.to_str()}_${id.to_str()}"

	## The message's page anchor, `msg-<id>`, for an element's id and a
	## link's `#`.
	page_anchor : MsgAnchor -> Str
	page_anchor = |MsgAnchor.({ topic: _, id })| "msg-${id.to_str()}"

	is_eq : _
}

# ── tests
## The message `id` under the topic `topic` spells, which a test's topic
## always does.
anchor_of : { topic : Str, id : Message.Id } -> MsgAnchor
anchor_of = |{ topic, id }|
	MsgAnchor.of({
		topic: Topic.from_str(topic) ?? crash "MsgAnchor's tests: a test's topic is one",
		id,
	})

## The second message's id.
second : Message.Id
second = Message.Id.first.next() ?? crash "MsgAnchor's tests: the first id has a next"

# The reference names the topic and the id, at the first id and the next,
# under two topics.
expect anchor_of({ topic: "plans", id: Message.Id.first }).to_str() == "MSG_plans_1"
expect anchor_of({ topic: "plans", id: second }).to_str() == "MSG_plans_2"
expect anchor_of({ topic: "roc-chat", id: second }).to_str() == "MSG_roc-chat_2"
# The page anchor names the id alone.
expect anchor_of({ topic: "plans", id: Message.Id.first }).page_anchor() == "msg-1"
expect anchor_of({ topic: "plans", id: second }).page_anchor() == "msg-2"
expect anchor_of({ topic: "roc-chat", id: second }).page_anchor() == "msg-2"
# Two messages are the same message when both the topic and the id match.
expect anchor_of({ topic: "plans", id: second }) == anchor_of({ topic: "plans", id: second })
expect anchor_of({ topic: "plans", id: second }) != anchor_of({ topic: "other", id: second })
expect anchor_of({ topic: "plans", id: second }) != anchor_of({
	topic: "plans",
	id: Message.Id.first,
})
