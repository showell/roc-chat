## These are Place's tests: both kinds of place, a channel and a DM, with
## their names; each equal only to itself; and, with a topic, a map's key.
import ChannelName
import Channels
import Dm
import Place
import Sample
import UserPair

PlaceSpec :: [].{}

## A channel, `text`, created alone.
channel : Str -> Channels.Channel
channel = |text| {
	name = ChannelName.from_str(text) ?? crash "PlaceSpec: a test's channel name is one"
	Channels.empty.create({ by: Sample.admin, name }).channel
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

## A place as a test reads it: its kind, then its name.
kind_and_name : Place -> Str
kind_and_name = |place|
	match place.which() {
		Channel(name) => "channel ${name.to_str()}"
		Dm(pair) => "DM ${pair.to_str()}"
	}

# Each place's kind and name.
expect places.map(kind_and_name) == ["channel plans", "channel general", "DM 1_2", "DM 1_1"]
expect places.map(Place.to_str) == ["plans", "general", "1_2", "1_1"]
# No channel's name is a pair, and no pair is a channel's name, so the two
# kinds never share a name.
expect [
	"1_2",
	"1_1",
].all(|text| ChannelName.from_str(text).is_err() and UserPair.from_str(text).is_ok())
expect [
	"plans",
	"general",
].all(|text| ChannelName.from_str(text).is_ok() and UserPair.from_str(text).is_err())
# Each place equals itself, made again, and no other.
expect places.all(|place| places.keep_if(|other| other == place).len() == 1)
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
	keyed.len() == 3
		and keyed.get((Place.channel(channel("plans")), plans)) == Ok("channel's plans, again")
		and keyed.get((Place.dm(dm_with("Apoorva")), plans)) == Ok("DM's plans")
		and keyed.get((Place.dm(dm_with("Steve")), plans)) == Err(KeyNotFound)
}
