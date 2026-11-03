## A conversation's stream: each message added after a page was drawn,
## written as that page writes it (`Page.message`), so the page and the
## stream can't disagree. The host holds the stream open on its bus key,
## the conversation's URL path, and knows nothing of conversations.
##
## A frame is one event, its id the message's number and its data the
## message's HTML. A page asks for the messages after the count it shows
## (`?after=<count>`), and a browser that reconnects says the last id it
## saw (`Last-Event-ID`), which wins. The host subscribes the stream in
## the call that read its backlog, so a page sees every message once.
import pf.Host
import pf.Http
import Ascii
import Author
import Conversation
import ConversationKey
import DateTime
import Directory
import HttpAnswer
import Message
import Name
import Page
import RequestHeader
import SignedIn
import Topic
import UnvalidatedString
import Users

ConversationStream :: [].{

	## **HOW MANY MESSAGES THE READER HAS SEEN**: the request's
	## `Last-Event-ID` when it is sent, else its query's `after`; or why
	## neither names a count.
	seen_count : { query : List(U8), headers : List(Http.Header) } -> Try(U16, [NoCount, BadCount])
	seen_count = |{ query, headers }|
		match RequestHeader.header_value(headers, "last-event-id") {
			Sent(id) => count_of(id)
			Repeated => Err(BadCount)
			Unsent =>
				if (query.is_empty())
					Err(NoCount)
				else if (query.starts_with(after_prefix))
					count_of(query.drop_first(after_prefix.len()))
				else
					Err(BadCount)
		}

	## Why a stream names no count, in words.
	words : [NoCount, BadCount] -> Str
	words = |why|
		match why {
			NoCount => "The stream names no count of the messages seen: `?after=<count>`, or a Last-Event-ID."
			BadCount => "The stream's count of the messages seen is not one: the digits of 0 to 65535, with no leading 0."
		}

	## **THE STREAM OF `key`'S CONVERSATION FOR `acting`**, `conversation`
	## as it is now: the messages after the reader's `seen` first, then
	## each one added; a 400 when `seen` is more than it holds. Each
	## message's author is found among `users`, as the page finds them.
	response : {
		key : ConversationKey,
		acting : SignedIn,
		users : Users,
		conversation : Conversation,
		seen : U16,
	} -> Http.Response
	response = |
		{
			key,
			acting,
			users,
			conversation,
			seen,
		},
	| {
		held = conversation.messages().len()
		if (seen.to_u64() > held)
			HttpAnswer.notice(400, { title: "Bad stream", said: "The stream asks for the messages after ${seen.to_str()}, and the conversation holds ${held.to_str()}." })
		else
			HttpAnswer.stream({
				key: bus_key(key),
				holder: acting.user().id().to_str().to_utf8(),
				backlog: conversation.messages_after(seen).join_map(
					|m|
						ConversationStream.frame({
							key,
							users,
							conversation,
							message: m,
						}),
				),
			})
	}

	## **`message`, ADDED TO `conversation`, SENT TO EVERY PAGE ON `key`'S
	## STREAM**, its author found among `users`.
	publish! : {
		key : ConversationKey,
		users : Users,
		conversation : Conversation,
		message : Message,
	} => {}
	publish! = |
		{
			key,
			users,
			conversation,
			message,
		},
	|
		Host.publish_bytes_to_streams_on_key!(
			bus_key(key),
			ConversationStream.frame({
				key,
				users,
				conversation,
				message,
			}),
		)

	## **ONE MESSAGE AS ONE EVENT**: `id:` its number, then its HTML, a
	## `data:` line a line, then the blank line that ends it.
	frame : {
		key : ConversationKey,
		users : Users,
		conversation : Conversation,
		message : Message,
	} -> List(U8)
	frame = |
		{
			key,
			users,
			conversation,
			message,
		},
	| {
		html = line_feeds_only(
			Page.message({
				conversation,
				key,
				users,
				message,
			}).to_utf8(),
		)
		"id: ${message.id().to_str()}\n"
			.to_utf8()
			.concat(html.split_on('\n').join_map(|line| "data: ".to_utf8().concat(line).append('\n')))
			.append('\n')
	}
}

after_prefix : List(U8)
after_prefix = "after=".to_utf8()

## The stream's bus key: the conversation's URL path.
bus_key : ConversationKey -> List(U8)
bus_key = |key| key.url_path().to_utf8()

## **THE COUNT `bytes` SPELL**: the digits of 0 to 65535, with no leading
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
			if (number > U16.highest.to_u64()) Err(BadCount) else Ok(number.to_u16_wrap())
		}
	}

