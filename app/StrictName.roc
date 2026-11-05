## This module is a strict name: a name that becomes a file's name and part
## of a URL. Topics (`Topic`) and channels' names (`ChannelName`) are strict
## names.
##
## A strict name is ASCII letters, digits and `-`, starts with a letter,
## and is at most `longest` bytes long. So no space, CR, LF, `/`, `.` or
## `_` reaches a path, a URL or a transcript's reference line. Because it
## starts with a letter and holds no `_`, a strict name never reads as a
## DM's pair of ids (`7_11`), and a message's reference (`MSG_plans_1`)
## splits at its `_`s unambiguously.
import Ascii

StrictName :: Str.{

	## The strict name `name`, or the first reason it is refused, checked in
	## this order: it is empty, its first byte is not a letter, it is longer
	## than `longest`, or it holds a byte other than a letter, a digit or
	## `-`.
	from_str : Str -> Try(StrictName, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	from_str = |name| {
		bytes = name.to_utf8()
		match bytes {
			[] => Err(Empty)
			[first, ..] if !Ascii.is_letter(first) => Err(StartsWithNonLetter)
			_ if bytes.len() > StrictName.longest => Err(TooLong)
			_ if !bytes.all(is_strict_byte) => Err(ForbiddenByte)
			_ => Ok(StrictName.(name))
		}
	}

	## The most bytes a strict name holds. Every byte is ASCII, so this is
	## also the most characters.
	longest : U64
	longest = 60

	## The name, as a file's name and a URL take it.
	to_str : StrictName -> Str
	to_str = |StrictName.(name)| name

	is_eq : _
	to_hash : _
}

## Is `b` a letter, a digit or `-`?
is_strict_byte : U8 -> Bool
is_strict_byte = |b| Ascii.is_letter(b) or Ascii.is_digit(b) or b == '-'

# ── tests
## The strict name `text`, as given, or why it is refused.
strict : Str -> Try(Str, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
strict = |text| StrictName.from_str(text).map_ok(StrictName.to_str)

# Kept as given, case and all.
expect
	["p", "Z", "plans", "aAzZ09-", "gopher-roc-2"].all(|text| strict(text) == Ok(text))
expect strict("") == Err(Empty)
# A first byte that is no letter: a space, a control byte, a digit, `-`,
# `_`, and the bytes just outside the letters' ranges.
expect
	[
		" ",
		"\t",
		"\n",
		"\r",
		"1plans",
		"-plans",
		"_plans",
		"@a",
		"[a",
		"`a",
		"{a",
	].all(|text| strict(text) == Err(StartsWithNonLetter))
# After the first byte, the bytes just outside every allowed range, and
# the bytes a path, a URL or a transcript must never see.
expect
	[
		"a/",
		"a:",
		"a@",
		"a[",
		"a`",
		"a{",
		"a,",
		"a.",
		"plans\nnext",
		"plans\r",
		"plans ",
		"a b",
		"plans_2",
		"café",
	].all(|text| strict(text) == Err(ForbiddenByte))
# The length at, under and over the longest.
expect StrictName.longest == 60
expect strict("a".repeat(59)) == Ok("a".repeat(59))
expect strict("a".repeat(60)) == Ok("a".repeat(60))
expect strict("a".repeat(61)) == Err(TooLong)
# The order: the first byte, then the length, then the other bytes.
expect strict("1${"a".repeat(60)}") == Err(StartsWithNonLetter)
expect strict("a${"a".repeat(59)} ") == Err(TooLong)
expect strict("a${"a".repeat(58)} ") == Err(ForbiddenByte)
