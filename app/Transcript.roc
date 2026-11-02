## **A CONVERSATION'S TRANSCRIPT**: its messages as one file, readable
## with `cat`, in the Zig chat's format:
##
##     -------------
##     MSG_planning_1
##     from: Steve
##     date: 2026-11-02T19:11:32Z
##
##     The markdown, exactly as written.
##
## Each message opens with the separator, then its reference
## (`Message.reference`), its author, its time, an empty line, its markdown
## and an empty line. A conversation with no messages is an empty file. A
## markdown line that is the separator, after any backslashes, is written
## with one backslash more, and read back with one fewer, so no message can
## forge the start of another.
import Author
import Conversation
import Message
import Timestamp
import Topic

Transcript :: [].{

	## The transcript of the whole conversation.
	write : Conversation -> Str
	write = |conversation| {
		topic = conversation.topic()
		Str.join_with(conversation.messages().map(|m| record({ topic, message: m })), "")
	}

	## What `append` gives: the conversation grown by one, and the one
	## message's record.
	Appended : { conversation : Conversation, record : Str }

	## **ONE MESSAGE'S RECORD, FOR A STORE TO APPEND**: the conversation
	## with `payload` appended, and that message's record, so the file a
	## store grows a record at a time is `write` of the conversation.
	append : Conversation, Message.Payload -> Try(Transcript.Appended, [Full])
	append = |before, payload| {
		after = before.append(payload)?
		added = after.messages().last() ?? crash "Transcript.append: an append adds a message"
		Ok({ conversation: after, record: record({ topic: after.topic(), message: added }) })
	}

	## `topic`'s conversation, each message appended in turn, or the first
	## thing wrong with the transcript.
	read : Topic,
	Str -> Try(
		Conversation,
		[
			BadEnds,
			BadHead(Message.Id),
			Author(Message.Id, [Blank, ControlByte]),
			Time(Message.Id, [WrongShape, OutOfRange]),
			Full,
		],
	)
	read = |topic, text|
		if (text.is_empty())
			Ok(Conversation.empty(topic))
		else if (!text.starts_with("${separator}\n") or !text.ends_with("\n\n"))
			Err(BadEnds)
		else {
			records = text.drop_prefix("${separator}\n").drop_suffix("\n\n").split_on("\n\n${separator}\n")
			read_onto(Conversation.empty(topic), records)
		}
}

separator : Str
separator = "-------------"

## One message as the transcript writes it.
record : { topic : Topic, message : { id : Message.Id, payload : Message.Payload } } -> Str
record = |{ topic, message: { id, payload } }|
	"${separator}\n${Message.reference(topic, id)}\nfrom: ${payload.author.to_str()}\ndate: ${payload.time.to_str()}\n\n${escape(payload.markdown)}\n\n"

## `so_far` with each record appended in order, or the first record's fault.
read_onto : Conversation, List(Str) -> Try(Conversation, _)
read_onto = |so_far, records|
	match records {
		[] => Ok(so_far)
		[first, .. as rest] => read_onto(read_message(so_far, first)?, rest)
	}

## `c` with the message `written` appended, or why it can't be.
read_message : Conversation, Str -> Try(Conversation, _)
read_message = |c, written| {
	id = c.next_id()?
	reference = Message.reference(c.topic(), id)
	match written.split_on("\n") {
		[
			head,
			from_line,
			date_line,
			"",
			.. as body,
		] if head == reference and from_line.starts_with("from: ") and date_line.starts_with("date: ") => {
			name = from_line.drop_prefix("from: ")
			date = date_line.drop_prefix("date: ")
			author = Author.from_str(name).map_err(|why| Author(id, why))?
			time = Timestamp.from_str(date).map_err(|why| Time(id, why))?
			c.append({
				author,
				time,
				markdown: unescape(Str.join_with(body, "\n")),
			})
		}
		_ => Err(BadHead(id))
	}
}

## Is `line` the separator after some backslashes?
is_separator_like : Str -> Bool
is_separator_like = |line| line.ends_with(separator) and line.drop_suffix(separator).to_utf8().all(|b| b == '\\')

escape : Str -> Str
escape = |md| Str.join_with(
	md.split_on("\n").map(|l| if (is_separator_like(l)) "\\${l}" else l),
	"\n",
)

unescape : Str -> Str
unescape = |md| Str.join_with(
	md.split_on("\n").map(|l| if (l.starts_with("\\") and is_separator_like(l)) l.drop_prefix("\\") else l),
	"\n",
)

# ── tests
expect is_separator_like("-------------")
expect is_separator_like("\\-------------")
expect is_separator_like("\\\\-------------")
expect !is_separator_like("a-------------")
expect !is_separator_like("-------------x")
expect !is_separator_like("\\x")
expect !is_separator_like("------------")
expect !is_separator_like("\\------------")
expect escape("a\n-------------\n\\-------------\nb") == "a\n\\-------------\n\\\\-------------\nb"
expect unescape("a\n\\-------------\n\\\\-------------\nb") == "a\n-------------\n\\-------------\nb"
# A lone backslash, or one before a near miss, is no escape.
expect unescape("\\\n\\------------") == "\\\n\\------------"
