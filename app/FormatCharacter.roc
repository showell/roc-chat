## **UNICODE'S FORMAT CHARACTERS (CATEGORY Cf)**: the invisible characters
## that steer how text around them is drawn, the one home of their set.
## Bidirectional overrides (U+202E draws what follows backwards) and
## zero-width characters (U+200B, U+200D, U+FEFF) let one name be drawn as
## another, so a permanent name refuses them (`Name`).
##
## **THE SET IS UNICODE 15.1's Cf**, written out as its ranges in `ranges`.
## A later Unicode can add to it; a pin move is the moment to compare.
##
## **WHY IT DECODES UTF-8 ITSELF**: the pinned Roc's `Str` has no way to
## its code points. A `Str` is always valid UTF-8, so each lead byte says
## how many bytes its character takes, and no check is needed.
FormatCharacter :: [].{

	## Does `text` hold a format character anywhere?
	is_in : Str -> Bool
	is_in = |text| code_points_onto({ out: [], bytes: text.to_utf8() }).any(is_format)
}

## **AN INTERVAL OF THE SET**: its first code point and its last, both in
## it.
Interval : { first : U32, last : U32 }

## Every Cf code point, by range, lowest first.
ranges : List(Interval)
ranges = [
	{ first: 0xAD, last: 0xAD },
	{ first: 0x600, last: 0x605 },
	{ first: 0x61C, last: 0x61C },
	{ first: 0x6DD, last: 0x6DD },
	{ first: 0x70F, last: 0x70F },
	{ first: 0x890, last: 0x891 },
	{ first: 0x8E2, last: 0x8E2 },
	{ first: 0x180E, last: 0x180E },
	{ first: 0x200B, last: 0x200F },
	{ first: 0x202A, last: 0x202E },
	{ first: 0x2060, last: 0x2064 },
	{ first: 0x2066, last: 0x206F },
	{ first: 0xFEFF, last: 0xFEFF },
	{ first: 0xFFF9, last: 0xFFFB },
	{ first: 0x110BD, last: 0x110BD },
	{ first: 0x110CD, last: 0x110CD },
	{ first: 0x13430, last: 0x1343F },
	{ first: 0x1BCA0, last: 0x1BCA3 },
	{ first: 0x1D173, last: 0x1D17A },
	{ first: 0xE0001, last: 0xE0001 },
	{ first: 0xE0020, last: 0xE007F },
]

## Is `point` a format character?
is_format : U32 -> Bool
is_format = |point| ranges.any(|range| point >= range.first and point <= range.last)

## `out` with the code point of each character `bytes` holds, in order.
## The lead byte says the length: below 0x80 one byte, from 0xC0 two, from
## 0xE0 three, from 0xF0 four; each later byte carries six bits.
code_points_onto : { out : List(U32), bytes : List(U8) } -> List(U32)
code_points_onto = |{ out, bytes }|
	match bytes {
		[] => out
		[
			lead,
			b2,
			b3,
			b4,
			.. as rest,
		] if lead >= 0xF0 =>
			code_points_onto({
				out: out.append(
					bits([
						lead - 0xF0,
						b2 - 0x80,
						b3 - 0x80,
						b4 - 0x80,
					]),
				),
				bytes: rest,
			})
		[
			lead,
			b2,
			b3,
			.. as rest,
		] if lead >= 0xE0 =>
			code_points_onto({
				out: out.append(
					bits([
						lead - 0xE0,
						b2 - 0x80,
						b3 - 0x80,
					]),
				),
				bytes: rest,
			})
		[lead, b2, .. as rest] if lead >= 0xC0 =>
			code_points_onto({
				out: out.append(bits([lead - 0xC0, b2 - 0x80])),
				bytes: rest,
			})
		[lead, .. as rest] => code_points_onto({ out: out.append(lead.to_u32()), bytes: rest })
	}

## The code point whose six-bit groups are `groups`, most significant first.
bits : List(U8) -> U32
bits = |groups| groups.fold(0, |point, group| point * 64 + group.to_u32())

# ── tests
## Each code point's character, from its UTF-32 bytes.
character : U32 -> Str
character = |point| {
	bytes = [
		(point % 256).to_u8_wrap(),
		(point // 256 % 256).to_u8_wrap(),
		(point // 65536).to_u8_wrap(),
		0,
	]
	Str.from_utf32_le(bytes) ?? crash "FormatCharacter's tests: a test's code point is a character"
}

# The characters a security review named, each refused alone and inside a
# name.
expect
	[0x202E, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]
		.map(
			|point| (
				FormatCharacter.is_in(character(point)),
				FormatCharacter.is_in("Ste${character(point)}ve"),
			),
		)
		== List.repeat((Bool.True, Bool.True), 6)
# Every range's first and last code point is in the set, and the code point
# on each side of it is not.
expect ranges.all(|range| FormatCharacter.is_in(character(range.first)) and FormatCharacter.is_in(character(range.last)))
expect
	ranges.all(|range| !FormatCharacter.is_in(character(range.first - 1)) and !FormatCharacter.is_in(character(range.last + 1)))
# Every length of character decoded: one byte, two, three and four.
expect code_points_onto({ out: [], bytes: "a¡€😀".to_utf8() }) == [0x61, 0xA1, 0x20AC, 0x1F600]
expect code_points_onto({ out: [], bytes: [] }) == []
# Each length at its lowest and highest code point.
expect
	[0x0, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF].all(
		|point| code_points_onto({ out: [], bytes: character(point).to_utf8() }) == [point],
	)
# Text with no format character, plain and not, is clean.
expect !FormatCharacter.is_in("Steve Howell")
expect !FormatCharacter.is_in("Zoë 🎉 李")
expect !FormatCharacter.is_in("")
