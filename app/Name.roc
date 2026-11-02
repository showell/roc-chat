## **A PERMANENT NAME**: a human's, an agent's or a channel's, exactly as
## given, the one home of the rule every name obeys. Names are permanent
## and case-sensitive: someone who signs up as "Steve Howell" is never shown
## as "steve howell". Opaque, so `from_str` is the only way in.
##
## **LETTERS, AND SINGLE SPACES BETWEEN WORDS**: every character is a
## letter of the name's alphabet (`NameAlphabet`, an allowlist: ASCII's
## letters and the accented Latin ones) or a space, and the spaces fall
## only between words, one at a time. So no name holds a digit,
## punctuation, an emoji, a control byte that could end a transcript's
## `from:` line, or an invisible character that could draw it as another
## name, and a permanent name looks like itself.
##
## **ONE NAMESPACE, UNIQUE REGARDLESS OF CASE**: humans, agents and
## channels share it, so no two of them have names that differ only in
## case. `key` is the one spelling that uniqueness compares.
import NameAlphabet
import StrictName

Name :: Str.{

	## The name `name`, or the first reason, in this order, it is refused:
	## empty, a character outside the alphabet that is no space, or a space
	## at either end or beside another.
	from_str : Str -> Try(Name, [Empty, ForbiddenCharacter, BadSpacing])
	from_str = |name|
		if (name.is_empty())
			Err(Empty)
		else if (!NameAlphabet.is_written_in(name))
			Err(ForbiddenCharacter)
		else if (name.starts_with(" ") or name.ends_with(" ") or name.contains("  "))
			Err(BadSpacing)
		else
			Ok(Name.(name))

	## The name, exactly as given.
	to_str : Name -> Str
	to_str = |Name.(name)| name

	## **WHAT UNIQUENESS COMPARES**: two names are the same name in the
	## namespace exactly when their keys are equal. Opaque, so a key is only
	## ever a name's, and is never shown.
	Key :: Str.{

		## **A CHANNEL'S PLACE IN THE NAMESPACE**: a strict name's key, its
		## letters folded as a name's are, so a channel `plans` and a user
		## `Plans` share one. A strict name is ASCII, and its digits and `-`,
		## which no name holds, are kept as they are.
		of_strict : StrictName -> Name.Key
		of_strict = |strict| Name.Key.(NameAlphabet.folded(strict.to_str()))

		is_eq : _
		to_hash : _
	}

	## **THE NAME'S KEY**: its letters case-folded (`NameAlphabet.folded`),
	## so `Zoë` and `ZOË` are one name.
	key : Name -> Name.Key
	key = |Name.(name)| Name.Key.(NameAlphabet.folded(name))

	is_eq : _
}

# ── tests
## The name `text`, as given, or why it is refused.
named : Str -> Try(Str, [Empty, ForbiddenCharacter, BadSpacing])
named = |text| Name.from_str(text).map_ok(Name.to_str)

# Names of letters, with single spaces between words, kept as given.
expect
	["Steve Howell", "Zoë", "Élodie", "CC", "S", "Zoë Ann Smith", "sTeVe"].map(named)
		== [
			Ok("Steve Howell"),
			Ok("Zoë"),
			Ok("Élodie"),
			Ok("CC"),
			Ok("S"),
			Ok("Zoë Ann Smith"),
			Ok("sTeVe"),
		]
expect named("") == Err(Empty)
# Anything outside the alphabet, anywhere: a digit, punctuation, an emoji,
# a control byte, a format character, a space that isn't ASCII's.
expect
	[
		"Steve!",
		"R2D2",
		"Steve 😀",
		"Ste\nve",
		"Steve\u(202e)llewoH",
		"\u(200b)",
		"Ste\u(200d)ve",
		"\u(feff)Steve",
		"Steve\u(a0)Howell",
		"Steve-Howell",
		"O'Brien",
		"\t",
	].map(named)
		== List.repeat(Err(ForbiddenCharacter), 12)
# Spaces: one between words kept; two together, or one at either end, or
# a name of spaces alone, refused.
expect
	[
		"Steve  Howell",
		" Zoë",
		"Zoë ",
		" ",
		"  ",
	].map(named)
		== List.repeat(Err(BadSpacing), 5)
# The order: a forbidden character is named before bad spacing.
expect named(" Steve!") == Err(ForbiddenCharacter)
# The key: names that differ only in case share one, accented letters
# included; any other difference keeps them apart.
## The key of the name `text`, which a test's text always is.
key_of : Str -> Name.Key
key_of = |text| (Name.from_str(text) ?? crash "Name's tests: a test's name is a name").key()

expect key_of("Steve Howell") == key_of("sTeVe hoWEll")
expect key_of("CC") == key_of("cc")
expect key_of("Zoë") == key_of("ZOË")
expect key_of("Élodie") == key_of("élodie")
expect key_of("ſteve") == key_of("Steve")
expect key_of("Steve Howell") != key_of("Steve Howel")
expect key_of("Steve Howell") != key_of("SteveHowell")
expect key_of("Zoë") != key_of("Zoe")
# A strict name's key: a user's of the same letters in any case, and no
# user's while it holds a digit or `-`.
## The key of the strict name `text`, which a test's always is.
strict_key_of : Str -> Name.Key
strict_key_of = |text| Name.Key.of_strict(StrictName.from_str(text) ?? crash "Name's tests: a test's strict name is one")

expect strict_key_of("Plans") == key_of("plans")
expect strict_key_of("plans") == key_of("PLANS")
expect strict_key_of("gopher-roc") != key_of("gopherroc")
expect strict_key_of("gopher-roc") == strict_key_of("Gopher-Roc")
# The name keeps its case; only the key folds it.
expect Name.from_str("Steve") != Name.from_str("steve")
