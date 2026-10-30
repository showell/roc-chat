## **THE NAME A PRINCIPAL GOES BY** (the Roc chat's auth design, section 1):
## a human chooses one at sign-up, and it "doesn't even have to be a real
## one" (Steve), but one is required; an agent's and a bot's names are held
## to the same rule. What the rule refuses is only what would hurt a reader
## or the store:
## - **UTF-8**, as every text is;
## - **trimmed of spaces at both ends,** then **1 to 64 bytes** (a byte
##   count, as every limit is: it protects the store, not a look);
## - **no control character**: ASCII's (a newline, a tab, DEL) and the C1
##   controls (U+0080 to U+009F), which would break a stored line or a page;
## - **no bidirectional control** (U+200E, U+200F, U+061C, U+202A to
##   U+202E, U+2066 to U+2069), which can make a name read as another one
##   reversed;
## - **no format or default-ignorable character**, which draws nothing:
##   Unicode's Cf (the soft hyphen U+00AD, U+200B to U+200F, U+2060 to
##   U+2064, U+FEFF, the tag characters U+E0000 to U+E007F, and the rest),
##   and the other default-ignorables (U+034F, the Hangul fillers, U+180B
##   to U+180F, U+FFF0 to U+FFF8, U+E0000 to U+E0FFF); the variation
##   selectors alone are kept, since an emoji's look needs U+FE0F;
## - **no line or paragraph separator** (U+2028, U+2029), and **no space
##   but ASCII's** (U+00A0, U+1680, U+2000 to U+200A, U+202F, U+205F,
##   U+3000), which a reader cannot tell from it or from nothing;
## - **something visible**: a name of combining marks, variation selectors
##   or a blank Braille cell alone is refused.
## Anything else goes: letters of any script, punctuation, emoji, spaces
## inside. Opaque, so a name that passed is the only kind there is. Pure.
##
## **Look-alikes are not this rule's to solve.** "Аnn" with a Cyrillic А is
## a name, and confusables are left alone: a renderer shows a display name
## with its principal's kind and its GitHub login (or its owner's) beside
## it, so an impersonation is visible there, where both names are.
import Ascii
import Bytes

DisplayName :: Str.{

	## Why a name is refused. **ONE ALIAS ON PURPOSE**: one rule for a name
	## wherever it comes from (sign-in, an agent's, a stored account), so
	## each refusal of one wraps this whole as `NameRefused`.
	Problem : [
		NotUtf8,
		Empty,
		TooLong,
		ControlCharacter,
		BidiControl,
		FormatCharacter,
		LineSeparator,
		NonAsciiSpace,
		NothingVisible,
	]

	## The name the bytes spell, as a form handed them.
	from_utf8 : List(U8) -> Try(DisplayName, DisplayName.Problem)
	from_utf8 = |bytes|
		match Str.from_utf8(bytes) {
			Ok(text) => DisplayName.from_str(text)
			Err(_) => Err(NotUtf8)
		}

	## The name `text` is, trimmed, when the rule takes it.
	from_str : Str -> Try(DisplayName, DisplayName.Problem)
	from_str = |text| {
		bytes = trim_spaces(Str.to_utf8(text))
		if bytes == [] {
			Err(Empty)
		} else if List.len(bytes) > max_bytes {
			Err(TooLong)
		} else if List.any(bytes, Ascii.is_control) or has_c1_control(bytes) {
			Err(ControlCharacter)
		} else if List.any(
			bidi_controls,
			|c| Bytes.find(bytes, { needle: Str.to_utf8(c), at: 0 }).is_ok(),
		) {
			Err(BidiControl)
		} else {
			points = code_points(bytes)
			if List.any(points, is_format) {
				Err(FormatCharacter)
			} else if List.any(points, |p| p == line_separator or p == paragraph_separator) {
				Err(LineSeparator)
			} else if List.any(points, is_other_space) {
				Err(NonAsciiSpace)
			} else if List.all(points, is_invisible) {
				Err(NothingVisible)
			} else {
				match Str.from_utf8(bytes) {
					Ok(name) => Ok(DisplayName.(name))
					Err(_) => crash "DisplayName.from_str: UTF-8 trimmed of ASCII spaces is UTF-8"
				}
			}
		}
	}

	## The name's text.
	to_str : DisplayName -> Str
	to_str = |DisplayName.(s)| s

	is_eq : _
}

## The most bytes a name may have.
max_bytes : U64
max_bytes = 64

## The first byte of every C1 control in UTF-8 (U+0080 to U+00BF begin with
## it), and the second bytes of the controls among them.
c1_lead : U8
c1_lead = 0xC2

c1_first : U8
c1_first = 0x80

c1_last : U8
c1_last = 0x9F

