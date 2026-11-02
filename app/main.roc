## **THE DEMO**: a topic's name and its transcript in, its page out. The
## host (host/main.zig) reads the file and writes the page; everything
## else is the pure core.
app [page] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/main.roc",
}

import Conversation

## The page for `topic`'s transcript, or a page saying what is wrong with it.
page : List(U8), List(U8) -> List(U8)
page = |topic, transcript|
	match (Str.from_utf8(topic), Str.from_utf8(transcript)) {
		(Ok(t), Ok(text)) =>
			match Conversation.read(t, text) {
				Ok(c) => c.html().to_utf8()
				Err(Malformed(why)) => "<!doctype html>\n<title>Not a transcript</title>\n<p>Not a transcript: ${why}.</p>\n".to_utf8()
			}
		_ => "<!doctype html>\n<title>Not a transcript</title>\n<p>Not a transcript: it is not UTF-8.</p>\n".to_utf8()
	}
