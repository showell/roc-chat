## This module writes a message's excerpt, the one line of plain text
## Recent shows under a conversation's name, from the message's markdown,
## as Gopher Chat's Recent wrote it (recent_feed.zig's `recentExcerpt`).
## Each quote-reply's fence (a fence whose language is `quote`) becomes
## `[quoted text]`, so a reply's new words survive the cut; any other
## fence loses its opening and closing lines, its code kept; each other line
## loses its markdown marks (`MarkdownMarks`), so the excerpt reads as text;
## each image, an
## HTML `<img ...>` or markdown's `![...](...)`, becomes `[image]`; each run
## of white space becomes one space, and the ends are trimmed; and the text
## is cut at `most_code_points`, with `…` after it.
import Ascii
import MarkdownMarks

RecentExcerpt :: [].{

	## The most code points an excerpt keeps before its `…`.
	most_code_points : U64
	most_code_points = 350

	## The excerpt of `markdown`.
	markdown_excerpt : Str -> Str
	markdown_excerpt = |markdown| {
		quoted = collapse_quotes(markdown.split_on("\n"))
		pictured = replace_markdown_images(replace_html_images(quoted.to_utf8()))
		spaced = collapse_white_space(pictured)
		cut_at_most(spaced, RecentExcerpt.most_code_points)
	}
}

## A fence's opening line, as Gopher's markdown read one: up to three
## spaces, then 3 to 10 of one of `` ` `` or `~`, then its information,
## whose first word is its language. A backtick fence's information holds
## no backtick.
FenceOpening : {
	mark : U8,
	count : U64,
	language : Str,
}

## The opening `line` is, or `NotAFence`.
fence_opening : Str -> Try(FenceOpening, [NotAFence])
fence_opening = |line| {
	bytes = line.to_utf8()
	indent = count_leading({ bytes, byte: ' ', from: 0 })
	if indent >= 4 {
		Err(NotAFence)
	} else {
		mark = bytes.get(indent) ? |_| NotAFence
		count = count_leading({ bytes, byte: mark, from: indent })
		information =
			Str.from_utf8_lossy(bytes.drop_first(indent + count)).trim()
		if (mark != '`' and mark != '~') or count < 3 or count > 10 {
			Err(NotAFence)
		} else if mark == '`' and information.contains("`") {
			Err(NotAFence)
		} else {
			Ok({
				mark,
				count,
				language: first_part(first_part(information, " "), "\t"),
			})
		}
	}
}

## Whether `line` closes a fence opened by `opening`: up to three spaces,
## at least as many of its mark, then only white space.
is_fence_closing : Str, FenceOpening -> Bool
is_fence_closing = |line, opening| {
	bytes = line.to_utf8()
	indent = count_leading({ bytes, byte: ' ', from: 0 })
	count = count_leading({ bytes, byte: opening.mark, from: indent })
	rest = Str.from_utf8_lossy(bytes.drop_first(indent + count))
	indent < 4 and count >= opening.count and rest.trim().is_empty()
}

## The part of `text` before its first `split`, or all of it.
first_part : Str, Str -> Str
first_part = |text, split|
	text.split_on(split).first() ?? crash "RecentExcerpt.first_part: a split holds one part at least"

## How many of `byte` run in `bytes` from `from`.
count_leading : {
	bytes : List(U8),
	byte : U8,
	from : U64,
} -> U64
count_leading = |{ bytes, byte, from }|
	match bytes.get(from) {
		Ok(found) if found == byte => 1 + count_leading({ bytes, byte, from: from + 1 })
		_ => 0
	}

## `lines` with each quote fence, to its closing line or the end, as the
## line `[quoted text]`; any other fence as its code alone, its lines never
## read as openings or as prose; and every other line as prose
## (`MarkdownMarks.prose_line`).
collapse_quotes : List(Str) -> Str
collapse_quotes = |lines| {
	var $kept = []
	var $fence = NoFence
	for line in lines {
		match $fence {
			NoFence =>
				match fence_opening(line) {
					Ok(opening) => {
						$fence = InFence(opening)
						if opening.language == "quote" {
							$kept = $kept.append("[quoted text]")
						}
					}
					Err(NotAFence) => {
						$kept = $kept.append(MarkdownMarks.prose_line(line))
					}
				}
			InFence(opening) =>
				if is_fence_closing(line, opening) {
					$fence = NoFence
				} else if opening.language != "quote" {
					$kept = $kept.append(line)
				}
		}
	}
	Str.join_with($kept, "\n")
}

