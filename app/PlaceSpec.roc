## **PLACE'S TESTS**: both kinds of place, a channel's and a DM's, named
## as a folder and a URL take them; equal only to themselves; and, with a
## topic, a map's key.
import ChannelName
import Channels
import Dm
import Place
import Sample

PlaceSpec :: [].{}

## A channel, `text`, created alone.
channel : Str -> Channels.Channel
channel = |text| {
	name = ChannelName.from_str(text) ?? crash "PlaceSpec: a test's channel name is one"
	Channels.empty.create({ by: Sample.admin, name }).created
}

## The DM between Steve and `text`.
dm_with : Str -> Dm
dm_with = |text| Dm.between({ a: Sample.human("Steve"), b: Sample.human(text) })

## Every kind of place: two channels, a DM of two and one's own DM.
places : List(Place)
places = [
	Place.channel(channel("plans")),
	Place.channel(channel("general")),
	Place.dm(dm_with("Apoorva")),
	Place.dm(dm_with("Steve")),
]

# Each tag's name: a channel's own, or a DM's pair.
expect places.map(Place.to_str) == ["plans", "general", "1_2", "1_1"]
# Each place equals itself, made again, and no other.
expect
	places.map(|place| places.keep_if(|other| other == place).len()) == [1, 1, 1, 1]
expect Place.channel(channel("plans")) == Place.channel(channel("plans"))
expect Place.dm(
	Dm.between({
		a: Sample.human("Apoorva"),
		b: Sample.human("Steve"),
	}),
) == Place.dm(dm_with("Apoorva"))
# A place and a topic key a map: the same topic in two places is two
# keys, and the same pair is one.
expect {
	plans = Sample.plans
	other = Sample.other
	keyed =
		Dict.empty()
			.insert((Place.channel(channel("plans")), plans), "channel's plans")
			.insert((Place.dm(dm_with("Apoorva")), plans), "DM's plans")
			.insert((Place.dm(dm_with("Apoorva")), other), "DM's other")
			.insert((Place.channel(channel("plans")), plans), "channel's plans, again")
	(
		keyed.len(),
		keyed.get((Place.channel(channel("plans")), plans)),
		keyed.get((Place.dm(dm_with("Apoorva")), plans)),
		keyed.get((Place.dm(dm_with("Steve")), plans)),
	)
		== (
			3,
			Ok("channel's plans, again"),
			Ok("DM's plans"),
			Err(KeyNotFound),
		)
}
