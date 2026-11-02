## **A USER'S ID**: a human's or an agent's number, unique and permanent,
## handy in a URL and in a file's name (`UserStem`). Steve is always 1.
##
## **ONE COUNT FOR HUMANS AND AGENTS**, as they share one namespace: an id
## alone says who, with no kind beside it to keep in step, and `apoorva-2`
## and an agent's `cc-3` are never the same number.
##
## **WHY U8**: the chat is a small group of humans and their agents, and
## 255 is many times that. Every id that lasts is written as its decimal
## digits (a file's name, a URL, a DM's name), so a wider type later moves
## no byte on disk.
UserId :: U8.{

	## Steve's id, always: the first user, and the admin (`Admin`).
	steve : UserId
	steve = UserId.(1)

	## The id after this one, unless this is the last a chat holds.
	next : UserId -> Try(UserId, [Full])
	next = |UserId.(n)| if (n == U8.highest) Err(Full) else Ok(UserId.(n + 1))

	## The number, as a URL, a file's name and a DM's name write it.
	to_str : UserId -> Str
	to_str = |UserId.(n)| n.to_str()

	## **WHICH COMES FIRST**, by number: a DM's pair and a channel's
	## members are written in this order.
	compare : UserId, UserId -> [Before, Same, After]
	compare = |
		UserId.(n),
		UserId.(other),
	| if (n < other) Before else if (n == other) Same else After

	is_eq : _
	to_hash : _
}

# ── tests
expect UserId.steve.to_str() == "1"
expect UserId.steve.next().map_ok(UserId.to_str) == Ok("2")
# The last id at, under and over the highest.
expect UserId.(254).next().map_ok(UserId.to_str) == Ok("255")
expect UserId.(255).next() == Err(Full)
# The order, both ways round, and the same id.
expect
	[
		UserId.steve.compare(UserId.(2)),
		UserId.(2).compare(UserId.steve),
		UserId.(2).compare(UserId.(2)),
		UserId.(9).compare(UserId.(10)),
	]
		== [Before, After, Same, Before]
