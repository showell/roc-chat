## A conversation's transcript is its messages as one file, readable with
## `cat`, in this format:
##
##     -------------
##     MSG_planning_1
##     from: Steve
##     date: 2026-11-02T19:11:32Z
##
##     The markdown, exactly as written.
##
## Each message opens with the separator, then its reference
## (`MessageAnchor`), its author, its time, an empty line, its markdown
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

	## A whole transcript file's bytes, as the disk holds them, which is what
	## `TranscriptFiles.read_transcript!` answers. They are untrusted: any bytes
	## at all, until `decode` reads them into a conversation or refuses
	## them. The type is opaque, and only `decode` opens one.
	Utf8Transcript :: List(U8).{

		## The bytes just read from a transcript file (`TranscriptFiles`' read,
		## the demo's), unchecked. Nothing is checked here: `decode` checks
		## everything.
		unchecked_from_file : List(U8) -> Transcript.Utf8Transcript
		unchecked_from_file = |bytes| Transcript.Utf8Transcript.(bytes)

		## The file's bytes as the disk holds them, to serve as plain text
		## (`/raw`), never as markup: what a reader of the file with `cat`
		## sees.
		to_plain_text : Transcript.Utf8Transcript -> List(U8)
		to_plain_text = |Transcript.Utf8Transcript.(bytes)| bytes
	}

	## One message's record, as a transcript file takes it, which is what
	## `TranscriptFiles.append_message!` adds at a transcript's end. The type is
	## opaque, and only `message_record` makes one, so its bytes are always
	## one record this module wrote.
	Utf8TranscriptMessage :: List(U8).{

		## Its bytes, for the file system to append.
		to_utf8_bytes : Transcript.Utf8TranscriptMessage -> List(U8)
		to_utf8_bytes = |Transcript.Utf8TranscriptMessage.(bytes)| bytes
	}

	## The most bytes a transcript file holds, 16 MiB; this is the limit's
	## one home. `message_record` refuses a record that would grow the file
	## past it, so every transcript the chat writes stays one the host will
	## read. The host's own read cap, host/file_primitives.zig's `read_most`,
	## sits strictly above this, a safety net and never the rule.
	most_bytes : U64
	most_bytes = 16 * 1024 * 1024

	## The record of the message a conversation was just grown by, as
	## `Conversation.append` answers them, written as the transcript file
	## writes it. Added at the end of `file`, which holds the conversation
	## before that message (`NoFile` when there is no file yet), it makes the
	## file hold `write(grown.conversation)`. It is refused (`FileFull`) when
	## the file would then hold more than `most_bytes`.
	message_record : {
		grown : { conversation : Conversation, message : Message },
		file : [NoFile, File(Transcript.Utf8Transcript)],
	} -> Try(Transcript.Utf8TranscriptMessage, [FileFull])
	message_record = |{ grown, file }| {
		record = write_message(grown.conversation, grown.message).to_utf8()
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

	## `topic`'s conversation, decoded from a transcript file as `read`
	## reads it, or the first thing wrong with the file (not UTF-8 first).
	## The refusal is `TranscriptRefusal`'s type, made here and nowhere
	## else, so every reader of a file puts it in the same words.
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
	read = |topic, text| read_onto(Conversation.empty(topic), Separator.records(text)?)

	## The last message of a transcript file, read from its last record
	## alone, so its cost is that message's and not the file's: its author,
	## its time and its markdown; `NoMessages` for an empty file; or
	## `Unreadable` when the last record is not one this module writes.
	## Only the last record is checked, so a file `decode` would refuse
	## earlier in it still answers here.
	latest_message : Transcript.Utf8Transcript -> Try(
		[NoMessages, Latest(Transcript.LatestMessage)],
		[Unreadable],
	)
	latest_message = |Transcript.Utf8Transcript.(bytes)|
		if bytes.is_empty() {
			Ok(NoMessages)
		} else {
			opening = "${Separator.line}\n".to_utf8()
			start =
				match last_record_start({ bytes, at: bytes.len() }) {
					Found(at) => at
					NoneFound if bytes.starts_with(opening) => opening.len()
					NoneFound => bytes.len()
				}
			record = bytes.sublist({ start, len: bytes.len() - start })
			match Str.from_utf8(record) {
				Ok(text) if text.ends_with("\n\n") =>
					latest_from_record(text.drop_suffix("\n\n")).map_ok(|latest| Latest(latest))
				_ => Err(Unreadable)
			}
		}

	## A transcript's last message, as `latest_message` reads it.
	LatestMessage : {
		author : Author,
		time : DateTime,
		markdown : Str,
	}

	## Who wrote a message of a transcript, and when; its markdown unread.
	Post : { author : Author, time : DateTime }

	## The latest post of each of `authors` among the transcript's last
	## `most` messages, newest first, read back from its end a record at a
	## time and stopping once each of them is found, or at the first record
	## written before `since` (a conversation's times never go backwards), so
	## its cost is those records' and not the file's; or `Unreadable` when
	## one of them is not a record this module writes. A channel's card reads
	## its members' participation so (`ChannelRoster`): with a handful of
	## members, a busy topic is a handful of records.
	latest_posts : Transcript.Utf8Transcript,
	{
		authors : List(Author),
		most : U64,
		since : DateTime,
	} -> Try(List(Transcript.Post), [Unreadable])
	latest_posts = |Transcript.Utf8Transcript.(bytes), { authors, most, since }|
		posts_before({ bytes, end: bytes.len(), left: most, since, wanted: authors, so_far: [] })
}

