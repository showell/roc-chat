## This module reads the words of a message as search knows them, as Gopher
## Chat's search did (angry-gopher's zig-server/src/search_tokens.zig). Words
## split on ASCII whitespace alone. The punctuation at a word's ends is
## trimmed, from both ends again and again: ASCII's, and the quotes, dashes
## and marks a phone types (`trimmed_marks`). What is inside a word stays,
## so "don't", "e.g" and "3.14" are words. A word is two bytes or more once
## trimmed. ASCII letters fold to lower case; any byte of 128 or more is a
## word's, matched byte for byte, so a word in another script is matched
## exactly. The client never reads words: it sends what was typed, and the
## server answers.
SearchWords :: [].{

	## Where a word stands in a message's bytes: its first byte and its
	## length.
	Span : { start : U64, length : U64 }

	## The shortest word, in bytes.
	shortest_word_bytes : U64
	shortest_word_bytes = 2

	## The longest key a search reads, in bytes; no longer word is
	## suggested, so a word suggested is always one a search finds.
	longest_key_bytes : U64
	longest_key_bytes = 256

	## Where each word of `bytes` stands, in order, each trimmed.
	spans : List(U8) -> List(SearchWords.Span)
	spans = |bytes| {
		var $found = []
		var $at = 0
		while $at < bytes.len() {
			next = next_run(bytes, $at)
			$at = next.after
			if next.word.length >= SearchWords.shortest_word_bytes {
				$found = $found.append(next.word)
			}
		}
		$found
	}

	## `bytes` with each ASCII capital made small.
	fold_ascii : List(U8) -> List(U8)
	fold_ascii = |bytes| bytes.map(lowered)

	## The bytes of `span` in `bytes`.
	span_bytes : List(U8), SearchWords.Span -> List(U8)
	span_bytes = |bytes, span| bytes.sublist({ start: span.start, len: span.length })

	## A key, the start of a word or the whole of one, as words are held:
	## trimmed and folded, at most `longest_key_bytes`. Only `of_typed` makes
	## one.
	SearchKey :: List(U8).{

		## The key `typed` spells: its ASCII spaces and its edge punctuation
		## trimmed, and folded. Empty when nothing of it is a word's, or when
		## it is longer than `longest_key_bytes`.
		of_typed : Str -> SearchWords.SearchKey
		of_typed = |typed| {
			bytes = typed.to_utf8()
			first = bytes.find_first_index(|byte| !is_key_space(byte)) ?? bytes.len()
			last = bytes.find_last_index(|byte| !is_key_space(byte)).map_ok(|at| at + 1) ?? first
			word = trim({ bytes, span: { start: first, length: last - first } })
			if word.length > SearchWords.longest_key_bytes {
				SearchWords.SearchKey.([])
			} else {
				SearchWords.SearchKey.(SearchWords.fold_ascii(SearchWords.span_bytes(bytes, word)))
			}
		}

		## Its bytes.
		bytes : SearchWords.SearchKey -> List(U8)
		bytes = |SearchWords.SearchKey.(held)| held

		## Its text: a key is cut only where a character ends.
		to_str : SearchWords.SearchKey -> Str
		to_str = |SearchWords.SearchKey.(held)|
			Str.from_utf8(held) ?? crash "SearchWords.SearchKey.to_str: a key is cut only between characters"

		## Is it long enough to be a whole word (`shortest_word_bytes`)?
		is_word_long : SearchWords.SearchKey -> Bool
		is_word_long = |SearchWords.SearchKey.(held)| held.len() >= SearchWords.shortest_word_bytes

		is_eq : _
	}

	## Each word of `folded_bytes` (a message's bytes, folded) that begins
	## with `prefix`, once, in the order they first stand; none longer than
	## `longest_key_bytes`, which no key names.
	prefixed_words : { folded_bytes : List(U8), prefix : SearchWords.SearchKey } -> List(List(U8))
	prefixed_words = |{ folded_bytes, prefix }| {
		wanted = prefix.bytes()
		var $held = []
		var $at = 0
		while $at < folded_bytes.len() {
			next = next_run(folded_bytes, $at)
			$at = next.after
			if is_key_long(next.word) {
				word = SearchWords.span_bytes(folded_bytes, next.word)
				if word.starts_with(wanted) and !$held.contains(word) {
					$held = $held.append(word)
				}
			}
		}
		$held
	}

	## Where the word `key` first stands in `folded_bytes` (a message's
	## bytes, folded) as a word of its own: its first byte, or `NotHeld`
	## when it holds none.
	word_at : { folded_bytes : List(U8), key : SearchWords.SearchKey } -> [At(U64), NotHeld]
	word_at = |{ folded_bytes, key }| {
		wanted = key.bytes()
		var $found = NotHeld
		var $at = 0
		while $found == NotHeld and $at < folded_bytes.len() {
			next = next_run(folded_bytes, $at)
			$at = next.after
			if next.word.length == wanted.len() and SearchWords.span_bytes(
				folded_bytes,
				next.word,
			) == wanted {
				$found = At(next.word.start)
			}
		}
		$found
	}
}

