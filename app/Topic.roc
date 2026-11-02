## **A TOPIC**: a conversation's name, which becomes a file name and a URL,
## so it is a strict name (`StrictName`, the one home of that rule). A
## topic is unique only within its channel or DM. Opaque, so `from_str` is
## the only way in, and a topic is never mistaken for a channel's name.
## With its place (`Place`), it keys a map.
import StrictName

Topic :: StrictName.{

	## The topic named `name`, refused as `StrictName.from_str` refuses it.
	from_str : Str -> Try(Topic, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	from_str = |name| StrictName.from_str(name).map_ok(|strict| Topic.(strict))

	## The name, as a file name and a URL take it.
	to_str : Topic -> Str
	to_str = |Topic.(strict)| strict.to_str()

	is_eq : _
	to_hash : _
}

# ── tests
# Refused as a strict name is, by each of its refusals; kept as given.
expect
	[
		"",
		"1plans",
		"a".repeat(61),
		"plans_2",
	].map(Topic.from_str)
		== [
			Err(Empty),
			Err(StartsWithNonLetter),
			Err(TooLong),
			Err(ForbiddenByte),
		]
expect Topic.from_str("gopher-roc-2").map_ok(Topic.to_str) == Ok("gopher-roc-2")
