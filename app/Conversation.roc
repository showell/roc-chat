## **A CONVERSATION**: a topic and its messages, in id order. It stands
## alone: no channel, no DM, no reader, no file. It grows only by `append`,
## which gives each payload the next id, so a conversation whose ids skip,
## repeat or run backwards can't be built.
import Message
import Topic

Conversation :: {
	topic : Topic,
	messages : List({ id : Message.Id, payload : Message.Payload }),
}.{

	## A conversation with no messages yet.
	empty : Topic -> Conversation
	empty = |topic| Conversation.({ topic, messages: [] })

	## The conversation with `payload` added as its next message, unless it
	## already holds as many as an id can number.
	append : Conversation, Message.Payload -> Try(Conversation, [Full])
	append = |before, payload| {
		id = before.next_id()?
		Conversation.(c) = before
		Ok(Conversation.({ ..c, messages: c.messages.append({ id, payload }) }))
	}

	## The id `append` gives the next message, unless the conversation is
	## full.
	next_id : Conversation -> Try(Message.Id, [Full])
	next_id = |Conversation.(c)|
		match c.messages.last() {
			Ok(latest) => latest.id.next()
			Err(ListWasEmpty) => Ok(Message.Id.first)
		}

	## Its topic.
	topic : Conversation -> Topic
	topic = |Conversation.(c)| c.topic

	## Its messages, oldest first, each with the id `append` gave it.
	messages : Conversation -> List({ id : Message.Id, payload : Message.Payload })
	messages = |Conversation.(c)| c.messages

	is_eq : _
}