## The bidirectional controls: the marks, the embeddings and overrides, and
## the isolates.
bidi_controls : List(Str)
bidi_controls = [
	"\u(200E)",
	"\u(200F)",
	"\u(061C)",
	"\u(202A)",
	"\u(202B)",
	"\u(202C)",
	"\u(202D)",
	"\u(202E)",
	"\u(2066)",
	"\u(2067)",
	"\u(2068)",
	"\u(2069)",
]

## **THE CODE POINTS OF UTF-8 BYTES** (`from_str` has its bytes from a
## Str, so they are UTF-8): each sequence's lead byte says its length,
## and each continuation byte carries six bits.
code_points : List(U8) -> List(U32)
code_points = |bytes| {
	bits = |b| b.to_u32() - continuation
	match bytes {
		[] => []
		[
			b0,
			b1,
			b2,
			b3,
			..,
		] if b0 >= lead4 =>
			List.prepend(
				code_points(List.drop_first(bytes, 4)),
				(b0.to_u32() - lead4.to_u32()) * 262144 + bits(b1) * 4096 + bits(b2) * 64 + bits(b3),
			)
		[
			b0,
			b1,
			b2,
			..,
		] if b0 >= lead3 =>
			List.prepend(
				code_points(List.drop_first(bytes, 3)),
				(b0.to_u32() - lead3.to_u32()) * 4096 + bits(b1) * 64 + bits(b2),
			)
		[b0, b1, ..] if b0 >= lead2 =>
			List.prepend(
				code_points(List.drop_first(bytes, 2)),
				(b0.to_u32() - lead2.to_u32()) * 64 + bits(b1),
			)
		[b0, ..] => List.prepend(code_points(List.drop_first(bytes, 1)), b0.to_u32())
	}
}

## The lead bytes of a two-, three- and four-byte sequence start here, and
## a continuation byte's six bits are what it holds past `continuation`.
lead2 : U8
lead2 = 0xC0

lead3 : U8
lead3 = 0xE0

lead4 : U8
lead4 = 0xF0

continuation : U32
continuation = 0x80

## `point` is in one of `ranges`, each from its first to its last, both in.
is_in : U32, List((U32, U32)) -> Bool
is_in = |point, ranges| List.any(ranges, |(first, last)| point >= first and point <= last)

## **FORMAT AND DEFAULT-IGNORABLE CHARACTERS**: Unicode's Cf, and the
## other default-ignorables but the variation selectors.
is_format : U32 -> Bool
is_format = |point|
	is_in(
		point,
		[
			(0xAD, 0xAD),
			(0x34F, 0x34F),
			(0x600, 0x605),
			(0x61C, 0x61C),
			(0x6DD, 0x6DD),
			(0x70F, 0x70F),
			(0x890, 0x891),
			(0x8E2, 0x8E2),
			(0x115F, 0x1160),
			(0x17B4, 0x17B5),
			(0x180B, 0x180F),
			(0x200B, 0x200F),
			(0x202A, 0x202E),
			(0x2060, 0x206F),
			(0x3164, 0x3164),
			(0xFEFF, 0xFEFF),
			(0xFFA0, 0xFFA0),
			(0xFFF0, 0xFFFB),
			(0x110BD, 0x110BD),
			(0x110CD, 0x110CD),
			(0x13430, 0x1343F),
			(0x1BCA0, 0x1BCA3),
			(0x1D173, 0x1D17A),
			(0xE0000, 0xE00FF),
			(0xE01F0, 0xE0FFF),
		],
	)

line_separator : U32
line_separator = 0x2028

paragraph_separator : U32
paragraph_separator = 0x2029

## **A SPACE THAT IS NOT ASCII'S**: Unicode's Zs but U+0020.
is_other_space : U32 -> Bool
is_other_space = |point|
	is_in(
		point,
		[
			(0xA0, 0xA0),
			(0x1680, 0x1680),
			(0x2000, 0x200A),
			(0x202F, 0x202F),
			(0x205F, 0x205F),
			(0x3000, 0x3000),
		],
	)

## **DRAWS NOTHING ON ITS OWN**: the ASCII space, a combining mark, a
## variation selector, the blank Braille cell.
is_invisible : U32 -> Bool
is_invisible = |point|
	is_in(
		point,
		[
			(0x20, 0x20),
			(0x300, 0x36F),
			(0x1AB0, 0x1AFF),
			(0x1DC0, 0x1DFF),
			(0x20D0, 0x20FF),
			(0x2800, 0x2800),
			(0xFE00, 0xFE0F),
			(0xFE20, 0xFE2F),
			(0xE0100, 0xE01EF),
		],
	)

## Spaces off both ends; only the ASCII space, since every other ASCII
## space is a control character, refused rather than trimmed.
trim_spaces : List(U8) -> List(U8)
trim_spaces = |bytes| {
	is_space = |c| c == ' '
	front = List.drop_first(bytes, Bytes.count_while(bytes, is_space))
	List.drop_last(front, Bytes.count_back(front, is_space))
}

