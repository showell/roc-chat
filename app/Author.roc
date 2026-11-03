## An author is who wrote a message. A transcript records an author only by
## name, so an `Author` is just a `Name`. The name follows the rules in
## `Name`. A user becomes an author through `Users.User.author`.
import Name

Author :: Name.{

	## The author named `name`, refused as `Name.from_str` refuses it.
	from_str : Str -> Try(Author, [Empty, TooLong, ForbiddenCharacter, BadSpacing])
	from_str = |name| Name.from_str(name).map_ok(Author.of)

	of : Name -> Author
	of = |given| Author.(given)

	name : Author -> Name
	name = |Author.(given)| given

	## The name, exactly as given.
	to_str : Author -> Str
	to_str = |Author.(given)| given.to_str()

	is_eq : _
}

# ── tests
# Refused as a name is, by each of its refusals; kept exactly as given.
expect Author.from_str("") == Err(Empty)
expect Author.from_str("a".repeat(61)) == Err(TooLong)
expect Author.from_str("a".repeat(60)).map_ok(Author.to_str) == Ok("a".repeat(60))
expect Author.from_str("Ste\u(200b)ve") == Err(ForbiddenCharacter)
expect Author.from_str(" Steve") == Err(BadSpacing)
expect Author.from_str("Zoë Ann").map_ok(Author.to_str) == Ok("Zoë Ann")
expect {
	steve = Name.from_str("Steve") ?? crash "Author's tests: a name"
	Author.of(steve).name() == steve and Author.of(steve).to_str() == "Steve"
}