## `bytes` with each `<img` that no letter, digit or `_` follows, to the
## next `>`, as `[image]`, the case of `img` aside.
replace_html_images : List(U8) -> List(U8)
replace_html_images = |bytes| {
	var $out = []
	var $at = 0
	while $at < bytes.len() {
		match html_image_end({ bytes, at: $at }) {
			Found(end) => {
				$out = List.concat($out, "[image]".to_utf8())
				$at = end + 1
			}
			_ => {
				$out = $out.append(bytes.get($at) ?? crash "RecentExcerpt: the loop stays inside the bytes")
				$at = $at + 1
			}
		}
	}
	$out
}

## Just past the `<img ...>` that starts at `at`, or `NoneFound`; a
## byte other than `<` is looked at no further.
html_image_end : { bytes : List(U8), at : U64 } -> [Found(U64), NoneFound]
html_image_end = |{ bytes, at }|
	if bytes.get(at) != Ok('<') {
		NoneFound
	} else {
		opens = Str.from_utf8_lossy(
			bytes.sublist({ start: at, len: 4 }),
		).with_ascii_lowercased() == "<img"
		next_is_word = bytes.get(at + 4).map_ok(is_word_byte) ?? Bool.False
		if opens and !next_is_word {
			find_byte({
				bytes,
				byte: '>',
				from: at + 4,
			})
		} else {
			NoneFound
		}
	}

## `bytes` with each `![alt](address)` as `[image]`.
replace_markdown_images : List(U8) -> List(U8)
replace_markdown_images = |bytes| {
	var $out = []
	var $at = 0
	while $at < bytes.len() {
		match markdown_image_end({ bytes, at: $at }) {
			Found(end) => {
				$out = List.concat($out, "[image]".to_utf8())
				$at = end
			}
			NoneFound => {
				$out = $out.append(bytes.get($at) ?? crash "RecentExcerpt: the loop stays inside the bytes")
				$at = $at + 1
			}
		}
	}
	$out
}

## Just past the `![alt](address)` that starts at `at`, or `NoneFound`.
markdown_image_end : { bytes : List(U8), at : U64 } -> [Found(U64), NoneFound]
markdown_image_end = |{ bytes, at }|
	if bytes.get(at) != Ok('!') or bytes.get(at + 1) != Ok('[') {
		NoneFound
	} else {
		match find_byte({
			bytes,
			byte: ']',
			from: at + 2,
		}) {
			Found(alt_end) if bytes.get(alt_end + 1) == Ok('(') =>
				match find_byte({
					bytes,
					byte: ')',
					from: alt_end + 2,
				}) {
					Found(address_end) => Found(address_end + 1)
					NoneFound => NoneFound
				}
			_ => NoneFound
		}
	}

## Where the next `byte` of `bytes` is, from `from`, or `NoneFound`.
find_byte : {
	bytes : List(U8),
	byte : U8,
	from : U64,
} -> [Found(U64), NoneFound]
find_byte = |{ bytes, byte, from }|
	match bytes.get(from) {
		Ok(found) if found == byte => Found(from)
		Ok(_) => find_byte({ bytes, byte, from: from + 1 })
		Err(OutOfBounds) => NoneFound
	}

## Whether `byte` is an ASCII letter, digit or `_`.
is_word_byte : U8 -> Bool
is_word_byte = |byte|
	Ascii.is_letter(byte) or Ascii.is_digit(byte) or byte == '_'

## Whether `byte` is white space, as Gopher's excerpt reads it.
is_white_space : U8 -> Bool
is_white_space = |byte|
	byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c or byte == 0x0b

