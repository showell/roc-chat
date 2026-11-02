## **A DM**: a place for exactly one or two humans, never an agent, named
## by its pair of user ids in numeric order: `7_11`, never `11_7`, and one
## human alone, in their own DM, `5_5`. A DM's name starts with a digit and
## holds a `_`, and a channel's never does (`StrictName`), so the two never
## collide.
##
## **A DM BEGINS WITH ITS FIRST MESSAGE**: opaque, so `start` is the only
## way in, and it gives the DM together with its first conversation,
## holding that message. A DM with no message, or with an agent in it,
## can't be built.
import Conversation
import DateTime
import Users
import Topic
import UserId

Dm :: { low : UserId, high : UserId }.{

	## **WHAT STARTING A DM NEEDS**: who writes the first message (`from`),
	## who it is to (`to`; `from` again for one's own DM), the topic, and
	## the message's markdown and time. Both are the directory's users, so
	## each is known to be a human or an agent.
	Start : {
		from : Users.User,
		to : Users.User,
		topic : Topic,
		markdown : Str,
		time : DateTime,
	}

	## The DM between `from` and `to`, and its conversation under `topic`,
	## whose first message `from` wrote; unless `from` is an agent, or else
	## `to` is (`Agent`, naming them).
	start : Dm.Start -> Try({ dm : Dm, conversation : Conversation }, [Agent(UserId)])
	start = |
		{
			from,
			to,
			topic,
			markdown,
			time,
		},
	| {
		human_only(from)?
		human_only(to)?
		pair =
			match from.id().compare(to.id()) {
				After => { low: to.id(), high: from.id() }
				_ => { low: from.id(), high: to.id() }
			}
		grown = Conversation.empty(topic).append({
			payload: { author: from.author(), markdown },
			time,
		}) ?? crash "Dm.start: an empty conversation takes its first message"
		Ok({ dm: Dm.(pair), conversation: grown.conversation })
	}

	## Its members' ids, lowest first: two, or one for one's own DM.
	members : Dm -> List(UserId)
	members = |Dm.({ low, high })| if (low == high) [low] else [low, high]

	## **ITS NAME**, as a folder's name and a URL take it: the ids, lowest
	## first, joined by `_`.
	to_str : Dm -> Str
	to_str = |Dm.({ low, high })| "${low.to_str()}_${high.to_str()}"

	is_eq : _
}

## Nothing, if `user` is a human; else the refusal naming them.
human_only : Users.User -> Try({}, [Agent(UserId)])
human_only = |user|
	match user.role() {
		Human => Ok({})
		Agent(_) => Err(Agent(user.id()))
	}
