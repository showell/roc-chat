## This module answers a search across every conversation a human may read,
## as Gopher Chat's did (angry-gopher's zig-server/src/chat_search.zig and
## search_index.zig), over the conversations `SearchRoute` reads for it.
## There are two questions. The words that begin with what was typed, each
## with how many messages hold it, the most held first (`words_for`); and
## the messages that hold a word (`messages_for`), each as an excerpt with
## the word marked (`excerpt_of`). The words are `SearchWords`'.
##
## The conversations searched are Recent's (`places_searched`): every place
## the human may read but their own DM. Messages are listed in the places'
## order, each place's topics in turn, each topic's messages in order; at
## most `most_messages` are listed, and no more than `most_answer_bytes` of
## their excerpts, while every match is counted. A search also says how
## many topics it could not read (`unreadable`).
import Browse
import ConversationKey
import Directory
import JsonOut
import Message
import RecentFeed
import SearchWords
import SignedIn
import UserId

Search :: [].{

	## One topic searched: its key, how a result names its place (`#` and a
	## channel's name, or "a direct message"), and its messages.
	Searched : {
		key : ConversationKey,
		place_label : Str,
		messages : List(Message),
	}

	## A word and how many messages hold it.
	WordCount : { word : Str, count : U64 }

	## A message's excerpt: the text before the word, the word as written,
	## and the text after, `…` where either side was cut.
	Excerpt : {
		before : Str,
		mark : Str,
		after : Str,
	}

	## A message that holds the word, in the topic searched.
	Hit : {
		searched : Search.Searched,
		message : Message,
		excerpt : Search.Excerpt,
	}

	## The messages listed, and how many hold the word in all.
	Results : { hits : List(Search.Hit), matched : U64 }

	## Where the words that begin with what was typed are asked:
	## `?prefix=<typed>`.
	words_path : Str
	words_path = "/chat/search/words"

	## Where the messages that hold a word are asked: `?word=<typed>`.
	messages_path : Str
	messages_path = "/chat/search/messages"

	## The most words one answer suggests.
	most_words : U64
	most_words = 20

	## The most messages one answer lists.
	most_messages : U64
	most_messages = 500

	## The most bytes of excerpt one answer lists, as JSON writes them.
	most_answer_bytes : U64
	most_answer_bytes = 2 * 1024 * 1024

	## The bytes of a message kept either side of the marked word.
	excerpt_pad : U64
	excerpt_pad = 90

	## The places `acting` searches in `directory`: Recent's, each place they
	## may read but their own DM; unless they act by an API key, or are an
	## agent, who don't search.
	places_searched : { acting : SignedIn, directory : Directory } -> Try(
		List(Browse.ListedPlace),
		[ByApiKey, Agent(UserId)],
	)
	places_searched = |{ acting, directory }| {
		reader = acting.human_in_session()?
		listed = Browse.places_for({ acting, directory })?
		Ok(RecentFeed.places_without_own_dm({ listed, reader: reader.user().id() }))
	}

	## The words of the messages of `topics` that begin with `prefix`, at
	## most `most_words`, each with how many messages hold it: the most held
	## first, then in byte order. An empty prefix suggests nothing.
	words_for : {
		topics : List(Search.Searched),
		prefix : SearchWords.SearchKey,
	} -> List(Search.WordCount)
	words_for = |{ topics, prefix }| {
		wanted = prefix.bytes()
		if wanted.is_empty() {
			[]
		} else {
			wanted_text = prefix.to_str()
			var $counts = Dict.empty()
			for topic in topics {
				for message in topic.messages {
					folded_text = message.markdown().with_ascii_lowercased()
					if folded_text.contains(wanted_text) {
						held = SearchWords.prefixed_words({
							folded_bytes: folded_text.to_utf8(),
							prefix,
						})
						for word in held {
							$counts = $counts.insert(word, count_after(word, $counts))
						}
					}
				}
			}
			$counts.to_list()
				.sort_with(most_held_first)
				.take_first(Search.most_words)
				.map(|(word, count)| { word: Str.from_utf8_lossy(word), count })
		}
	}

	## The messages of `topics` that hold `word` as a word of their own,
	## in order, each with its excerpt: at most `most_messages`, and no more
	## than `most_answer_bytes` of excerpts (the first always listed), every
	## one counted. A key shorter than a word finds nothing.
	messages_for : {
		topics : List(Search.Searched),
		word : SearchWords.SearchKey,
	} -> Search.Results
	messages_for = |{ topics, word }|
		if !word.is_word_long() {
			{ hits: [], matched: 0 }
		} else {
			var $hits = []
			var $matched = 0
			var $bytes = 0
			var $full = Bool.False
			for topic in topics {
				for message in topic.messages {
					match place_in_message(message, word) {
						At(at) => {
							$matched = $matched + 1
							if !$full and $hits.len() < Search.most_messages {
								excerpt = excerpt_around({
									markdown: message.markdown().to_utf8(),
									at,
									length: word.bytes().len(),
								})
								cost = excerpt_cost(excerpt)
								if $hits.is_empty() or $bytes + cost <= Search.most_answer_bytes {
									$bytes = $bytes + cost
									$hits = $hits.append({ searched: topic, message, excerpt })
								} else {
									$full = Bool.True
								}
							}
						}
						NotHeld => {}
					}
				}
			}
			{ hits: $hits, matched: $matched }
		}

	## The excerpt of `markdown` around the word `key`, where it first stands
	## as a word: `excerpt_pad` bytes either side, cut where a character
	## ends, `…` where cut. A message that doesn't hold it is its first bytes,
	## unmarked.
	excerpt_of : { markdown : Str, key : SearchWords.SearchKey } -> Search.Excerpt
	excerpt_of = |{ markdown, key }| {
		bytes = markdown.to_utf8()
		match SearchWords.word_at({ folded_bytes: SearchWords.fold_ascii(bytes), key }) {
			At(at) => excerpt_around({ markdown: bytes, at, length: key.bytes().len() })
			NotHeld => {
				end = char_start_at_or_before(bytes, smaller(bytes.len(), 2 * Search.excerpt_pad))
				{
					before: "",
					mark: "",
					after: cut_text({
						bytes,
						span: { start: 0, length: end },
						tail: if end < bytes.len() {
							"…"
						} else {
							""
						},
					}),
				}
			}
		}
	}

	## The words' answer, as Gopher's `/chat/search/words` wrote it:
	## `{"prefix":...,"most":20,"unreadable":N,"words":[{"word":...,"count":N},...]}`.
	words_answer : {
		prefix : SearchWords.SearchKey,
		words : List(Search.WordCount),
		unreadable : U64,
	} -> JsonOut
	words_answer = |{ prefix, words, unreadable }|
		JsonOut.json_object([
			("prefix", JsonOut.string(prefix.to_str())),
			("most", JsonOut.number(Search.most_words)),
			("unreadable", JsonOut.number(unreadable)),
			(
				"words",
				JsonOut.array(
					words.map(
						|{ word, count }|
							JsonOut.json_object([
								("word", JsonOut.string(word)),
								("count", JsonOut.number(count)),
							]),
					),
				),
			),
		])

	## The messages' answer, as Gopher's `/chat/search/messages` wrote it,
	## each message naming its conversation's page, its place, its topic, its
	## id, its author, its time and its excerpt.
	messages_answer : {
		word : SearchWords.SearchKey,
		found : Search.Results,
		unreadable : U64,
	} -> JsonOut
	messages_answer = |{ word, found, unreadable }|
		JsonOut.json_object([
			("word", JsonOut.string(word.to_str())),
			("matched", JsonOut.number(found.matched)),
			("unreadable", JsonOut.number(unreadable)),
			("messages", JsonOut.array(found.hits.map(hit_json))),
		])
}

