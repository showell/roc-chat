## This module is search's side of the host's search index
## (host/search_index.zig, docs/platform.md, "The search index"): what it
## holds of each topic, and the questions put to it. The index is a cache of
## the transcripts, which stay the database. A topic's key is its
## conversation's page; each of its messages is held as its markdown, under
## a label of its author and its time, in order, so a text's place is its
## message's id less one.
##
## A topic is filled from its transcript the first time a search reaches it
## (`SearchRoute`), and each message appended to a topic after is added as
## it lands (`note_record!`, which `TranscriptFiles.append_message!` calls
## once the file holds it). A message never changes, an edit being a new
## one, so the index only grows. The index answers which words and which
## messages of the topics it is asked about match; who may ask about which
## topics is `Browse.places_for`'s, and the answer's shape `Search`'s.
import pf.Host
import Author
import ConversationKey
import DateTime
import Message
import SearchWords
import Transcript

SearchIndex :: [].{

	## A message the index holds the word in, and the place of its topic
	## among those asked about, from 0.
	Holding : { topic_at : U64, message : Message }

	## A topic's key in the index.
	key_of : ConversationKey -> List(U8)
	key_of = |key| key.url_path(Page).to_utf8()

	## The places, from 0, of the topics of `keys` the index doesn't hold yet.
	find_keys_not_held! : List(ConversationKey) => List(U64)
	find_keys_not_held! = |keys| Host.search_index_keys_not_held!(keys.map(SearchIndex.key_of))

	## `key`'s topic held with `messages`, in place of what it held; or, when
	## its transcript can't be read, held as one a search may miss.
	load_topic! : ConversationKey, [Messages(List(Message)), Unreadable] => {}
	load_topic! = |key, held| {
		index_key = SearchIndex.key_of(key)
		match held {
			Messages(messages) => {
				Host.open_search_index_key!(index_key, Searchable)
				for message in messages {
					add!(
						index_key,
						{
							author: message.author(),
							time: message.time(),
							markdown: message.markdown(),
						},
					)
				}
			}
			Unreadable => Host.open_search_index_key!(index_key, Unsearchable)
		}
	}

	## The message `record` holds, added to `key`'s topic as it lands, after
	## the transcript holds it. A topic the index doesn't hold yet takes
	## nothing: a search reads it from its file.
	note_record! : ConversationKey, Transcript.Utf8TranscriptMessage => {}
	note_record! = |key, record| {
		file = Transcript.Utf8Transcript.unchecked_from_file(record.to_utf8_bytes())
		match Transcript.latest_message(file) {
			Ok(Latest(latest)) => add!(SearchIndex.key_of(key), latest)
			_ => crash "SearchIndex.note_record!: a record is one message Transcript wrote"
		}
	}

	## How many of `keys` the index couldn't read: a question of no word,
	## which no message holds.
	count_unsearchable! : List(ConversationKey) => U64
	count_unsearchable! = |keys| {
		asked = keys.map(SearchIndex.key_of)
		Host.find_texts_in_search_index!(asked, [], 0).unsearchable
	}

	## At most `most` words of the messages of `keys` that begin with
	## `prefix`, each with how many messages hold it, the most held first,
	## then in byte order; and how many of `keys` the index couldn't read.
	find_words! : {
		keys : List(ConversationKey),
		prefix : SearchWords.SearchKey,
		most : U64,
	} => { words : List({ word : Str, count : U64 }), unsearchable : U64 }
	find_words! = |{ keys, prefix, most }| {
		asked = keys.map(SearchIndex.key_of)
		got = Host.find_words_in_search_index!(asked, prefix.bytes(), most)
		{
			words: got.words.map(|{ word, count }| { word: Str.from_utf8_lossy(word), count }),
			unsearchable: got.unsearchable,
		}
	}

	## At most `most` messages of `keys` that hold `word` as a word of their
	## own, in order; how many hold it in all; and how many of `keys` the
	## index couldn't read.
	find_messages! : {
		keys : List(ConversationKey),
		word : SearchWords.SearchKey,
		most : U64,
	} => {
		found_messages : List(SearchIndex.Holding),
		matched : U64,
		unsearchable : U64,
	}
	find_messages! = |{ keys, word, most }| {
		asked = keys.map(SearchIndex.key_of)
		got = Host.find_texts_in_search_index!(asked, word.bytes(), most)
		{
			found_messages: got.hits.map(
				|{ key_at, label, text, text_at }| {
					topic_at: key_at,
					message: message_of({ label, text, text_at }),
				},
			),
			matched: got.matched,
			unsearchable: got.unsearchable,
		}
	}
}

## A message added at the end of the topic `index_key`, labelled with its
## author and its time.
add! : List(U8),
{
	author : Author,
	time : DateTime,
	markdown : Str,
} => {}
add! = |index_key, { author, time, markdown }|
	Host.append_text_to_search_index_key!(
		index_key,
		"${author.to_str()}\n${time.to_str()}".to_utf8(),
		markdown.to_utf8(),
	)

## The message a hit names: its id its place plus one, its author and time
## its label's, as `add!` wrote them.
message_of : {
	label : List(U8),
	text : List(U8),
	text_at : U64,
} -> Message
message_of = |{ label, text, text_at }| {
	parts = Str.from_utf8(label) ?? crash "SearchIndex: a label is UTF-8"
	(author, time) =
		match parts.split_on("\n") {
			[name, date] =>
				(
					Author.from_str(name) ?? crash "SearchIndex: a label's author",
					DateTime.from_str(date) ?? crash "SearchIndex: a label's time",
				)
			_ => crash "SearchIndex: a label is an author and a time"
		}
	digits = (text_at + 1).to_str().to_utf8()
	id = Message.Id.from_digits(digits) ?? crash "SearchIndex: a text's place is its id less one"
	markdown = Str.from_utf8(text) ?? crash "SearchIndex: a text is a message's markdown"
	Message.numbered_message({ id, unnumbered: { payload: { author, markdown }, time } })
}
