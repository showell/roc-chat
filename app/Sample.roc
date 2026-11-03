## This module holds the samples the `*Spec.roc` modules share: topics,
## messages, conversations and a directory of users, so each test reads as
## what it checks. Only a Spec imports it; no production module does.
import Admin
import Author
import Conversation
import Directory
import Message
import DateTime
import Name
import SignedIn
import Topic
import UserId
import Users

Sample :: [].{

	## The topic the samples are written under.
	plans : Topic
	plans = Topic.from_str("plans") ?? crash "Sample.plans: a topic's name"

	## Another topic, whose transcript is not `plans`'s.
	other : Topic
	other = Topic.from_str("other") ?? crash "Sample.other: a topic's name"

	## An unnumbered message, from its parts' text, each a test's own and
	## accepted.
	unnumbered_message : {
		author : Str,
		time : Str,
		markdown : Str,
	} -> Message.Unnumbered(Author)
	unnumbered_message = |
		{
			author,
			time,
			markdown,
		},
	|
		{
			payload: {
				author: Author.from_str(author) ?? crash "Sample.unnumbered_message: a test's author is a name",
				markdown,
			},
			time: DateTime.from_str(time) ?? crash "Sample.unnumbered_message: a test's time is a time",
		}

	## Steve's hello.
	hello : Message.Unnumbered(Author)
	hello = Sample.unnumbered_message({
		author: "Steve",
		time: "2026-11-02T19:11:32Z",
		markdown: "Hello",
	})

	## CC's reply, a minute later, with a list in its markdown.
	reply : Message.Unnumbered(Author)
	reply = Sample.unnumbered_message({
		author: "CC",
		time: "2026-11-02T19:12:28Z",
		markdown: "Hi!\n\n- one\n- two",
	})

	## `topic`'s conversation of `unnumbered_messages`, appended in order; a
	## test's conversation is never full, and its times never go backwards.
	conversation : Topic, List(Message.Unnumbered(Author)) -> Conversation
	conversation = |topic, unnumbered_messages|
		unnumbered_messages.fold(
			Conversation.empty(topic),
			|c, a| (c.append(a) ?? crash "Sample.conversation: a test's conversation is neither full nor backdated").conversation,
		)

	## `plans`'s hello and reply.
	hello_and_reply : Conversation
	hello_and_reply = Sample.conversation(Sample.plans, [Sample.hello, Sample.reply])

	## A conversation one message short of full: 65,534 of Steve's hello.
	## It is a constant, so the specs that need it share one, built once: the
	## build is about a second of a cold run. Only the tests of the most a
	## conversation holds use it.
	almost_full : Conversation
	almost_full = append_hellos({ so_far: Conversation.empty(Sample.plans), count: 65534 })

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

	## The sample directory: Steve (1) and Apoorva (2), who are humans, and
	## CC (3), Steve's agent.
	directory : Directory
	directory = {
		founded = Directory.with_founder(Sample.name("Steve"))
		with_apoorva = (founded.add_human(Sample.name("Apoorva")) ?? crash "Sample.directory: Apoorva's name is free").directory
		founder = with_apoorva.users().user(UserId.steve) ?? crash "Sample.directory: Steve is id 1"
		owner = founder.as_human() ?? crash "Sample.directory: Steve is a human"
		with_cc = with_apoorva.add_agent({
			name: Sample.name("CC"),
			owner,
		}) ?? crash "Sample.directory: CC's name is free"
		with_cc.directory
	}

	## The sample directory with `count` more humans, each
	## named for their place in letters (`Filler aa`, `Filler ab`...).
	crowded_directory : U64 -> Directory
	crowded_directory = |count|
		List.from_iter(U64.until(0, count)).fold(
			Sample.directory,
			|so_far, at| (so_far.add_human(Sample.name("Filler ${place_in_letters(at)}")) ?? crash "Sample.crowded_directory: a filler's name is free").directory,
		)

	## Steve, signed in as an admin. This is the specs' one way to an admin,
	## through the door that stands in for a session (`SignedIn`).
	admin : Admin
	admin = Admin.of(SignedIn.dangerously_assume(Sample.steve)) ?? crash "Sample.admin: Steve is an admin"

	## Steve, in the sample directory.
	steve : Users.User
	steve = Sample.user("Steve")

	## The sample directory's user named `text`, which it holds.
	user : Str -> Users.User
	user = |text|
		Sample.directory.users().to_list().find_first(|u| u.name().to_str() == text) ?? crash "Sample.user: the sample directory holds ${text}"

	## The sample directory's human named `text`, which it holds.
	human : Str -> Users.Human
	human = |text| Sample.user(text).as_human() ?? crash "Sample.human: ${text} is a human"
}

## `at`, below 676, as two letters: 0 is `aa`, 1 `ab`, 26 `ba`.
place_in_letters : U64 -> Str
place_in_letters = |at|
	Str.from_utf8([
		'a' + (at // 26).to_u8_wrap(),
		'a' + (at % 26).to_u8_wrap(),
	]) ?? crash "Sample.place_in_letters: letters are UTF-8"

## `so_far` with `count` more of Steve's hello.
append_hellos : { so_far : Conversation, count : U64 } -> Conversation
append_hellos = |{ so_far, count }|
	if (count == 0)
		so_far
	else
		append_hellos({
			so_far: (so_far.append(Sample.hello) ?? crash "Sample.append_hellos: the conversation has room").conversation,
			count: count - 1,
		})
