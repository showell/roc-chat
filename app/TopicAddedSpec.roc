## These are the tests of `TopicAdded`: the event that tells a sidebar of a
## new topic, and who of a place is told.
import Access
import Channels
import ConversationKey
import Directory
import Sample
import TopicAdded
import UnvalidatedString
import UserId

TopicAddedSpec :: [].{}

## The sample's users, with the default channel holding all three: Steve
## and Apoorva, humans, and CC, an agent.
directory : Directory
directory = {
	channels =
		Channels.from_stored([{ name: Channels.default_name, members: "1\n2\n3\n".to_utf8() }])
			?? crash "TopicAddedSpec.directory: a members file"
	Directory.from_stored({ users: Sample.directory.users(), channels })
		?? crash "TopicAddedSpec.directory: its members are users"
}

## The conversation at `path`, in `directory`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "TopicAddedSpec: a path is UTF-8",
	directory,
}).map_ok(|found| found.key) ?? crash "TopicAddedSpec: a conversation's path"

# Gopher's three fields, a line each: the place, the topic and its page; no
# id, so a browser's count of messages is untouched.
expect
	TopicAdded.frame(key_at("/chat/dm/1_2/plans"))
		== "event: topic-added\ndata: /chat/dm/1_2\ndata: plans\ndata: /chat/dm/1_2/plans\n\n".to_utf8()
expect
	TopicAdded.frame(key_at("/chat/channel/general/roc-chat-2"))
		== "event: topic-added\ndata: /chat/channel/general\ndata: roc-chat-2\ndata: /chat/channel/general/roc-chat-2\n\n".to_utf8()

# Who is told, the post's readers: everyone who may read the place, as
# Gopher Chat told every member: a DM's two humans; a channel's members, an
# agent among them, though no agent has a sidebar.
expect
	Access.members({ place: key_at("/chat/dm/1_2/plans").place(), directory }).map(UserId.to_str)
		== ["1", "2"]
expect
	Access.members({ place: key_at("/chat/channel/general/plans").place(), directory }).map(UserId.to_str)
		== ["1", "2", "3"]
