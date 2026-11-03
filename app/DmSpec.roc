## These are the tests of `Dm`: a DM started with its first message,
## between humans, named by its pair in numeric order; the same DM made by
## `between`; and no DM's name a channel's.
import ChannelName
import DateTime
import Dm
import Message
import Sample
import UserId
import Users

DmSpec :: [].{}

## Noon on the day of the samples.
noon : DateTime
noon = DateTime.from_str("2026-11-02T12:00:00Z") ?? crash "DmSpec: a time"

## Who a test's DM is between: its first message's writer, and who it is
## to.
Ends : { from : Users.Human, to : Users.Human }

## A DM started from `from` to `to`, in `plans`, saying hello at noon.
start_dm : Ends -> { dm : Dm, conversation : _ }
start_dm = |{ from, to }|
	Dm.start({
		to,
		topic: Sample.plans,
		first_message: { payload: { author: from, markdown: "hello" }, time: noon },
	})

## A started DM's name and members, as a test compares them.
name_and_members : Ends -> { name : Str, members : List(Str) }
name_and_members = |pair| {
	dm = start_dm(pair).dm
	{ name: dm.to_str(), members: dm.members().map(UserId.to_str) }
}

## The humans the crowded sample numbers 9 and 10.
nine_and_ten : { nine : Users.Human, ten : Users.Human }
nine_and_ten = {
	users = Sample.crowded_directory(7).users()
	human = |at| ((users.user(at) ?? crash "DmSpec: the crowded sample has ten users").as_human()) ?? crash "DmSpec: a filler is a human"
	nine = UserId.from_str("9") ?? crash "DmSpec: 9 is an id"
	ten = UserId.from_str("10") ?? crash "DmSpec: 10 is an id"
	{ nine: human(nine), ten: human(ten) }
}

# Two humans, either one starting: one DM, lowest id first.
expect
	[
		name_and_members({ from: Sample.human("Steve"), to: Sample.human("Apoorva") }),
		name_and_members({ from: Sample.human("Apoorva"), to: Sample.human("Steve") }),
	].all(|dm| dm == { name: "1_2", members: ["1", "2"] })
expect
	start_dm({ from: Sample.human("Steve"), to: Sample.human("Apoorva") }).dm
		== start_dm({ from: Sample.human("Apoorva"), to: Sample.human("Steve") }).dm
# The order is numeric, not the names' text: 9 before 10, both ways.
expect
	[
		name_and_members({ from: nine_and_ten.ten, to: nine_and_ten.nine }),
		name_and_members({ from: nine_and_ten.nine, to: nine_and_ten.ten }),
	].all(|dm| dm == { name: "9_10", members: ["9", "10"] })
# One human alone: their own DM, one member.
expect name_and_members({
	from: Sample.human("Apoorva"),
	to: Sample.human("Apoorva"),
}) == { name: "2_2", members: ["2"] }
# `between` makes the DM `start` made, either way round; a different pair
# is a different DM.
expect
	[
		Dm.between({ a: Sample.human("Steve"), b: Sample.human("Apoorva") }),
		Dm.between({ a: Sample.human("Apoorva"), b: Sample.human("Steve") }),
	].all(|dm| dm == start_dm({ from: Sample.human("Steve"), to: Sample.human("Apoorva") }).dm)
expect
	Dm.between({ a: Sample.human("Steve"), b: Sample.human("Steve") })
		!= Dm.between({ a: Sample.human("Steve"), b: Sample.human("Apoorva") })
expect Dm.between({ a: nine_and_ten.ten, b: nine_and_ten.nine }).pair().to_str() == "9_10"
# The DM begins with its first message: the writer's, numbered 1, under
# the topic, at its time, as its author.
expect {
	conversation = start_dm({
		from: Sample.human("Apoorva"),
		to: Sample.human("Steve"),
	}).conversation
	conversation.topic() == Sample.plans
		and conversation.messages().map(
			|m| (
				m.id(),
				m.author().to_str(),
				m.time(),
				m.markdown(),
			),
		)
			== [
				(
					Message.Id.first,
					"Apoorva",
					noon,
					"hello",
				),
			]
}
# No DM's name is a channel's: each is refused as one, by its first byte.
expect
	["1_2", "2_2", "9_10", "255_255"].all(
		|text| ChannelName.from_str(text) == Err(StartsWithNonLetter),
	)
