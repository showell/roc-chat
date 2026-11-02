## **THE ALPHABET A NAME IS WRITTEN IN**: an allowlist, the one home of
## which letters a permanent name may hold (`Name`), how their case folds,
## and how each is spelled in ASCII. The letters are ASCII's `A`-`Z` and
## `a`-`z`, and the accented Latin ones of Latin-1 (U+00C0 to U+00FF) and
## Latin Extended-A (U+0100 to U+017F) whose fold has an ASCII spelling in
## `spellings`. Anything else (a digit, punctuation, `×`, `÷`, an emoji, a
## control character, an invisible format character such as U+202E or
## U+200B) is refused by not being listed.
##
## **NO LETTER PASSES FOR ANOTHER NAME'S**: `ı`, `ĸ`, `ŀ` and `ŉ` are left
## out of `spellings`, so they are refused, and so is `Ŀ`, whose fold is
## `ŀ`. A dotless `i`, a kra drawn as `k`, an `l` with a dot after it and
## an `n` with an apostrophe before it each let one name look like another.
##
## **BYTE BY BYTE**: every accented letter is two UTF-8 bytes, a lead of
## 0xC3, 0xC4 or 0xC5 and one more, so the rules read bytes, and a `Str`,
## always valid UTF-8, needs no decoder.
import Ascii
import StrictName

NameAlphabet :: [].{

	## **TEXT WRITTEN IN THE ALPHABET**: every character a letter of it or
	## a space. Opaque, so `written` is the only way in, and `folded` and
	## `ascii_spelling` never meet a character they have no rule for.
	Written :: Str.{

		## The text, exactly as given.
		to_str : NameAlphabet.Written -> Str
		to_str = |NameAlphabet.Written.(text)| text

		is_eq : _
	}

	## `text`, written in the alphabet; unless a character of it is no
	## letter of the alphabet and no space.
	written : Str -> Try(NameAlphabet.Written, [ForbiddenCharacter])
	written = |text|
		if (is_all_letters_or_spaces(text.to_utf8()))
			Ok(NameAlphabet.Written.(text))
		else
			Err(ForbiddenCharacter)

	## **THE CASE-FOLDED SPELLING**: each letter of a name's text, or of a
	## strict name, folded by Unicode's simple case folding, so names that
	## differ only in case, `ZOË` and `Zoë`, fold alike. `ſ` folds to `s`,
	## and `ß` and `İ` stay as they are. A strict name's digits and `-`
	## stay as they are.
	folded : [Written(NameAlphabet.Written), Strict(StrictName)] -> Str
	folded = |text|
		letters(text)
			.map(|point| encoded(fold(point)))
			.join()
			|> utf8("NameAlphabet.folded: a letter folds to a letter, and letters are UTF-8")

	## **THE ASCII SPELLING**: each letter of `text` folded, then spelled
	## in ASCII by `spellings`, so in small letters: `Élodie` is `elodie`,
	## `Æsir` is `aesir`; spaces stay as they are.
	ascii_spelling : NameAlphabet.Written -> Str
	ascii_spelling = |text|
		letters(Written(text))
			.map(|point| spelled(fold(point)))
			.join()
			|> utf8("NameAlphabet.ascii_spelling: an ASCII spelling is UTF-8")
}

## **EACH ACCENTED LETTER'S ASCII SPELLING, ITS ONE HOME**: the folded
## letters, in rows, each row spelled as one ASCII text. A two-byte letter
## is in the alphabet exactly when its fold is in a row. `İ` folds to
## itself, so it sits among the small letters.
spellings : List((Str, Str))
spellings = [
	("àáâãäåāăą", "a"),
	("æ", "ae"),
	("çćĉċč", "c"),
	("ðďđ", "d"),
	("èéêëēĕėęě", "e"),
	("ĝğġģ", "g"),
	("ĥħ", "h"),
	("ìíîïĩīĭįİ", "i"),
	("ĳ", "ij"),
	("ĵ", "j"),
	("ķ", "k"),
	("ĺļľł", "l"),
	("ñńņňŋ", "n"),
	("òóôõöøōŏő", "o"),
	("œ", "oe"),
	("ŕŗř", "r"),
	("śŝşš", "s"),
	("ß", "ss"),
	("ţťŧ", "t"),
	("þ", "th"),
	("ùúûüũūŭůűų", "u"),
	("ŵ", "w"),
	("ýÿŷ", "y"),
	("źżž", "z"),
]

