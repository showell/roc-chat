## **A CONVERSATION**: a topic and its messages, in id order. It stands
## alone: no channel, no DM, no reader, no file. Opaque, so it grows only
## by `append`, which numbers each message by `next_id` and refuses one
## dated before the latest, so a conversation whose ids skip, repeat or run
## backwards, or whose times run backwards, can't be built.
import Author
import Message
import MsgAnchor
import Topic

Conversation :: {
	topic : Topic,
	messages : List(Message),
}.{

	## A conversation with no messages yet.
	empty : Topic -> Conversation
	empty = |topic| Conversation.({ topic, messages: [] })

	## The conversation with the unnumbered message added as its next
	## message, and that message, numbered by `next_id`; unless it already
	## holds as many as an id can number (`Full`, asked first), or the
	## unnumbered message is dated before its latest message (`Backdated`).
	##
	## **TIMES NEVER GO BACKWARDS**: a message's time is never earlier than
	## its conversation's latest. Equal is allowed: times are to the
	## second, and two messages can share one.
	append : Conversation,
	Message.Unnumbered(Author) -> Try(
		{ conversation : Conversation, message : Message },
		[Full, Backdated],
	)
	append = |conversation, unnumbered_message| {
		id = Conversation.next_id(conversation)?
		Conversation.(c) = conversation
		match c.messages.last() {
			Ok(latest) if unnumbered_message.time.compare(latest.time()) == Before => Err(Backdated)
			_ => {
				message = Message.numbered({ id, unnumbered: unnumbered_message })
				Ok({
					conversation: Conversation.({ ..c, messages: c.messages.append(message) }),
					message,
				})
			}
		}
	}

	## **THE NEXT MESSAGE'S ID, ITS ONE HOME**: 1 for the first, else the
	## one after the latest's, unless the conversation is full. `append`
	## numbers by it, and a reader asks it first, to name the message it is
	## reading in a refusal.
	next_id : Conversation -> Try(Message.Id, [Full])
	next_id = |Conversation.(c)|
		match c.messages.last() {
			Ok(latest) => latest.id().next()
			Err(ListWasEmpty) => Ok(Message.Id.first)
		}

	## **HOW THE MESSAGE `id` IS NAMED** (`MsgAnchor`): its reference,
	## `MSG_<topic>_<n>`, and its page anchor. Unique only within the
	## conversation's place, as its topic is: pages and links pair it with
	## the `Place`.
	reference : Conversation, Message.Id -> MsgAnchor
	reference = |Conversation.(c), id| MsgAnchor.of({ topic: c.topic, id })

	## Its topic.
	topic : Conversation -> Topic
	topic = |Conversation.(c)| c.topic

	## Its messages, oldest first, each numbered by `append`.
	messages : Conversation -> List(Message)
	messages = |Conversation.(c)| c.messages

	## **THE MESSAGES A READER HAS NOT SEEN**, oldest first: those past the
	## first `count`, which are the ones numbered past `count`, as `append`
	## numbers from 1 with no gap.
	messages_after : Conversation, U16 -> List(Message)
	messages_after = |Conversation.(c), count| c.messages.drop_first(count.to_u64())

	is_eq : _
}
