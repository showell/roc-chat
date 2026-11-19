## These are the tests of `Presence`: who is online, when a human comes
## online, which requests count, and what the other humans are sent.
import ConversationKey
import Presence
import Sample
import Seconds
import Timestamp
import Topic
import UnvalidatedString
import UserId

PresenceSpec :: [].{}

## The moment the tests call now.
now : Timestamp
now = Timestamp.at_second(1_800_000_000)

## Seen `ago` seconds before now.
seen_ago : I64 -> Presence.LastSeen
seen_ago = |ago| SeenAt(Timestamp.at_second(1_800_000_000 - ago))

# Online for five minutes after a request, and not at five minutes or after;
# never seen, never online.
expect Presence.online_window == Seconds.of(300)
expect Presence.is_online({ last_seen: seen_ago(0), now })
expect Presence.is_online({ last_seen: seen_ago(299), now })
expect !Presence.is_online({ last_seen: seen_ago(300), now })
expect !Presence.is_online({ last_seen: seen_ago(3600), now })
expect !Presence.is_online({ last_seen: NeverSeen, now })

# A human comes online on their first request, and on one after five minutes
# of quiet or more; not on one within the five minutes, so a reload doesn't
# tell anyone again.
expect Presence.comes_online({ last_seen: NeverSeen, now })
expect Presence.comes_online({ last_seen: seen_ago(300), now })
expect Presence.comes_online({ last_seen: seen_ago(86_400), now })
expect !Presence.comes_online({ last_seen: seen_ago(299), now })
expect !Presence.comes_online({ last_seen: seen_ago(0), now })

## The conversation at `path`, in the sample's directory.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "PresenceSpec: a path is UTF-8",
	directory: Sample.directory,
}).map_ok(|found| found.key) ?? crash "PresenceSpec: a conversation's path"

# Every request but a stream is activity, a page and a post alike.
expect {
	key = key_at("/chat/dm/1_2/plans")
	[
		ShowConversation(key),
		AppendToConversation(key),
		SendToConversation(key),
		ReactInConversation(key),
		ShowBrowse,
		ShowAgents,
	].all(Presence.counts_as_activity)
		and !Presence.counts_as_activity(OpenConversationStream(key))
		and !Presence.counts_as_activity(OpenAgentStream)
}

# The keys: the one the host remembers a human under, and the one a viewer's
# own frames go on, beside no conversation's (a conversation's is its path,
# under /chat).
expect Presence.last_seen_key(UserId.chat_owner) == "last-seen/1".to_utf8()
expect Presence.viewer_stream_key(UserId.chat_owner) == "/viewers/1".to_utf8()

# The frames: the dot's, naming the human by id; the notice's, Gopher Chat's
# words, a link to the recipient's DM with them, the name escaped.
expect Presence.online_frame(Sample.user("Apoorva").id()) == "event: online\ndata: 2\n\n".to_utf8()
expect Presence.notice_words("Apoorva") == "Apoorva has come online."
expect
	Presence.notice_frame({ name: "Apoorva", link: Presence.link_to(key_at("/chat/dm/1_2/ChitChat")) })
		== "event: notice\ndata: <a href=\"/chat/dm/1_2/ChitChat\">Apoorva has come online.</a>\n\n".to_utf8()
expect
	Str.from_utf8_lossy(Presence.notice_frame({ name: "<b>", link: Presence.link_to(key_at("/chat/dm/1_2/plans")) }))
		.contains(">&lt;b&gt; has come online.</a>")

# A notice links to the DM's first topic, or to `general` when it has none.
expect {
	topic = |text| Topic.from_str(text) ?? crash "PresenceSpec: a topic"
	Presence.notice_topic([topic("ChitChat"), topic("plans")]) == topic("ChitChat")
		and Presence.notice_topic([]) == topic("general")
}
