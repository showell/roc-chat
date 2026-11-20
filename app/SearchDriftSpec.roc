## **THE DRIFT GATE, THE ROC'S HALF**: the route asks the host's search index
## (host/search_index.zig), and `Search`'s own search stays as the
## reference it must agree with. One fixed corpus and one file of
## questions with their answers hold both: this spec runs each question
## through `Search.words_for` and `Search.messages_for`, and
## host/search_drift_test.zig through the index, and each must give every
## answer in app/search_drift_answers.txt exactly. That test's header says
## the files' format.
import "search_drift_corpus.txt" as corpus : Str
import "search_drift_answers.txt" as answers : Str
import ConversationKey
import Directory
import Sample
import Search
import SearchWords
import UnvalidatedString

SearchDriftSpec :: [].{}

## The sample directory, with the channel `general`.
directory : Directory
directory = Sample.with_default_channel(Sample.directory)

## The topic `name` of `#general`, holding Steve's messages of `markdowns`,
## in order.
topic_of : Str, List(Str) -> Search.Searched
topic_of = |name, markdowns| {
	path = "/chat/channel/general/${name}"
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "SearchDriftSpec: a path is UTF-8",
		directory,
	}).map_ok(|found| found.key) ?? crash "SearchDriftSpec: a corpus topic's name is a topic's"
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
	{ key, place_label: "#general", messages: conversation.messages() }
}

## The topics of `text`, a corpus, in order: each `=== <topic>` line opens
## one, and a `---` line splits its messages.
topics_of : Str -> List(Search.Searched)
topics_of = |text|
	text.split_on("=== ").drop_first(1).map(
		|piece|
			match piece.split_on("\n") {
				[name, .. as rest] => {
					body = Str.join_with(rest, "\n").drop_suffix("\n")
					topic_of(name, body.split_on("\n---\n"))
				}
				[] => crash "SearchDriftSpec: a topic has a name"
			},
	)

## The reference's answer to one question, of `kind`, in `topics`, as the
## answers file writes it.
answer_of : {
	topics : List(Search.Searched),
	kind : Str,
	key : SearchWords.SearchKey,
} -> Str
answer_of = |{ topics, kind, key }|
	if kind == "words" {
		words = Search.words_for({ topics, prefix: key })
		Str.join_with(words.map(|{ word, count }| "${word}=${count.to_str()}"), " ")
	} else {
		found = Search.messages_for({ topics, word: key })
		hits = found.hits.map(
			|hit| " ${hit.found_in.key.topic().to_str()}#${hit.message.id().to_str()}",
		)
		"matched=${found.matched.to_str()}${Str.join_with(hits, "")}"
	}

## Each line of `asked`, the answers file, the reference doesn't give over
## the corpus `text`, with what it gives instead; and each key that isn't
## one `of_typed` makes.
mismatches_of : Str, Str -> List(Str)
mismatches_of = |text, asked| {
	topics = topics_of(text)
	asked.drop_suffix("\n").split_on("\n").keep_oks(
		|line|
			match line.split_on("\t") {
				[kind, typed, want] => {
					key = SearchWords.SearchKey.of_typed(typed)
					got = answer_of({ topics, kind, key })
					if key.to_str() != typed {
						Ok("${line}: not a key of_typed makes")
					} else if got != want {
						Ok("${line}: the reference gives ${got}")
					} else {
						Err(Agrees)
					}
				}
				_ => Ok("${line}: not a question and its answer")
			},
	)
}

# Every answer of the drift corpus, as the host's index gives it, is the
# reference's too.
expect mismatches_of(corpus, answers) == []
expect answers.split_on("\n").len() > 60 and topics_of(corpus).len() == 3