## **EACH CR LF AND EACH LONE CR AS AN LF**: an event's data can't hold a
## CR, and an HTML parser reads both as an LF, so the page shows the same.
line_feeds_only : List(U8) -> List(U8)
line_feeds_only = |bytes|
	bytes.fold(
		{ written: [], previous: 0 },
		|so_far, byte|
			if (byte == '\r')
				{ written: so_far.written.append('\n'), previous: byte }
			else if (byte == '\n' and so_far.previous == '\r')
				{ ..so_far, previous: byte }
			else
				{ written: so_far.written.append(byte), previous: byte },
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
	ConversationStream.seen_count({
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
expect ConversationStream.words(NoCount) == "The stream names no count of the messages seen: `?after=<count>`, or a Last-Event-ID."
expect ConversationStream.words(BadCount) == "The stream's count of the messages seen is not one: the digits of 0 to 65535, with no leading 0."

## The users of the tests' directory: Steve alone, id 1.
users : Users
users = Directory.with_founder(Name.from_str("Steve") ?? crash "ConversationStream's tests: a name").users()

## Steve, the founder of the tests' directory, signed in as a test assumes him.
steve : SignedIn
steve = SignedIn.dangerously_assume(users.to_list().first() ?? crash "ConversationStream's tests: Steve is the first user")

## `plans` in Steve's own DM.
plans_key : ConversationKey
plans_key = ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8("/chat/dm/1_1/plans".to_utf8()) ?? crash "ConversationStream's tests: a path is UTF-8",
	directory: Directory.with_founder(Name.from_str("Steve") ?? crash "ConversationStream's tests: a name"),
}) ?? crash "ConversationStream's tests: Steve's own DM is a place"

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
		|so_far, markdown| (so_far.append({ payload: { author, markdown }, time }) ?? crash "ConversationStream's tests: a message joins").conversation,
	)
}

## The stream of `plans` holding "Hello" and "Hi!" for Steve, after `seen`,
## as a test reads it: its status, kind, key and holder in a line, and its
## body.
streamed_after : U16 -> (Str, Str)
streamed_after = |seen| {
	answered = ConversationStream.response({
		key: plans_key,
		acting: steve,
		users,
		conversation: plans_holding(["Hello", "Hi!"]),
		seen,
	})
	kind = if (answered.kind == Stream) "stream" else "whole"
	(
		"${answered.status.to_str()} ${kind} on ${Str.from_utf8_lossy(answered.stream_key)} for ${Str.from_utf8_lossy(answered.stream_holder)}",
		Str.from_utf8_lossy(answered.body),
	)
}

## What every stream of `plans` for Steve says of itself.
plans_stream : Str
plans_stream = "200 stream on /chat/dm/1_1/plans for 1"

## The frame of the message `n` of `plans`, by Steve, id 1, its markdown a
## paragraph `said`, as frozen.
frozen_frame : Str, Str -> Str
frozen_frame = |n, said| "id: ${n}\ndata: <article class=\"message\" id=\"msg-${n}\" data-author=\"1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-${n}\">MSG_plans_${n}</a></header>\ndata: <div class=\"body\"><p>${said}</p>\ndata: </div></article>\ndata: \n\n"

# A frame's data lines, joined by LF as a browser joins them, are exactly
# the page's HTML for the message, a list's lines and all.
expect {
	conversation = plans_holding(["Hello", "- one\n- two"])
	conversation.messages().all(
		|m| {
			framed = ConversationStream.frame({
				key: plans_key,
				users,
				conversation,
				message: m,
			})
			data =
				Str.from_utf8_lossy(framed)
					.split_on("\n")
					.keep_if(|line| line.starts_with("data: "))
					.map(|line| line.drop_prefix("data: "))
			Str.join_with(data, "\n").to_utf8()
				== Page.message({
					conversation,
					key: plans_key,
					users,
					message: m,
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
			ConversationStream.frame({
				key: plans_key,
				users,
				conversation,
				message: conversation.messages().first() ?? crash "ConversationStream's tests: one message",
			}),
		)
	}
	framed_by(stranger).starts_with("id: 1\ndata: <article class=\"message\" id=\"msg-1\"><header><span class=\"author\">LC</span>")
		and framed_by(steve.user().author()).starts_with("id: 1\ndata: <article class=\"message\" id=\"msg-1\" data-author=\"1\"><header><span class=\"author\">Steve</span>")
}
# The backlog after each count: every frame, the one after, none; past the
# conversation, a 400.
expect streamed_after(0) == (plans_stream, "${frozen_frame("1", "Hello")}${frozen_frame("2", "Hi!")}")
expect streamed_after(1) == (plans_stream, frozen_frame("2", "Hi!"))
expect streamed_after(2) == (plans_stream, "")
expect {
	(said, body) = streamed_after(3)
	said == "400 whole on  for " and body.contains("The stream asks for the messages after 3, and the conversation holds 2.")
}
