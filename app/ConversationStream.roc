## A conversation's stream: each message added after a page was drawn,
## written as that page writes it (`ConversationPage.message`), so the page
## and the stream can't disagree. The host holds the stream open on its bus key,
## the conversation's URL path, and knows nothing of conversations.
##
## A frame is one event, its id the message's number and its data the
## message's HTML. A page asks for the messages after the count it shows
## (`?after=<count>`), and a browser that reconnects says the last id it
## saw (`Last-Event-ID`), which wins.
##
## A message whose notes change (`MessageNotes`: an edit of it, a reaction
## to it) is sent again, as a `replace` event with no id, so the count a
## reader has seen stays the count of messages: its data is the message's
## HTML drawn anew, which the page puts in place of the one it shows. A
## stream's backlog sends, before the messages after the reader's count,
## each message up to the count whose notes are not a fresh message's, as
## they are now, so a reader that reconnects misses no edit or reaction.
import pf.Host
import pf.Http
import Ascii
import Author
import Conversation
import ConversationKey
import ConversationPage
import DateTime
import Directory
import HttpAnswer
import Message
import MessageNotes
import Name
import PageKit
import Reactions
import RequestHeader
import SignedIn
import Topic
import TrustedHtml
import UnvalidatedString
import UserId
import Users

ConversationStream :: [].{

	## How many messages the reader has seen: the request's `Last-Event-ID`
	## when it is sent, else its query's `after`; or why neither names a
	## count.
	request_seen_count : {
		query : List(U8),
		headers : List(Http.Header),
	} -> Try(U16, [NoCount, BadCount])
	request_seen_count = |{ query, headers }|
		match RequestHeader.header_value(headers, "last-event-id") {
			Sent(id) => count_of(id)
			Repeated => Err(BadCount)
			Unsent =>
				if query.is_empty() {
					Err(NoCount)
				} else if query.starts_with(after_prefix) {
					count_of(query.drop_first(after_prefix.len()))
				} else {
					Err(BadCount)
				}
		}

	## Why a stream names no count, in words.
	count_refusal_words : [NoCount, BadCount] -> Str
	count_refusal_words = |why|
		match why {
			NoCount =>
				"The stream names no count of the messages seen: `?after=<count>`, or a Last-Event-ID."
			BadCount =>
				"The stream's count of the messages seen is not one: the digits of 0 to 65535, with no leading 0."
		}

	## The stream of `key`'s conversation for `acting`, `conversation` and
	## its `reactions` as they are now: each message the reader has seen
	## whose notes are not fresh, again, then the messages after the
	## reader's `seen_count`, then each one added; a 400 when `seen_count`
	## is more than it holds. Each message's author is found among `users`,
	## as the page finds them.
	response : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
		conversation : Conversation,
		reactions : Reactions,
		seen_count : U16,
	} -> Http.Response
	response = |
		{
			key,
			acting,
			users,
			conversation,
			reactions,
			seen_count,
		},
	| {
		held = conversation.messages().len()
		if seen_count.to_u64() > held {
			HttpAnswer.page(
				400,
				PageKit.notice({
					title: "Bad stream",
					text: "The stream asks for the messages after ${seen_count.to_str()}, and the conversation holds ${held.to_str()}.",
				}),
			)
		} else {
			drawn =
				List.map2(
					conversation.messages(),
					MessageNotes.notes_of_messages({ conversation, reactions }),
					|message, notes| {
						message,
						html: ConversationPage.message({
							conversation,
							key,
							users,
							message,
							notes,
						}),
						notes,
					},
				)
			seen = drawn.take_first(seen_count.to_u64())
			HttpAnswer.stream({
				key: bus_key(key),
				holder: ConversationStream.holder(acting.user().id()),
				backlog: List.concat(
					seen.keep_if(|one| !one.notes.is_fresh()).join_map(
						|one| replacement_frame(one.html),
					),
					drawn.drop_first(seen_count.to_u64()).join_map(
						|one| ConversationStream.frame({ id: one.message.id(), html: one.html }),
					),
				),
			})
		}
	}

	## Sends a message just added to the conversation `key` to every page on
	## its stream: its id, and its `html` as `ConversationPage.message` writes
	## it.
	publish! : {
		key : ConversationKey,
		id : Message.Id,
		html : TrustedHtml,
	} => {}
	publish! = |{ key, id, html }|
		Host.publish_bytes_to_streams_on_key!(bus_key(key), ConversationStream.frame({ id, html }))

	## Sends the message `id` of `conversation` again to every page on its
	## stream, drawn with its notes as they are now, `reactions` among them,
	## as a `replace` event: after an edit of it, or a reaction to it.
	publish_again! : {
		key : ConversationKey,
		conversation : Conversation,
		reactions : Reactions,
		users : Users,
		id : Message.Id,
	} => {}
	publish_again! = |{ key, conversation, reactions, users, id }|
		match message_drawn_again({ key, conversation, reactions, users, id }) {
			Ok(html) => Host.publish_bytes_to_streams_on_key!(bus_key(key), replacement_frame(html))
			Err(NoSuchMessage) =>
				crash "ConversationStream.publish_again!: the caller names a message the conversation holds"
		}

	## Who holds a conversation's stream that `user` opened, as the host
	## counts streams: the user's id.
	holder : UserId -> List(U8)
	holder = |user| user.to_str().to_utf8()

	## One message as one event: `id:` its number, then its `html`, a
	## `data:` line a line, then the blank line that ends it.
	frame : { id : Message.Id, html : TrustedHtml } -> List(U8)
	frame = |{ id, html }|
		List.concat("id: ${id.to_str()}\n".to_utf8(), data_lines(html)).append('\n')
}

