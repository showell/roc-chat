## **A MESSAGE**: who wrote it, when, and what, with the id its
## conversation gives it. Immutable: an edit is a new message. A message
## knows nothing of who may write where; that is the conversation's.
##
## Opaque, so its parts are read, never changed. A message keeps no order
## of its own: `numbered` takes whatever id it is given. The order is
## kept by `Conversation`, which is opaque too, and whose `append` is the
## only way a message joins one, numbered by `Conversation.next_id`.
import Author
import DateTime

Message :: {
	id : Message.Id,
	author : Author,
	time : DateTime,
	markdown : Str,
}.{

	## **WHAT ARRIVES**: who wrote it and the markdown, exactly as written.
	## The message, with its id and time, is made from it as early as
	## possible.
	Payload : {
		author : Author,
		markdown : Str,
	}

	## **A PAYLOAD AND ITS TIME**: what a conversation appends, so the id and
	## the time are added in one place.
	Arrival : {
		payload : Message.Payload,
		time : DateTime,
	}

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

		## The number, as a page's anchors and a refusal write it.
		to_str : Message.Id -> Str
		to_str = |Message.Id.(n)| n.to_str()

		is_eq : _
	}

	## The message numbered `id`, from what arrived.
	numbered : { id : Message.Id, arrival : Message.Arrival } -> Message
	numbered = |{ id, arrival: { payload, time } }|
		Message.(
			{
				id,
				author: payload.author,
				time,
				markdown: payload.markdown,
			},
		)

	## Its id.
	id : Message -> Message.Id
	id = |Message.(m)| m.id

	## Who wrote it.
	author : Message -> Author
	author = |Message.(m)| m.author

	## When.
	time : Message -> DateTime
	time = |Message.(m)| m.time

	## Its markdown, exactly as written.
	markdown : Message -> Str
	markdown = |Message.(m)| m.markdown

	is_eq : _
}

# ── tests
steve : Author
steve = Author.from_str("Steve") ?? crash "Message's tests: an author's name"

noon : DateTime
noon = DateTime.from_str("2026-11-02T12:00:00Z") ?? crash "Message's tests: a time"

hello : Message.Arrival
hello = { payload: { author: steve, markdown: "hello" }, time: noon }

cc : Author
cc = Author.from_str("CC") ?? crash "Message's tests: an author's name"

later : DateTime
later = DateTime.from_str("2026-11-02T12:01:00Z") ?? crash "Message's tests: a time"

## A second arrival, every part unlike `hello`'s, so a message is seen to
## carry its own.
reply : Message.Arrival
reply = { payload: { author: cc, markdown: "hi" }, time: later }

## A message's parts, as a test compares them.
parts : Message -> {
	id : Str,
	author : Author,
	time : DateTime,
	markdown : Str,
}
parts = |m| {
	id: m.id().to_str(),
	author: m.author(),
	time: m.time(),
	markdown: m.markdown(),
}

expect Message.Id.first.to_str() == "1"
expect Message.Id.first.next().map_ok(Message.Id.to_str) == Ok("2")
# The last id at, under and over the highest.
expect Message.Id.(65534).next().map_ok(Message.Id.to_str) == Ok("65535")
expect Message.Id.(65535).next() == Err(Full)
# A message numbered with the id it is given, each part what arrived.
expect parts(Message.numbered({ id: Message.Id.first, arrival: hello })) == {
	id: "1",
	author: steve,
	time: noon,
	markdown: "hello",
}
expect parts(Message.numbered({ id: Message.Id.(65535), arrival: reply })) == {
	id: "65535",
	author: cc,
	time: later,
	markdown: "hi",
}
