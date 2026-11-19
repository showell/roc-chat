## A DM is a place where two humans talk, or where one human writes alone.
## Agents can't be in a DM: every way to make one takes `Users.Human`s.
##
## A DM is named by its members' ids, lowest first, joined by `_`: the DM
## between users 7 and 11 is `7_11`, never `11_7`, and user 5's own DM is
## `5_5`. `UserPair` decides that spelling.
import Conversation
import Message
import Topic
import UserId
import UserPair
import Users

Dm :: UserPair.{

	## What starting a DM takes: who it is to (the writer again, for their
	## own DM), the topic, and the first message, written by a human.
	Start : {
		to : Users.Human,
		topic : Topic,
		first_message : Message.Unnumbered(Users.Human),
	}

	## The DM between the first message's writer and `to`, and its
	## conversation under `topic` grown by that message, as
	## `Conversation.append` answers it.
	start : Dm.Start -> { dm : Dm, grown : { conversation : Conversation, message : Message } }
	start = |{ to, topic, first_message }| {
		from = first_message.payload.author
		first = {
			payload: { author: from.author(), markdown: first_message.payload.markdown },
			time: first_message.time,
		}
		grown =
			Conversation.empty(topic).append(first)
				?? crash "Dm.start: an empty conversation takes its first message"
		{ dm: Dm.between({ one: from, other: to }), grown }
	}

	## The DM between `one` and `other`, given in either order.
	between : { one : Users.Human, other : Users.Human } -> Dm
	between = |{ one, other }| Dm.(UserPair.of({ one: one.id(), other: other.id() }))

	pair : Dm -> UserPair
	pair = |Dm.(ids)| ids

	## The members' ids, lowest first: two, or one for a human's own DM.
	members : Dm -> List(UserId)
	members = |Dm.(ids)| ids.members()

	## The DM's name, as its folder and its URL spell it.
	to_str : Dm -> Str
	to_str = |Dm.(ids)| ids.to_str()

	is_eq : _
	to_hash : _
}
