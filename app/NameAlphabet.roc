## This module is the alphabet a person's, an agent's or a channel's name is
## written in (`Name`). It decides which letters a name may hold, how each
## letter's case folds, and how each letter is spelled in ASCII.
##
## The alphabet is an allowlist. Its letters are ASCII's `A` to `Z` and `a`
## to `z`, and the accented Latin letters of Latin-1 (U+00C0 to U+00FF) and
## Latin Extended-A (U+0100 to U+017F) that have a row in `spellings`.
## Anything else is refused because it isn't listed: a digit, punctuation,
## `×`, `÷`, an emoji, a control character, or an invisible character such
## as U+202E or U+200B.
##
## Some Latin letters are left out because they let one name pass for
## another: a dotless `ı`, a kra `ĸ` that looks like `k`, the dotted `ŀ`
## and its capital `Ŀ`, and `ŉ` with its apostrophe.
##
## Every accented letter is two bytes of UTF-8, so the module reads a
## name's bytes directly; a `Str` is always valid UTF-8.
import Ascii

NameAlphabet :: [].{

	## Text written in the alphabet: every character is a letter of it or a
	## space. Only `written_text` makes one, so `case_fold` and `ascii_spelling`
	## never meet a character they have no rule for.
	Written :: Str.{

		## The text, exactly as given.
		to_str : NameAlphabet.Written -> Str
		to_str = |NameAlphabet.Written.(text)| text

		is_eq : _
	}

	## `text` as written text, or `ForbiddenCharacter` if any character
	## of it is neither a letter of the alphabet nor a space.
	written_text : Str -> Try(NameAlphabet.Written, [ForbiddenCharacter])
	written_text = |text|
		if (is_all_letters_or_spaces(text.to_utf8()))
			Ok(NameAlphabet.Written.(text))
		else
			Err(ForbiddenCharacter)

	## `text` with each letter case-folded by Unicode's simple case
	## folding, so `ZOË` and `Zoë` fold to the same text. `ſ` folds to `s`;
	## `ß` and `İ` have no simple fold and stay as they are.
	case_fold : NameAlphabet.Written -> Str
	case_fold = |text|
		code_points(text)
			.map(|point| utf8_bytes(fold(point)))
			.join()
			|> decode_utf8("NameAlphabet.case_fold: a letter folds to a letter, and letters are UTF-8")

	## `text` folded, then each letter spelled in ASCII by `spellings`:
	## `Élodie` is `elodie`, and `Æsir` is `aesir`. Spaces stay as they are.
	ascii_spelling : NameAlphabet.Written -> Str
	ascii_spelling = |text|
		code_points(text)
			.map(|point| point_spelling(fold(point)))
			.join()
			|> decode_utf8("NameAlphabet.ascii_spelling: an ASCII spelling is UTF-8")
}

## Each accented letter's ASCII spelling. A row holds folded letters and
## the ASCII text each one is spelled as. A two-byte letter is in the
## alphabet exactly when its fold is in a row. `İ` folds to itself, so it
## sits among the small letters.
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

## The ASCII spelling of the folded letter or space `point`: itself if it
## is ASCII, else its row's spelling.
point_spelling : U32 -> List(U8)
point_spelling = |point|
	if (point < 0x80)
		[point.to_u8_wrap()]
	else
		match row_of(point) {
			Ok((_, ascii)) => ascii.to_utf8()
			Err(NotFound) =>
				crash "NameAlphabet.point_spelling: written text holds only letters whose fold has a row"
		}

## The row of `spellings` that holds the two-byte letter `point`.
row_of : U32 -> Try((Str, Str), [NotFound])
row_of = |point| {
	letter = decode_utf8(
		utf8_bytes(point),
		"NameAlphabet.row_of: a code point below U+0800 is UTF-8",
	)
	spellings.find_first(|(row, _)| row.contains(letter))
}