## One listed message, as the messages' answer writes it.
hit_json : Search.Hit -> JsonOut
hit_json = |{ searched, message, excerpt }|
	JsonOut.json_object([
		("page", JsonOut.string(searched.key.url_path(Page))),
		("place", JsonOut.string(searched.place_label)),
		("topic", JsonOut.string(searched.key.topic().to_str())),
		("id", JsonOut.number(message.id().to_u64())),
		("from", JsonOut.string(message.author().to_str())),
		("date", JsonOut.string(message.time().to_str())),
		("before", JsonOut.string(excerpt.before)),
		("mark", JsonOut.string(excerpt.mark)),
		("after", JsonOut.string(excerpt.after)),
	])

## What an excerpt costs the answer, as JSON writes it.
excerpt_cost : Search.Excerpt -> U64
excerpt_cost = |{ before, mark, after }|
	[before, mark, after].map(|part| JsonOut.string(part).bytes().len()).sum()

## A word count before another: the more held first, then the word in byte
## order.
most_held_first : (List(U8), U64), (List(U8), U64) -> [Before, Same, After]
most_held_first = |(one_word, one_count), (other_word, other_count)|
	if one_count > other_count {
		Before
	} else if one_count < other_count {
		After
	} else {
		compare_bytes(one_word, other_word)
	}

## Two lists of bytes in byte order, a list before any it begins.
compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |one, other|
	match (one, other) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([one_byte, .. as one_rest], [other_byte, .. as other_rest]) =>
			if one_byte < other_byte {
				Before
			} else if one_byte > other_byte {
				After
			} else {
				compare_bytes(one_rest, other_rest)
			}
	}

## The excerpt of `markdown` around the `length` bytes of the word at
## `at`. The cut never crosses the word, whose edges are a character's.
excerpt_around : {
	markdown : List(U8),
	at : U64,
	length : U64,
} -> Search.Excerpt
excerpt_around = |{ markdown, at, length }| {
	word_end = at + length
	padded_start = if at > Search.excerpt_pad {
		at - Search.excerpt_pad
	} else {
		0
	}
	start = smaller(char_start_at_or_after(markdown, padded_start), at)
	padded_end = smaller(markdown.len(), word_end + Search.excerpt_pad)
	end = larger(char_start_at_or_before(markdown, padded_end), word_end)
	before_mark = if start > 0 {
		"…"
	} else {
		""
	}
	after_mark = if end < markdown.len() {
		"…"
	} else {
		""
	}
	before = cut_text({
		bytes: markdown,
		span: { start, length: at - start },
		tail: "",
	})
	{
		before: "${before_mark}${before}",
		mark: cut_text({
			bytes: markdown,
			span: { start: at, length },
			tail: "",
		}),
		after: cut_text({
			bytes: markdown,
			span: { start: word_end, length: end - word_end },
			tail: after_mark,
		}),
	}
}

