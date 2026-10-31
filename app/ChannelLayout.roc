## **WHERE A CHANNEL'S FILES ARE** (the store's layout for channels, pure:
## Store.roc will name these paths and no others). Each channel is a
## folder, named by its name's key (ChannelName.key, lowercase), and each
## of its topics a folder inside it, named by its name's key:
##
##     chat/channels/<channel>/channel                       its name and members
##     chat/channels/<channel>/topics/<topic>/topic          its name and kind
##     chat/channels/<channel>/topics/<topic>/transcript     its messages
##     chat/channels/<channel>/topics/<topic>/offsets        where each starts
##     chat/channels/<channel>/topics/<topic>/tally          their count, bytes
##
## **ONE PLACE, ONE PATH**: names `==` (caselessly) give the same path, and
## different places different paths, so two channels' `ChitChat`s never
## share a file, and no two spellings of one topic make two (on a disk that
## folds case, or one that does not). A name holds no `/` or `.`, by its
## rule, so no path climbs out of its folder.
import ChannelName
import Topic
import TopicName

ChannelLayout := [].{

	## The folder of every channel.
	channels_path : List(U8)
	channels_path = "chat/channels".to_utf8()

	## A channel's own record: its name, as made, and its members.
	channel_path : ChannelName -> List(U8)
	channel_path = |name| "${folder(name)}/channel".to_utf8()

	## The folder of a channel's topics.
	topics_path : ChannelName -> List(U8)
	topics_path = |name| "${folder(name)}/topics".to_utf8()

	## A topic's own record: its name, as made, and its kind.
	topic_path : Topic.At -> List(U8)
	topic_path = |at| "${topic_folder(at)}/topic".to_utf8()

	## A topic's transcript.
	transcript_path : Topic.At -> List(U8)
	transcript_path = |at| "${topic_folder(at)}/transcript".to_utf8()

	## Where each of a topic's messages starts in its transcript.
	offsets_path : Topic.At -> List(U8)
	offsets_path = |at| "${topic_folder(at)}/offsets".to_utf8()

	## A topic's count of messages and bytes.
	tally_path : Topic.At -> List(U8)
	tally_path = |at| "${topic_folder(at)}/tally".to_utf8()
}

## A channel's folder.
folder : ChannelName -> Str
folder = |name| "chat/channels/${name.key()}"

## A topic's folder, in its channel's.
topic_folder : Topic.At -> Str
topic_folder = |at| "${folder(at.channel)}/topics/${at.topic.key()}"

# ── tests
## Where `channel`'s topic `name` is.
at_of : Str, Str -> Topic.At
at_of = |channel, name|
	match (ChannelName.from_str(channel), TopicName.from_str(name)) {
		(Ok(c), Ok(t)) => { channel: c, topic: t }
		_ => crash "at_of: a test's names are names"
	}

## Every path of the topic at `at`.
paths : Topic.At -> List(List(U8))
paths = |at| [
	ChannelLayout.channel_path(at.channel),
	ChannelLayout.topics_path(at.channel),
	ChannelLayout.topic_path(at),
	ChannelLayout.transcript_path(at),
	ChannelLayout.offsets_path(at),
	ChannelLayout.tally_path(at),
]

expect ChannelLayout.channel_path(
	at_of(
		"Cobblestone",
		"x",
	).channel,
) == "chat/channels/cobblestone/channel".to_utf8()
expect ChannelLayout.transcript_path(
	at_of(
		"Cobblestone",
		"ChitChat",
	),
) == "chat/channels/cobblestone/topics/chitchat/transcript".to_utf8()
expect ChannelLayout.topic_path(
	at_of(
		"Cobblestone",
		"ChitChat",
	),
) == "chat/channels/cobblestone/topics/chitchat/topic".to_utf8()
expect ChannelLayout.offsets_path(
	at_of(
		"Cobblestone",
		"ChitChat",
	),
) == "chat/channels/cobblestone/topics/chitchat/offsets".to_utf8()
expect ChannelLayout.tally_path(
	at_of(
		"Cobblestone",
		"ChitChat",
	),
) == "chat/channels/cobblestone/topics/chitchat/tally".to_utf8()
expect ChannelLayout.topics_path(
	at_of(
		"Cobblestone",
		"x",
	).channel,
) == "chat/channels/cobblestone/topics".to_utf8()
# One place, one path: any spelling of it.
expect paths(at_of("COBBLESTONE", "chitchat")) == paths(at_of("Cobblestone", "ChitChat"))
# Two channels' ChitChats: no path shared.
expect paths(
	at_of(
		"Cobblestone",
		"ChitChat",
	),
).drop_first(2).all(|p| !paths(at_of("general", "ChitChat")).contains(p))
expect ChannelLayout.transcript_path(
	at_of(
		"Cobblestone",
		"ChitChat",
	),
) != ChannelLayout.transcript_path(at_of("general", "ChitChat"))
# Two topics of one channel: their own files, the channel's shared.
expect ChannelLayout.transcript_path(
	at_of(
		"Cobblestone",
		"ChitChat",
	),
) != ChannelLayout.transcript_path(at_of("Cobblestone", "Plans"))
expect ChannelLayout.channel_path(
	at_of(
		"Cobblestone",
		"ChitChat",
	).channel,
) == ChannelLayout.channel_path(at_of("Cobblestone", "Plans").channel)
# Every path is under the channels' folder.
expect paths(at_of("a-1-", "road-trip-2")).all(|p| p.starts_with("chat/channels/".to_utf8()))