## A C1 control's two bytes are somewhere in `bytes`.
has_c1_control : List(U8) -> Bool
has_c1_control = |bytes|
	match bytes {
		[lead, second, ..] =>
			if lead == c1_lead and second >= c1_first and second <= c1_last {
				Bool.True
			} else {
				has_c1_control(List.drop_first(bytes, 1))
			}
		_ => Bool.False
	}

# ── tests

named : Str -> Try(Str, DisplayName.Problem)
named = |text| DisplayName.from_str(text).map_ok(DisplayName.to_str)

# Taken: anything readable, real or not, trimmed.
expect named("Steve") == Ok("Steve")
expect named("  Steve Howell  ") == Ok("Steve Howell")
expect named("x") == Ok("x")
expect named("🦊 fox of the woods") == Ok("🦊 fox of the woods")
expect named("Zoë, née Ünal") == Ok("Zoë, née Ünal")
expect named("名前") == Ok("名前")
expect named("a  b") == Ok("a  b")
expect named("Robert'); DROP TABLE") == Ok("Robert'); DROP TABLE")
expect named("<script>") == Ok("<script>")
expect named("role=admin name=x") == Ok("role=admin name=x")

# The length: 64 bytes, counted after the trim; 65 refused; a multi-byte
# character counts its bytes.
sixty_four : Str
sixty_four = Str.repeat("n", 64)

expect named(sixty_four) == Ok(sixty_four)
expect named("  ${sixty_four}  ") == Ok(sixty_four)
expect named(Str.repeat("n", 65)) == Err(TooLong)
expect named(Str.repeat("é", 32)) == Ok(Str.repeat("é", 32))
expect named(Str.repeat("é", 33)) == Err(TooLong)

# Empty, or spaces alone.
expect named("") == Err(Empty)
expect named("   ") == Err(Empty)

# Control characters: ASCII's at each end and inside, DEL, and C1's.
expect
	List.all(
		[
			"a\nb",
			"a\rb",
			"\tab",
			"ab\n",
			"a\u(0)b",
			"a\u(7F)b",
			"a\u(80)b",
			"a\u(85)b",
			"a\u(9F)b",
		],
		|bad| named(bad) == Err(ControlCharacter),
	)

# Next to the C1 range, and other two-byte characters, are fine.
expect named("a\u(A1)b") == Ok("a\u(A1)b")
expect named("a\u(7E)b") == Ok("a~b")

# **NAMES THAT LOOK LIKE NOTHING**: a
# format or default-ignorable character anywhere; a line or paragraph
# separator; a space not ASCII's; nothing visible at all.
expect
	List.all(
		[
			"\u(200B)",
			"\u(FEFF)",
			"Ann\u(200D)",
			"\u(AD)",
			"A\u(AD)nn",
			"\u(E0041)",
			"Ann\u(E0001)",
			"\u(2060)",
			"\u(34F)x",
			"\u(3164)",
			"\u(115F)",
			"\u(FFA0)",
			"\u(180E)",
			"\u(600)1",
			"\u(FFF9)x",
		],
		|bad| named(bad) == Err(FormatCharacter),
	)
expect named("Ann\u(2028)Admin") == Err(LineSeparator)
expect named("Ann\u(2029)") == Err(LineSeparator)
expect
	List.all(
		[
			"\u(A0)",
			"a\u(A0)b",
			"\u(3000)",
			"Ann\u(3000)Admin",
			"a\u(2003)b",
			"a\u(202F)b",
			"a\u(205F)b",
			"a\u(1680)b",
		],
		|bad| named(bad) == Err(NonAsciiSpace),
	)
expect
	List.all(
		[
			"\u(301)",
			"\u(301)\u(302)",
			"\u(FE0F)",
			"\u(2800)",
			" \u(20DD) ",
		],
		|bad| named(bad) == Err(NothingVisible),
	)
# Kept: a variation selector on something visible, a combining mark on a
# letter, a letter of another script.
expect named("\u(2764)\u(FE0F)") == Ok("\u(2764)\u(FE0F)")
expect named("e\u(301)") == Ok("e\u(301)")
expect named("\u(1F98A)") == Ok("\u(1F98A)")
# A look-alike is a name: a Cyrillic А before "nn" passes, and the
# renderer shows the login beside it (the module's note).
expect named("\u(410)nn") == Ok("\u(410)nn")

# The code points: one, two, three and four bytes.
expect code_points(Str.to_utf8("a\u(E9)\u(20AC)\u(1F98A)")) == [
	0x61,
	0xE9,
	0x20AC,
	0x1F98A,
]

# Bidirectional controls, each one.
expect List.all(bidi_controls, |c| named("ab${c}cd") == Err(BidiControl))
expect named("\u(202E)nimda") == Err(BidiControl)

# Bytes that are not UTF-8.
expect DisplayName.from_utf8([0x61, 0xff]).map_ok(DisplayName.to_str) == Err(NotUtf8)
expect DisplayName.from_utf8(Str.to_utf8(" Ann ")).map_ok(DisplayName.to_str) == Ok("Ann")
