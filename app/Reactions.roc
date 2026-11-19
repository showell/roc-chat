## A conversation's reactions: which user reacted to which of its messages
## with which emoji. A reaction is not a message. Only the current set is
## kept, with no history: a user reacts with an emoji once, and taking it
## back removes it. Two users may react with one emoji, and one user with
## several.
##
## The set is kept beside the conversation's transcript, in its own file
## (`TranscriptFiles`), one reaction a line, as JSON, in the order the
## reactions were made:
##
##     {"msg":3,"uid":1,"emoji":"👍"}
##
## The file is rewritten whole at each change. An emoji is 1 to 16 bytes of
## UTF-8 holding no ASCII byte (`Emoji`), so it never needs JSON's escapes,
## and `from_file` reads exactly what `to_file` writes, refusing any other
## line.
import Message
import UserId

Reactions :: List(Reactions.Reaction).{

	## An emoji, as a reaction names it: 1 to 16 bytes, none of them ASCII.
	## Every emoji's code points are past ASCII, and so are the variation
	## selector and the joiner, so this takes any emoji the picker offers and
	## refuses a word, a digit, a space, a quote or a control. Which emojis
	## the picker offers is the script's to say.
	Emoji :: Str.{

		## The emoji `text` is, or `NotAnEmoji`.
		from_str : Str -> Try(Reactions.Emoji, [NotAnEmoji])
		from_str = |text| {
			bytes = text.to_utf8()
			if bytes.is_empty() or bytes.len() > most_emoji_bytes or bytes.any(|byte| byte < 128) {
				Err(NotAnEmoji)
			} else {
				Ok(Reactions.Emoji.(text))
			}
		}

		## The emoji, as written.
		to_str : Reactions.Emoji -> Str
		to_str = |Reactions.Emoji.(text)| text

		is_eq : _
	}

	## One reaction: a user's emoji on a message.
	Reaction : { message : Message.Id, user : UserId, emoji : Reactions.Emoji }

	## One emoji's reactions to one message, as a page shows them: the emoji
	## and who reacted with it, in the order they did.
	Chip : { emoji : Reactions.Emoji, reactors : List(UserId) }

	## The most reactions a conversation holds, 10,000, so its file stays
	## small.
	most_reactions : U64
	most_reactions = 10_000

	## No reactions.
	empty : Reactions
	empty = Reactions.([])

	## The set with `reaction` in it (`On`) or out of it (`Off`). A reaction
	## already in, or already out, leaves the set as it was. A new reaction
	## past `most_reactions` is refused (`TooManyReactions`).
	set : Reactions,
	{ reaction : Reactions.Reaction, wanted : [On, Off] } -> Try(
		Reactions,
		[TooManyReactions],
	)
	set = |Reactions.(held), { reaction, wanted }|
		match wanted {
			Off => Ok(Reactions.(held.keep_if(|other| other != reaction)))
			On if held.contains(reaction) => Ok(Reactions.(held))
			On if held.len() >= Reactions.most_reactions => Err(TooManyReactions)
			On => Ok(Reactions.(held.append(reaction)))
		}

	## The reactions to `message`, an emoji a chip, each in the order it was
	## first used.
	chips : Reactions, Message.Id -> List(Reactions.Chip)
	chips = |Reactions.(held), message|
		held.keep_if(|reaction| reaction.message == message).fold(
			[],
			|so_far, reaction|
				match so_far.find_first_index(|chip| chip.emoji == reaction.emoji) {
					Ok(at) =>
						so_far.update(at, |chip| { ..chip, reactors: chip.reactors.append(reaction.user) })
							?? crash "Reactions.chips: the index was just found"
					Err(NotFound) => so_far.append({ emoji: reaction.emoji, reactors: [reaction.user] })
				},
		)

	## The file's bytes: each reaction a line, in order.
	to_file : Reactions -> List(U8)
	to_file = |Reactions.(held)| held.join_map(|reaction| "${line_of(reaction)}\n".to_utf8())

	## The reactions a file holds, as `to_file` writes them; unless a line is
	## anything else (`BadLine`), or holds a reaction an earlier line holds
	## (`RepeatedLine`), each naming the line's number.
	from_file : List(U8) -> Try(Reactions, [BadLine(U64), RepeatedLine(U64)])
	from_file = |bytes|
		match Str.from_utf8(bytes) {
			Err(_) => Err(BadLine(1))
			Ok(text) =>
				if text.is_empty() {
					Ok(Reactions.empty)
				} else if text.ends_with("\n") {
					read_lines({ held: [], lines: text.drop_suffix("\n").split_on("\n"), number: 1 })
				} else {
					Err(BadLine(text.split_on("\n").len()))
				}
		}

	is_eq : _
}

