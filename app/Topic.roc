## This module is a topic: a conversation's name. A topic becomes a file's
## name and part of a URL, so it is a strict name (`StrictName`). A topic is
## unique only within its channel or DM; with its place (`Place`) it keys a
## map. Being its own type, a topic can't be passed where a channel's name
## is wanted.
import StrictName

Topic :: StrictName.{

	## The topic `name`, refused as `StrictName.from_str` refuses it.
	from_str : Str -> Try(Topic, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	from_str = |name| StrictName.from_str(name).map_ok(|strict| Topic.(strict))

	## The topic, as a file's name and a URL take it.
	to_str : Topic -> Str
	to_str = |Topic.(strict)| strict.to_str()

	is_eq : _
	to_hash : _
}

# ── tests
# Refused as a strict name is, by each of its refusals; kept as given.
expect Topic.from_str("") == Err(Empty)
expect Topic.from_str("1plans") == Err(StartsWithNonLetter)
expect Topic.from_str("a".repeat(61)) == Err(TooLong)
expect Topic.from_str("plans_2") == Err(ForbiddenByte)
expect Topic.from_str("roc-chat-2").map_ok(Topic.to_str) == Ok("roc-chat-2")
expect Topic.from_str("Plans").map_ok(Topic.to_str) == Ok("Plans")
