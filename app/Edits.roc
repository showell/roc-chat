## **QUOTE-REPLY AND EDIT, THE OLD CLIENT'S RULES, KEPT BY THE SERVER**
## (chat-client's js/chat.js, `doQuote`, `doEdit`, `pickQuoteFence`, and
## the "Edit of" supersession, js/chat.js `appendMessage` with
## js/message.js `markEdited`). The browser asks for the text; the rules
## (the reference's spelling, the fence, who may edit) stay here. Pure.
##
## **AN EDIT IS A NEW MESSAGE** that starts "Edit of MSG_<ref>", the
## reference of an earlier message in its topic. Only its author's edit
## supersedes it ("no post can hide another's"); the original is kept, and
## its bubble shows "Edited in MSG_<the edit>" and the original in a
## spoiler. The last of several edits is the one named.
import Cast
import MessageCodec
import MessageRef
import Topic

Edits := [].{

	## **WHICH MESSAGE AN EDIT EDITS**: its number, when `body` starts
	## "Edit of " and a reference to a message of this topic, the full one
	## (`MSG_<channel>.<topic>_<n>`) or the short one (`MSG_<topic>_<n>`, a
	## DM's, and what the old client wrote in a channel too), ended as the
	## old `\b` ended it: by anything not a letter, a digit or `_`, the
	## longest reference that leaves (`Edit of MSG_Lobby.Chat_3. Typo`).
	target : Topic.At, List(U8) -> Try(U64, [NotAnEdit])
	target = |at, body| {
		lead = "Edit of MSG_".to_utf8()
		if !body.starts_with(lead) {
			Err(NotAnEdit)
		} else {
			rest = body.drop_first(lead.len() - 4)
			longest(at, rest.take_first(token_len(rest, 0)))
		}
	}

	## **WHICH MESSAGES ARE SUPERSEDED, AND BY WHICH EDIT**: each message
	## of `messages` (one topic's, oldest first) that a later one by the same
	## author edits, with the last such edit's number.
	superseded : Topic.At, List(MessageCodec.Fields) -> List({ n : U64, by : U64 })
	superseded = |at, messages|
		messages.fold(
			[],
			|found, m|
				match Edits.target(at, m.body) {
					Err(NotAnEdit) => found
					Ok(t) =>
						if t >= m.id {
							found
						} else {
							match messages.find_first(|o| o.id == t) {
								Ok(original) if original.by == m.by => found.keep_if(|f| f.n != t).append({
									n: t,
									by: m.id,
								})
								_ => found
							}
						}
				},
		)

	## **THE QUOTE-REPLY**, as the old `doQuote` wrote it: `In <ref> I said:`
	## (or `you said:`, by whether the asker wrote it), then the markdown in
	## a `quote` fence one tilde longer than any run of tildes that opens a
	## line inside it, then a blank line.
	quote : {
		ref : Str,
		mine : Bool,
		markdown : List(U8),
	} -> List(U8)
	quote = |
		{
			ref,
			mine,
			markdown,
		},
	| {
		fence = List.repeat('~', longest_tilde_run(markdown) + 1)
		said = if (mine) "I said" else "you said"
		List.join([
			"In ${ref} ${said}:\n".to_utf8(),
			fence,
			" quote\n".to_utf8(),
			markdown,
			"\n".to_utf8(),
			fence,
			"\n\n".to_utf8(),
		])
	}

	## **THE EDIT'S DRAFT**, as the old `doEdit` wrote it: `Edit of <ref>`, a
	## blank line, then the markdown; `caret` is where the cursor goes, after
	## the blank line (in UTF-16 units, the browser's, as the prefix is ASCII).
	draft : { ref : Str, markdown : List(U8) } -> { text : List(U8), caret : U64 }
	draft = |{ ref, markdown }| {
		prefix = "Edit of ${ref}\n\n".to_utf8()
		{ text: prefix.concat(markdown), caret: prefix.len() }
	}
}

## The reference's run: the bytes a reference can hold (a name's letters,
## digits and `-`, the `.` between the names, the `_` before the number).
token_len : List(U8), U64 -> U64
token_len = |s, i|
	match s.get(i) {
		Ok(c) if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-' => token_len(
			s,
			i + 1,
		)
		_ => i
	}

## **THE LONGEST REFERENCE `run` STARTS WITH**, as the old pattern's
## greedy match found it: the whole run, or else its longest start that ends
## at a number followed by a `.` or a `-`.
longest : Topic.At, List(U8) -> Try(U64, [NotAnEdit])
longest = |at, run|
	match in_this(at, run) {
		Ok(n) => Ok(n)
		Err(NotAnEdit) =>
			match cut(run, run.len()) {
				Ok(start) => longest(at, start)
				Err(NotAnEdit) => Err(NotAnEdit)
			}
	}

## `MSG_<channel>.<topic>_<n>` or `MSG_<topic>_<n>`, a message of `at`'s.
in_this : Topic.At, List(U8) -> Try(U64, [NotAnEdit])
in_this = |at, bytes| {
	text = Str.from_utf8(bytes) ?? ""
	ref =
		match MessageRef.from_str(text) {
			Ok(r) => Ok(r)
			Err(NotAReference) => MessageRef.in_topic(at, Str.from_utf8(bytes.drop_first(4)) ?? "")
		}
	match ref {
		Ok(r) if r.at() == at => Ok(r.n())
		_ => Err(NotAnEdit)
	}
}

