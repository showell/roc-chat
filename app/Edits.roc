## **QUOTE-REPLY AND EDIT, THE OLD CLIENT'S RULES, KEPT BY THE SERVER**
## (chat-client's js/chat.js, `doQuote`, `doEdit`, `pickQuoteFence`, and
## the "Edit of" supersession, js/chat.js `appendMessage` with
## js/message.js `markEdited`). The browser asks for the text; the rules
## (the reference's spelling, the fence, who may edit) stay here. Pure.
##
## **AN EDIT IS A NEW MESSAGE** that starts "Edit of MSG_<ref>", the
## reference of an earlier message in its topic or its conversation
## (MessageRef.Where, MessageRef.number_in). Only its author's edit
## supersedes it ("no post can hide another's"); the original is kept, and
## its bubble shows "Edited in MSG_<the edit>" and the original in a
## spoiler. The last of several edits is the one named.
import Cast
import ConvAccess
import MessageCodec
import MessageRef

Edits := [].{

	## **WHICH MESSAGE AN EDIT EDITS**: its number, when `body` starts
	## "Edit of " and a reference to a message of this topic, the full one
	## (`MSG_<channel>.<topic>_<n>`) or the short one (`MSG_<topic>_<n>`, a
	## DM's, and what the old client wrote in a channel too), or of this
	## conversation (`MSG_<conversation>_<n>`), ended as the
	## old `\b` ended it: by anything not a letter, a digit or `_`, the
	## longest reference that leaves (`Edit of MSG_Lobby.Chat_3. Typo`).
	##
	## **ITS COST IS BOUNDED**, whatever the body: the run is read no
	## further than the longest reference (`ref_most`), so a body of 64 KB
	## costs what one of 146 bytes does. A run longer than that reference is
	## read as the old pattern read it: the longest start that ends at a
	## number followed by a `.` or a `-`.
	target : MessageRef.Where, List(U8) -> Try(U64, [NotAnEdit])
	target = |at, body|
		if !body.starts_with(lead) {
			Err(NotAnEdit)
		} else {
			rest = body.drop_first(lead.len() - 4)
			run = rest.take_first(token_len(rest, 0))
			if run.len() <= ref_most {
				longest(at, run)
			} else {
				# Too long to be one: only a start of it can be.
				match cut(run, run.len()) {
					Ok(start) => longest(at, start)
					Err(NotAnEdit) => Err(NotAnEdit)
				}
			}
		}

	## **WHETHER `edit` SUPERSEDES `original`**, the one rule of it: a later
	## message by the same author (the old `sameAuthor`; so a message never
	## supersedes itself, and no post hides another's).
	supersedes : { original : MessageCodec.Fields, edit : MessageCodec.Fields } -> Bool
	supersedes = |{ original, edit }| original.id < edit.id and original.by == edit.by

	## **WHICH OF `messages` ARE SUPERSEDED, AND BY WHICH EDIT**: one
	## topic's messages from `first` on, oldest first, each superseded by the
	## last later message of its author's that edits it (`supersedes`). One
	## pass: only a body that starts "Edit of MSG_" is read, and its original
	## is found by its place (`id - first`), never searched for.
	Supersession : { first : U64, by : List(U64) }

	superseded : MessageRef.Where, List(MessageCodec.Fields) -> Edits.Supersession
	superseded = |at, messages| {
		first = messages.first().map_ok(|m| m.id) ?? 1
		by = messages.fold(
			List.repeat(0, messages.len()),
			|marks, m|
				match Edits.target(at, m.body) {
					Ok(t) if t >= first =>
						match messages.get(t - first) {
							Ok(original) if Edits.supersedes({
								original,
								edit: m,
							}) => marks.set(
								t - first,
								m.id,
							) ?? crash "Edits.superseded: an original found by its place is in the list"
							_ => marks
						}
					_ => marks
				},
		)
		{ first, by }
	}

	## **THE EDIT THAT SUPERSEDES MESSAGE `n`**, among those `superseded`
	## found, or none.
	edit_of : Edits.Supersession, U64 -> [NotEdited, EditedIn(U64)]
	edit_of = |{ first, by }, n|
		if n < first {
			NotEdited
		} else {
			match by.get(n - first) {
				Ok(e) if e != 0 => EditedIn(e)
				_ => NotEdited
			}
		}

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

## What an edit starts with.
lead : List(U8)
lead = "Edit of MSG_".to_utf8()

## **THE LONGEST REFERENCE**: `MSG_`, a channel's name (at most 40), `.`,
## a topic's (at most 80), `_` and a message's number (at most 19 digits).
ref_most : U64
ref_most = 4 + 40 + 1 + 80 + 1 + 19

## The reference's run: the bytes a reference can hold (a name's letters,
## digits and `-`, the `.` between the names, the `_` before the number).
token_len : List(U8), U64 -> U64
token_len = |s, i|
	if i > ref_most {
		i
	} else {
		match s.get(i) {
			Ok(c) if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-' => token_len(
				s,
				i + 1,
			)
			_ => i
		}
	}

## **THE LONGEST REFERENCE `run` STARTS WITH**, as the old pattern's
## greedy match found it: the whole run, or else its longest start that ends
## at a number followed by a `.` or a `-`.
longest : MessageRef.Where, List(U8) -> Try(U64, [NotAnEdit])
longest = |at, run|
	match in_this(at, run) {
		Ok(n) => Ok(n)
		Err(NotAnEdit) =>
			match cut(run, run.len()) {
				Ok(start) => longest(at, start)
				Err(NotAnEdit) => Err(NotAnEdit)
			}
	}

