## **DM'S AND PLACE'S TESTS**: a DM starts with its first message, between
## humans only, named by its pair in numeric order; and no DM's name is a
## channel's.
import ChannelName
import Directory
import DateTime
import Dm
import Message
import Place
import Sample
import UserId

DmSpec :: [].{}

## Noon on the day of the samples.
noon : DateTime
noon = DateTime.from_str("2026-11-02T12:00:00Z") ?? crash "DmSpec: a time"

## **WHO A TEST'S DM IS BETWEEN**: its first message's writer, and who it
## is to.
Ends : { from : Directory.User, to : Directory.User }

## A DM started from `from` to `to`, in `plans`, saying hello at noon.
started : Ends -> Try({ dm : Dm, conversation : _ }, [Agent(UserId)])
started = |{ from, to }|
	Dm.start({
		from,
		to,
		topic: Sample.plans,
		markdown: "hello",
		time: noon,
	})

## A started DM's name and members, as a test compares them.
named : Ends -> Try({ name : Str, members : List(Str) }, [Agent(UserId)])
named = |pair|
	started(pair).map_ok(
		|{ dm, conversation: _ }| {
			name: dm.to_str(),
			members: dm.members().map(UserId.to_str),
		},
	)

## The users the crowded sample numbers 9 and 10.
nine_and_ten : { nine : Directory.User, ten : Directory.User }
nine_and_ten = {
	users = Sample.crowded(7).users()
	when_found = |at| users.get(at) ?? crash "DmSpec: the crowded sample has ten users"
	{ nine: when_found(8), ten: when_found(9) }
}

# Two humans, either one starting: one DM, lowest id first.
expect named({
	from: Sample.steve,
	to: Sample.user("Apoorva"),
}) == Ok({ name: "1_2", members: ["1", "2"] })
expect named({
	from: Sample.user("Apoorva"),
	to: Sample.steve,
}) == Ok({ name: "1_2", members: ["1", "2"] })
expect
	started({ from: Sample.steve, to: Sample.user("Apoorva") }).map_ok(|s| s.dm)
		== started({ from: Sample.user("Apoorva"), to: Sample.steve }).map_ok(|s| s.dm)
# The order is numeric, not the names' text: 9 before 10, both ways.
expect named({
	from: nine_and_ten.ten,
	to: nine_and_ten.nine,
}) == Ok({ name: "9_10", members: ["9", "10"] })
expect named({
	from: nine_and_ten.nine,
	to: nine_and_ten.ten,
}) == Ok({ name: "9_10", members: ["9", "10"] })
# One human alone: their own DM, one member.
expect named({
	from: Sample.user("Apoorva"),
	to: Sample.user("Apoorva"),
}) == Ok({ name: "2_2", members: ["2"] })
# An agent, as either side or both, is refused by id, the sender asked
# first.
expect
	[
		named({ from: Sample.user("CC"), to: Sample.steve }),
		named({ from: Sample.steve, to: Sample.user("CC") }),
		named({ from: Sample.user("CC"), to: Sample.user("CC") }),
	]
		== List.repeat(Err(Agent(Sample.user("CC").id())), 3)
# The DM begins with its first message: the sender's, numbered 1, under
# the topic, at its time.
expect
	started({ from: Sample.user("Apoorva"), to: Sample.steve }).map_ok(
		|{ dm: _, conversation }| {
			topic: conversation.topic(),
			messages: conversation.messages().map(
				|m| (
					m.id(),
					m.author().to_str(),
					m.time(),
					m.markdown(),
				),
			),
		},
	)
		== Ok({
			topic: Sample.plans,
			messages: [
				(
					Message.Id.first,
					"Apoorva",
					noon,
					"hello",
				),
			],
		})
# A place's name: a channel's own, or a DM's pair.
expect {
	plans = ChannelName.from_str("plans") ?? crash "DmSpec: plans is a channel's name"
	dm = (
		started({
			from: Sample.steve,
			to: Sample.user("Apoorva"),
		}) ?? crash "DmSpec: two humans start a DM"
	).dm
	[Place.(Channel(plans)).to_str(), Place.(Dm(dm)).to_str()] == ["plans", "1_2"]
}
# No DM's name is a channel's: each is refused as one, by its first byte.
expect
	["1_2", "2_2", "9_10", "255_255"].map(ChannelName.from_str)
		== List.repeat(Err(StartsWithNonLetter), 4)
