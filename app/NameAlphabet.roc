## **THE ALPHABET A NAME IS WRITTEN IN**: an allowlist, the one home of
## which letters a permanent name may hold (`Name`), and of how their case
## folds. The letters are ASCII's `A`-`Z` and `a`-`z`, and the accented
## Latin ones: Latin-1's (U+00C0 to U+00FF, but for `×` and `÷`) and Latin
## Extended-A's (U+0100 to U+017F). Anything else (a digit, punctuation,
## an emoji, a control character, an invisible format character such as
## U+202E or U+200B) is refused by not being listed.
##
## **BYTE BY BYTE**: every accented letter is two UTF-8 bytes, a lead of
## 0xC3, 0xC4 or 0xC5 and one more, so both rules match on bytes, and a
## `Str`, always valid UTF-8, needs no decoder.
import Ascii

NameAlphabet :: [].{

	## Is every character of `text` a letter of the alphabet or a space?
	is_written_in : Str -> Bool
	is_written_in = |text| is_all_letters_or_spaces(text.to_utf8())

	## **THE CASE-FOLDED SPELLING**: each letter of `text`, which is written
	## in the alphabet or is ASCII, folded by Unicode's simple case folding, so names
	## that differ only in case, `ZOË` and `Zoë`, fold alike. `ſ` folds to
	## `s`, and `ß`, `ĸ`, `ŉ`, `ı` and `İ` stay as they are.
	folded : Str -> Str
	folded = |text|
		Str.from_utf8(
			folded_onto({
				out: [],
				bytes: text.to_utf8(),
			}),
		) ?? crash "NameAlphabet.folded: a letter folds to a letter, and letters are UTF-8"
}

## Is every character `bytes` hold a letter or a space?
is_all_letters_or_spaces : List(U8) -> Bool
is_all_letters_or_spaces = |bytes|
	match bytes {
		[] => Bool.True
		[b, .. as rest] if b == ' ' or Ascii.is_letter(b) => is_all_letters_or_spaces(rest)
		[
			0xC3,
			b,
			.. as rest,
		] if b >= 0x80 and b != 0x97 and b != 0xB7 => is_all_letters_or_spaces(rest)
		[lead, _, .. as rest] if lead == 0xC4 or lead == 0xC5 => is_all_letters_or_spaces(rest)
		_ => Bool.False
	}

## `out` with each character of `bytes`, which are written in the
## alphabet, folded.
folded_onto : { out : List(U8), bytes : List(U8) } -> List(U8)
folded_onto = |{ out, bytes }|
	match bytes {
		[] => out
		[lead, b, .. as rest] if lead >= 0xC3 and lead <= 0xC5 => {
			point = (lead - 0xC0).to_u32() * 64 + (b - 0x80).to_u32()
			folded_onto({ out: out.concat(encoded(fold(point))), bytes: rest })
		}
		[b, .. as rest] => {
			point = b.to_u32()
			folded_onto({ out: out.concat(encoded(fold(point))), bytes: rest })
		}
	}

## **ONE LETTER'S FOLD**: its lower case, where it has one by Unicode's
## simple case folding.
fold : U32 -> U32
fold = |point|
	if (point >= 'A' and point <= 'Z')
		point + 32
	else if (point >= 0xC0 and point <= 0xDE and point != 0xD7)
		point + 0x20
	else if (point == 0x178)
		0xFF
	else if (point == 0x17F)
		's'
	else if (is_upper_of_pair(point))
		point + 1
	else
		point

## **LATIN EXTENDED-A'S CASE PAIRS**: each capital is followed by its small
## letter, from an even code point in three runs and an odd one in two.
is_upper_of_pair : U32 -> Bool
is_upper_of_pair = |point| {
	is_even = point % 2 == 0
	(point >= 0x100 and point <= 0x12F and is_even)
		or (point >= 0x132 and point <= 0x137 and is_even)
		or (point >= 0x139 and point <= 0x148 and !is_even)
		or (point >= 0x14A and point <= 0x177 and is_even)
		or (point >= 0x179 and point <= 0x17E and !is_even)
}

## A code point below U+0800 as UTF-8: one byte below 0x80, else two.
encoded : U32 -> List(U8)
encoded = |point|
	if (point < 0x80)
		[point.to_u8_wrap()]
	else
		[(0xC0 + point // 64).to_u8_wrap(), (0x80 + point % 64).to_u8_wrap()]

# ── tests
# Each end of every listed range kept, and the character beside it, past
# the list, refused: ASCII's letters, Latin-1's (around `×` and `÷`) and
# Latin Extended-A's.
expect
	[
		"A",
		"Z",
		"a",
		"z",
		" ",
		"À",
		"Ö",
		"Ø",
		"ö",
		"ø",
		"ÿ",
		"Ā",
		"ſ",
		"Élodie",
		"Zoë Ann",
	].all(NameAlphabet.is_written_in)
expect
	[
		"@",
		"[",
		"`",
		"{",
		"¿",
		"×",
		"÷",
		"ƀ",
		"0",
		"9",
		"!",
		"-",
		"'",
		".",
		"\t",
		"\u(0)",
		"\u(a0)",
		"\u(202e)",
		"\u(200b)",
		"\u(feff)",
		"😀",
		"李",
	].all(|text| !NameAlphabet.is_written_in(text))
# One stray character anywhere refuses the whole text.
expect !NameAlphabet.is_written_in("Steve!")
expect !NameAlphabet.is_written_in("R2D2")
expect NameAlphabet.is_written_in("")
# The fold: each run's capitals to their small letters, at each run's
# ends; small letters and the uncased ones as they are.
expect
	[
		"AZ",
		"ÀÖ",
		"ØÞ",
		"ĀĮ",
		"ĲĶ",
		"ĹŇ",
		"ŊŶ",
		"ŹŽ",
		"Ÿ",
		"ſ",
		"ZOË Ann",
	].map(NameAlphabet.folded)
		== ["az", "àö", "øþ", "āį", "ĳķ", "ĺň", "ŋŷ", "źž", "ÿ", "s", "zoë ann"]
expect
	["azàöøþÿ", "āįĳķĺňŋŷźž", "ßĸŉıİ", " "].map(NameAlphabet.folded)
		== ["azàöøþÿ", "āįĳķĺňŋŷźž", "ßĸŉıİ", " "]
