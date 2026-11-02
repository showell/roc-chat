## **SAMPLES FOR THE SPECS**: the topics, payloads and conversation the
## `*Spec.roc` modules share, so each test reads as what it checks. Only a
## Spec imports it; no production module does.
import Author
import Conversation
import Message
import DateTime
import Topic

Sample :: [].{

	## The topic the samples are written under.
	plans : Topic
	plans = Topic.from_str("plans") ?? crash "Sample.plans: a topic's name"

	## Another topic, whose transcript is not `plans`'s.
	other : Topic
	other = Topic.from_str("other") ?? crash "Sample.other: a topic's name"

	## What arrives, from its parts' text, each a test's own and accepted.
	arrival : {
		author : Str,
		time : Str,
		markdown : Str,
	} -> Message.Arrival
	arrival = |
		{
			author,
			time,
			markdown,
		},
	|
		{
			payload: {
				author: Author.from_str(author) ?? crash "Sample.arrival: a test's author is a name",
				markdown,
			},
			time: DateTime.from_str(time) ?? crash "Sample.arrival: a test's time is a time",
		}

	## Steve's hello.
	hello : Message.Arrival
	hello = Sample.arrival({
		author: "Steve",
		time: "2026-11-02T19:11:32Z",
		markdown: "Hello",
	})

	## CC's reply, a minute later, with a list in its markdown.
	reply : Message.Arrival
	reply = Sample.arrival({
		author: "CC",
		time: "2026-11-02T19:12:28Z",
		markdown: "Hi!\n\n- one\n- two",
	})

	## `topic`'s conversation of `arrivals`, appended in order; a test's
	## conversation is never full.
	conversation : Topic, List(Message.Arrival) -> Conversation
	conversation = |topic, arrivals|
		arrivals.fold(
			Conversation.empty(topic),
			|c, a| c.append(a) ?? crash "Sample.conversation: a test's conversation is not full",
		)

	## `plans`'s hello and reply.
	two : Conversation
	two = Sample.conversation(Sample.plans, [Sample.hello, Sample.reply])

	## **A CONVERSATION ONE MESSAGE SHORT OF FULL**: 65,534 of Steve's hello.
	## A function, not a constant, so the work runs with the test, never in
	## `roc check`'s compile-time evaluation.
	almost_full : {} -> Conversation
	almost_full = |{}| filled({ so_far: Conversation.empty(Sample.plans), count: 65534 })

	## The first message's id.
	first : Message.Id
	first = Message.Id.first

	## The second message's id.
	second : Message.Id
	second = Message.Id.first.next() ?? crash "Sample.second: the first id has a next"
}

## `so_far` with `count` more of Steve's hello.
filled : { so_far : Conversation, count : U64 } -> Conversation
filled = |{ so_far, count }|
	if (count == 0)
		so_far
	else
		filled({
			so_far: so_far.append(Sample.hello) ?? crash "Sample.filled: the conversation has room",
			count: count - 1,
		})
