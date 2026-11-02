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
## (`Conversation.reference`), its author, its time, an empty line, its markdown
## and an empty line. A conversation with no messages is an empty file. No
## message's markdown can forge the start of another, and a body holding
## the bare separator, which no writer makes, is refused (Separator).
import Author
import Conversation
import Message
import Separator
import DateTime
import Topic

Transcript :: [].{

	## The transcript of the whole conversation.
	write : Conversation -> Str
	write = |conversation| Str.join_with(conversation.messages().map(|m| record(conversation, m)), "")

	## `topic`'s conversation, each message appended in turn, or the first
	## thing wrong with the transcript.
	read : Topic,
	Str -> Try(
		Conversation,
		[
			BadEnds,
			BadHead(Message.Id),
			Author(Message.Id, [Blank, ControlByte, Padded]),
			DateTime(Message.Id, [WrongShape, OutOfRange]),
			BadBody(Message.Id),
			Backdated(Message.Id),
			Full,
		],
	)
	read = |topic, text|
		if (text.is_empty())
			Ok(Conversation.empty(topic))
		else if (!text.starts_with("${Separator.line}\n") or !text.ends_with("\n\n"))
			Err(BadEnds)
		else {
			records = text.drop_prefix("${Separator.line}\n").drop_suffix("\n\n").split_on("\n\n${Separator.line}\n")
			read_onto(Conversation.empty(topic), records)
		}
}

## One message as the transcript writes it.
record : Conversation, Message -> Str
record = |conversation, message|
	"${Separator.line}\n${conversation.reference(message.id())}\nfrom: ${message.author().to_str()}\ndate: ${message.time().to_str()}\n\n${Separator.escape(message.markdown())}\n\n"

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
	reference = c.reference(id)
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
			time = DateTime.from_str(date).map_err(|why| DateTime(id, why))?
			markdown = Separator.unescape(Str.join_with(body, "\n")).map_err(|BareSeparator| BadBody(id))?
			grown = c.append({ payload: { author, markdown }, time }).map_err(
				|why|
					match why {
						Full => Full
						Backdated => Backdated(id)
					},
			)?
			Ok(grown.conversation)
		}
		_ => Err(BadHead(id))
	}
}
