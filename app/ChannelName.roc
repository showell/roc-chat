## **A CHANNEL'S NAME**: it becomes a folder's name and a URL, so it is a
## strict name (`StrictName`), and it lives in the one namespace with the
## users' names, so it is a permanent name too (`name`, which uniqueness
## keys). Opaque, so `from_str` is the only way in. A strict name starts
## with a letter and holds no `_`, so no channel's name is ever a DM's
## (`7_11`).
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

	## **THE NAME IN THE NAMESPACE**: the permanent name it spells. A strict
	## name is never blank and holds only letters, digits and `-`, so every
	## one is a permanent name; one that isn't is a broken promise.
	name : ChannelName -> Name
	name = |ChannelName.(strict)|
		Name.from_str(strict.to_str()) ?? crash "ChannelName.name: a strict name is always a permanent name, and \"${strict.to_str()}\" is not"

	is_eq : _
	to_hash : _
}

# ── tests
# Refused as a strict name is, by each of its refusals.
expect
	[
		"",
		"1plans",
		"a".repeat(61),
		"plans_2",
	].map(ChannelName.from_str)
		== [
			Err(Empty),
			Err(StartsWithNonLetter),
			Err(TooLong),
			Err(ForbiddenByte),
		]
# Its permanent name is its own spelling, case kept, at both ends of the
# length.
expect
	[
		"gopher-roc",
		"Gopher-Roc",
		"p",
		"a".repeat(60),
	].map(
		|text| ChannelName.from_str(text).map_ok(|c| (c.to_str(), c.name().to_str())),
	)
		== [
			Ok(("gopher-roc", "gopher-roc")),
			Ok(("Gopher-Roc", "Gopher-Roc")),
			Ok(("p", "p")),
			Ok(("a".repeat(60), "a".repeat(60))),
		]
