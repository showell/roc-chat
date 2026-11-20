## This module takes markdown's marks out of a line of prose, so an excerpt
## reads as text (Steve, 2026-11-20, of Recent's excerpts: "```roc
## Markdown.r…" read as markup). A line loses its quote markers (`>`, each
## with the spaces after it) and a heading's `#`s; then inline code loses
## its backticks, its text kept as written; emphasis loses its `*`, `_` and
## `~~` runs; and a link `[text](address)` becomes its text. An image's
## `![...](...)` is left whole, for `RecentExcerpt` to say `[image]`.
##
## A run of `*` or `_` is a mark when it stands at one edge of a word: not
## inside a word (a snake-case name's `_`, `2*3`'s `*`, keep theirs), and not alone between
## spaces (`5 * 3` keeps its). `~` is a mark only doubled, as strikethrough
## is written. A code fence's lines are not prose, and `RecentExcerpt`
## never hands them here.
import Ascii

MarkdownMarks :: [].{

	## `line`, a line of prose, without its markdown marks.
	prose_line : Str -> Str
	prose_line = |line| {
		unmarked = drop_block_marks(line.to_utf8())
		Str.from_utf8_lossy(inline_plain(unmarked))
	}
}

## `bytes` without its leading spaces.
drop_spaces : List(U8) -> List(U8)
drop_spaces = |bytes|
	match bytes {
		[first, .. as rest] if first == ' ' or first == '\t' => drop_spaces(rest)
		_ => bytes
	}

## `bytes` without its leading quote markers, each `>` with the spaces after
## it.
drop_quote_marks : List(U8) -> List(U8)
drop_quote_marks = |bytes|
	match bytes {
		[first, .. as rest] if first == '>' => drop_quote_marks(drop_spaces(rest))
		_ => bytes
	}

## `bytes` without its leading spaces, quote markers, and a heading's one to
## six `#`s with the spaces after them.
drop_block_marks : List(U8) -> List(U8)
drop_block_marks = |bytes| {
	unquoted = drop_quote_marks(drop_spaces(bytes))
	hashes = count_run({
		bytes: unquoted,
		from: 0,
		byte: '#',
	})
	after = unquoted.get(hashes)
	if hashes >= 1 and hashes <= 6 and (after == Ok(' ') or after == Err(OutOfBounds)) {
		drop_spaces(unquoted.drop_first(hashes))
	} else {
		unquoted
	}
}

## How many of `byte` run in `bytes` from `from`.
count_run : {
	bytes : List(U8),
	from : U64,
	byte : U8,
} -> U64
count_run = |{ bytes, from, byte }|
	match bytes.get(from) {
		Ok(found) if found == byte => 1 + count_run({ bytes, from: from + 1, byte })
		_ => 0
	}

## Whether `byte` belongs to a word: an ASCII letter or digit, or any byte of
## a character past ASCII.
is_word_byte : U8 -> Bool
is_word_byte = |byte| Ascii.is_letter(byte) or Ascii.is_digit(byte) or byte >= 0x80

## Whether the byte at `at` of `bytes`, if there is one, is white space; the
## ends of the line count as space.
is_space_at : List(U8), Try(U64, [OutOfBounds]) -> Bool
is_space_at = |bytes, at|
	match at {
		Ok(index) =>
			match bytes.get(index) {
				Ok(byte) => Ascii.is_space(byte)
				Err(OutOfBounds) => Bool.True
			}
		Err(OutOfBounds) => Bool.True
	}

## Whether the byte at `at` of `bytes`, if there is one, belongs to a word.
is_word_at : List(U8), Try(U64, [OutOfBounds]) -> Bool
is_word_at = |bytes, at|
	match at {
		Ok(index) => bytes.get(index).map_ok(is_word_byte) ?? Bool.False
		Err(OutOfBounds) => Bool.False
	}

