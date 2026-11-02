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
## order is the conversation's. A conversation with no messages is an empty
## file. A markdown line that is the separator, after any backslashes, is
## written with one backslash more, and read back with one fewer, so no
## message can forge the start of another.
import Author
import Message
import Sample
import Timestamp
import Topic

Transcript := [].{

	## The transcript of `topic`'s messages.
	write : Topic, List(Message) -> Str
	write = |topic, messages| Str.join_with(messages.map(|m| as_written(topic, m)), "")

	## `topic`'s messages, or the first thing wrong with the transcript.
	read : Topic, Str -> Try(List(Message), [Malformed(Str)])
	read = |topic, text|
		if (text.is_empty())
			Ok([])
		else if (!text.starts_with("${separator}\n") or !text.ends_with("\n\n"))
			Err(Malformed("a transcript starts with the separator and ends with an empty line"))
		else
			read_onto({
				topic,
				written: text.drop_prefix("${separator}\n").drop_suffix("\n\n").split_on("\n\n${separator}\n"),
				id: Message.Id.first,
				so_far: [],
			})
}

separator : Str
separator = "-------------"

## One message as the transcript writes it.
as_written : Topic, Message -> Str
as_written = |topic, m|
	"${separator}\nMSG_${topic.to_str()}_${m.id().to_str()}\nfrom: ${m.author().to_str()}\ndate: ${m.time().to_str()}\n\n${escape(m.markdown())}\n\n"

## Each message as written, in order, `id` the first one's, onto `so_far`.
read_onto : {
	topic : Topic,
	written : List(Str),
	id : Message.Id,
	so_far : List(Message),
} -> Try(List(Message), [Malformed(Str)])
read_onto = |
	{
		topic,
		written,
		id,
		so_far,
	},
|
	match written {
		[] => Ok(so_far)
		# The last message never asks for a next id, which would refuse falsely at id 65,535.
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
			read_onto({
				topic,
				written: rest,
				id: next,
				so_far: so_far.append(m),
			})
		}
	}

## Message `id` of `topic`, as written.
read_message : {
	topic : Topic,
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
		] if id_line == "MSG_${topic.to_str()}_${n}" and from_line.starts_with("from: ") and date_line.starts_with("date: ") => {
			author = Author.from_str(from_line.drop_prefix("from: ")).map_err(
				|why|
					match why {
						Blank => Malformed("message ${n} has no author")
						LineBreak => Malformed("message ${n}'s author breaks a line")
					},
			)?
			time = Timestamp.from_str(date_line.drop_prefix("date: ")).map_err(
				|why|
					match why {
						WrongShape => Malformed("message ${n}'s date is not YYYY-MM-DDTHH:MM:SSZ")
						OutOfRange => Malformed("message ${n}'s date is no time a clock shows")
					},
			)?
			Ok(
				Message.new({
					id,
					author,
					time,
					markdown: unescape(Str.join_with(body, "\n")),
				}),
			)
		}
		_ => Err(Malformed("message ${n} is not `MSG_${topic.to_str()}_${n}`, `from:`, `date:` and an empty line"))
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
plans : Topic
plans = Sample.plans

## A transcript of one message from Steve, with `from` and `date` lines as
## given.
one_with : { from : Str, date : Str } -> Str
one_with = |{ from, date }| "-------------\nMSG_plans_1\n${from}\n${date}\n\nhi\n\n"

expect Transcript.write(
	plans,
	[
		Sample.said({
			id: Sample.first,
			author: "Steve",
			markdown: "Hello",
		}),
	],
) == "-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nHello\n\n"
expect Transcript.read(plans, Transcript.write(plans, Sample.two)) == Ok(Sample.two)
# No messages: an empty file, both ways.
expect Transcript.write(plans, []) == ""
expect Transcript.read(plans, "") == Ok([])
expect Transcript.read(plans, Transcript.write(plans, [])) == Ok([])
# The start and the end, each wrong alone.
expect Transcript.read(
	plans,
	"\n",
) == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
expect Transcript.read(
	plans,
	"MSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nhi\n\n",
) == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
expect Transcript.read(
	plans,
	"-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nhi\n",
) == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
expect Transcript.read(
	plans,
	"-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nhi",
) == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
# Each line of the head, bad alone, beside the good one.
expect Transcript.read(
	plans,
	one_with({ from: "from: Steve", date: "date: 2026-11-02T19:11:32Z" }),
).is_ok()
expect Transcript.read(
	plans,
	one_with({ from: "frm: Steve", date: "date: 2026-11-02T19:11:32Z" }),
) == Err(Malformed("message 1 is not `MSG_plans_1`, `from:`, `date:` and an empty line"))
expect Transcript.read(
	plans,
	one_with({ from: "from: Steve", date: "dt: 2026-11-02T19:11:32Z" }),
) == Err(Malformed("message 1 is not `MSG_plans_1`, `from:`, `date:` and an empty line"))
expect Transcript.read(
	plans,
	one_with({ from: "from: ", date: "date: 2026-11-02T19:11:32Z" }),
) == Err(Malformed("message 1 has no author"))
expect Transcript.read(
	plans,
	one_with({ from: "from:  ", date: "date: 2026-11-02T19:11:32Z" }),
) == Err(Malformed("message 1 has no author"))
expect Transcript.read(
	plans,
	one_with({ from: "from: Steve\r", date: "date: 2026-11-02T19:11:32Z" }),
) == Err(Malformed("message 1's author breaks a line"))
expect Transcript.read(
	plans,
	one_with({ from: "from: Steve", date: "date: 2026-11-02" }),
) == Err(Malformed("message 1's date is not YYYY-MM-DDTHH:MM:SSZ"))
expect Transcript.read(
	plans,
	one_with({ from: "from: Steve", date: "date: 2026-13-02T19:11:32Z" }),
) == Err(Malformed("message 1's date is no time a clock shows"))
# A body that holds the separator, or a backslash before it, comes back whole.
forged : List(Message)
forged = [
	Sample.said({
		id: Sample.first,
		author: "Mallory",
		markdown: "a\n-------------\nMSG_plans_2\nfrom: Steve",
	}),
	Sample.said({
		id: Sample.second,
		author: "Mallory",
		markdown: "\\-------------\n\\\\-------------",
	}),
]
expect Transcript.read(plans, Transcript.write(plans, forged)) == Ok(forged)
expect Transcript.write(plans, forged).split_on("\n${separator}\n").len() == 2
# Near the separator but not it: written as is, read back unchanged.
near : List(Message)
near = [
	Sample.said({
		id: Sample.first,
		author: "Steve",
		markdown: "a-------------\n-------------x\n\\x",
	}),
]
expect Transcript.read(plans, Transcript.write(plans, near)) == Ok(near)
expect Transcript.write(plans, near).contains("\n\na-------------\n-------------x\n\\x\n\n")
expect is_separator_like("-------------")
expect is_separator_like("\\-------------")
expect is_separator_like("\\\\-------------")
expect !is_separator_like("a-------------")
expect !is_separator_like("-------------x")
expect !is_separator_like("\\x")
expect !is_separator_like("------------")
# Out of order, or another topic's: refused by number.
expect Transcript.read(
	plans,
	Transcript.write(
		plans,
		[
			Sample.said({
				id: Sample.second,
				author: "Steve",
				markdown: "x",
			}),
		],
	),
) == Err(Malformed("message 1 is not `MSG_plans_1`, `from:`, `date:` and an empty line"))
expect Transcript.read(
	Sample.other,
	Transcript.write(plans, Sample.two),
) == Err(Malformed("message 1 is not `MSG_other_1`, `from:`, `date:` and an empty line"))