## The next run of bytes that are not whitespace at or after `at`, trimmed
## (perhaps to nothing), and where the run ends.
next_run : List(U8), U64 -> { word : SearchWords.Span, after : U64 }
next_run = |bytes, at| {
	total = bytes.len()
	var $at = at
	while $at < total and is_whitespace(byte_at(bytes, $at)) {
		$at = $at + 1
	}
	start = $at
	while $at < total and !is_whitespace(byte_at(bytes, $at)) {
		$at = $at + 1
	}
	{ word: trim({ bytes, span: { start, length: $at - start } }), after: $at }
}

## `byte`, a capital made small.
lowered : U8 -> U8
lowered = |byte| {
	if byte >= 'A' and byte <= 'Z' {
		byte + 32
	} else {
		byte
	}
}

## Is `word` a word a key can name: two bytes or more, and at most
## `longest_key_bytes`?
is_key_long : SearchWords.Span -> Bool
is_key_long = |word|
	word.length >= SearchWords.shortest_word_bytes and word.length <= SearchWords.longest_key_bytes

## The byte at `at`, which the loops keep inside `bytes`.
byte_at : List(U8), U64 -> U8
byte_at = |bytes, at| bytes.get(at) ?? crash "SearchWords: the loop stays inside the bytes"

## Is `byte` ASCII whitespace, as Zig's `std.ascii.isWhitespace` reads it:
## a space, a tab, a line feed, a CR, a vertical tab or a form feed?
is_whitespace : U8 -> Bool
is_whitespace = |byte| byte == ' ' or (byte >= 0x09 and byte <= 0x0D)

## Is `byte` one a typed key's ends lose before its trim: a space, a tab, a
## CR or a line feed?
is_key_space : U8 -> Bool
is_key_space = |byte| byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n'

## Is `byte` ASCII punctuation: `!` to `/`, `:` to `@`, `[` to `` ` ``, or
## `{` to `~`?
is_ascii_punctuation : U8 -> Bool
is_ascii_punctuation = |byte|
	(byte >= '!' and byte <= '/')
		or (byte >= ':' and byte <= '@')
		or (byte >= '[' and byte <= '`')
		or (byte >= '{' and byte <= '~')

## What a word's ends lose besides ASCII punctuation, as UTF-8: the quotes
## and apostrophes of every kind, the guillemets, the ellipsis and the
## dashes, the inverted marks, the primes, and the no-break space.
trimmed_marks : List(List(U8))
trimmed_marks = [
	"‘",
	"’",
	"‚",
	"‛",
	"“",
	"”",
	"„",
	"‟",
	"«",
	"»",
	"‹",
	"›",
	"…",
	"–",
	"—",
	"―",
	"¡",
	"¿",
	"′",
	"″",
	"\u(a0)",
].map(Str.to_utf8)

## `span` of `bytes` with its edge punctuation trimmed, from both ends
## until neither end is any.
trim : { bytes : List(U8), span : SearchWords.Span } -> SearchWords.Span
trim = |{ bytes, span }| {
	var $start = span.start
	var $length = span.length
	var $trimming = Bool.True
	while $trimming and $length > 0 {
		if is_ascii_punctuation(byte_at(bytes, $start)) {
			$start = $start + 1
			$length = $length - 1
		} else if is_ascii_punctuation(byte_at(bytes, $start + $length - 1)) {
			$length = $length - 1
		} else if byte_at(bytes, $start) < 0x80 and byte_at(bytes, $start + $length - 1) < 0x80 {
			# Every mark begins and ends with a byte of 128 or more.
			$trimming = Bool.False
		} else {
			word = SearchWords.span_bytes(bytes, { start: $start, length: $length })
			match trimmed_marks.find_first(|mark| word.starts_with(mark)) {
				Ok(mark) => {
					$start = $start + mark.len()
					$length = $length - mark.len()
				}
				Err(NotFound) =>
					match trimmed_marks.find_first(|mark| word.ends_with(mark)) {
						Ok(mark) => {
							$length = $length - mark.len()
						}
						Err(NotFound) => {
							$trimming = Bool.False
						}
					}
			}
		}
	}
	{ start: $start, length: $length }
}

