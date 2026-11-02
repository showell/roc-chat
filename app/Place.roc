## **WHERE A CONVERSATION LIVES**: a channel or a DM. A topic is unique
## only within its place, so a conversation's identity is its place and its
## topic; the conversation itself stands alone, knowing neither
## (`Conversation`).
##
## **A PLACE'S NAME** is a folder's and a URL's: a channel's name, or a
## DM's pair. A channel's starts with a letter and holds no `_`; a DM's
## starts with a digit and holds one; so no two places share a name.
import ChannelName
import Dm

Place := [Channel(ChannelName), Dm(Dm)].{

	## Its name, as a folder's name and a URL take it.
	to_str : Place -> Str
	to_str = |Place.(place)|
		match place {
			Channel(name) => name.to_str()
			Dm(dm) => dm.to_str()
		}

	is_eq : _
}
