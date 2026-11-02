## **HOW ONE MESSAGE IS NAMED**: the one home of both rules for it, side by
## side. Its reference, `MSG_<topic>_<n>`, is what a transcript's id line
## and a page's link write (roc-markdown reads that spelling in a
## message's text too, by its own copy of the rule). Its page anchor,
## `msg-<n>`, is what an element's id and a link's `#` write. Opaque, so
## `of` is the only way in, from a topic and an id.
##
## **UNIQUE ONLY WITHIN ITS PLACE**: a topic is unique only within its
## channel or DM (`Place`), so `MSG_plans_1` names a message in every
## place that has a `plans`, and a page's anchor names one only on its own
## page. Pages and links pair a reference with its place.
import Message
import Topic

MsgAnchor :: { topic : Topic, id : Message.Id }.{

	## The message `id` of `topic`'s conversation.
	of : { topic : Topic, id : Message.Id } -> MsgAnchor
	of = |named| MsgAnchor.(named)

	## **ITS REFERENCE**, `MSG_<topic>_<n>`.
	to_str : MsgAnchor -> Str
	to_str = |MsgAnchor.({ topic, id })| "MSG_${topic.to_str()}_${id.to_str()}"

	## **ITS PAGE ANCHOR**, `msg-<n>`: an element's id and a link's `#`.
	page_anchor : MsgAnchor -> Str
	page_anchor = |MsgAnchor.({ topic: _, id })| "msg-${id.to_str()}"

	is_eq : _
}

# ── tests
## The topic `text` names, which a test's always does.
topic_of : Str -> Topic
topic_of = |text| Topic.from_str(text) ?? crash "MsgAnchor's tests: a test's topic is one"

## The second message's id.
second : Message.Id
second = Message.Id.first.next() ?? crash "MsgAnchor's tests: the first id has a next"

## Each message's reference and page anchor, as a test compares them.
spelled : List(MsgAnchor) -> List((Str, Str))
spelled = |anchors| anchors.map(|anchor| (anchor.to_str(), anchor.page_anchor()))

# The reference names the topic and the id; the page anchor the id alone,
# at the first id and the next, under two topics.
expect
	spelled([
		MsgAnchor.of({ topic: topic_of("plans"), id: Message.Id.first }),
		MsgAnchor.of({ topic: topic_of("plans"), id: second }),
		MsgAnchor.of({ topic: topic_of("gopher-roc"), id: second }),
	])
		== [
			("MSG_plans_1", "msg-1"),
			("MSG_plans_2", "msg-2"),
			("MSG_gopher-roc_2", "msg-2"),
		]
expect
	MsgAnchor.of({ topic: topic_of("plans"), id: second })
		== MsgAnchor.of({ topic: topic_of("plans"), id: second })
expect
	MsgAnchor.of({ topic: topic_of("plans"), id: second })
		!= MsgAnchor.of({ topic: topic_of("other"), id: second })