## The words of `text`, folded, as a test reads them.
words_of : Str -> List(Str)
words_of = |text| {
	bytes = text.to_utf8()
	SearchWords.spans(bytes).map(
		|span| Str.from_utf8_lossy(SearchWords.fold_ascii(SearchWords.span_bytes(bytes, span))),
	)
}

## The text of the key `typed` spells, as a test reads it.
key_text : Str -> Str
key_text = |typed| SearchWords.SearchKey.of_typed(typed).to_str()

## Where the word `typed` first stands in `text`, folded, as a test reads it.
place_of_word : Str, Str -> [At(U64), NotHeld]
place_of_word = |text, typed| SearchWords.word_at({
	folded_bytes: SearchWords.fold_ascii(text.to_utf8()),
	key: SearchWords.SearchKey.of_typed(typed),
})

# ── tests
# Gopher's search_tokens.zig tests, one for one.
# Words split on whitespace, ASCII lowercased.
expect words_of("The page  LAYOUT\tis\noff") == ["the", "page", "layout", "is", "off"]
expect words_of("") == [] and words_of(" \t\n \u(0b)\u(0c)") == []
# Edge punctuation is trimmed, from both ends and again; what is inside stays.
expect words_of("Hello, world!") == ["hello", "world"]
expect words_of("(\"quoted\"), [x1] {braces}...") == ["quoted", "x1", "braces"]
expect words_of("don't e.g. 3.14 a-b") == ["don't", "e.g", "3.14", "a-b"]
expect words_of("--dashes-- **bold** _em_ `code`") == ["dashes", "bold", "em", "code"]
# The curly quotes and apostrophes a phone types are trimmed, and their kin;
# inside a word a curly apostrophe stays.
expect words_of("“Hello” ‘there’") == ["hello", "there"]
expect words_of("«Bonjour» ‹x1› wait… ¿Qué?") == ["bonjour", "x1", "wait", "qué"]
expect words_of("don’t") == ["don’t"] and words_of("“(‘word’)”") == ["word"]
# A byte of 128 or more is a word's, matched exactly; only ASCII folds. An
# emoji alone is a word: four bytes.
expect words_of("Café Été 日本") == [
	"café",
	"Été",
	"日本",
] and words_of("ok 😀") == ["ok", "😀"]
# A word is two bytes or more.
expect words_of("a I x. ab (c) é") == ["ab", "é"] and words_of("!!! ... “”") == []
# A no-break space inside a word glues it; at its edge it is trimmed.
expect words_of("a\u(a0)b \u(a0)cd") == ["a\u(a0)b", "cd"]
# A key as typed is a word's start, trimmed and folded like one; one longer
# than the longest key is none, and one at it is kept.
expect key_text("  Lay ") == "lay" and key_text("“Don't") == "don't"
expect key_text("?!") == "" and key_text("") == "" and key_text(" ") == ""
expect key_text("a".repeat(256)) == "a".repeat(256) and key_text("a".repeat(257)) == ""
# A key of one byte is a word's start, and two bytes are a whole word's.
expect !SearchWords.SearchKey.of_typed("x").is_word_long()
expect SearchWords.SearchKey.of_typed("xy").is_word_long()
# A word is found where it stands alone, never inside a longer word.
expect place_of_word("the layout, then", "Layout") == At(4)
expect
	SearchWords.prefixed_words({
		folded_bytes: "lay layout lay x".to_utf8(),
		prefix: SearchWords.SearchKey.of_typed("la"),
	})
		== ["lay".to_utf8(), "layout".to_utf8()]
expect place_of_word("layouts lay", "layout") == NotHeld and place_of_word("(lay)", "lay") == At(1)