## The most bytes an emoji may be: an emoji, a joiner and another, or one
## with its variation selector, with room to spare, and no sentence.
most_emoji_bytes : U64
most_emoji_bytes = 16

## One reaction as its line writes it.
line_of : Reactions.Reaction -> Str
line_of = |{ message, user, emoji }|
	"{\"msg\":${message.to_str()},\"uid\":${user.to_str()},\"emoji\":\"${emoji.to_str()}\"}"

## `held` and the reactions `lines` hold, the first of them line `number`.
read_lines : {
	held : List(Reactions.Reaction),
	lines : List(Str),
	number : U64,
} -> Try(Reactions, [BadLine(U64), RepeatedLine(U64)])
read_lines = |{ held, lines, number }|
	match lines {
		[] => Ok(Reactions.(held))
		[first, .. as rest] => {
			reaction = reaction_of_line(first) ? |NotALine| BadLine(number)
			if held.contains(reaction) {
				Err(RepeatedLine(number))
			} else {
				read_lines({ held: held.append(reaction), lines: rest, number: number + 1 })
			}
		}
	}

## The reaction `line` holds, exactly as `line_of` writes it, or `NotALine`.
reaction_of_line : Str -> Try(Reactions.Reaction, [NotALine])
reaction_of_line = |line|
	if line.starts_with("{\"msg\":") and line.ends_with("\"}") {
		inner = line.drop_prefix("{\"msg\":").drop_suffix("\"}")
		match inner.split_on(",\"uid\":") {
			[message_digits, rest] =>
				match rest.split_on(",\"emoji\":\"") {
					[user_digits, emoji_text] => {
						message = Message.Id.from_digits(message_digits.to_utf8()) ? |_| NotALine
						user = UserId.from_str(user_digits) ? |_| NotALine
						emoji = Reactions.Emoji.from_str(emoji_text) ? |_| NotALine
						Ok({ message, user, emoji })
					}
					_ => Err(NotALine)
				}
			_ => Err(NotALine)
		}
	} else {
		Err(NotALine)
	}

# ── tests
## The emoji `text` is, which a test knows.
emoji_of : Str -> Reactions.Emoji
emoji_of = |text| Reactions.Emoji.from_str(text) ?? crash "Reactions' tests: an emoji"

## The message `number`, which a test knows is an id.
message_of : Str -> Message.Id
message_of = |number| Message.Id.from_digits(number.to_utf8()) ?? crash "Reactions' tests: a message's id"

## The user `number`, which a test knows is an id.
user_of : Str -> UserId
user_of = |number| UserId.from_str(number) ?? crash "Reactions' tests: a user's id"

## The reaction of user `user` to message `message` with `emoji`.
reaction_of : { message : Str, user : Str, emoji : Str } -> Reactions.Reaction
reaction_of = |{ message, user, emoji }| {
	message: message_of(message),
	user: user_of(user),
	emoji: emoji_of(emoji),
}

## `reactions` with each of `changes` made in turn, which a test knows fit.
after_changes : Reactions, List((Reactions.Reaction, [On, Off])) -> Reactions
after_changes = |reactions, changes|
	changes.fold(
		reactions,
		|so_far, (reaction, wanted)|
			so_far.set({ reaction, wanted }) ?? crash "Reactions' tests: a change fits",
	)

thumbs : Reactions.Reaction
thumbs = reaction_of({ message: "3", user: "1", emoji: "👍" })

## The chips of `message`, as a test reads them: each emoji and its reactors' ids.
chip_text : Reactions, Str -> List((Str, List(Str)))
chip_text = |reactions, message|
	reactions.chips(message_of(message)).map(
		|chip| (chip.emoji.to_str(), chip.reactors.map(UserId.to_str)),
	)

# An emoji: one, a joined one and one with its selector; and everything
# holding ASCII, nothing, or past 16 bytes refused.
expect ["👍", "🎉", "❤️", "👩‍💻", "é"].all(|text| Reactions.Emoji.from_str(text).map_ok(Reactions.Emoji.to_str) == Ok(text))
expect
	["", "+1", "👍 ", "a", "\"", "👍\n", "👍👍👍👍👍"].all(
		|text| Reactions.Emoji.from_str(text) == Err(NotAnEmoji),
	)
