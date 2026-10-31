## **A REFERENCE TO A MESSAGE, NAMING ITS CHANNEL AND ITS TOPIC** (Steve's
## decision of 2026-10-31: "no URL or message reference is ambiguous"):
## the message's topic (Topic.At, both names) and its number in that
## topic, from 1. Written `MSG_<channel>.<topic>_<n>`
## (`MSG_Cobblestone.ChitChat_5`): neither name can hold a `.` or a `_`,
## so the text splits one way only, and a reference is found by both names
## at once, never by "the first topic of that name".
##
## **WITHIN A TOPIC'S OWN PAGE** the client's id stays `<topic>_<n>`
## (`local_id`), its anchor `#msg-<topic>_<n>`, as the client and its
## contract want; `in_topic` reads one back only in the topic the page is,
## so a page never lends its id to another channel's topic of that name.
## Pure.
import ChannelName
import Topic
import TopicName

MessageRef :: { at : Topic.At, n : U64 }.{

	## The reference `text` spells, `MSG_<channel>.<topic>_<n>`: both names
	## by their rules, and `n` a decimal from 1, without a leading zero, of
	## at most 19 digits.
	from_str : Str -> Try(MessageRef, [NotAReference])
	from_str = |text| {
		bytes = text.to_utf8()
		if !bytes.starts_with(prefix) {
			Err(NotAReference)
		} else {
			rest = bytes.drop_first(prefix.len())
			match List.split_first(rest, '.') {
				Err(NotFound) => Err(NotAReference)
				Ok({ before, after }) => {
					channel = ChannelName.from_str(name_of(before)?).map_err(|_| NotAReference)?
					local_of(channel, after)
				}
			}
		}
	}

	## The reference as it is written in a message.
	to_str : MessageRef -> Str
	to_str = |MessageRef.(r)| "MSG_${r.at.channel.to_str()}.${r.at.topic.to_str()}_${r.n.to_str()}"

	## **THE MESSAGE'S ID IN ITS TOPIC'S OWN PAGE**: `<topic>_<n>`.
	local_id : MessageRef -> Str
	local_id = |MessageRef.(r)| "${r.at.topic.to_str()}_${r.n.to_str()}"

	## **A PAGE'S LOCAL ID, READ IN THE PAGE'S OWN TOPIC**: `<topic>_<n>`,
	## its topic `page`'s (in any case), or no reference.
	in_topic : Topic.At, Str -> Try(MessageRef, [NotAReference])
	in_topic = |page, id| {
		ref = local_of(page.channel, id.to_utf8())?
		if (ref.at() == page) Ok(ref) else Err(NotAReference)
	}

	## **WHERE A READER GOES**: the topic's page, at the message's anchor.
	href : MessageRef -> Str
	href = |MessageRef.(r)| "/channel/${r.at.channel.to_str()}/${r.at.topic.to_str()}#msg-${r.at.topic.to_str()}_${r.n.to_str()}"

	## The message's topic.
	at : MessageRef -> Topic.At
	at = |MessageRef.(r)| r.at

	## Its number in the topic, from 1.
	n : MessageRef -> U64
	n = |MessageRef.(r)| r.n

	is_eq : _
}

## The written form's head.
prefix : List(U8)
prefix = "MSG_".to_utf8()

## `<topic>_<n>`, in `channel`.
local_of : ChannelName, List(U8) -> Try(MessageRef, [NotAReference])
local_of = |channel, bytes|
	match List.split_last(bytes, '_') {
		Err(NotFound) => Err(NotAReference)
		Ok({ before, after }) => {
			topic = TopicName.from_str(name_of(before)?).map_err(|_| NotAReference)?
			number = number_of(after)?
			Ok(MessageRef.({ at: { channel, topic }, n: number }))
		}
	}

## The bytes as text, for a name's rule to judge.
name_of : List(U8) -> Try(Str, [NotAReference])
name_of = |bytes| Str.from_utf8(bytes).map_err(|_| NotAReference)

