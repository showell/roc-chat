## These are the tests of `MessageNotice`: the event that tells a human of a
## message in one of their places, and who is told.
import Access
import Channels
import ConversationKey
import Directory
import Message
import MessageNotice
import Sample
import UnvalidatedString
import UserId

MessageNoticeSpec :: [].{}

## The sample's users, with the default channel holding all three: Steve
## and Apoorva, humans, and CC, an agent.
directory : Directory
directory = {
	channels =
		Channels.from_stored([{ name: Channels.default_name, members: "1\n2\n3\n".to_utf8() }])
			?? crash "MessageNoticeSpec.directory: a members file"
	Directory.from_stored({ users: Sample.directory.users(), channels })
		?? crash "MessageNoticeSpec.directory: its members are users"
}

## The conversation at `path`, in `directory`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "MessageNoticeSpec: a path is UTF-8",
	directory,
}).map_ok(|found| found.key) ?? crash "MessageNoticeSpec: a conversation's path"

## Who of the readers of `path` is told of a message by the user `author`.
told_at : Str, UserId -> List(Str)
told_at = |path, author|
	MessageNotice.recipients({
		readers: Access.members({ place: key_at(path).place(), directory }),
		author,
	}).map(UserId.to_str)

# Gopher's words: a DM says the topic, a channel its name and the topic.
expect
	MessageNotice.words({ author: "Steve", key: key_at("/chat/dm/1_2/plans") })
		== "Steve sent you a message on plans."
expect
	MessageNotice.words({ author: "Apoorva", key: key_at("/chat/channel/general/roc-chat-2") })
		== "Apoorva posted to general > roc-chat-2."

## The id of a topic's third message.
third : Message.Id
third = {
	second = Message.Id.first.next() ?? crash "MessageNoticeSpec: the first id has a next"
	second.next() ?? crash "MessageNoticeSpec: the second id has a next"
}

# The event: `message-notice`, a link to the message itself, its anchor on
# its topic's page, in a DM and in a channel; its words escaped; no event
# id, so a browser's count of messages is untouched.
expect
	MessageNotice.frame({ author: "Steve", key: key_at("/chat/dm/1_2/plans"), id: third })
		== "event: message-notice\ndata: <a href=\"/chat/dm/1_2/plans#msg-3\">Steve sent you a message on plans.</a>\n\n".to_utf8()
expect
	MessageNotice.frame({ author: "Apoorva", key: key_at("/chat/channel/general/roc-chat-2"), id: Message.Id.first })
		== "event: message-notice\ndata: <a href=\"/chat/channel/general/roc-chat-2#msg-1\">Apoorva posted to general &gt; roc-chat-2.</a>\n\n".to_utf8()
expect
	Str.from_utf8_lossy(MessageNotice.frame({ author: "A<b>", key: key_at("/chat/dm/1_2/plans"), id: third }))
		.contains(">A&lt;b&gt; sent you a message on plans.</a>")
# Who is told: every reader but the author. A DM's other human; a channel's
# other members, an agent among them, as topic-added tells them; the author
# never; and nobody of a message in one's own DM.
expect told_at("/chat/dm/1_2/plans", UserId.chat_owner) == ["2"]
expect told_at("/chat/channel/general/plans", UserId.chat_owner) == ["2", "3"]
expect told_at("/chat/dm/1_1/plans", UserId.chat_owner) == []