## Is `point`, once folded, a letter of the alphabet?
is_letter : U32 -> Bool
is_letter = |point| {
	folded = fold(point)
	if (folded < 0x80)
		Ascii.is_letter(folded.to_u8_wrap())
	else
		row_of(folded).is_ok()
}

## Is every character of `bytes` a letter of the alphabet or a space?
is_all_letters_or_spaces : List(U8) -> Bool
is_all_letters_or_spaces = |bytes|
	match bytes {
		[] => Bool.True
		[b, .. as rest] if b == ' ' or Ascii.is_letter(b) => is_all_letters_or_spaces(rest)
		[lead, b, .. as rest] if lead >= 0xC0 and lead < 0xE0 =>
			is_letter(two_byte_code_point(lead, b)) and is_all_letters_or_spaces(rest)
		_ => Bool.False
	}

## The code points of `text`'s characters.
code_points : NameAlphabet.Written -> List(U32)
code_points = |text| code_points_onto({ out: [], bytes: text.to_str().to_utf8() })

## `out` with the code point of each character of `bytes` appended. Every
## character of written text is one or two bytes.
code_points_onto : { out : List(U32), bytes : List(U8) } -> List(U32)
code_points_onto = |{ out, bytes }|
	match bytes {
		[] => out
		[b, .. as rest] if b < 0x80 => code_points_onto({
			out: out.append(b.to_u32()),
			bytes: rest,
		})
		[lead, b, .. as rest] if lead >= 0xC0 and lead < 0xE0 =>
			code_points_onto({ out: out.append(two_byte_code_point(lead, b)), bytes: rest })
		_ =>
			crash "NameAlphabet.code_points_onto: written text holds only one- and two-byte characters"
	}

## The code point of the two-byte character whose bytes are `lead`, `b`.
two_byte_code_point : U8, U8 -> U32
two_byte_code_point = |lead, b| (lead - 0xC0).to_u32() * 64 + (b - 0x80).to_u32()

## `bytes` decoded as UTF-8, which they always are; a crash saying `why`
## if they aren't.
decode_utf8 : List(U8), Str -> Str
decode_utf8 = |bytes, why|
	match Str.from_utf8(bytes) {
		Ok(text) => text
		Err(_) => crash why
	}

## The fold of the letter `point`, by Unicode's simple case folding: its
## small letter if it is a capital, else itself.
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
	else if (is_capital_of_pair(point))
		point + 1
	else
		point

## Is `point` a capital in Latin Extended-A whose small letter follows it?
## The pairs start on an even code point in three runs and an odd one in
## two.
is_capital_of_pair : U32 -> Bool
is_capital_of_pair = |point| {
	is_even = point % 2 == 0
	(point >= 0x100 and point <= 0x12F and is_even)
		or (point >= 0x132 and point <= 0x137 and is_even)
		or (point >= 0x139 and point <= 0x148 and !is_even)
		or (point >= 0x14A and point <= 0x177 and is_even)
		or (point >= 0x179 and point <= 0x17E and !is_even)
}