after_prefix : List(U8)
after_prefix = "after=".to_utf8()

## The message `id` of `conversation` drawn with its notes as they are now,
## or `NoSuchMessage`.
message_drawn_again : {
	key : ConversationKey,
	conversation : Conversation,
	reactions : Reactions,
	users : Users,
	id : Message.Id,
} -> Try(TrustedHtml, [NoSuchMessage])
message_drawn_again = |{ key, conversation, reactions, users, id }| {
	at = id.to_u64() - 1
	match (
		conversation.messages().get(at),
		MessageNotes.notes_of_messages({ conversation, reactions }).get(at),
	) {
		(Ok(message), Ok(notes)) => Ok(
			ConversationPage.message({ conversation, key, users, message, notes }),
		)
		_ => Err(NoSuchMessage)
	}
}

## A message drawn anew, as one `replace` event: no id, so a reader's
## count of messages seen stays as it was, then its `html`, a `data:` line a
## line, and the blank line that ends it.
replacement_frame : TrustedHtml -> List(U8)
replacement_frame = |html|
	List.concat("event: replace\n".to_utf8(), data_lines(html)).append('\n')

## The `html` as an event's data: a `data:` line a line.
data_lines : TrustedHtml -> List(U8)
data_lines = |html|
	line_feeds_only(html.to_utf8()).split_on('\n').join_map(
		|line| List.concat("data: ".to_utf8(), line).append('\n'),
	)

## The stream's bus key: the conversation's URL path.
bus_key : ConversationKey -> List(U8)
bus_key = |key| key.url_path(Page).to_utf8()

## The count `bytes` spell: the digits of 0 to 65535, with no leading
## `0`, so a count has one spelling.
count_of : List(U8) -> Try(U16, [BadCount])
count_of = |bytes|
	match bytes {
		[] => Err(BadCount)
		['0'] => Ok(0)
		['0', ..] => Err(BadCount)
		_ if bytes.len() > 5 or !bytes.all(Ascii.is_digit) => Err(BadCount)
		_ => {
			number = bytes.fold(0, |so_far, b| so_far * 10 + (b - '0').to_u64())
			if number > U16.highest.to_u64() {
				Err(BadCount)
			} else {
				Ok(number.to_u16_wrap())
			}
		}
	}

## The bytes with each CR LF and each lone CR made an LF: an event's data
## can't hold a CR, and an HTML parser reads both as an LF, so the page shows the same.
line_feeds_only : List(U8) -> List(U8)
line_feeds_only = |bytes|
	bytes.fold(
		{ written: [], previous: 0 },
		|so_far, byte|
			if byte == '\r' {
				{ written: so_far.written.append('\n'), previous: byte }
			} else if byte == '\n' and so_far.previous == '\r' {
				{ ..so_far, previous: byte }
			} else {
				{ written: so_far.written.append(byte), previous: byte }
			},
	).written

# ── tests
# A count: one spelling each, at and past each edge.
expect count_of("0".to_utf8()) == Ok(0)
expect count_of("6".to_utf8()) == Ok(6)
expect count_of("65535".to_utf8()) == Ok(65535)
expect
	[
		"",
		"00",
		"06",
		"65536",
		"100000",
		"-1",
		"6 ",
		"x",
	].all(|text| count_of(text.to_utf8()) == Err(BadCount))
