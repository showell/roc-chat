## This module answers search's two routes (`Route` lists them), as Gopher
## Chat's `/chat/search/words` and `/chat/search/messages` did, in JSON.
## For each place Recent lists the human (`Search.places_searched`), it lists
## the topics, and asks the host's search index (`SearchIndex`) which of
## their messages match; `Search` shapes the answer. A topic the index
## doesn't hold yet is read from its transcript and handed to it first, so
## the first search to reach a topic reads it, and the ones after read no
## disk. Both routes are a human's, by their own session: a key is
## refused, as Recent refuses one.
##
## A search's cost is bounded three ways. It reads at most
## `most_bytes_read` of transcripts into the index, Gopher's index's cap on
## what it held (search_index.zig's `text_most_total`): each topic past it
## is counted among those it could not read, unread, and left for a later
## search to read. Its answer lists at most `Search.most_messages` and
## `Search.most_answer_bytes`. And a human asks at most
## `SearchLimit.per_second_most` searches a second.
import pf.Host
import pf.Http
import Browse
import BrowseRoute
import Clock
import ConversationKey
import FileFacts
import HttpAnswer
import Directory
import JsonOut
import Search
import SearchIndex
import SearchLimit
import SearchWords
import SignedIn
import Timestamp
import Transcript
import TranscriptFiles
import UrlEncodedForm
import UserId

SearchRoute :: [].{

	## The most bytes of transcript one search reads: 64 MiB.
	most_bytes_read : U64
	most_bytes_read = 64 * 1024 * 1024

	## A GET of a search's question, `asked_of`, by `acting`, its typed key
	## in the query of `request`: the answer, or a refusal in JSON.
	serve! : {
		asked_of : [Words, Messages],
		acting : SignedIn,
		directory : Directory,
		request : Http.Request,
	} => Http.Response
	serve! = |{ asked_of, acting, directory, request }|
		match answer_search!({ asked_of, acting, directory, query: request.query }) {
			Ok(answer) => HttpAnswer.json(answer)
			Err(NotAHuman) => error_answer(403, "Search is a human's, by their own session.")
			Err(BadQuery(words)) => error_answer(400, words)
			Err(TooFast) => error_answer(429, "too many searches; wait a second")
			Err(FileSystem(fault)) => error_answer(500, FileFacts.fault_words(fault))
		}
}

## The answer to `asked_of` for `acting`, at the host's clock; unless they
## are no human by their own session, the query can't be read, they search
## too fast, or a read failed.
answer_search! : {
	asked_of : [Words, Messages],
	acting : SignedIn,
	directory : Directory,
	query : List(U8),
} => Try(
	JsonOut,
	[
		NotAHuman,
		BadQuery(Str),
		TooFast,
		FileSystem(FileFacts.Fault),
	],
)
answer_search! = |{ asked_of, acting, directory, query }| {
	human = acting.human_in_session() ? |_| NotAHuman
	places = Search.places_searched({ acting, directory }) ? |_| NotAHuman
	field =
		match asked_of {
			Words => "prefix"
			Messages => "word"
		}
	key = typed_key(query, field) ? |words| BadQuery(words)
	take_search_slot!(human.user().id(), Clock.read_clock!({}))?
	{ topics, unread } = fill_index!(places) ? |fault| FileSystem(fault)
	keys = topics.map(|topic| topic.key)
	match asked_of {
		Words =>
			if key.bytes().is_empty() {
				Ok(Search.words_answer({ prefix: key, words: [], unreadable: unread + SearchIndex.unsearchable!(keys) }))
			} else {
				got = SearchIndex.words!(keys, key, Search.most_words)
				Ok(Search.words_answer({ prefix: key, words: got.words, unreadable: unread + got.unsearchable }))
			}
		Messages =>
			if !key.is_word_long() {
				Ok(
					Search.messages_answer({
						word: key,
						found: { hits: [], matched: 0 },
						unreadable: unread + SearchIndex.unsearchable!(keys),
					}),
				)
			} else {
				got = SearchIndex.messages!(keys, key, Search.most_messages)
				found = got.found.map(
					|{ topic_at, message }| {
						found_in: topics.get(topic_at) ?? crash "SearchRoute: a hit's topic is one asked about",
						message,
					},
				)
				Ok(
					Search.messages_answer({
						word: key,
						found: { hits: Search.listed_hits({ found, word: key }), matched: got.matched },
						unreadable: unread + got.unsearchable,
					}),
				)
			}
	}
}