## A message's number: digits, from 1, no leading zero, at most 19 (so it
## fits a U64).
number_of : List(U8) -> Try(U64, [NotAReference])
number_of = |digits|
	match digits {
		[] | ['0', ..] => Err(NotAReference)
		_ =>
			if digits.len() > 19 {
				Err(NotAReference)
			} else {
				digits.fold_try(
					0,
					|sum, c| if (c >= '0' and c <= '9') Ok(sum * 10 + (c - '0').to_u64()) else Err(NotAReference),
				)
			}
	}

# ── tests
## Where `channel`'s topic `name` is.
at_of : Str, Str -> Topic.At
at_of = |channel, name|
	match (ChannelName.from_str(channel), TopicName.from_str(name)) {
		(Ok(c), Ok(t)) => { channel: c, topic: t }
		_ => crash "at_of: a test's names are names"
	}

## The reference `text` is, in a test where it is one.
ref : Str -> MessageRef
ref = |text|
	match MessageRef.from_str(text) {
		Ok(r) => r
		Err(NotAReference) => crash "ref: a test's reference is one"
	}

# Read: both names, then the number.
expect ref("MSG_Cobblestone.ChitChat_5").at() == at_of("Cobblestone", "ChitChat")
expect ref("MSG_Cobblestone.ChitChat_5").n() == 5
expect ref("MSG_a-1-.road-trip-2_12").at() == at_of("a-1-", "road-trip-2")
expect ref("MSG_x.y_9999999999999999999").n() == 9999999999999999999
# Written back as read; each spelling kept, both names caseless.
expect ref("MSG_Cobblestone.ChitChat_5").to_str() == "MSG_Cobblestone.ChitChat_5"
expect ref("MSG_cobblestone.CHITCHAT_5") == ref("MSG_Cobblestone.ChitChat_5")
expect ref("MSG_cobblestone.chitchat_5") != ref("MSG_cobblestone.chitchat_6")
# Two channels' ChitChats: two references.
expect ref("MSG_Cobblestone.ChitChat_5") != ref("MSG_general.ChitChat_5")
# Not one.
expect MessageRef.from_str("Cobblestone.ChitChat_5") == Err(NotAReference)
expect MessageRef.from_str("MSG_ChitChat_5") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone.ChitChat") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone.ChitChat_") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone.ChitChat_0") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone.ChitChat_05") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone.ChitChat_5x") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone.ChitChat_+5") == Err(NotAReference)
expect MessageRef.from_str("MSG_x.y_10000000000000000000") == Err(NotAReference)
expect MessageRef.from_str("MSG_.ChitChat_5") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone._5") == Err(NotAReference)
expect MessageRef.from_str("MSG_1st.ChitChat_5") == Err(NotAReference)
expect MessageRef.from_str("MSG_Cobblestone.Chit--Chat_5") == Err(NotAReference)
expect MessageRef.from_str("MSG_a.b.c_5") == Err(NotAReference)
expect MessageRef.from_str("MSG_a.b_c_5") == Err(NotAReference)
expect MessageRef.from_str("MSG_caf\u(e9).b_5") == Err(NotAReference)

# The page's own id, and where a reader goes.
expect ref("MSG_Cobblestone.ChitChat_5").local_id() == "ChitChat_5"
expect ref("MSG_Cobblestone.ChitChat_5").href() == "/channel/Cobblestone/ChitChat#msg-ChitChat_5"
# A local id, read in its own page's topic only.
expect MessageRef.in_topic(
	at_of("Cobblestone", "ChitChat"),
	"ChitChat_5",
) == Ok(ref("MSG_Cobblestone.ChitChat_5"))
expect MessageRef.in_topic(
	at_of("Cobblestone", "ChitChat"),
	"chitchat_5",
) == Ok(ref("MSG_Cobblestone.ChitChat_5"))
expect MessageRef.in_topic(
	at_of("general", "ChitChat"),
	"ChitChat_5",
) == Ok(ref("MSG_general.ChitChat_5"))
expect MessageRef.in_topic(at_of("Cobblestone", "ChitChat"), "Plans_5") == Err(NotAReference)
expect MessageRef.in_topic(at_of("Cobblestone", "ChitChat"), "ChitChat_0") == Err(NotAReference)
expect MessageRef.in_topic(
	at_of("Cobblestone", "ChitChat"),
	"MSG_Cobblestone.ChitChat_5",
) == Err(NotAReference)
