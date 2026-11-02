## **WHERE A CONVERSATION LIVES**: a channel or a DM. A topic is unique
## only within its place, so a conversation's identity is its place and its
## topic, and the pair keys a map (`to_hash`); the conversation itself
## stands alone, knowing neither (`Conversation`).
##
## **ONLY A PLACE THAT EXISTS**: opaque, and its doors take a
## `Channels.Channel` or a `Dm`, so a place for a channel no directory
## holds can't be built.
##
## **A PLACE'S NAME** is a folder's and a URL's: a channel's name, or a
## DM's pair (`UserPair`). A channel's starts with a letter and holds no
## `_`; a DM's starts with a digit and holds one; so no two places share a
## name.
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

	## **WHICH KIND OF PLACE, AND ITS NAME**: a channel's name, or a DM's
	## pair. A view only: no place is built from one.
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
