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
## (`MsgAnchor`), its author, its time, an empty line, its markdown
## and an empty line. A conversation with no messages is an empty file. No
## message's markdown can forge the start of another, and a body holding
## the bare separator, which no writer makes, is refused (Separator).
import Author
import Conversation
import Message
import Separator
import DateTime
import Topic
import TranscriptRefusal

Transcript :: [].{

	## **A WHOLE TRANSCRIPT FILE'S BYTES, AS THE DISK HOLDS THEM**: what
	## `FileSystem.read_transcript!` answers. **UNTRUSTED**: any bytes at
	## all, until `decode` reads them into a conversation or refuses them.
	## Opaque, and only `decode` opens one.
	Utf8Transcript :: List(U8).{

		## **THE BYTES OF A TRANSCRIPT FILE, UNCHECKED**: the door for bytes
		## just read from a file (`FileSystem`'s read, the demo's). Nothing is
		## checked here: `decode` checks everything.
		unchecked_from_file : List(U8) -> Transcript.Utf8Transcript
		unchecked_from_file = |bytes| Transcript.Utf8Transcript.(bytes)
	}

	## **ONE MESSAGE'S RECORD, AS A TRANSCRIPT FILE TAKES IT**: what
	## `FileSystem.append_message!` adds at a transcript's end. Opaque, and
	## only `message_record` makes one, so its bytes are always one record
	## this module wrote.
	Utf8TranscriptMessage :: List(U8).{

		## Its bytes, for the file system to append.
		to_utf8_bytes : Transcript.Utf8TranscriptMessage -> List(U8)
		to_utf8_bytes = |Transcript.Utf8TranscriptMessage.(bytes)| bytes
	}

	## **THE MOST BYTES A TRANSCRIPT FILE HOLDS, THE LIMIT'S ONE HOME**:
	## 16 MiB. `message_record` refuses a record that would grow the file
	## past it, so every transcript the chat writes stays one the host will
	## read. The host's own read cap (`read_most`, host/file_primitives.zig)
	## sits strictly above this, a safety net and never the rule.
	most_bytes : U64
	most_bytes = 16 * 1024 * 1024

	## **THE RECORD OF `message`, THE LATEST OF `conversation`**, as the
	## transcript file writes it: added at the end of `file`, the file that
	## holds the conversation before it (`NoFile` when there is none yet),
	## the file holds `write(conversation)`. Unless the file would then hold
	## more than `most_bytes` (`FileFull`).
	message_record : {
		conversation : Conversation,
		message : Message,
		file : [NoFile, File(Transcript.Utf8Transcript)],
	} -> Try(Transcript.Utf8TranscriptMessage, [FileFull])
	message_record = |
		{
			conversation,
			message,
			file,
		},
	| {
		record = write_message(conversation, message).to_utf8()
		held =
			match file {
				NoFile => 0
				File(Transcript.Utf8Transcript.(bytes)) => bytes.len()
			}
		match room({ held, adding: record.len() }) {
			Fits => Ok(Transcript.Utf8TranscriptMessage.(record))
			Overflows => Err(FileFull)
		}
	}

	## **A TRANSCRIPT FILE, DECODED**: `topic`'s conversation, as `read`
	## reads it, or the first thing wrong with the file (not UTF-8 first).
	## **ITS REFUSAL IS `TranscriptRefusal`'S TYPE**, made here and nowhere
	## else, so every reader of a file words it as it comes.
	decode : Topic, Transcript.Utf8Transcript -> Try(Conversation, _)
	decode = |topic, Transcript.Utf8Transcript.(bytes)|
		match Str.from_utf8(bytes) {
			Ok(text) => Transcript.read(topic, text).map_err(|why| Transcript(why))
			Err(_) => Err(TranscriptNotUtf8)
		}

	## The transcript of the whole conversation.
	write : Conversation -> Str
	write = |conversation| Str.join_with(
		conversation.messages().map(|m| write_message(conversation, m)),
		"",
	)

	## `topic`'s conversation, each message appended in turn, or the first
	## thing wrong with the transcript, as tags inferred from the body
	## (`TranscriptRefusal.Why` lists them, under `Transcript`, and puts
	## them in words).
	read : Topic, Str -> Try(Conversation, _)
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

## **WHETHER `adding` BYTES FIT AFTER THE `held` A FILE HOLDS**, at most
## `most_bytes` in all.
room : { held : U64, adding : U64 } -> [Fits, Overflows]
room = |{ held, adding }| if (held + adding <= Transcript.most_bytes) Fits else Overflows

## One message as the transcript writes it.
write_message : Conversation, Message -> Str
write_message = |conversation, message|
	\\${Separator.line}
	\\${conversation.reference(message.id()).to_str()}
	\\from: ${message.author().to_str()}
	\\date: ${message.time().to_str()}
	\\
	\\${Separator.escape(message.markdown())}
	\\
	\\

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
	reference = c.reference(id).to_str()
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
			markdown = Separator.unescape(
				Str.join_with(
					body,
					"\n",
				),
			).map_err(|BareSeparator| BadBody(id))?
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

# ── tests
# The limit, at and around it: a file may hold exactly `most_bytes`.
expect
	[
		{ held: Transcript.most_bytes - 10, adding: 9 },
		{ held: Transcript.most_bytes - 10, adding: 10 },
		{ held: Transcript.most_bytes - 10, adding: 11 },
		{ held: 0, adding: Transcript.most_bytes },
		{ held: 0, adding: Transcript.most_bytes + 1 },
	].map(room)
		== [
			Fits,
			Fits,
			Overflows,
			Fits,
			Overflows,
		]
expect Transcript.most_bytes == 16_777_216
