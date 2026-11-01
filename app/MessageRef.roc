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
##
## **A CONVERSATION'S MESSAGE** (`Where`'s `InConversation`) is written
## `MSG_<conversation>_<n>` (`MSG_4_3`): the conversation's id and the
## message's, the old app's `MSG_<sid>_<n>` with the conversation as its
## unit, so it names its conversation, as a channel's reference names its
## channel. Its page's id is `<conversation>_<n>`. It holds no `.`, so it
## is never a channel's reference; it reads like a DM's short one only for
## a DM topic named all in digits, and each is read only on its own page
## (`number_in`), so no page reads one two ways. Pure.
import ChannelName
import ConvAccess
import Topic
import TopicName

MessageRef :: { at : Topic.At, n : U64 }.{

	## **WHERE A MESSAGE IS**: a channel's or a DM's topic, or a
	## conversation.
	Where : [InTopic(Topic.At), InConversation(ConvAccess.ConvId)]

	## **A MESSAGE'S REFERENCE, AS IT TRAVELS** (what a quote-reply and an
	## edit write): a channel's full `MSG_<channel>.<topic>_<n>`, a DM's
	## short `MSG_<topic>_<n>` ("this topic, on this page"), a
	## conversation's `MSG_<conversation>_<n>`.
	spelled : MessageRef.Where, U64 -> Str
	spelled = |place, n|
		match place {
			InTopic(at) => {
				ref = MessageRef.({ at, n })
				if (at.channel.is_dm()) "MSG_${ref.local_id()}" else ref.to_str()
			}
			InConversation(_) => "MSG_${MessageRef.local(place, n)}"
		}

	## **A MESSAGE'S ID ON ITS PAGE**: `<topic>_<n>`, or a conversation's
	## `<conversation>_<n>`, as the page's notices say it.
	local : MessageRef.Where, U64 -> Str
	local = |place, n|
		match place {
			InTopic(at) => MessageRef.({ at, n }).local_id()
			InConversation(c) => "${c.to_u64().to_str()}_${n.to_str()}"
		}

	## **THE NUMBER OF THE MESSAGE OF `place` THAT `text` REFERS TO**, read
	## on `place`'s own page: a topic's full reference or its short one, a
	## conversation's own; anything else, another topic's or another
	## conversation's included, is no reference here.
	number_in : MessageRef.Where, Str -> Try(U64, [NotAReference])
	number_in = |place, text| {
		bytes = text.to_utf8()
		if !bytes.starts_with(prefix) {
			Err(NotAReference)
		} else {
			rest = bytes.drop_first(prefix.len())
			match place {
				InTopic(at) => topic_number(at, text)
				InConversation(c) =>
					match List.split_first(rest, '_') {
						Err(NotFound) => Err(NotAReference)
						Ok({ before, after }) =>
							if number_of(before) == Ok(c.to_u64()) {
								number_of(after)
							} else {
								Err(NotAReference)
							}
					}
			}
		}
	}

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

## A topic's reference in `text` (which starts `MSG_`): its full one, or
## its short one read in `at`; the number of a message of `at`'s.
topic_number : Topic.At, Str -> Try(U64, [NotAReference])
topic_number = |at, text| {
	short = Str.from_utf8(text.to_utf8().drop_first(prefix.len())) ?? ""
	ref =
		match MessageRef.from_str(text) {
			Ok(r) => Ok(r)
			Err(NotAReference) => MessageRef.in_topic(at, short)
		}
	match ref {
		Ok(r) if r.at() == at => Ok(r.n())
		_ => Err(NotAReference)
	}
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

# The page's own id, and place a reader goes.
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

## Conversation `n`, in a test.
conv : U64 -> ConvAccess.ConvId
conv = |n| ConvAccess.ConvId.from_u64(n) ?? crash "conv: a test's id is not 0"

dm_at : Topic.At
dm_at = { channel: ChannelName.dm_of(1, 2), topic: at_of("Cobblestone", "ChitChat").topic }

# Spelled as each kind travels: a channel's full, a DM's short, a
# conversation's by its id.
expect MessageRef.spelled(InTopic(at_of("Cobblestone", "ChitChat")), 5) == "MSG_Cobblestone.ChitChat_5"
expect MessageRef.spelled(InTopic(dm_at), 5) == "MSG_ChitChat_5"
expect MessageRef.spelled(InConversation(conv(4)), 3) == "MSG_4_3"
expect MessageRef.local(InTopic(at_of("Cobblestone", "ChitChat")), 5) == "ChitChat_5"
expect MessageRef.local(InConversation(conv(4)), 3) == "4_3"
# Read on its own page: a conversation's own reference, and no other.
expect MessageRef.number_in(InConversation(conv(4)), "MSG_4_3") == Ok(3)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_44_3") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_5_3") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_3") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_4_03") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_04_3") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_4_3_1") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "4_3") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_ChitChat_3") == Err(NotAReference)
expect MessageRef.number_in(InConversation(conv(4)), "MSG_a.ChitChat_3") == Err(NotAReference)
# A topic's page reads its full and its short reference, never a
# conversation's, nor another topic's.
expect MessageRef.number_in(InTopic(at_of("Cobblestone", "ChitChat")), "MSG_Cobblestone.ChitChat_5") == Ok(5)
expect MessageRef.number_in(InTopic(at_of("Cobblestone", "ChitChat")), "MSG_ChitChat_5") == Ok(5)
expect MessageRef.number_in(InTopic(at_of("Cobblestone", "ChitChat")), "MSG_general.ChitChat_5") == Err(NotAReference)
expect MessageRef.number_in(InTopic(at_of("Cobblestone", "ChitChat")), "MSG_4_3") == Err(NotAReference)
expect MessageRef.number_in(InTopic(at_of("Cobblestone", "ChitChat")), "ChitChat_5") == Err(NotAReference)
