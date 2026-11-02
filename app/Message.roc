## **A MESSAGE**: who wrote it, when, and what, with the id its
## conversation gives it. Immutable: an edit is a new message. A message
## knows nothing of who may write where; that is the conversation's.
##
## Opaque, and its ids come only from a chain: a message is the first, or
## the one `after` another, so message n exists only after message n - 1.
## `Conversation.append` is that chain's one keeper, so a conversation's
## order is its ids' order.
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

	## A conversation's first message.
	first : Message.Arrival -> Message
	first = |arrival| numbered({ id: Message.Id.first, arrival })

	## The message after `latest`, unless `latest` has the last id a
	## conversation holds.
	after : Message, Message.Arrival -> Try(Message, [Full])
	after = |Message.(latest), arrival| {
		id = latest.id.next()?
		Ok(numbered({ id, arrival }))
	}

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

## A second arrival, every part unlike `hello`'s, so a message `after`
## another is seen to carry its own.
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
# The first message is 1, the one after it 2, each with what arrived.
expect parts(Message.first(hello)) == {
	id: "1",
	author: steve,
	time: noon,
	markdown: "hello",
}
expect
	Message.first(hello).after(reply).map_ok(parts)
		== Ok({
			id: "2",
			author: cc,
			time: later,
			markdown: "hi",
		})
# After the last id, no message.
expect numbered({ id: Message.Id.(65534), arrival: hello }).after(reply).map_ok(parts) == Ok({
	id: "65535",
	author: cc,
	time: later,
	markdown: "hi",
})
expect numbered({ id: Message.Id.(65535), arrival: hello }).after(reply) == Err(Full)