## The ASCII spelling of the folded letter `point`, a space or a letter
## of the alphabet: itself, if it is ASCII; else its row's.
spelled : U32 -> List(U8)
spelled = |point|
	if (point < 0x80)
		[point.to_u8_wrap()]
	else
		match row_of(point) {
			Ok((_, ascii)) => ascii.to_utf8()
			Err(NotFound) => crash "NameAlphabet.spelled: written text holds only letters whose fold has a row"
		}

## The row of `spellings` holding the two-byte letter `point`.
row_of : U32 -> Try((Str, Str), [NotFound])
row_of = |point| {
	letter = utf8(encoded(point), "NameAlphabet.row_of: a code point below U+0800 is UTF-8")
	spellings.find_first(|(row, _)| row.contains(letter))
}

## Is `point`, folded, a letter of the alphabet?
is_letter : U32 -> Bool
is_letter = |point| {
	folded = fold(point)
	if (folded < 0x80)
		Ascii.is_letter(folded.to_u8_wrap())
	else
		row_of(folded).is_ok()
}

## Is every character `bytes` hold a letter or a space?
is_all_letters_or_spaces : List(U8) -> Bool
is_all_letters_or_spaces = |bytes|
	match bytes {
		[] => Bool.True
		[b, .. as rest] if b == ' ' or Ascii.is_letter(b) => is_all_letters_or_spaces(rest)
		[lead, b, .. as rest] if lead >= 0xC0 and lead < 0xE0 =>
			is_letter(two_byte(lead, b)) and is_all_letters_or_spaces(rest)
		_ => Bool.False
	}

## The characters of a name's text or a strict name, as code points.
letters : [Written(NameAlphabet.Written), Strict(StrictName)] -> List(U32)
letters = |text| {
	bytes =
		match text {
			Written(written) => written.to_str().to_utf8()
			Strict(strict) => strict.to_str().to_utf8()
		}
	letters_onto({ out: [], bytes })
}

## `out` with each character of `bytes`, one or two bytes each, as a code
## point.
letters_onto : { out : List(U32), bytes : List(U8) } -> List(U32)
letters_onto = |{ out, bytes }|
	match bytes {
		[] => out
		[b, .. as rest] if b < 0x80 => letters_onto({ out: out.append(b.to_u32()), bytes: rest })
		[lead, b, .. as rest] if lead >= 0xC0 and lead < 0xE0 =>
			letters_onto({ out: out.append(two_byte(lead, b)), bytes: rest })
		_ => crash "NameAlphabet.letters_onto: written text and strict names hold only one- and two-byte characters"
	}

## The code point of the two-byte character `lead`, `b`.
two_byte : U8, U8 -> U32
two_byte = |lead, b| (lead - 0xC0).to_u32() * 64 + (b - 0x80).to_u32()

## `bytes` as text, which they always are; `why` says why, if not.
utf8 : List(U8), Str -> Str
utf8 = |bytes, why|
	match Str.from_utf8(bytes) {
		Ok(text) => text
		Err(_) => crash why
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
## Is `text` written in the alphabet?
is_written : Str -> Bool
is_written = |text| NameAlphabet.written(text).is_ok()

## The text `text`, written in the alphabet, which a test's always is.
in_alphabet : Str -> NameAlphabet.Written
in_alphabet = |text| NameAlphabet.written(text) ?? crash "NameAlphabet's tests: a test's text is written in the alphabet"

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
		"ž",
		"ſ",
		"Élodie",
		"Zoë Ann",
	].all(is_written)
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
	].all(|text| !is_written(text))
