## **CONVERSATION'S TESTS**: numbering by `append`, from the first id to
## the last a conversation holds.
import Conversation
import Message
import Sample

ConversationSpec :: [].{}

expect Conversation.empty(Sample.plans).messages() == []
expect Conversation.empty(Sample.plans).topic() == Sample.plans
expect Conversation.empty(Sample.plans).next_id() == Ok(Sample.first)
# Each append takes the next id, in order.
expect Sample.two.messages() == [
	{ id: Sample.first, payload: Sample.hello },
	{ id: Sample.second, payload: Sample.reply },
]
expect Sample.two.next_id().map_ok(Message.Id.to_str) == Ok("3")
expect Sample.conversation(Sample.plans, [Sample.hello]).next_id() == Ok(Sample.second)
expect Sample.two.topic() == Sample.plans
# The last id at, under and over the highest: 65,534 messages take one
# more, the 65,535th, and then none.
expect {
	almost = Sample.almost_full({})
	full = almost.append(Sample.reply) ?? crash "ConversationSpec: the 65,535th message fits"
	last = full.messages().last().map_ok(|m| m.id.to_str())
	(almost.next_id().map_ok(Message.Id.to_str) == Ok("65535")
		and full.messages().len() == 65535
		and last == Ok("65535")
		and full.next_id() == Err(Full)
		and full.append(Sample.hello) == Err(Full))
}