## The run's longest start before `i` that ends at a digit with a `.` or a
## `-` after it.
cut : List(U8), U64 -> Try(List(U8), [NotAnEdit])
cut = |run, i|
	if i < 2 {
		Err(NotAnEdit)
	} else {
		at_i = i - 1
		match (run.get(at_i - 1), run.get(at_i)) {
			(
				Ok(d),
				Ok(c),
			) if d >= '0' and d <= '9' and (c == '.' or c == '-') => Ok(run.take_first(at_i))
			_ => cut(run, at_i)
		}
	}

## The longest run of `~` that opens a line, at least 2 (so the fence is at
## least 3), as `pickQuoteFence`.
longest_tilde_run : List(U8) -> U64
longest_tilde_run = |md| {
	walked = md.fold(
		{
			longest: 2,
			run: 0,
			at_line_start: Bool.True,
			counting: Bool.True,
		},
		|st, c|
			if c == '\n' {
				{
					longest: U64.max(st.longest, st.run),
					run: 0,
					at_line_start: Bool.True,
					counting: Bool.True,
				}
			} else if c == '~' and st.counting {
				{
					..st,
					run: st.run + 1,
					at_line_start: Bool.False,
				}
			} else {
				{
					longest: U64.max(st.longest, st.run),
					run: 0,
					at_line_start: Bool.False,
					counting: Bool.False,
				}
			},
	)
	U64.max(walked.longest, walked.run)
}

# ── tests
at_of : Str, Str -> Topic.At
at_of = |c, t| (MessageRef.from_str("MSG_${c}.${t}_1") ?? crash "a test's names are names").at()

expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Lobby.Chat_3\n\nfixed".to_utf8()) == Ok(3)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Lobby.Chat_3".to_utf8()) == Ok(3)
expect Edits.target(
	at_of("Lobby", "Chat"),
	"Edit of MSG_Other.Chat_3\n".to_utf8(),
) == Err(NotAnEdit)
expect Edits.target(
	at_of("Lobby", "Chat"),
	"Edit of MSG_Lobby.Chat_x\n".to_utf8(),
) == Err(NotAnEdit)
expect Edits.target(at_of("Lobby", "Chat"), "edit of MSG_Lobby.Chat_3".to_utf8()) == Err(NotAnEdit)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Chat_3\n".to_utf8()) == Ok(3)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Else_3\n".to_utf8()) == Err(NotAnEdit)
# Ended as the old `\b` ended it: by a `.` or `-` after the number (or
# anything else no reference holds), not by a letter, a digit or a `_`.
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Lobby.Chat_3. Typo".to_utf8()) == Ok(3)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Chat_3-ish".to_utf8()) == Ok(3)
expect Edits.target(
	at_of("a-1-", "road-trip-2"),
	"Edit of MSG_a-1-.road-trip-2_12.".to_utf8(),
) == Ok(12)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Chat_3--".to_utf8()) == Ok(3)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Chat_3x".to_utf8()) == Err(NotAnEdit)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Chat_3_".to_utf8()) == Err(NotAnEdit)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_Chat_3, now".to_utf8()) == Ok(3)

# Only the author's own later edit supersedes, the last of them named.
expect {
	at = at_of("Lobby", "Chat")
	m = |
		id,
		by,
		body,
	| {
		id,
		at: 0,
		by: if (by == 2) Cast.boss.id() else Cast.ann.id(),
		body: body.to_utf8(),
	}
	msgs = [
		m(
			1,
			1,
			"hi",
		),
		m(
			2,
			2,
			"Edit of MSG_Lobby.Chat_1",
		),
		m(
			3,
			1,
			"Edit of MSG_Lobby.Chat_1",
		),
		m(
			4,
			1,
			"Edit of MSG_Lobby.Chat_1",
		),
		m(
			5,
			1,
			"Edit of MSG_Lobby.Chat_9",
		),
	]
	Edits.superseded(at, msgs) == [{ n: 1, by: 4 }]
}

expect Edits.quote({
	ref: "MSG_Lobby.Chat_3",
	mine: Bool.True,
	markdown: "hi".to_utf8(),
}) == "In MSG_Lobby.Chat_3 I said:\n~~~ quote\nhi\n~~~\n\n".to_utf8()
expect Edits.quote({
	ref: "MSG_Chat_3",
	mine: Bool.False,
	markdown: "a\n~~~~ quote\nb\n~~~~".to_utf8(),
}) == "In MSG_Chat_3 you said:\n~~~~~ quote\na\n~~~~ quote\nb\n~~~~\n~~~~~\n\n".to_utf8()
expect Edits.quote({
	ref: "R",
	mine: Bool.False,
	markdown: "x ~~~~~~ y".to_utf8(),
}).starts_with("In R you said:\n~~~ quote\n".to_utf8())
expect Edits.draft({ ref: "MSG_Lobby.Chat_3", markdown: "old".to_utf8() }) == {
	text: "Edit of MSG_Lobby.Chat_3\n\nold".to_utf8(),
	caret: 26,
}
