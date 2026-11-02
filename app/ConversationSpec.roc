## **CONVERSATION'S TESTS**: numbering by `append`, from the first id to
## the last a conversation holds.
import Conversation
import Message
import Sample

ConversationSpec :: [].{}

## Each message's id, author and markdown, as a test compares them.
summary : List(Message) -> List(
	{
		id : Str,
		author : Str,
		markdown : Str,
	},
)
summary = |messages| messages.map(
	|m| {
		id: m.id().to_str(),
		author: m.author().to_str(),
		markdown: m.markdown(),
	},
)

expect Conversation.empty(Sample.plans).messages() == []
expect Conversation.empty(Sample.plans).topic() == Sample.plans
# A message's reference: its conversation's topic and its id, whether or
# not the conversation holds it yet.
expect Conversation.empty(Sample.plans).reference(Sample.first) == "MSG_plans_1"
expect Conversation.empty(Sample.plans).reference(Sample.second) == "MSG_plans_2"
expect Conversation.empty(Sample.other).reference(Sample.second) == "MSG_other_2"
expect Sample.two.reference(Sample.second) == "MSG_plans_2"
expect Conversation.empty(Sample.plans).next_id() == Ok(Sample.first)
# Each append takes the next id, in order, with what arrived.
expect summary(Sample.two.messages()) == [
	{
		id: "1",
		author: "Steve",
		markdown: "Hello",
	},
	{
		id: "2",
		author: "CC",
		markdown: "Hi!\n\n- one\n- two",
	},
]
expect Sample.two.messages().map(Message.time) == [Sample.hello.time, Sample.reply.time]
expect Sample.two.next_id().map_ok(Message.Id.to_str) == Ok("3")
expect Sample.conversation(Sample.plans, [Sample.hello]).next_id() == Ok(Sample.second)
expect Sample.two.topic() == Sample.plans
# `append` gives back the conversation grown by one and the message it
# added, which is that conversation's latest, at the first id and the
# third.
expect
	Conversation.empty(Sample.plans).append(Sample.hello)
		== Ok({
			conversation: Sample.conversation(Sample.plans, [Sample.hello]),
			added: Message.numbered({ id: Sample.first, arrival: Sample.hello }),
		})
expect
	Sample.two.append(Sample.reply).map_ok(
		|{ conversation, added }| {
			added: summary([added]),
			latest: conversation.messages().last() == Ok(added),
			count: conversation.messages().len(),
		},
	)
		== Ok({
			added: [
				{
					id: "3",
					author: "CC",
					markdown: "Hi!\n\n- one\n- two",
				},
			],
			latest: Bool.True,
			count: 3,
		})
# The last id at, under and over the highest: 65,534 messages take one
# more, the 65,535th, and then none.
expect {
	almost = Sample.almost_full({})
	grown = almost.append(Sample.reply) ?? crash "ConversationSpec: the 65,535th message fits"
	full = grown.conversation
	{
		next_of_almost: almost.next_id().map_ok(Message.Id.to_str),
		added: grown.added.id().to_str(),
		count: full.messages().len(),
		next_of_full: full.next_id(),
		appended: full.append(Sample.hello),
	}
		== {
			next_of_almost: Ok("65535"),
			added: "65535",
			count: 65535,
			next_of_full: Err(Full),
			appended: Err(Full),
		}
}
