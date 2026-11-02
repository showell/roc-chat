## **A CONVERSATION**: a topic and its messages, in id order. It stands
## alone: no channel, no DM, no reader, no file. It grows only by `append`,
## which makes each message the one after its latest, so a conversation
## whose ids skip, repeat or run backwards can't be built.
import Message
import Topic

Conversation :: {
	topic : Topic,
	messages : List(Message),
}.{

	## A conversation with no messages yet.
	empty : Topic -> Conversation
	empty = |topic| Conversation.({ topic, messages: [] })

	## The conversation with what arrived added as its next message, its id
	## and time given here, unless it already holds as many as an id can
	## number.
	append : Conversation, Message.Arrival -> Try(Conversation, [Full])
	append = |Conversation.(c), arrival| {
		added =
			match c.messages.last() {
				Ok(latest) => latest.after(arrival)?
				Err(ListWasEmpty) => Message.first(arrival)
			}
		Ok(Conversation.({ ..c, messages: c.messages.append(added) }))
	}

	## The id `append` gives the next message, unless the conversation is
	## full.
	next_id : Conversation -> Try(Message.Id, [Full])
	next_id = |Conversation.(c)|
		match c.messages.last() {
			Ok(latest) => latest.id().next()
			Err(ListWasEmpty) => Ok(Message.Id.first)
		}

	## **THE ONE NAME OF A MESSAGE**, `MSG_<topic>_<n>`, as a transcript's
	## id line and a page's link write it.
	reference : Conversation, Message.Id -> Str
	reference = |Conversation.(c), id| "MSG_${c.topic.to_str()}_${id.to_str()}"

	## Its topic.
	topic : Conversation -> Topic
	topic = |Conversation.(c)| c.topic

	## Its messages, oldest first, each numbered by `append`.
	messages : Conversation -> List(Message)
	messages = |Conversation.(c)| c.messages

	is_eq : _
}