# 16 bytes is an emoji, 17 is not.
expect Reactions.Emoji.from_str("👍👍👍👍").map_ok(Reactions.Emoji.to_str) == Ok("👍👍👍👍")
expect Reactions.Emoji.from_str("👍👍👍👍é") == Err(NotAnEmoji)
# A reaction on, then on again, is one reaction; off takes it out, and off
# again changes nothing.
expect after_changes(Reactions.empty, [(thumbs, On)]).chips(message_of("3")).len() == 1
expect after_changes(Reactions.empty, [(thumbs, On), (thumbs, On)]) == after_changes(Reactions.empty, [(thumbs, On)])
expect after_changes(Reactions.empty, [(thumbs, On), (thumbs, Off)]) == Reactions.empty
expect after_changes(Reactions.empty, [(thumbs, Off)]) == Reactions.empty
# Two users with one emoji share a chip, in the order they reacted; one
# user's two emojis are two chips; another message's are its own.
expect {
	reactions = after_changes(
		Reactions.empty,
		[
			(reaction_of({ message: "3", user: "2", emoji: "🎉" }), On),
			(thumbs, On),
			(reaction_of({ message: "3", user: "2", emoji: "👍" }), On),
			(reaction_of({ message: "4", user: "1", emoji: "👍" }), On),
		],
	)
	chip_text(reactions, "3") == [("🎉", ["2"]), ("👍", ["1", "2"])]
		and chip_text(reactions, "4") == [("👍", ["1"])]
		and chip_text(reactions, "5") == []
}
# At the most a conversation holds, a new reaction is refused, and one
# already there, or one taken out, is not.
expect {
	full = Reactions.(
		List.from_iter(U64.to(1, Reactions.most_reactions)).map(
			|number| reaction_of({ message: "1", user: number.to_str(), emoji: "👍" }),
		),
	)
	one_less = full.set({ reaction: reaction_of({ message: "1", user: "1", emoji: "👍" }), wanted: Off })
	full.set({ reaction: thumbs, wanted: On }) == Err(TooManyReactions)
		and full.set({ reaction: reaction_of({ message: "1", user: "1", emoji: "👍" }), wanted: On }) == Ok(full)
		and one_less.map_ok(|fewer| fewer.set({ reaction: thumbs, wanted: On }).is_ok()) == Ok(Bool.True)
}
# The file: each reaction a line, read back as written; none is an empty file.
expect {
	reactions = after_changes(
		Reactions.empty,
		[(thumbs, On), (reaction_of({ message: "65535", user: "65535", emoji: "👩‍💻" }), On)],
	)
	written = "{\"msg\":3,\"uid\":1,\"emoji\":\"👍\"}\n{\"msg\":65535,\"uid\":65535,\"emoji\":\"👩‍💻\"}\n"
	reactions.to_file() == written.to_utf8() and Reactions.from_file(written.to_utf8()) == Ok(reactions)
}
expect Reactions.empty.to_file() == [] and Reactions.from_file([]) == Ok(Reactions.empty)
# Every other line refused, by its number.
expect
	[
		"{\"msg\":3,\"uid\":1,\"emoji\":\"👍\"}",
		"{\"msg\":3,\"uid\":1,\"emoji\":\"+1\"}\n",
		"{\"msg\":0,\"uid\":1,\"emoji\":\"👍\"}\n",
		"{\"msg\":3,\"uid\":01,\"emoji\":\"👍\"}\n",
		"{\"msg\":3, \"uid\":1,\"emoji\":\"👍\"}\n",
		"{\"uid\":1,\"msg\":3,\"emoji\":\"👍\"}\n",
		"{\"msg\":3,\"uid\":1,\"emoji\":\"👍\",\"on\":true}\n",
		"\n",
	].all(|text| Reactions.from_file(text.to_utf8()) == Err(BadLine(1)))
expect
	Reactions.from_file("{\"msg\":3,\"uid\":1,\"emoji\":\"👍\"}\nx\n".to_utf8()) == Err(BadLine(2))
expect
	Reactions.from_file("{\"msg\":3,\"uid\":1,\"emoji\":\"👍\"}\n{\"msg\":3,\"uid\":1,\"emoji\":\"👍\"}\n".to_utf8())
		== Err(RepeatedLine(2))
expect Reactions.from_file([0xFF, '\n']) == Err(BadLine(1))
