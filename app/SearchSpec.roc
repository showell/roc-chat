## These are the tests of `Search`: which places a human searches, the
## words suggested and their order, the messages found and their caps, and
## the answers' JSON. `SearchWords` holds the words' own tests.
import Browse
import ConversationKey
import Directory
import Search
import SearchWords
import Sample
import Script
import SignedIn
import UnvalidatedString

SearchSpec :: [].{}

## The sample directory, with the channel `general` holding Steve alone.
directory : Directory
directory = Sample.with_default_channel(Sample.directory)

## The conversation at `path` in `directory`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "SearchSpec: a path is UTF-8",
	directory,
}).map_ok(|found| found.key) ?? crash "SearchSpec: a conversation's path"

## The topic at `path`, its place named `place_label`, holding Steve's
## messages of `markdowns`, in order.
topic_of : {
	path : Str,
	place_label : Str,
	markdowns : List(Str),
} -> Search.Searched
topic_of = |{ path, place_label, markdowns }| {
	key = key_at(path)
	conversation = Sample.conversation(
		key.topic(),
		markdowns.map(
			|markdown| Sample.unnumbered_message({
				author: "Steve",
				time: "2026-11-02T19:11:32Z",
				markdown,
			}),
		),
	)
	{ key, place_label, messages: conversation.messages() }
}

## The pages of `human`'s places searched.
searched_paths : Str -> List(Str)
searched_paths = |human|
	match Browse.places_for({
		acting: SignedIn.dangerously_assume(Sample.user(human)),
		directory,
	}) {
		Ok(places) => places.map(|listed| ConversationKey.place_url_path(listed.place))
		Err(_) => crash "SearchSpec.searched_paths: a human searches"
	}

## A topic of `#general`, which only Steve reads.
general : Search.Searched
general = topic_of({
	path: "/chat/channel/general/plans",
	place_label: "#general",
	markdowns: ["The layout is off.", "lay it out"],
})

## A topic of Steve's DM with Apoorva.
with_apoorva : Search.Searched
with_apoorva = topic_of({
	path: "/chat/dm/1_2/plans",
	place_label: "a direct message",
	markdowns: ["Layout: done", "layouts and LAYOUT"],
})

## The words beginning with `typed` in `topics`, each with its count.
words_in : List(Search.Searched), Str -> List((Str, U64))
words_in = |topics, typed|
	Search.words_for({
		topics,
		prefix: SearchWords.SearchKey.of_typed(typed),
	}).map(|{ word, count }| (word, count))

## The pages and ids of the messages of `topics` that hold `typed`.
hits_in : List(Search.Searched), Str -> List((Str, U64))
hits_in = |topics, typed|
	Search.messages_for({ topics, word: SearchWords.SearchKey.of_typed(typed) }).hits.map(
		|hit| (hit.found_in.key.url_path(Page), hit.message.id().to_u64()),
	)

# The access rule: a human searches Browse's places, each they may read,
# their own DM included (Steve, 2026-11-20: yes, a message to yourself is
# like any other). Steve reads his own DM, his DM with Apoorva and
# `#general`; Apoorva, who is not in `#general`, reads her DM with Steve and
# her own, never his.
expect searched_paths("Steve") == ["/chat/dm/1_1", "/chat/dm/1_2", "/chat/channel/general"]
expect searched_paths("Apoorva") == ["/chat/dm/1_2", "/chat/dm/2_2"]
# An agent's key, or any key, searches nothing.
expect
	Browse.places_for({
		acting: SignedIn.dangerously_assume(Sample.user("CC")),
		directory,
	}).is_err()

# A reader sees only the hits of what they may read: the route searches
# their places alone, so Apoorva's search of "layout" finds the DM's
# messages and none of `#general`'s, which Steve's finds too.
expect {
	readable = [general, with_apoorva].keep_if(
		|topic| searched_paths("Apoorva").contains(ConversationKey.place_url_path(topic.key.place())),
	)
	hits_in(readable, "layout") == [("/chat/dm/1_2/plans", 1), ("/chat/dm/1_2/plans", 2)]
		and hits_in([with_apoorva, general], "layout")
			== [
				("/chat/dm/1_2/plans", 1),
				("/chat/dm/1_2/plans", 2),
				("/chat/channel/general/plans", 1),
			]
}

# Words: each message counts a word once, however often it holds it; the
# most held first, then in byte order; a word only where it begins with the
# prefix, folded.
expect words_in([general, with_apoorva], "LA") == [
	("layout", 3),
	("lay", 1),
	("layouts", 1),
]
expect words_in([general, with_apoorva], "layo") == [("layout", 3), ("layouts", 1)]
expect words_in(
	[general],
	"zz",
) == [] and words_in([general], "") == [] and words_in([general], "?") == []
# At most `most_words` words, the rest left out.
expect {
	many = topic_of({
		path: "/chat/channel/general/many",
		place_label: "#general",
		markdowns: ["w00 w01 w02 w03 w04 w05 w06 w07 w08 w09 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21"],
	})
	words_in([many], "w").len() == 20 and words_in([many], "w").last() == Ok(("w19", 1))
}

# Messages: in the topics' order, each topic's in order; a key shorter than a
# word finds nothing; a word inside a longer one is no match.
expect hits_in([general, with_apoorva], "l") == []
expect hits_in([general], "lay") == [("/chat/channel/general/plans", 2)]
# At most `most_messages` listed, and every match counted.
expect {
	crowd = topic_of({
		path: "/chat/channel/general/crowd",
		place_label: "#general",
		markdowns: List.repeat("hello there", 501),
	})
	found = Search.messages_for({ topics: [crowd], word: SearchWords.SearchKey.of_typed("hello") })
	found.hits.len() == 500 and found.matched == 501
}

# app/search.js asks the two paths `Route` serves, and holds the shortest
# word the server reads.
expect {
	script = Str.from_utf8_lossy(Script.Search.bytes())
	script.contains("'${Search.words_path}'")
		and script.contains("'${Search.messages_path}'")
		and script.contains("SHORTEST_WORD = ${SearchWords.shortest_word_bytes.to_str()};")
}

# The answers, as Gopher's routes wrote them.
expect
	Search.words_answer({
		prefix: SearchWords.SearchKey.of_typed("La"),
		words: [{ word: "layout", count: 3 }],
		unreadable: 0,
	}).bytes()
		== "{\"prefix\":\"la\",\"most\":20,\"unreadable\":0,\"words\":[{\"word\":\"layout\",\"count\":3}]}".to_utf8()
expect {
	word = SearchWords.SearchKey.of_typed("layout")
	found = Search.messages_for({ topics: [with_apoorva], word })
	Search.messages_answer({
		word,
		found: { hits: found.hits.take_first(1), matched: found.matched },
		unreadable: 1,
	}).bytes()
		== "{\"word\":\"layout\",\"matched\":2,\"unreadable\":1,\"messages\":[{\"page\":\"/chat/dm/1_2/plans\",\"place\":\"a direct message\",\"topic\":\"plans\",\"id\":1,\"from\":\"Steve\",\"date\":\"2026-11-02T19:11:32Z\",\"before\":\"\",\"mark\":\"Layout\",\"after\":\": done\"}]}".to_utf8()
}
