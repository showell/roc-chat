## **A MESSAGE**: who wrote it, when, and what, with the id its
## conversation gave it. Immutable: an edit is a new message. A message
## knows nothing of who may write where; that is the conversation's.
import Author
import Timestamp

Message :: {
	id : Message.Id,
	author : Author,
	time : Timestamp,
	markdown : Str,
}.{

	## **A MESSAGE'S ID**: its number in its conversation, counting from 1,
	## so a conversation's order is its ids' order. At most U16's highest,
	## 65,535: a conversation that long is archived, never grown.
	Id :: U16.{

		## The first message's id.
		first : Message.Id
		first = Message.Id.(1)

		## The id after this one, unless this is the last a conversation
		## holds.
		next : Message.Id -> Try(Message.Id, [Full])
		next = |Message.Id.(n)| if (n == U16.highest) Err(Full) else Ok(Message.Id.(n + 1))

		## The id as the transcript and the page write it.
		to_str : Message.Id -> Str
		to_str = |Message.Id.(n)| n.to_str()

		is_eq : _
	}

	## A message from its parts, each already checked by its own type.
	new : {
		id : Message.Id,
		author : Author,
		time : Timestamp,
		markdown : Str,
	} -> Message
	new = |m| Message.(m)

	## Its id in its conversation.
	id : Message -> Message.Id
	id = |Message.(m)| m.id

	## Who wrote it.
	author : Message -> Author
	author = |Message.(m)| m.author

	## When it was written.
	time : Message -> Timestamp
	time = |Message.(m)| m.time

	## What was written: markdown, exactly as written.
	markdown : Message -> Str
	markdown = |Message.(m)| m.markdown

	is_eq : _
}

# ── tests
expect Message.Id.first.to_str() == "1"
expect Message.Id.first.next().map_ok(Message.Id.to_str) == Ok("2")
expect Message.Id.(65534).next().map_ok(Message.Id.to_str) == Ok("65535")
expect Message.Id.(65535).next() == Err(Full)
