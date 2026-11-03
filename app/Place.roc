## A place is where a conversation lives: a channel or a DM. A topic is
## unique only within its place, so a place and a topic together name one
## conversation, and the pair can key a map. The conversation itself knows
## neither (`Conversation`).
##
## The type is opaque, and it is built only from a `Channels.Channel` or a
## `Dm`, so no place names a channel that no directory holds.
##
## A place's name is its folder's name and its part of a URL: a channel's
## name, or a DM's pair (`UserPair`). No channel's name is also a pair, so
## no two places share a name.
import ChannelName
import Channels
import Dm
import UserPair

Place :: [Channel(ChannelName), Dm(UserPair)].{

	## The place that is `channel`.
	channel : Channels.Channel -> Place
	channel = |found| Place.(Channel(found.name()))

	## The place that is `dm`.
	dm : Dm -> Place
	dm = |found| Place.(Dm(found.pair()))

	## Which kind of place it is, with the channel's name or the DM's pair.
	## No place is built from this union.
	which : Place -> [Channel(ChannelName), Dm(UserPair)]
	which = |Place.(place)| place

	## Its name, as a folder's name and a URL take it.
	to_str : Place -> Str
	to_str = |Place.(place)|
		match place {
			Channel(name) => name.to_str()
			Dm(pair) => pair.to_str()
		}

	is_eq : _
	to_hash : _
}