## The UTF-8 bytes of a code point below U+0800: one byte below 0x80, else
## two.
utf8_bytes : U32 -> List(U8)
utf8_bytes = |point|
	if (point < 0x80)
		[point.to_u8_wrap()]
	else
		[(0xC0 + point // 64).to_u8_wrap(), (0x80 + point % 64).to_u8_wrap()]

# ── tests
## Is `text` written in the alphabet?
is_written : Str -> Bool
is_written = |text| NameAlphabet.written_text(text).is_ok()

## `text` as written text, which a test's text always is.
in_alphabet : Str -> NameAlphabet.Written
in_alphabet = |text|
	NameAlphabet.written_text(text)
		?? crash "NameAlphabet's tests: a test's text is written in the alphabet"

# Each end of every range is kept, and the character just past it is
# refused: ASCII's letters, Latin-1's (around `×` and `÷`) and Latin
# Extended-A's.
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
# The letters that pass for others are refused; the letters beside them
# are kept.
expect ["ı", "ĸ", "Ŀ", "ŀ", "ŉ"].all(|text| !is_written(text))
expect ["İ", "ķ", "Ľ", "ľ", "Ł", "ň", "Ŋ"].all(is_written)
# One stray character anywhere refuses the whole text.
expect NameAlphabet.written_text("Steve!") == Err(ForbiddenCharacter)
expect NameAlphabet.written_text("R2D2") == Err(ForbiddenCharacter)
expect NameAlphabet.written_text("Zoëı") == Err(ForbiddenCharacter)
expect NameAlphabet.written_text("").map_ok(NameAlphabet.Written.to_str) == Ok("")
expect NameAlphabet.written_text("Zoë Ann").map_ok(NameAlphabet.Written.to_str) == Ok("Zoë Ann")

## The fold of `text`.
folded_text : Str -> Str
folded_text = |text| NameAlphabet.case_fold(in_alphabet(text))

# Each run's capitals fold to their small letters, at each run's ends.
expect folded_text("AZ") == "az"
expect folded_text("ÀÖ") == "àö"
expect folded_text("ØÞ") == "øþ"
expect folded_text("ĀĮ") == "āį"
expect folded_text("ĲĶ") == "ĳķ"
expect folded_text("ĹĽ") == "ĺľ"
expect folded_text("ŁŇ") == "łň"
expect folded_text("ŊŶ") == "ŋŷ"
expect folded_text("ŹŽ") == "źž"
expect folded_text("Ÿ") == "ÿ"
expect folded_text("ſ") == "s"
expect folded_text("ZOË Ann") == "zoë ann"
# Small letters, the letters with no simple fold, and spaces stay.
expect
	["azàöøþÿ", "āįĳķĺľłňŋŷźž", "ßİ", " "].all(|text| folded_text(text) == text)
# Every letter of every row is spelled as its row says.
expect
	spellings.all(
		|(row, ascii)| {
			count = code_points(in_alphabet(row)).len()
			NameAlphabet.ascii_spelling(in_alphabet(row)) == ascii.repeat(count)
		},
	)

## The ASCII spelling of `text`.
ascii_text : Str -> Str
ascii_text = |text| NameAlphabet.ascii_spelling(in_alphabet(text))

# The ends of each range, capitals and small letters, folded and spelled.
expect ascii_text("AZaz") == "azaz"
expect ascii_text("ÀÅàå") == "aaaa"
expect ascii_text("ÇçÈËèëÌÏìï") == "cceeeeiiii"
expect ascii_text("ÐðÑñÒÖòöØø") == "ddnnoooooo"
expect ascii_text("ÙÜùüÝýÿŸ") == "uuuuyyyy"
expect ascii_text("ĀąĆčĎđĒěĜģĤħĨİ") == "aaccddeegghhii"
expect ascii_text("ĴĵĶķĹľŁłŃňŊŋ") == "jjkkllllnnnn"
expect ascii_text("ŌőŔřŚšŢŧŨųŴŵŶŷŹž") == "oorrssttuuwwyyzz"
expect ascii_text("ſ") == "s"
# Every letter spelled with more than one, capital and small.
expect ascii_text("ß") == "ss"
expect ascii_text("Æ") == "ae"
expect ascii_text("æ") == "ae"
expect ascii_text("Ĳ") == "ij"
expect ascii_text("ĳ") == "ij"
expect ascii_text("Œ") == "oe"
expect ascii_text("œ") == "oe"
expect ascii_text("Þ") == "th"
expect ascii_text("þ") == "th"
# Whole names, with their spaces.
expect ascii_text("Élodie") == "elodie"
expect ascii_text("Zoë Ann") == "zoe ann"
expect ascii_text("Æsir Þór") == "aesir thor"
expect ascii_text("Łukasz Ő") == "lukasz o"