# The letters that pass for others' are refused, each beside the letter
# next to it, kept; `Ŀ` with its small letter.
expect ["ı", "ĸ", "Ŀ", "ŀ", "ŉ"].all(|text| !is_written(text))
expect ["İ", "ķ", "Ľ", "ľ", "Ł", "ň", "Ŋ"].all(is_written)
# One stray character anywhere refuses the whole text.
expect NameAlphabet.written("Steve!") == Err(ForbiddenCharacter)
expect NameAlphabet.written("R2D2") == Err(ForbiddenCharacter)
expect NameAlphabet.written("Zoëı") == Err(ForbiddenCharacter)
expect NameAlphabet.written("").map_ok(NameAlphabet.Written.to_str) == Ok("")
expect NameAlphabet.written("Zoë Ann").map_ok(NameAlphabet.Written.to_str) == Ok("Zoë Ann")
# The fold: each run's capitals to their small letters, at each run's
# ends; small letters and the uncased ones as they are.
## `text`'s fold, written in the alphabet.
folded_text : Str -> Str
folded_text = |text| NameAlphabet.folded(Written(in_alphabet(text)))

expect
	[
		"AZ",
		"ÀÖ",
		"ØÞ",
		"ĀĮ",
		"ĲĶ",
		"ĹĽ",
		"ŁŇ",
		"ŊŶ",
		"ŹŽ",
		"Ÿ",
		"ſ",
		"ZOË Ann",
	].map(folded_text)
		== [
			"az",
			"àö",
			"øþ",
			"āį",
			"ĳķ",
			"ĺľ",
			"łň",
			"ŋŷ",
			"źž",
			"ÿ",
			"s",
			"zoë ann",
		]
expect
	["azàöøþÿ", "āįĳķĺľłňŋŷźž", "ßİ", " "].map(folded_text)
		== ["azàöøþÿ", "āįĳķĺľłňŋŷźž", "ßİ", " "]
# A strict name folds its letters, and keeps its digits and `-`.
expect {
	strict = StrictName.from_str("Gopher-Roc-2") ?? crash "NameAlphabet's tests: a strict name"
	NameAlphabet.folded(Strict(strict)) == "gopher-roc-2"
}
# The ASCII spelling: every row's letters, each its row's spelling.
expect
	spellings.all(
		|(row, ascii)| {
			count = letters(Written(in_alphabet(row))).len()
			NameAlphabet.ascii_spelling(in_alphabet(row)) == ascii.repeat(count)
		},
	)
# The ends of each range, capitals and small letters, folded and spelled.
expect
	[
		"AZaz",
		"ÀÅàå",
		"ÇçÈËèëÌÏìï",
		"ÐðÑñÒÖòöØø",
		"ÙÜùüÝýÿŸ",
		"ĀąĆčĎđĒěĜģĤħĨİ",
		"ĴĵĶķĹľŁłŃňŊŋ",
		"ŌőŔřŚšŢŧŨųŴŵŶŷŹž",
		"ſ",
	].map(|text| NameAlphabet.ascii_spelling(in_alphabet(text)))
		== [
			"azaz",
			"aaaa",
			"cceeeeiiii",
			"ddnnoooooo",
			"uuuuyyyy",
			"aaccddeegghhii",
			"jjkkllllnnnn",
			"oorrssttuuwwyyzz",
			"s",
		]
# Every letter spelled with more than one: capitals and small letters.
expect
	[
		"ß",
		"Æ",
		"æ",
		"Ĳ",
		"ĳ",
		"Œ",
		"œ",
		"Þ",
		"þ",
	].map(|text| NameAlphabet.ascii_spelling(in_alphabet(text)))
		== ["ss", "ae", "ae", "ij", "ij", "oe", "oe", "th", "th"]
# Whole names, spaces kept.
expect
	[
		"Élodie",
		"Zoë Ann",
		"Æsir Þór",
		"Łukasz Ő",
	].map(|text| NameAlphabet.ascii_spelling(in_alphabet(text)))
		== ["elodie", "zoe ann", "aesir thor", "lukasz o"]
