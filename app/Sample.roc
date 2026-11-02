## **SAMPLES FOR THE TESTS**: the messages, ids, topic and time the
## modules' `expect`s share, so each test reads as what it checks. It exists
## for the tests; nothing else calls it.
import Author
import Message
import Timestamp
import Topic

Sample :: [].{

	## A message from `author`, written at `time`.
	said : {
		id : Message.Id,
		author : Str,
		markdown : Str,
	} -> Message
	said = |
		{
			id,
			author,
			markdown,
		},
	|
		Message.new({
			id,
			author: Author.from_str(author) ?? crash "Sample.said: a test's author is a name",
			time: Sample.time,
			markdown,
		})

	## The time every sample message was written.
	time : Timestamp
	time = Timestamp.from_str("2026-11-02T19:11:32Z") ?? crash "Sample.time: a real time"

	## The topic the samples are written under.
	plans : Topic
	plans = Topic.from_str("plans") ?? crash "Sample.plans: a topic's name"

	## Another topic, whose transcript is not `plans`'s.
	other : Topic
	other = Topic.from_str("other") ?? crash "Sample.other: a topic's name"

	## The first message's id.
	first : Message.Id
	first = Message.Id.first

	## The second message's id.
	second : Message.Id
	second = Message.Id.first.next() ?? crash "Sample.second: the first id has a next"

	## Two messages, the second with a list in its markdown.
	two : List(Message)
	two = [
		Sample.said({
			id: Sample.first,
			author: "Steve",
			markdown: "Hello",
		}),
		Sample.said({
			id: Sample.second,
			author: "CC",
			markdown: "Hi!\n\n- one\n- two",
		}),
	]
}

# ── tests
expect Sample.said({
	id: Sample.first,
	author: "Steve",
	markdown: "Hello",
}).author().to_str() == "Steve"
expect Sample.time.to_str() == "2026-11-02T19:11:32Z"
expect Sample.second.to_str() == "2"