## The key the query's `field` holds, none when it is missing; unless the
## query can't be read, in words.
typed_key : List(U8), Str -> Try(SearchWords.SearchKey, Str)
typed_key = |query, field|
	match UrlEncodedForm.field({ body: query, name: field }) {
		Ok(unchecked) => Ok(unchecked.search_key())
		Err(MissingField) => Ok(SearchWords.SearchKey.of_typed(""))
		Err(fault) => Err(UrlEncodedForm.fault_words({ fault, name: field }))
	}

## A refusal as search's client reads one: `{"error":...}`, with `status`.
error_answer : U16, Str -> Http.Response
error_answer = |status, words| {
	answer = HttpAnswer.json(JsonOut.json_object([("error", JsonOut.string(words))]))
	{ ..answer, status }
}

## Takes a slot of `human`'s search limit at `now`; unless every slot holds
## a search of this second.
take_search_slot! : UserId, Timestamp => Try({}, [TooFast])
take_search_slot! = |human, now| {
	keys = SearchLimit.slot_keys(human)
	var $slots = []
	for key in keys {
		kept = Host.read_second_kept_under_key!(key)
		slot =
			match kept.status {
				Missing => NeverUsed
				Found => UsedAt(Timestamp.at_second(kept.second))
			}
		$slots = $slots.append(slot)
	}
	index = SearchLimit.slot_for_search($slots, now)?
	key = keys.get(index) ?? crash "SearchRoute.take_search_slot!: one slot a key"
	_ = Host.replace_second_kept_under_key!(key, now.to_seconds_since_epoch())
	Ok({})
}

## Each topic of `places`, in order, with how a result names its place;
## each the index doesn't hold read from its transcript, decoded and handed
## to it, while the bytes read stay within `most_bytes_read`; and how many
## topics past those bytes were left unread. A transcript that is not one
## the chat writes is handed to the index as unreadable, which counts it.
## Unless the host's listing or a read failed.
fill_index! : List(Browse.ListedPlace) => Try(
	{ topics : List(Search.Where), unread : U64 },
	_,
)
fill_index! = |places| {
	with_topics = BrowseRoute.load_place_topics!(places)?
	var $wheres = []
	for { label: _, place, topics } in with_topics {
		place_label =
			match place.which() {
				Channel(channel) => "#${channel.to_str()}"
				Dm(_) => "a direct message"
			}
		for topic in topics {
			$wheres = $wheres.append({ key: ConversationKey.of({ place, topic }), place_label })
		}
	}
	var $unread = 0
	var $read = 0
	for at in SearchIndex.keys_not_held!($wheres.map(|topic| topic.key)) {
		key = ($wheres.get(at) ?? crash "SearchRoute.fill_index!: a place the index named").key
		if $read >= SearchRoute.most_bytes_read {
			$unread = $unread + 1
		} else {
			match TranscriptFiles.read_transcript!(key)? {
				NoFile => SearchIndex.fill!(key, Messages([]))
				File(utf8) => {
					$read = $read + utf8.to_plain_text().len()
					if $read > SearchRoute.most_bytes_read {
						$unread = $unread + 1
					} else {
						match Transcript.decode(key.topic(), utf8) {
							Ok(conversation) => SearchIndex.fill!(key, Messages(conversation.messages()))
							Err(_) => SearchIndex.fill!(key, Unreadable)
						}
					}
				}
			}
		}
	}
	Ok({ topics: $wheres, unread: $unread })
}

# ── tests
# A key typed, a key missing (none), and a query that can't be read.
expect typed_key("prefix=La".to_utf8(), "prefix") == Ok(SearchWords.SearchKey.of_typed("la"))
expect typed_key("".to_utf8(), "word") == Ok(SearchWords.SearchKey.of_typed(""))
expect typed_key("word=%zz".to_utf8(), "word").is_err()
expect error_answer(429, "too many searches; wait a second").status == 429
