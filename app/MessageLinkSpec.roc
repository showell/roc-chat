## These are the tests of where a link to a message, `/chat/msg/<id>`, goes,
## as Gopher Chat's did (`MessageLinkPlaces`): the places a topic's link may
## mean for each reader, and the one it goes to of those found, or none.
## `MessageLink` holds the reading's own tests, `MessageLinkRoute` its
## answers', `RouteSpec` the route's, and `DeviceSessionsSpec` a device's
## session's.
import ChannelName
import Channels
import ConversationKey
import Directory
import MessageLink
import MessageLinkPlaces
import Sample
import Script
import SignedIn
import UnvalidatedString

MessageLinkSpec :: [].{}

## The sample directory's users, with two channels: `general`, holding
## Steve and his agent CC, and `plans-room`, holding Apoorva.
directory : Directory
directory = {
	channels =
		Channels.from_stored([
			{ name: Channels.default_name, members: "1\n3\n".to_utf8() },
			{
				name: ChannelName.from_str("plans-room") ?? crash "MessageLinkSpec: a channel's name",
				members: "2\n".to_utf8(),
			},
		]) ?? crash "MessageLinkSpec: two members files"
	Directory.from_stored({ users: Sample.directory.users(), channels })
		?? crash "MessageLinkSpec: the channels' members are users"
}

## The conversation at `path` in `directory`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "MessageLinkSpec: a path is UTF-8",
	directory,
}).map_ok(|found| found.key) ?? crash "MessageLinkSpec: a conversation's path"

## The places a topic's link may mean for the user named `name`, by their
## own session, by their URLs.
meant_for : Str -> List(Str)
meant_for = |name|
	MessageLinkPlaces.readable_places({
		acting: SignedIn.dangerously_assume(Sample.user(name)),
		directory,
	}).map(ConversationKey.place_url_path)

# A topic's link may mean each place the reader may read: their DMs, their
# own among them (Steve, 2026-11-20: yes, as Recent and search), then their
# channels; never another human's own DM, and never a channel they are not
# in.
expect meant_for("Steve") == ["/chat/dm/1_1", "/chat/dm/1_2", "/chat/channel/general"]
expect meant_for("Apoorva") == ["/chat/dm/1_2", "/chat/dm/2_2", "/chat/channel/plans-room"]
# An agent is in no DM: its channels alone.
expect meant_for("CC") == ["/chat/channel/general"]

# Of the conversations found with the link's topic: the one, none, or no
# guess between two.
expect
	MessageLinkPlaces.destination([key_at("/chat/dm/1_2/plans")])
		== GoesTo(key_at("/chat/dm/1_2/plans"))
expect MessageLinkPlaces.destination([]) == Nowhere
expect
	MessageLinkPlaces.destination([key_at("/chat/dm/1_2/plans"), key_at("/chat/channel/general/plans")])
		== Ambiguous
# The reader's own DM counts as any place: its `plans` beside their DM's is
# two, no guess.
expect
	MessageLinkPlaces.destination([key_at("/chat/dm/1_1/plans"), key_at("/chat/dm/1_2/plans")])
		== Ambiguous

# A link's path is the route's: a topic's and a channel's, written back.
expect
	["plans_1", "general.plans_1"].all(
		|text|
			MessageLink.from_str(text).map_ok(MessageLink.url_path)
				== Ok("${MessageLink.path_prefix}${text}"),
	)

# app/actions.js opens the links the route serves.
expect Str.from_utf8_lossy(Script.Actions.bytes()).contains("'${MessageLink.path_prefix}'")