## `bytes` as text, each run of white space one space, none at the ends.
collapse_white_space : List(U8) -> Str
collapse_white_space = |bytes| {
	var $out = []
	var $in_space = Bool.False
	for byte in bytes {
		if is_white_space(byte) {
			$in_space = Bool.True
		} else {
			if $in_space and !$out.is_empty() {
				$out = $out.append(' ')
			}
			$in_space = Bool.False
			$out = $out.append(byte)
		}
	}
	Str.from_utf8_lossy($out)
}

## `text` cut after `most` code points, its last spaces dropped and `…`
## added, when it holds more; else `text`.
cut_at_most : Str, U64 -> Str
cut_at_most = |text, most| {
	bytes = text.to_utf8()
	var $points = 0
	var $cut = NotCut
	var $at = 0
	for byte in bytes {
		if byte < 0x80 or byte >= 0xC0 {
			if $points == most and $cut == NotCut {
				$cut = CutAt($at)
			}
			$points = $points + 1
		}
		$at = $at + 1
	}
	match $cut {
		CutAt(end) => "${Str.from_utf8_lossy(bytes.take_first(end)).trim()}…"
		NotCut => text
	}
}

# ── tests
# A nested quote collapses whole, and the reply's own words stay.
expect
	RecentExcerpt.markdown_excerpt("In MSG_test_2 I said:\n~~~~ quote\nIn MSG_test_1 I said:\n~~~ quote\nhi\n~~~\n\nhello\n~~~~\n\nyo")
		== "In MSG_test_2 I said: [quoted text] yo"
# A code fence is its code, its marks gone and its lines joined by single
# spaces; a code line is never read as prose.
expect RecentExcerpt.markdown_excerpt("look:\n```\ncode here\n```\ndone") == "look: code here done"
expect
	RecentExcerpt.markdown_excerpt("through `Markdown`:\n```roc\nMarkdown.render(*md*)\n```")
		== "through Markdown: Markdown.render(*md*)"
# Prose loses its marks: a quote's `>`, emphasis.
expect RecentExcerpt.markdown_excerpt("> the sidebar\n\n**yes**") == "the sidebar yes"
# An unclosed quote runs to the end.
expect RecentExcerpt.markdown_excerpt("a\n``` quote\nb\nc") == "a [quoted text]"
# Images, HTML and markdown, as `[image]`; `<imgx` is no image.
expect RecentExcerpt.markdown_excerpt("see <IMG src=\"/x.png\"> and ![a cat](/c.png)!") == "see [image] and [image]!"
expect RecentExcerpt.markdown_excerpt("<imgx> <img") == "<imgx> <img"
expect RecentExcerpt.markdown_excerpt("![no address] ![a](b") == "![no address] ![a](b"
# White space runs as one space, the ends trimmed.
expect RecentExcerpt.markdown_excerpt("  a \t\r\n b  ") == "a b"
expect RecentExcerpt.markdown_excerpt("") == ""
# The cut: at the most, nothing is cut; one more, and it is.
expect RecentExcerpt.markdown_excerpt("x".repeat(350)) == "x".repeat(350)
expect RecentExcerpt.markdown_excerpt("x".repeat(351)) == "${"x".repeat(350)}…"
# A space before the cut is dropped; code points count, not bytes.
expect cut_at_most("ab cd", 3) == "ab…"
expect cut_at_most("ééé", 2) == "éé…"
expect cut_at_most("ééé", 3) == "ééé"
# A fence's opening: its mark, its count and its language, or none.
expect fence_opening("~~~~ quote") == Ok({
	mark: '~',
	count: 4,
	language: "quote",
})
expect fence_opening("   ```zig x") == Ok({
	mark: '`',
	count: 3,
	language: "zig",
})
expect [
	"plain",
	"~~ short",
	"```a`b",
	"    ```",
	"~~~~~~~~~~~",
].all(|line| fence_opening(line) == Err(NotAFence))
expect is_fence_closing(
	"~~~~ ",
	{
		mark: '~',
		count: 4,
		language: "",
	},
)
expect !is_fence_closing(
	"~~~",
	{
		mark: '~',
		count: 4,
		language: "",
	},
)
expect !is_fence_closing(
	"~~~~ x",
	{
		mark: '~',
		count: 4,
		language: "",
	},
)
