## This module is a person's, an agent's or a channel's permanent name. A
## name is kept exactly as it was given, case and all: someone who signs up
## as "Steve Howell" is never shown as "steve howell".
##
## A name is made of letters of `NameAlphabet` and single spaces between
## words, and is at most `longest` characters long. So a name holds no
## digit, punctuation, emoji, control character, or invisible character
## that could make it look like another name.
##
## People, agents and channels share one namespace, in which two names that
## differ only in case are the same name. A name's `key` is what that
## comparison uses.
import NameAlphabet
import StrictName

Name :: NameAlphabet.Written.{

	## The name `name`, or the first reason it is refused, checked in this
	## order: it is empty, it is longer than `longest`, it holds a
	## character that is neither a letter nor a space, or it has a space at
	## either end or two together. The length is checked before the
	## characters, so a long text costs no more than a count.
	from_str : Str -> Try(Name, [Empty, TooLong, ForbiddenCharacter, BadSpacing])
	from_str = |name|
		if (name.is_empty())
			Err(Empty)
		else if (character_count(name) > Name.longest)
			Err(TooLong)
		else {
			written = NameAlphabet.written_text(name)?
			if (name.starts_with(" ") or name.ends_with(" ") or name.contains("  "))
				Err(BadSpacing)
			else
				Ok(Name.(written))
		}

	## The most characters a name holds. An accented letter is one
	## character but two bytes, so a name is at most twice this in bytes.
	longest : U64
	longest = 60

	## The name, exactly as given.
	to_str : Name -> Str
	to_str = |Name.(text)| text.to_str()

	## The name as text written in the alphabet, for `NameAlphabet`'s
	## functions to read.
	written_text : Name -> NameAlphabet.Written
	written_text = |Name.(text)| text

	## A name's place in the namespace: two names are the same name exactly
	## when their keys are equal. Only a name or a strict name makes a key,
	## and a key is never shown.
	Key :: Str.{

		## A strict name's place in the namespace, so a channel `plans` and
		## a user `Plans` have the same key. A strict name is ASCII, so its
		## letters fold as ASCII's do, and its digits and `-` stay.
		of_strict : StrictName -> Name.Key
		of_strict = |strict| Name.Key.(strict.to_str().with_ascii_lowercased())

		is_eq : _
		to_hash : _
	}

	## The name's key: its letters case-folded (`NameAlphabet.case_fold`), so
	## `Zoë` and `ZOË` have the same key.
	key : Name -> Name.Key
	key = |Name.(text)| Name.Key.(NameAlphabet.case_fold(text))

	is_eq : _
}

## How many characters `text` holds: its bytes, less those that continue
## a character (0x80 to 0xBF).
character_count : Str -> U64
character_count = |text| text.to_utf8().count_if(|b| b < 0x80 or b >= 0xC0)

# ── tests
## The name `text`, as given, or why it is refused.
checked_name : Str -> Try(Str, [Empty, TooLong, ForbiddenCharacter, BadSpacing])
checked_name = |text| Name.from_str(text).map_ok(Name.to_str)

# Letters, with single spaces between words, kept as given.
expect
	[
		"Steve Howell",
		"Zoë",
		"Élodie",
		"CC",
		"S",
		"Zoë Ann Smith",
		"sTeVe",
	].all(|text| checked_name(text) == Ok(text))
expect checked_name("") == Err(Empty)
# Anything outside the alphabet, anywhere: a digit, punctuation, an emoji,
# a control byte, an invisible character, a space that isn't ASCII's.
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
	].all(|text| checked_name(text) == Err(ForbiddenCharacter))
# Two spaces together, a space at either end, or spaces alone.
expect
	[
		"Steve  Howell",
		" Zoë",
		"Zoë ",
		" ",
		"  ",
	].all(|text| checked_name(text) == Err(BadSpacing))
# The length at, under and over the longest, in ASCII letters and in
# accented ones, which count one apiece though each is two bytes.
expect Name.longest == 60
expect
	[
		"a".repeat(59),
		"a".repeat(60),
		"é".repeat(60),
		"Zoë ${"a".repeat(56)}",
	].all(|text| checked_name(text) == Ok(text))
expect
	[
		"a".repeat(61),
		"é".repeat(61),
		"Zoë ${"a".repeat(57)}",
	].all(|text| checked_name(text) == Err(TooLong))
# The order: empty, then the length, then a forbidden character, then the
# spacing.
expect checked_name(" Steve!") == Err(ForbiddenCharacter)
expect checked_name(" ${"a".repeat(60)}") == Err(TooLong)
expect checked_name("!${"a".repeat(60)}") == Err(TooLong)
expect checked_name("!${"a".repeat(59)}") == Err(ForbiddenCharacter)
expect checked_name(" ${"a".repeat(59)}") == Err(BadSpacing)
# The name keeps its case; only its key folds it.
expect Name.from_str("Steve") != Name.from_str("steve")

## The key of the name `text`, which a test's text always is.
key_of : Str -> Name.Key
key_of = |text| (Name.from_str(text) ?? crash "Name's tests: a test's name is a name").key()

# Names that differ only in case have one key, accented letters included;
# any other difference keeps them apart.
expect key_of("Steve Howell") == key_of("sTeVe hoWEll")
expect key_of("CC") == key_of("cc")
expect key_of("Zoë") == key_of("ZOË")
expect key_of("Élodie") == key_of("élodie")
expect key_of("ſteve") == key_of("Steve")
expect key_of("Steve Howell") != key_of("Steve Howel")
expect key_of("Steve Howell") != key_of("SteveHowell")
expect key_of("Zoë") != key_of("Zoe")

## The key of the strict name `text`, which a test's text always is.
strict_key_of : Str -> Name.Key
strict_key_of = |text| Name.Key.of_strict(StrictName.from_str(text) ?? crash "Name's tests: a test's strict name is one")

# A strict name has a name's key when its letters match in any case, and
# no name's key while it holds a digit or `-`; its own digits and `-` stay
# in its key.
expect strict_key_of("Plans") == key_of("plans")
expect strict_key_of("plans") == key_of("PLANS")
expect strict_key_of("AZaz") == key_of("azAZ")
expect strict_key_of("gopher-roc") != key_of("gopherroc")
expect strict_key_of("gopher-roc") == strict_key_of("Gopher-Roc")
expect strict_key_of("Gopher-Roc-2") == strict_key_of("gopher-roc-2")
expect strict_key_of("gopher-roc-2") != strict_key_of("gopher-roc-3")
expect strict_key_of("gopher-roc") != strict_key_of("gopherroc")