## Whether the run of `length` emphasis bytes at `at` is a mark: at one edge
## of a word, not inside one and not alone between spaces.
is_emphasis_mark : {
	bytes : List(U8),
	at : U64,
	length : U64,
} -> Bool
is_emphasis_mark = |{ bytes, at, length }| {
	before = if at == 0 {
		Err(OutOfBounds)
	} else {
		Ok(at - 1)
	}
	after = Ok(at + length)
	inside_word = is_word_at(bytes, before) and is_word_at(bytes, after)
	between_spaces = is_space_at(bytes, before) and is_space_at(bytes, after)
	!inside_word and !between_spaces
}

## Just past the link `[text](address)` whose `[` is at `at`, with its
## text's end, or `NoLink`.
link_end : { bytes : List(U8), at : U64 } -> [Link({ text_end : U64, end : U64 }), NoLink]
link_end = |{ bytes, at }|
	match find_byte({
		bytes,
		byte: ']',
		from: at + 1,
	}) {
		Found(text_end) if bytes.get(text_end + 1) == Ok('(') =>
			match find_byte({
				bytes,
				byte: ')',
				from: text_end + 2,
			}) {
				Found(address_end) => Link({ text_end, end: address_end + 1 })
				NoneFound => NoLink
			}
		_ => NoLink
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

## `bytes` without inline code's backticks, emphasis marks, and links'
## brackets and addresses. Inside inline code, every byte is kept.
inline_plain : List(U8) -> List(U8)
inline_plain = |bytes| {
	var $out = []
	var $at = 0
	var $in_code = Bool.False
	while $at < bytes.len() {
		byte = bytes.get($at) ?? crash "MarkdownMarks: the loop stays inside the bytes"
		length = count_run({ bytes, from: $at, byte })
		if byte == '`' {
			$in_code = !$in_code
			$at = $at + length
		} else if $in_code {
			$out = $out.append(byte)
			$at = $at + 1
		} else if byte == '*' or byte == '_' or (byte == '~' and length >= 2) {
			if !is_emphasis_mark({ bytes, at: $at, length }) {
				$out = List.concat($out, bytes.sublist({ start: $at, len: length }))
			}
			$at = $at + length
		} else if byte == '[' and ($at == 0 or bytes.get($at - 1) != Ok('!')) {
			match link_end({ bytes, at: $at }) {
				Link({ text_end, end }) => {
					text = bytes.sublist({ start: $at + 1, len: text_end - $at - 1 })
					$out = List.concat($out, inline_plain(text))
					$at = end
				}
				NoLink => {
					$out = $out.append(byte)
					$at = $at + 1
				}
			}
		} else {
			$out = $out.append(byte)
			$at = $at + 1
		}
	}
	$out
}

# ── tests
# Quote markers and a heading's marks go; a bullet stays.
expect MarkdownMarks.prose_line("> the sidebar on a phone") == "the sidebar on a phone"
expect MarkdownMarks.prose_line(" > > nested") == "nested"
expect MarkdownMarks.prose_line("## Plans") == "Plans" and MarkdownMarks.prose_line("#hashtag") == "#hashtag"
expect MarkdownMarks.prose_line("- a bullet") == "- a bullet"
# Inline code keeps its text, marks and all, without its backticks.
expect MarkdownMarks.prose_line("through `Markdown`: done") == "through Markdown: done"
expect MarkdownMarks.prose_line("``a_*b*``") == "a_*b*"
# Emphasis at a word's edge goes; inside a word, or alone, it stays.
expect MarkdownMarks.prose_line("**bold**, *it* and _it_ ~~gone~~") == "bold, it and it gone"
expect MarkdownMarks.prose_line("MSG_test_2 and 2*3 and 5 * 3 and a ~ b") == "MSG_test_2 and 2*3 and 5 * 3 and a ~ b"
# A link is its text; an image is left whole.
expect MarkdownMarks.prose_line("see [the *docs*](https://x.y/a_b) now") == "see the docs now"
expect MarkdownMarks.prose_line("![a cat](/c.png) [no address]") == "![a cat](/c.png) [no address]"
expect MarkdownMarks.prose_line("") == ""