## A reference to a message of `where`'s (MessageRef.number_in).
in_this : MessageRef.Where, List(U8) -> Try(U64, [NotAnEdit])
in_this = |place, bytes|
	match Str.from_utf8(bytes) {
		Ok(text) => MessageRef.number_in(place, text).map_err(|_| NotAnEdit)
		Err(_) => Err(NotAnEdit)
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
at_of : Str, Str -> MessageRef.Where
at_of = |c, t| InTopic((MessageRef.from_str("MSG_${c}.${t}_1") ?? crash "a test's names are names").at())

## Conversation `n`'s place, in a test.
conv_of : U64 -> MessageRef.Where
conv_of = |n| InConversation(ConvAccess.ConvId.from_u64(n) ?? crash "conv_of: a test's id is not 0")

# A conversation's edit: its own reference, ended as the old `\b` ended
# it; another conversation's, or a topic's, is no edit.
expect Edits.target(conv_of(4), "Edit of MSG_4_3\n\nfixed".to_utf8()) == Ok(3)
expect Edits.target(conv_of(4), "Edit of MSG_4_3. Typo".to_utf8()) == Ok(3)
expect Edits.target(conv_of(4), "Edit of MSG_4_3x".to_utf8()) == Err(NotAnEdit)
expect Edits.target(conv_of(4), "Edit of MSG_5_3".to_utf8()) == Err(NotAnEdit)
expect Edits.target(conv_of(4), "Edit of MSG_Chat_3".to_utf8()) == Err(NotAnEdit)
expect Edits.target(at_of("Lobby", "Chat"), "Edit of MSG_4_3".to_utf8()) == Err(NotAnEdit)
expect {
	found = Edits.superseded(
		conv_of(4),
		[
			{ id: 1, at: 0, by: Cast.ann.id(), body: "hi".to_utf8() },
			{ id: 2, at: 0, by: Cast.ann.id(), body: "Edit of MSG_4_1\n\nhello".to_utf8() },
		],
	)
	Edits.edit_of(found, 1) == EditedIn(2) and Edits.edit_of(found, 2) == NotEdited
}

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
	found = Edits.superseded(at, msgs)
	[
		1,
		2,
		3,
		4,
		5,
	].map(|n| Edits.edit_of(found, n)) == [
		EditedIn(4),
		NotEdited,
		NotEdited,
		NotEdited,
		NotEdited,
	]
}

## A message of a test: its number, its author (Ann, or the boss), its body.
said : {
	id : U64,
	boss : Bool,
	body : Str,
} -> MessageCodec.Fields
said = |
	{
		id,
		boss,
		body,
	},
| {
	id,
	at: 0,
	by: if (boss) Cast.boss.id() else Cast.ann.id(),
	body: body.to_utf8(),
}

# A message never supersedes itself: "Edit of …_5" posted as 5.
expect {
	at = at_of("Lobby", "Chat")
	found = Edits.superseded(
		at,
		[
			said({
				id: 5,
				boss: Bool.False,
				body: "Edit of MSG_Lobby.Chat_5",
			}),
		],
	)
	Edits.edit_of(found, 5) == NotEdited
}
# An edit of an edit: both are superseded, each by its own.
expect {
	at = at_of("Lobby", "Chat")
	found = Edits.superseded(
		at,
		[
			said({
				id: 1,
				boss: Bool.False,
				body: "hi",
			}),
			said({
				id: 2,
				boss: Bool.False,
				body: "Edit of MSG_Lobby.Chat_1\n\nhello",
			}),
			said({
				id: 3,
				boss: Bool.False,
				body: "Edit of MSG_Lobby.Chat_2\n\nhello!",
			}),
		],
	)
	[
		1,
		2,
		3,
	].map(|n| Edits.edit_of(found, n)) == [
		EditedIn(2),
		EditedIn(3),
		NotEdited,
	]
}
# From a page's first on: an original before it is not among them, one in
# it is found by its place.
expect {
	at = at_of("Lobby", "Chat")
	found = Edits.superseded(
		at,
		[
			said({
				id: 7,
				boss: Bool.True,
				body: "hi",
			}),
			said({
				id: 8,
				boss: Bool.True,
				body: "Edit of MSG_Lobby.Chat_3",
			}),
			said({
				id: 9,
				boss: Bool.True,
				body: "Edit of MSG_Lobby.Chat_7",
			}),
		],
	)
	[
		3,
		7,
		8,
		9,
	].map(|n| Edits.edit_of(found, n)) == [
		NotEdited,
		EditedIn(9),
		NotEdited,
		NotEdited,
	]
}
# A DM's edit, by its short reference or its full one.
expect {
	dm = at_of("dm-2-7", "ChitChat")
	Edits.target(dm, "Edit of MSG_ChitChat_3\n\nx".to_utf8()) == Ok(3)
		and Edits.target(dm, "Edit of MSG_dm-2-7.ChitChat_3".to_utf8()) == Ok(3)
		and Edits.target(dm, "Edit of MSG_dm-2-8.ChitChat_3".to_utf8()) == Err(NotAnEdit)
}
# A crafted body of 64 KB costs what a reference does: refused, or read to
# its longest start, never parsed once per `-`.
dashes : List(U8)
dashes = List.join(List.repeat("1-".to_utf8(), 32768))

expect Edits.target(
	at_of("Lobby", "Chat"),
	"Edit of MSG_1".to_utf8().concat(dashes),
) == Err(NotAnEdit)
expect Edits.target(
	at_of("Lobby", "Chat"),
	"Edit of MSG_Chat_3-".to_utf8().concat(List.repeat('a', 65536)),
) == Ok(3)

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
