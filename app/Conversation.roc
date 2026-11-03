## A conversation is a topic and its messages, in order. It knows nothing
## about where it lives (a channel or a DM), who reads it, or how it is
## stored. The type is opaque, and `append` is the only way to add a
## message, so every conversation has ids 1, 2, 3 and so on, and times that
## don't go backwards.
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

	## Adds a message, giving it the next id. It refuses a message dated
	## before the latest one. A message dated the same second as the latest
	## is fine, since times are to the second.
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

	## The id the next message will get. `Transcript` also uses it, to name
	## the message it is reading when it refuses a file.
	next_id : Conversation -> Try(Message.Id, [Full])
	next_id = |Conversation.(c)|
		match c.messages.last() {
			Ok(latest) => latest.id().next()
			Err(ListWasEmpty) => Ok(Message.Id.first)
		}

	## The reference for message `id`, `MSG_<topic>_<n>`. It's unique only
	## within the conversation's channel or DM, as the topic is.
	reference : Conversation, Message.Id -> MsgAnchor
	reference = |Conversation.(c), id| MsgAnchor.of({ topic: c.topic, id })

	topic : Conversation -> Topic
	topic = |Conversation.(c)| c.topic

	## Oldest first.
	messages : Conversation -> List(Message)
	messages = |Conversation.(c)| c.messages

	## The messages after the first `count`: what a reader who has seen
	## `count` messages hasn't seen yet. Oldest first.
	messages_after : Conversation, U16 -> List(Message)
	messages_after = |Conversation.(c), count| c.messages.drop_first(count.to_u64())

	is_eq : _
}
