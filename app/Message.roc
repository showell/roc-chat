## **A MESSAGE**: who wrote it, when, and what, with the id its
## conversation gave it. Immutable: an edit is a new message. A message
## knows nothing of who may write where; that is the conversation's.
Message :: {
	id : U64,
	author : Str,
	at : Str,
	markdown : Str,
}.{

	## A message from its parts. Ids count from 1, and a message has an
	## author.
	new : { id : U64, author : Str, at : Str, markdown : Str } -> Try(Message, [NoId, NoAuthor])
	new = |m|
		if m.id == 0 {
			Err(NoId)
		} else if m.author.trim() == "" {
			Err(NoAuthor)
		} else {
			Ok(Message.(m))
		}

	## Its number in its conversation, from 1.
	id : Message -> U64
	id = |Message.(m)| m.id

	## Who wrote it, by their permanent name.
	author : Message -> Str
	author = |Message.(m)| m.author

	## When it was written: an ISO 8601 time in UTC.
	at : Message -> Str
	at = |Message.(m)| m.at

	## What was written: markdown, exactly as written.
	markdown : Message -> Str
	markdown = |Message.(m)| m.markdown

	is_eq : _
}

# ── tests
expect Message.new({ id: 0, author: "Steve", at: "", markdown: "hi" }).map_ok(Message.id) == Err(NoId)
expect Message.new({ id: 1, author: " ", at: "", markdown: "hi" }).map_ok(Message.id) == Err(NoAuthor)
expect Message.new({ id: 1, author: "Steve", at: "", markdown: "hi" }).map_ok(Message.author) == Ok("Steve")
