## **A DM**: a place for exactly one or two humans, never an agent, named
## by its pair of user ids in numeric order (`UserPair`, the one home of
## that spelling): `7_11`, never `11_7`, and one human alone, in their own
## DM, `5_5`. Its doors take only `Users.Human`s, so a DM holding an agent
## can't be typed.
##
## **A DM BEGINS WITH ITS FIRST MESSAGE**: enforced where a DM is created.
## `start` is the one door that makes a new DM, and it gives the DM
## together with its first conversation, holding that message, so no new
## DM is ever empty. `between` loads a DM that already exists, from its
## folder on disk; a DM's folder is written only with the conversation
## `start` gives, so a DM that was never started is never loaded.
import Conversation
import Message
import Topic
import UserId
import UserPair
import Users

Dm :: UserPair.{

	## **WHAT STARTING A DM NEEDS**: who it is to (`to`; the writer again
	## for one's own DM), the topic, and the first message as it arrives
	## (`Message.Arrival`, the shape's one home), written by a human.
	Start : {
		to : Users.Human,
		topic : Topic,
		arrival : Message.Arrival(Users.Human),
	}

	## **THE ONE WAY A NEW DM BEGINS**: the DM between the first message's
	## writer and `to`, and its conversation under `topic`, holding that
	## message.
	start : Dm.Start -> { dm : Dm, conversation : Conversation }
	start = |
		{
			to,
			topic,
			arrival,
		},
	| {
		from = arrival.payload.author
		first = {
			payload: { author: from.author(), markdown: arrival.payload.markdown },
			time: arrival.time,
		}
		grown = Conversation.empty(topic).append(first) ?? crash "Dm.start: an empty conversation takes its first message"
		{ dm: Dm.between({ a: from, b: to }), conversation: grown.conversation }
	}

	## **A DM THAT EXISTS, LOADED**: the DM between `a` and `b`, in either
	## order, for a DM already on disk (`start` makes a new one).
	between : { a : Users.Human, b : Users.Human } -> Dm
	between = |{ a, b }| Dm.(UserPair.of({ a: a.id(), b: b.id() }))

	## Its pair of ids.
	pair : Dm -> UserPair
	pair = |Dm.(ids)| ids

	## Its members' ids, lowest first: two, or one for one's own DM.
	members : Dm -> List(UserId)
	members = |Dm.(ids)| ids.members()

	## **ITS NAME**, as a folder's name and a URL take it: its pair's
	## spelling.
	to_str : Dm -> Str
	to_str = |Dm.(ids)| ids.to_str()

	is_eq : _
	to_hash : _
}
