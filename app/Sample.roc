## **SAMPLES FOR THE SPECS**: the topics, payloads and conversation the
## `*Spec.roc` modules share, so each test reads as what it checks. Only a
## Spec imports it; no production module does.
import Author
import Conversation
import Directory
import Message
import DateTime
import Name
import Topic
import UserId

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
	## conversation is never full, and its times never go backwards.
	conversation : Topic, List(Message.Arrival) -> Conversation
	conversation = |topic, arrivals|
		arrivals.fold(
			Conversation.empty(topic),
			|c, a| (c.append(a) ?? crash "Sample.conversation: a test's conversation is neither full nor backdated").conversation,
		)

	## `plans`'s hello and reply.
	two : Conversation
	two = Sample.conversation(Sample.plans, [Sample.hello, Sample.reply])

	## **A CONVERSATION ONE MESSAGE SHORT OF FULL**: 65,534 of Steve's hello.
	## A constant, so the specs that need it share one, built once: the
	## build is about a second of a cold run. Only the tests of the most a
	## conversation holds use it.
	almost_full : Conversation
	almost_full = filled({ so_far: Conversation.empty(Sample.plans), count: 65534 })

	## The first message's id.
	first : Message.Id
	first = Message.Id.first

	## The second message's id.
	second : Message.Id
	second = Message.Id.first.next() ?? crash "Sample.second: the first id has a next"

	## The third message's id.
	third : Message.Id
	third = Sample.second.next() ?? crash "Sample.third: the second id has a next"

	## The permanent name `text`, which a test's always is.
	name : Str -> Name
	name = |text| Name.from_str(text) ?? crash "Sample.name: a test's name is a name"

	## **THE SAMPLE DIRECTORY**: Steve (1) and Apoorva (2), humans, and CC
	## (3), Steve's agent.
	directory : Directory
	directory = {
		founded = Directory.founded_by(Sample.name("Steve"))
		with_apoorva = (founded.add_human(Sample.name("Apoorva")) ?? crash "Sample.directory: Apoorva's name is free").directory
		with_cc = with_apoorva.add_agent({
			name: Sample.name("CC"),
			owner: UserId.steve,
		}) ?? crash "Sample.directory: CC's name is free"
		with_cc.directory
	}

	## **THE SAMPLE DIRECTORY, CROWDED**: with `count` more humans, each
	## named for their place (`filler-0`, `filler-1`...).
	crowded : U64 -> Directory
	crowded = |count|
		List.from_iter(U64.until(0, count)).fold(
			Sample.directory,
			|so_far, at| (so_far.add_human(Sample.name("filler-${at.to_str()}")) ?? crash "Sample.crowded: a filler's name is free").directory,
		)

	## Steve, in the sample directory.
	steve : Directory.User
	steve = Sample.user("Steve")

	## The sample directory's user named `text`, which it holds.
	user : Str -> Directory.User
	user = |text|
		Sample.directory.users().find_first(|u| u.name().to_str() == text) ?? crash "Sample.user: the sample directory holds ${text}"
}

## `so_far` with `count` more of Steve's hello.
filled : { so_far : Conversation, count : U64 } -> Conversation
filled = |{ so_far, count }|
	if (count == 0)
		so_far
	else
		filled({
			so_far: (so_far.append(Sample.hello) ?? crash "Sample.filled: the conversation has room").conversation,
			count: count - 1,
		})
