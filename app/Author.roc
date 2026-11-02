## **AN AUTHOR**: who wrote a message, by their permanent name (`Name`,
## the one home of the rule a name obeys). An author is a user in the role
## of writing, and the transcript records only the name, so an author is
## only the name.
import Name

Author :: Name.{

	## The author named `name`, refused as `Name.from_str` refuses it.
	from_str : Str -> Try(Author, [Blank, ControlByte, FormatCharacter, Padded])
	from_str = |name| Name.from_str(name).map_ok(Author.of)

	## The author of that name.
	of : Name -> Author
	of = |given| Author.(given)

	## The permanent name.
	name : Author -> Name
	name = |Author.(given)| given

	## The name, exactly as given.
	to_str : Author -> Str
	to_str = |Author.(given)| given.to_str()

	is_eq : _
}

# ── tests
# Refused as a name is, by each of its refusals; kept exactly as given.
expect
	[
		"",
		"Ste\nve",
		"Ste\u(200b)ve",
		" Steve",
	].map(Author.from_str)
		== [
			Err(Blank),
			Err(ControlByte),
			Err(FormatCharacter),
			Err(Padded),
		]
expect Author.from_str("Zoë Ann").map_ok(Author.to_str) == Ok("Zoë Ann")
expect {
	steve = Name.from_str("Steve") ?? crash "Author's tests: a name"
	(Author.of(steve).name(), Author.of(steve).to_str()) == (steve, "Steve")
}
