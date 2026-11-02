## **A MESSAGE**: who wrote it, when, and what (its payload), with the id
## its conversation gives it. Immutable: an edit is a new message. A message
## knows nothing of who may write where; that is the conversation's.
##
## There is no way to build a numbered message here: only
## `Conversation.append` gives a payload its id, so a message's id is always
## its place in its conversation.
import Author
import Timestamp
import Topic

Message :: [].{

	## **WHAT A MESSAGE IS BEFORE IT HAS AN ID**: who wrote it, when, and the
	## markdown, exactly as written.
	Payload : {
		author : Author,
		time : Timestamp,
		markdown : Str,
	}

	## **A MESSAGE'S ID**: its number in its conversation, counting from 1,
	## so a conversation's order is its ids' order. At most U16's highest,
	## 65,535: a conversation that long is archived, never grown.
	Id :: U16.{

		## The first message's id.
		first : Message.Id
		first = Message.Id.(1)

		## The id after this one, unless this is the last a conversation
		## holds.
		next : Message.Id -> Try(Message.Id, [Full])
		next = |Message.Id.(n)| if (n == U16.highest) Err(Full) else Ok(Message.Id.(n + 1))

		## The number, as a page's anchors and a refusal write it.
		to_str : Message.Id -> Str
		to_str = |Message.Id.(n)| n.to_str()

		is_eq : _
	}

	## **THE ONE NAME OF A MESSAGE**, `MSG_<topic>_<n>`, as a transcript's
	## id line and a page's link write it.
	reference : Topic, Message.Id -> Str
	reference = |topic, id| "MSG_${topic.to_str()}_${id.to_str()}"
}

# ── tests
plans : Topic
plans = Topic.from_str("plans") ?? crash "Message's tests: a topic's name"

expect Message.Id.first.to_str() == "1"
expect Message.Id.first.next().map_ok(Message.Id.to_str) == Ok("2")
expect Message.reference(plans, Message.Id.first) == "MSG_plans_1"
expect Message.Id.first.next().map_ok(|id| Message.reference(plans, id)) == Ok("MSG_plans_2")
# The last id at, under and over the highest.
expect Message.Id.(65534).next().map_ok(Message.Id.to_str) == Ok("65535")
expect Message.Id.(65535).next() == Err(Full)