## The text of `span` of `bytes`, which starts and ends where characters
## do, and `tail` after it.
cut_text : {
	bytes : List(U8),
	span : SearchWords.Span,
	tail : Str,
} -> Str
cut_text = |{ bytes, span, tail }| {
	text = Str.from_utf8(
		SearchWords.span_bytes(bytes, span),
	) ?? crash "Search.cut_text: an excerpt is cut only between characters"
	"${text}${tail}"
}

## The smaller of `one` and `other`.
smaller : U64, U64 -> U64
smaller = |one, other| {
	if one < other {
		one
	} else {
		other
	}
}

## The larger of `one` and `other`.
larger : U64, U64 -> U64
larger = |one, other| {
	if one > other {
		one
	} else {
		other
	}
}

## Where `word` first stands in `message` as a word of its own, or
## `NotHeld`. Most messages don't hold it even inside another word, and
## are passed over at once.
place_in_message : Message, SearchWords.SearchKey -> [At(U64), NotHeld]
place_in_message = |message, word| {
	folded_text = message.markdown().with_ascii_lowercased()
	if folded_text.contains(word.to_str()) {
		SearchWords.word_at({ folded_bytes: folded_text.to_utf8(), key: word })
	} else {
		NotHeld
	}
}

## The byte at `at`, which the loops keep inside `bytes`.
byte_in : List(U8), U64 -> U8
byte_in = |bytes, at| bytes.get(at) ?? crash "Search: the loop stays inside the bytes"

## How many messages hold `word` once one more does, by `counts` so far.
count_after : List(U8), Dict(List(U8), U64) -> U64
count_after = |word, counts|
	match counts.get(word) {
		Ok(count) => count + 1
		Err(KeyNotFound) => 1
	}

## Is `byte` the second, third or fourth byte of a UTF-8 character?
is_continuation : U8 -> Bool
is_continuation = |byte| byte >= 0x80 and byte < 0xC0

## `at`, or the start of the next character after it.
char_start_at_or_after : List(U8), U64 -> U64
char_start_at_or_after = |bytes, at| {
	var $at = at
	while $at < bytes.len() and is_continuation(byte_in(bytes, $at)) {
		$at = $at + 1
	}
	$at
}

## `at`, or the start of the character it falls inside.
char_start_at_or_before : List(U8), U64 -> U64
char_start_at_or_before = |bytes, at| {
	var $at = at
	while $at > 0 and $at < bytes.len() and is_continuation(byte_in(bytes, $at)) {
		$at = $at - 1
	}
	$at
}

# ── tests
# An excerpt, as Gopher's chat_search.zig tests: short, it is whole, nothing
# cut; a word at the start or the end is cut nowhere.
expect
	[
		("a Word here", ("a ", "Word", " here")),
		("word then", ("", "word", " then")),
		("then word", ("then ", "word", "")),
		("word", ("", "word", "")),
	].all(
		|(markdown, (before, mark, after))|
			Search.excerpt_of({
				markdown,
				key: SearchWords.SearchKey.of_typed("word"),
			}) == { before, mark, after },
	)
# `excerpt_pad` bytes before the word are kept whole, and one more is cut.
expect {
	kept = "${"b".repeat(89)} "
	past = "${"b".repeat(90)} "
	key = SearchWords.SearchKey.of_typed("word")
	Search.excerpt_of({ markdown: "${kept}word", key }).before == kept
		and Search.excerpt_of({
			markdown: "${past}word",
			key,
		}).before == "…${past.drop_prefix("b")}"
}
# `excerpt_pad` bytes after the word are kept whole, and one more is cut.
expect {
	kept = " ${"b".repeat(89)}"
	key = SearchWords.SearchKey.of_typed("word")
	Search.excerpt_of({ markdown: "word${kept}", key }).after == kept
		and Search.excerpt_of({ markdown: "word${kept}b", key }).after == "${kept}…"
}
# An excerpt is cut where a character ends, never inside one: `é` is two bytes.
expect {
	accents = "é".repeat(60)
	got = Search.excerpt_of({
		markdown: "${accents} word ${accents}",
		key: SearchWords.SearchKey.of_typed("word"),
	})
	got.mark == "word" and got.before.starts_with("…") and got.after.ends_with("…")
}
# A message that doesn't hold the word is its first bytes, unmarked.
expect
	Search.excerpt_of({ markdown: "x".repeat(200), key: SearchWords.SearchKey.of_typed("word") })
		== {
			before: "",
			mark: "",
			after: "${"x".repeat(180)}…",
		}
expect compare_bytes([1], [1, 0]) == Before
expect compare_bytes([2], [1, 9]) == After
expect compare_bytes([], []) == Same