# A CR LF and a lone CR each one LF; an LF alone kept.
expect line_feeds_only("a\r\nb\rc\nd\r\r\n".to_utf8()) == "a\nb\nc\nd\n\n".to_utf8()
expect line_feeds_only("a\n\nb".to_utf8()) == "a\n\nb".to_utf8()
expect line_feeds_only([]) == []

## The count a request with `query` and `headers` (name, value) has seen.
seen_by : Str, List((Str, Str)) -> Try(U16, _)
seen_by = |query, headers|
	ConversationStream.request_seen_count({
		query: query.to_utf8(),
		headers: headers.map(|(name, value)| { name: name.to_utf8(), value: value.to_utf8() }),
	})

# The query's count, and the Last-Event-ID's, which wins; both sides.
expect seen_by("after=6", []) == Ok(6)
expect seen_by("after=0", []) == Ok(0)
expect seen_by("", []) == Err(NoCount)
expect seen_by("after=", []) == Err(BadCount)
expect seen_by("after=6&x=1", []) == Err(BadCount)
expect seen_by("before=6", []) == Err(BadCount)
expect seen_by("after=6", [("Last-Event-ID", "9")]) == Ok(9)
expect seen_by("", [("last-event-id", "9")]) == Ok(9)
expect seen_by("after=6", [("Last-Event-ID", "x")]) == Err(BadCount)
expect seen_by("after=6", [("Last-Event-ID", "9"), ("Last-Event-ID", "9")]) == Err(BadCount)
expect
	ConversationStream.count_refusal_words(NoCount)
		== "The stream names no count of the messages seen: `?after=<count>`, or a Last-Event-ID."
expect
	ConversationStream.count_refusal_words(BadCount)
		== "The stream's count of the messages seen is not one: the digits of 0 to 65535, with no leading 0."
expect ConversationStream.holder(UserId.chat_owner) == "1".to_utf8()

## The users of the tests' directory: Steve alone, id 1.
users : Users
users =
	Directory.with_founder(Name.from_str("Steve") ?? crash "ConversationStream's tests: a name")
		.users()

## Steve, the founder of the tests' directory, signed in as a test assumes him.
steve : SignedIn
steve =
	SignedIn.dangerously_assume(users.to_list().first() ?? crash "ConversationStream's tests: Steve is the first user")

## `plans` in Steve's own DM.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8())
		?? crash "ConversationStream's tests: a path is UTF-8",
	directory: Directory.with_founder(Name.from_str("Steve") ?? crash "ConversationStream's tests: a name"),
}).map_ok(|found| found.key) ?? crash "ConversationStream's tests: Steve's own DM is a place"

## `plans`, holding a message by Steve of each markdown, at one time.
plans_holding : List(Str) -> Conversation
plans_holding = |markdowns| plans_holding_by(steve.user().author(), markdowns)

## `plans`, holding a message by `author` of each markdown, at one time.
plans_holding_by : Author, List(Str) -> Conversation
plans_holding_by = |author, markdowns| {
	plans = Topic.from_str("plans") ?? crash "ConversationStream's tests: a topic"
	time = DateTime.from_str("2026-11-02T19:11:32Z") ?? crash "ConversationStream's tests: a time"
	markdowns.fold(
		Conversation.empty(plans),
		|so_far, markdown| (
			so_far.append({
				payload: { author, markdown },
				time,
			}) ?? crash "ConversationStream's tests: a message joins"
		).conversation,
	)
}

## The stream of `plans` holding "Hello" and "Hi!" for Steve, after
## `seen_count`.
streamed_after : U16 -> Http.Response
streamed_after = |seen_count|
	ConversationStream.response({
		key: plans_key,
		acting: steve,
		users,
		conversation: plans_holding(["Hello", "Hi!"]),
		reactions: Reactions.empty,
		seen_count,
	})

## Is `response` a 200 stream of `plans` for Steve, its backlog `backlog`?
is_plans_stream_with : Http.Response, Str -> Bool
is_plans_stream_with = |response, backlog|
	response.status == 200
		and response.kind == Stream
		and response.stream_key == "/chat/dm/1_1/plans".to_utf8()
		and response.stream_holder == "1".to_utf8()
		and response.body == backlog.to_utf8()

## The frame of the message `id` of `plans`, by Steve, user 1, its markdown
## the one paragraph `paragraph`, as frozen.
frozen_frame : { id : Str, paragraph : Str } -> Str
frozen_frame = |
	{ id, paragraph },
| "id: ${id}\ndata: <article class=\"message\" id=\"msg-${id}\" data-author=\"1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-${id}\">MSG_plans_${id}</a></header>\ndata: <div class=\"body\"><p>${paragraph}</p>\ndata: </div></article>\ndata: \n\n"

