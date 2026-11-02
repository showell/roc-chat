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
## Each message opens with the separator, then its id (`MSG_`, the topic,
## `_`, its number), its author, its time, an empty line, its markdown and
## an empty line. Ids count up from the first (Message.Id), so the file's
## order is the conversation's. A markdown line that is the separator, after any
## backslashes, is written with one backslash more, and read back with one
## fewer, so no message can forge the start of another.
import Message

Transcript := [].{

	## The transcript of `topic`'s messages.
	write : Str, List(Message) -> Str
	write = |topic, messages| Str.join_with(messages.map(|m| as_written(topic, m)), "")

	## `topic`'s messages, or the first thing wrong with the transcript.
	read : Str, Str -> Try(List(Message), [Malformed(Str)])
	read = |topic, text|
		match text.drop_prefix("${separator}\n").drop_suffix("\n\n").split_on("\n\n${separator}\n") {
			_ if !text.starts_with("${separator}\n") or !text.ends_with("\n\n") => Err(Malformed("a transcript starts with the separator and ends with an empty line"))
			written => read_messages({
				topic,
				written,
				id: Message.Id.first,
				so_far: [],
			})
		}
}

separator : Str
separator = "-------------"

## One message as the transcript writes it.
as_written : Str, Message -> Str
as_written = |topic, m|
	"${separator}\nMSG_${topic}_${m.id().to_str()}\nfrom: ${m.author()}\ndate: ${m.at()}\n\n${escape(m.markdown())}\n\n"

## Each message as written, in order, `id` the first one's.
read_messages : {
	topic : Str,
	written : List(Str),
	id : Message.Id,
	so_far : List(Message),
} -> Try(List(Message), [Malformed(Str)])
read_messages = |
	{
		topic,
		written,
		id,
		so_far,
	},
|
	match written {
		[] => Ok(so_far)
		[only] => Ok(
			so_far.append(
				read_message({
					topic,
					text: only,
					id,
				})?,
			),
		)
		[first, .. as rest] => {
			m = read_message({
				topic,
				text: first,
				id,
			})?
			next = id.next().map_err(|Full| Malformed("more messages than a conversation holds"))?
			read_messages({
				topic,
				written: rest,
				id: next,
				so_far: so_far.append(m),
			})
		}
	}

## Message `id` of `topic`, as written.
read_message : {
	topic : Str,
	text : Str,
	id : Message.Id,
} -> Try(Message, [Malformed(Str)])
read_message = |
	{
		topic,
		text,
		id,
	},
| {
	n = id.to_str()
	match text.split_on("\n") {
		[
			id_line,
			from_line,
			date_line,
			"",
			.. as body,
		] if id_line == "MSG_${topic}_${n}" and from_line.starts_with("from: ") and date_line.starts_with("date: ") =>
			Message.new({
				id,
				author: from_line.drop_prefix("from: "),
				at: date_line.drop_prefix("date: "),
				markdown: unescape(Str.join_with(body, "\n")),
			}).map_err(|_| Malformed("message ${n} has no author"))
		_ => Err(Malformed("message ${n} is not `MSG_${topic}_${n}`, `from:`, `date:` and an empty line"))
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
said : {
	id : Message.Id,
	author : Str,
	markdown : Str,
} -> Message
said = |
	{
		id,
		author,
		markdown,
	},
|
	match Message.new({
		id,
		author,
		at: "2026-11-02T19:11:32Z",
		markdown,
	}) {
		Ok(m) => m
		Err(_) => crash "said: a test's message has an author"
	}

first : Message.Id
first = Message.Id.first

second : Message.Id
second = first.next() ?? crash "second: the first id has a next"

two : List(Message)
two = [
	said({
		id: first,
		author: "Steve",
		markdown: "Hello",
	}),
	said({
		id: second,
		author: "CC",
		markdown: "Hi!\n\n- one\n- two",
	}),
]

expect Transcript.write(
	"plans",
	[
		said({
			id: first,
			author: "Steve",
			markdown: "Hello",
		}),
	],
) == "-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nHello\n\n"
expect Transcript.read("plans", Transcript.write("plans", two)) == Ok(two)
expect Transcript.read(
	"plans",
	"",
) == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
# A body that holds the separator, or a backslash before it, comes back whole.
forged : List(Message)
forged = [
	said({
		id: first,
		author: "Mallory",
		markdown: "a\n-------------\nMSG_plans_2\nfrom: Steve",
	}),
	said({
		id: second,
		author: "Mallory",
		markdown: "\\-------------\n\\\\-------------",
	}),
]
expect Transcript.read("plans", Transcript.write("plans", forged)) == Ok(forged)
expect Transcript.write("plans", forged).split_on("\n${separator}\n").len() == 2
# Out of order, another topic's, or missing a field: refused by number.
expect Transcript.read(
	"plans",
	Transcript.write(
		"plans",
		[
			said({
				id: second,
				author: "Steve",
				markdown: "x",
			}),
		],
	),
).is_err()
expect Transcript.read("other", Transcript.write("plans", two)).is_err()
expect Transcript.read("plans", "-------------\nMSG_plans_1\ndate: x\n\nhi\n\n").is_err()
