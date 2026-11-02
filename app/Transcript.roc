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
## an empty line. Numbers count up from 1, so the file's order is the
## conversation's. A markdown line that is the separator, after any
## backslashes, is written with one backslash more, and read back with one
## fewer, so no message can forge the start of another.
import Message

Transcript := [].{

	## The transcript of `topic`'s messages.
	write : Str, List(Message) -> Str
	write = |topic, messages| Str.join_with(messages.map(|m| entry(topic, m)), "")

	## `topic`'s messages, or the first thing wrong with the transcript.
	read : Str, Str -> Try(List(Message), [Malformed(Str)])
	read = |topic, text|
		match text.drop_prefix("${separator}\n").drop_suffix("\n\n").split_on("\n\n${separator}\n") {
			_ if !text.starts_with("${separator}\n") or !text.ends_with("\n\n") => Err(Malformed("a transcript starts with the separator and ends with an empty line"))
			entries => read_entries(topic, entries, 1, [])
		}
}

separator : Str
separator = "-------------"

## One message as the transcript writes it.
entry : Str, Message -> Str
entry = |topic, m|
	"${separator}\nMSG_${topic}_${m.id().to_str()}\nfrom: ${m.author()}\ndate: ${m.at()}\n\n${escape(m.markdown())}\n\n"

## Each entry, in order, its number the next one.
read_entries : Str, List(Str), U64, List(Message) -> Try(List(Message), [Malformed(Str)])
read_entries = |topic, entries, n, read_so_far|
	match entries {
		[] => Ok(read_so_far)
		[first, .. as rest] => {
			m = read_entry(topic, first, n)?
			read_entries(topic, rest, n + 1, read_so_far.append(m))
		}
	}

## Message `n` of `topic`, from its entry.
read_entry : Str, Str, U64 -> Try(Message, [Malformed(Str)])
read_entry = |topic, text, n|
	match text.split_on("\n") {
		[id_line, from_line, date_line, "", .. as body] if id_line == "MSG_${topic}_${n.to_str()}" and from_line.starts_with("from: ") and date_line.starts_with("date: ") =>
			Message.new({
				id: n,
				author: from_line.drop_prefix("from: "),
				at: date_line.drop_prefix("date: "),
				markdown: unescape(Str.join_with(body, "\n")),
			}).map_err(|_| Malformed("message ${n.to_str()} has no author"))
		_ => Err(Malformed("message ${n.to_str()} is not `MSG_${topic}_${n.to_str()}`, `from:`, `date:` and an empty line"))
	}

## Is `line` the separator after some backslashes?
is_separator_like : Str -> Bool
is_separator_like = |line| line.ends_with(separator) and line.drop_suffix(separator).to_utf8().all(|b| b == '\\')

escape : Str -> Str
escape = |md| Str.join_with(md.split_on("\n").map(|l| if (is_separator_like(l)) "\\${l}" else l), "\n")

unescape : Str -> Str
unescape = |md| Str.join_with(md.split_on("\n").map(|l| if (l.starts_with("\\") and is_separator_like(l)) l.drop_prefix("\\") else l), "\n")

# ── tests
said : U64, Str, Str -> Message
said = |id, author, markdown|
	match Message.new({ id, author, at: "2026-11-02T19:11:32Z", markdown }) {
		Ok(m) => m
		Err(_) => crash "said: a test's message has an id and an author"
	}

two : List(Message)
two = [said(1, "Steve", "Hello"), said(2, "CC", "Hi!\n\n- one\n- two")]

expect Transcript.write("plans", [said(1, "Steve", "Hello")]) == "-------------\nMSG_plans_1\nfrom: Steve\ndate: 2026-11-02T19:11:32Z\n\nHello\n\n"
expect Transcript.read("plans", Transcript.write("plans", two)) == Ok(two)
expect Transcript.read("plans", "") == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
# A body that holds the separator, or a backslash before it, comes back whole.
forged : List(Message)
forged = [said(1, "Mallory", "a\n-------------\nMSG_plans_2\nfrom: Steve"), said(2, "Mallory", "\\-------------\n\\\\-------------")]
expect Transcript.read("plans", Transcript.write("plans", forged)) == Ok(forged)
expect Transcript.write("plans", forged).split_on("\n${separator}\n").len() == 2
# Out of order, another topic's, or missing a field: refused by number.
expect Transcript.read("plans", Transcript.write("plans", [said(2, "Steve", "x")])).is_err()
expect Transcript.read("other", Transcript.write("plans", two)).is_err()
expect Transcript.read("plans", "-------------\nMSG_plans_1\ndate: x\n\nhi\n\n").is_err()
