## This module is a channel's name. A channel's name becomes a folder's
## name and part of a URL, so it is a strict name (`StrictName`). It also
## shares one namespace with people's and agents' names, where its place
## is its `key`.
import Name
import StrictName

ChannelName :: StrictName.{

	## The channel's name `name`, refused as `StrictName.from_str` refuses
	## it.
	from_str : Str -> Try(ChannelName, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	from_str = |name| StrictName.from_str(name).map_ok(|strict| ChannelName.(strict))

	## The name, as a folder's name and a URL take it.
	to_str : ChannelName -> Str
	to_str = |ChannelName.(strict)| strict.to_str()

	## Its place in the namespace it shares with people and agents.
	key : ChannelName -> Name.Key
	key = |ChannelName.(strict)| Name.Key.of_strict(strict)

	is_eq : _
	to_hash : _
}

# ── tests
## The channel named `text`, which a test's text always names.
channel : Str -> ChannelName
channel = |text|
	ChannelName.from_str(text) ?? crash "ChannelName's tests: a test's text is a channel's name"

# Refused as a strict name is, by each of its refusals.
expect ChannelName.from_str("") == Err(Empty)
expect ChannelName.from_str("1plans") == Err(StartsWithNonLetter)
expect ChannelName.from_str("a".repeat(61)) == Err(TooLong)
expect ChannelName.from_str("plans_2") == Err(ForbiddenByte)
# Kept as given, case and all, at both ends of the length.
expect
	[
		"roc-chat",
		"Roc-Chat",
		"p",
		"a".repeat(60),
	].all(|text| ChannelName.from_str(text).map_ok(ChannelName.to_str) == Ok(text))
# Its key is its strict name's: the same in any case, and apart otherwise.
expect
	channel("Roc-Chat").key()
		== Name.Key.of_strict(StrictName.from_str("Roc-Chat") ?? crash "ChannelName's tests: a strict name")
expect channel("Roc-Chat").key() == channel("roc-chat").key()
expect channel("roc-chat").key() != channel("roc-chat-2").key()