## The latest posts of `wanted` before `end` of `bytes`, newest first, after
## `so_far`: from at most `left` more records, none written before `since`.
posts_before : {
	bytes : List(U8),
	end : U64,
	left : U64,
	since : DateTime,
	wanted : List(Author),
	so_far : List(Transcript.Post),
} -> Try(List(Transcript.Post), [Unreadable])
posts_before = |{ bytes, end, left, since, wanted, so_far }|
	if end == 0 or left == 0 or wanted.is_empty() {
		Ok(so_far)
	} else {
		opening = "${Separator.line}\n".to_utf8()
		marker_len = "\n${Separator.line}\n".to_utf8().len()
		bounds =
			match last_record_start({ bytes, at: end }) {
				Found(at) => Ok({ start: at, before: at - marker_len + 1 })
				NoneFound if bytes.starts_with(opening) => Ok({ start: opening.len(), before: 0 })
				NoneFound => Err(Unreadable)
			}
		{ start, before } = bounds?
		post = post_from_record(bytes.sublist({ start, len: end - start }))?
		if DateTime.compare(post.time, since) == Before {
			Ok(so_far)
		} else if wanted.contains(post.author) {
			posts_before({
				bytes,
				end: before,
				left: left - 1,
				since,
				wanted: wanted.drop_if(|author| author == post.author),
				so_far: so_far.append(post),
			})
		} else {
			posts_before({ bytes, end: before, left: left - 1, since, wanted, so_far })
		}
	}

## One record's author and time, from its head alone.
post_from_record : List(U8) -> Try(Transcript.Post, [Unreadable])
post_from_record = |record|
	match Str.from_utf8(record) {
		Ok(text) if text.ends_with("\n\n") =>
			match text.split_on("\n") {
				[head, from_line, date_line, "", ..] if head.starts_with("MSG_") and from_line.starts_with("from: ") and date_line.starts_with("date: ") => {
					author = Author.from_str(from_line.drop_prefix("from: ")) ? |_| Unreadable
					time = DateTime.from_str(date_line.drop_prefix("date: ")) ? |_| Unreadable
					Ok({ author, time })
				}
				_ => Err(Unreadable)
			}
		_ => Err(Unreadable)
	}

## Where the last record of `bytes` before `at` starts: just after the
## last separator line that follows a line end, or `NoneFound`.
last_record_start : { bytes : List(U8), at : U64 } -> [Found(U64), NoneFound]
last_record_start = |{ bytes, at }| {
	marker = "\n${Separator.line}\n".to_utf8()
	if at < marker.len() {
		NoneFound
	} else {
		from = at - marker.len()
		if bytes.get(from) == Ok('\n') and bytes.sublist({
			start: from,
			len: marker.len(),
		}) == marker {
			Found(at)
		} else {
			last_record_start({ bytes, at: at - 1 })
		}
	}
}

## One record's message, as `read_message` reads its head and body, with
## no conversation to number it.
latest_from_record : Str -> Try(Transcript.LatestMessage, [Unreadable])
latest_from_record = |written|
	match written.split_on("\n") {
		[
			head,
			from_line,
			date_line,
			"",
			.. as body,
		] if head.starts_with("MSG_") and from_line.starts_with("from: ") and date_line.starts_with("date: ") => {
			author = Author.from_str(from_line.drop_prefix("from: ")) ? |_| Unreadable
			time = DateTime.from_str(date_line.drop_prefix("date: ")) ? |_| Unreadable
			markdown = Separator.unescape(Str.join_with(body, "\n")) ? |_| Unreadable
			Ok({ author, time, markdown })
		}
		_ => Err(Unreadable)
	}

## Whether `adding` bytes fit after the `held` bytes a file holds, at most
## `most_bytes` in all.
room : { held : U64, adding : U64 } -> [Fits, Overflows]
room = |{ held, adding }|
	if held + adding <= Transcript.most_bytes {
		Fits
	} else {
		Overflows
	}

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

## `conversation` with the message `written` appended, or why it can't be.
read_message : Conversation, Str -> Try(Conversation, _)
read_message = |conversation, written| {
	id = conversation.next_id()?
	reference = conversation.reference(id).to_str()
	match written.split_on("\n") {
		[
			head,
			from_line,
			date_line,
			"",
			.. as body,
		] if head
			== reference
			and from_line.starts_with("from: ")
			and date_line.starts_with("date: ") => {
			name = from_line.drop_prefix("from: ")
			date = date_line.drop_prefix("date: ")
			author = Author.from_str(name).map_err(|why| Author(id, why))?
			time = DateTime.from_str(date).map_err(|why| DateTime(id, why))?
			markdown = Separator.unescape(
				Str.join_with(body, "\n"),
			).map_err(|BareSeparator| BadBody(id))?
			grown = conversation.append({ payload: { author, markdown }, time }).map_err(
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
expect room({ held: Transcript.most_bytes - 10, adding: 9 }) == Fits
expect room({ held: Transcript.most_bytes - 10, adding: 10 }) == Fits
expect room({ held: Transcript.most_bytes - 10, adding: 11 }) == Overflows
expect room({ held: 0, adding: Transcript.most_bytes }) == Fits
expect room({ held: 0, adding: Transcript.most_bytes + 1 }) == Overflows
expect Transcript.most_bytes == 16_777_216
