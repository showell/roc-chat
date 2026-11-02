## **A CHANNEL'S NAME**: it becomes a folder's name and a URL, so it is a
## strict name (`StrictName`), and it lives in the one namespace with the
## users' names, where its place is its key (`Name.Key.of_strict`).
## Opaque, so `from_str` is the only way in. A strict name starts with a
## letter and holds no `_`, so no channel's name is ever a DM's (`7_11`).
import Name
import StrictName

ChannelName :: StrictName.{

	## The channel named `name`, refused as `StrictName.from_str` refuses
	## it.
	from_str : Str -> Try(ChannelName, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	from_str = |name| StrictName.from_str(name).map_ok(|strict| ChannelName.(strict))

	## The name, as a folder's name and a URL take it.
	to_str : ChannelName -> Str
	to_str = |ChannelName.(strict)| strict.to_str()

	## Its place in the namespace it shares with the users.
	key : ChannelName -> Name.Key
	key = |ChannelName.(strict)| Name.Key.of_strict(strict)

	is_eq : _
	to_hash : _
}

# ── tests
# Refused as a strict name is, by each of its refusals.
expect ChannelName.from_str("") == Err(Empty)
expect ChannelName.from_str("1plans") == Err(StartsWithNonLetter)
expect ChannelName.from_str("a".repeat(61)) == Err(TooLong)
expect ChannelName.from_str("plans_2") == Err(ForbiddenByte)
# Kept as given, case and all, at both ends of the length; its key is a
# strict name's.
expect ChannelName.from_str("gopher-roc").map_ok(|c| c.to_str()) == Ok("gopher-roc")
expect ChannelName.from_str("Gopher-Roc").map_ok(|c| c.to_str()) == Ok("Gopher-Roc")
expect ChannelName.from_str("p").map_ok(|c| c.to_str()) == Ok("p")
expect ChannelName.from_str("a".repeat(60)).map_ok(|c| c.to_str()) == Ok("a".repeat(60))
expect {
	text = "Gopher-Roc"
	channel = ChannelName.from_str(text) ?? crash "ChannelName's tests: a channel's name"
	strict = StrictName.from_str(text) ?? crash "ChannelName's tests: a strict name"
	channel.key() == Name.Key.of_strict(strict)
}