## The frame of `message` of `conversation`, in `plans_key`, its HTML as
## the page writes it.
message_frame : Conversation, Message -> List(U8)
message_frame = |conversation, message|
	ConversationStream.frame({
		id: message.id(),
		html: ConversationPage.message({
			conversation,
			key: plans_key,
			users,
			message,
			notes: MessageNotes.fresh,
		}),
	})

# A frame's data lines, joined by LF as a browser joins them, are exactly
# the page's HTML for the message, a list's lines and all.
expect {
	conversation = plans_holding(["Hello", "- one\n- two"])
	conversation.messages().all(
		|m| {
			framed = message_frame(conversation, m)
			data =
				Str.from_utf8_lossy(framed)
					.split_on("\n")
					.keep_if(|line| line.starts_with("data: "))
					.map(|line| line.drop_prefix("data: "))
			Str.join_with(data, "\n").to_utf8()
				== ConversationPage.message({
					conversation,
					key: plans_key,
					users,
					message: m,
					notes: MessageNotes.fresh,
				}).to_utf8()
		},
	)
}
# A message by an author no user is names no author's id; one by a user does.
expect {
	stranger = Author.from_str("LC") ?? crash "ConversationStream's tests: a name"
	framed_by = |author| {
		conversation = plans_holding_by(author, ["Hello"])
		Str.from_utf8_lossy(
			message_frame(
				conversation,
				conversation.messages().first() ?? crash "ConversationStream's tests: one message",
			),
		)
	}
	framed_by(stranger)
		.starts_with("id: 1\ndata: <article class=\"message\" id=\"msg-1\"><header><span class=\"author\">LC</span>")
		and framed_by(steve.user().author())
			.starts_with("id: 1\ndata: <article class=\"message\" id=\"msg-1\" data-author=\"1\"><header><span class=\"author\">Steve</span>")
}
# The backlog after each count: every frame, the one after, none; past the
# conversation, a 400.
expect
	is_plans_stream_with(
		streamed_after(0),
		"${frozen_frame({ id: "1", paragraph: "Hello" })}${frozen_frame({ id: "2", paragraph: "Hi!" })}",
	)
expect is_plans_stream_with(streamed_after(1), frozen_frame({ id: "2", paragraph: "Hi!" }))
expect is_plans_stream_with(streamed_after(2), "")
expect {
	response = streamed_after(3)
	response.status == 400
		and response.kind == Whole
		and response.stream_key == []
		and Str.from_utf8_lossy(response.body)
			.contains("The stream asks for the messages after 3, and the conversation holds 2.")
}
# A message whose notes are not fresh is sent again, before the messages
# after the count, when the reader has seen it; a reader who hasn't gets it
# among the messages, drawn with its notes, and nothing again.
expect {
	conversation = plans_holding(["Hello", "Edit of MSG_plans_1\n\nHello!"])
	streamed = |seen_count|
		Str.from_utf8_lossy(
			ConversationStream.response({
				key: plans_key,
				acting: steve,
				users,
				conversation,
				reactions: Reactions.empty,
				seen_count,
			}).body,
		)
	after_one = streamed(1)
	after_none = streamed(0)
	after_one.starts_with("event: replace\ndata: <article class=\"message\" id=\"msg-1\"")
		and after_one.contains("\n\nid: 2\ndata: <article")
		and !after_one.contains("id: 1\n")
		and after_none.starts_with("id: 1\ndata: <article class=\"message\" id=\"msg-1\"")
		and !after_none.contains("event: replace")
		and streamed(2).starts_with("event: replace\n")
		and !streamed(2).contains("id: ")
}
# Sent again: the message as edited, with no id; a message not held is none.
expect {
	conversation = plans_holding(["Hello", "Edit of MSG_plans_1\n\nHello!"])
	first = Message.Id.first
	missing = Message.Id.from_digits("3".to_utf8()) ?? crash "ConversationStream's tests: an id"
	drawn = message_drawn_again({
		key: plans_key,
		conversation,
		reactions: Reactions.empty,
		users,
		id: first,
	})
	match drawn {
		Ok(html) =>
			Str.from_utf8_lossy(replacement_frame(html)).starts_with("event: replace\ndata: <article")
				and Str.from_utf8_lossy(html.to_utf8()).contains("Edited in")
				and message_drawn_again({
					key: plans_key,
					conversation,
					reactions: Reactions.empty,
					users,
					id: missing,
				}).is_err()
		Err(NoSuchMessage) => Bool.False
	}
}
