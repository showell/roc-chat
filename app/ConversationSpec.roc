## These are the tests of `Conversation`: numbering by `append`, from the
## first id to the last a conversation holds.
import Author
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
expect Conversation.empty(Sample.plans).reference(Sample.first).to_str() == "MSG_plans_1"
expect Conversation.empty(Sample.plans).reference(Sample.second).to_str() == "MSG_plans_2"
expect Conversation.empty(Sample.other).reference(Sample.second).to_str() == "MSG_other_2"
expect Sample.hello_and_reply.reference(Sample.second).to_str() == "MSG_plans_2"
expect Conversation.empty(Sample.plans).next_id() == Ok(Sample.first)
# The messages past a count, at none, one, all and past all.
expect
	summary(Sample.hello_and_reply.messages_after(0)) == summary(Sample.hello_and_reply.messages())
expect summary(Sample.hello_and_reply.messages_after(1)).map(|m| m.id) == ["2"]
expect Sample.hello_and_reply.messages_after(2) == []
expect Sample.hello_and_reply.messages_after(3) == []
# Each append takes the next id, in order, with the unnumbered message's
# parts.
expect summary(Sample.hello_and_reply.messages()) == [
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
expect Sample.hello_and_reply.messages().map(Message.time) == [Sample.hello.time, Sample.reply.time]
expect Sample.hello_and_reply.next_id().map_ok(Message.Id.to_str) == Ok("3")
expect Sample.conversation(Sample.plans, [Sample.hello]).next_id() == Ok(Sample.second)
expect Sample.hello_and_reply.topic() == Sample.plans
# `append` gives back the conversation grown by one and the message it
# added, which is that conversation's latest, at the first id and the
# third.
expect
	Conversation.empty(Sample.plans).append(Sample.hello)
		== Ok({
			conversation: Sample.conversation(Sample.plans, [Sample.hello]),
			message: Message.numbered_message({ id: Sample.first, unnumbered: Sample.hello }),
		})
expect {
	grown =
		Sample.hello_and_reply.append(Sample.reply)
			?? crash "ConversationSpec: a third message fits"
	summary([grown.message]) == [
		{
			id: "3",
			author: "CC",
			markdown: "Hi!\n\n- one\n- two",
		},
	]
		and grown.conversation.messages().last() == Ok(grown.message)
		and grown.conversation.messages().len() == 3
}
# Times never go backwards: at message 2 and message 3, the latest's time
# again, or a second later, is appended; a second earlier is refused.
## Steve's hello at `time`.
hello_at : Str -> Message.Unnumbered(Author)
hello_at = |time|
	Sample.unnumbered_message({ author: "Steve", time, markdown: "Hello" })

## The id `unnumbered_message` takes, appended alone after `c`'s messages,
## or why it is refused.
appended_alone : Conversation, Message.Unnumbered(Author) -> Try(Str, [Full, Backdated])
appended_alone = |c, unnumbered_message|
	c.append(unnumbered_message).map_ok(|grown| grown.message.id().to_str())

## The conversation of Steve's hello alone.
hello_alone : Conversation
hello_alone = Sample.conversation(Sample.plans, [Sample.hello])

expect appended_alone(hello_alone, hello_at("2026-11-02T19:11:32Z")) == Ok("2")
expect appended_alone(hello_alone, hello_at("2026-11-02T19:11:33Z")) == Ok("2")
expect appended_alone(hello_alone, hello_at("2026-11-02T19:11:31Z")) == Err(Backdated)
expect appended_alone(hello_alone, hello_at("2025-11-02T19:11:32Z")) == Err(Backdated)
expect appended_alone(Sample.hello_and_reply, hello_at("2026-11-02T19:12:28Z")) == Ok("3")
expect appended_alone(Sample.hello_and_reply, hello_at("2026-11-02T19:12:29Z")) == Ok("3")
expect appended_alone(Sample.hello_and_reply, hello_at("2026-11-02T19:12:27Z")) == Err(Backdated)
expect appended_alone(Sample.hello_and_reply, hello_at("2026-11-02T19:11:32Z")) == Err(Backdated)
# The first message has no latest to be before.
expect appended_alone(Conversation.empty(Sample.plans), hello_at("0000-01-01T00:00:00Z")) == Ok("1")
# The last id at, under and over the highest: 65,534 messages take one
# more, the 65,535th, and then none. The refusal past it is `Full`, asked
# before the time: Steve's hello is also dated before CC's reply.
expect {
	almost = Sample.almost_full
	grown = almost.append(Sample.reply) ?? crash "ConversationSpec: the 65,535th message fits"
	full = grown.conversation
	almost.next_id().map_ok(Message.Id.to_str) == Ok("65535")
		and grown.message.id().to_str() == "65535"
		and full.messages().len() == 65535
		and full.next_id() == Err(Full)
		and full.append(Sample.hello) == Err(Full)
}
