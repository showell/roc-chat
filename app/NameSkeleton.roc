## This module is a name's skeleton: what is left of it once everything that
## lets one name pass for another is folded away. A new human's name is
## refused when its skeleton is another name's (`Directory`), so no one signs
## up as `Steve Howel1` beside `Steve Howell`, or as `rnod` beside `mod`.
##
## The skeleton of a name is made in this order:
##
## - its letters case-folded, and each accented letter written as the plain
##   letters it is written on (`NameAlphabet.plain_folded`): `Zoë` is `zoe`;
## - its separators dropped, the spaces a name holds and the `-` a strict
##   name holds: `Roc Chat` and `roc-chat` are both `rocchat`;
## - the digits and letters that look alike made one: `0` is `o`, and `1`
##   and `i` are `l`;
## - then the pairs that look like one letter made it, left to right: `rn`
##   is `m`, and `vv` is `w`.
##
## A skeleton is never shown and never stored: it is worked out from the
## names at each check, so existing names are never touched.
import ChannelName
import Name

NameSkeleton :: Str.{

	## The skeleton of the name `name`.
	of_name : Name -> NameSkeleton
	of_name = |name| of_plain(name.plain_folded())

	## The skeleton of the channel's name `name`, a strict name's ASCII.
	of_channel : ChannelName -> NameSkeleton
	of_channel = |name| of_plain(name.to_str().with_ascii_lowercased())

	## The skeleton of a reserved word, as `reserved_words` spells them.
	of_word : Str -> NameSkeleton
	of_word = |word| of_plain(word.with_ascii_lowercased())

	## The words no new human may be named after, nor anything that looks
	## like one: the chat's roles, its own name, and its agents' names. The
	## chat's owner and every agent are also kept out by `Directory`, as
	## existing names.
	reserved_words : List(Str)
	reserved_words = [
		"admin",
		"administrator",
		"root",
		"system",
		"support",
		"help",
		"owner",
		"moderator",
		"mod",
		"staff",
		"security",
		"roc-chat",
		"CC",
		"LC",
	]

	## Whether `skeleton` is a reserved word's skeleton.
	is_reserved : NameSkeleton -> Bool
	is_reserved = |skeleton| NameSkeleton.reserved_words.any(|word| NameSkeleton.of_word(word) == skeleton)

	## The skeleton's text, for the tests.
	to_str : NameSkeleton -> Str
	to_str = |NameSkeleton.(text)| text

	is_eq : _
	to_hash : _
}

## The skeleton of `text`, ASCII already lowercased: its separators dropped,
## then its lookalike characters, then its lookalike pairs, folded.
of_plain : Str -> NameSkeleton
of_plain = |text| {
	singles =
		text.to_utf8()
			.drop_if(|byte| byte == ' ' or byte == '-')
			.map(fold_single)
	folded = fold_pairs({ out: [], bytes: singles })
	NameSkeleton.(Str.from_utf8(folded) ?? crash "NameSkeleton.of_plain: ASCII folds to ASCII")
}

## The one character `byte` looks like: `0` is `o`; `1` and `i` are `l`.
fold_single : U8 -> U8
fold_single = |byte|
	if byte == '0' {
		'o'
	} else if byte == '1' or byte == 'i' {
		'l'
	} else {
		byte
	}

## `out` with `bytes` appended, `rn` as `m` and `vv` as `w`, left to right.
fold_pairs : { out : List(U8), bytes : List(U8) } -> List(U8)
fold_pairs = |{ out, bytes }|
	match bytes {
		[] => out
		[first, second, .. as rest] if first == 'r' and second == 'n' =>
			fold_pairs({ out: out.append('m'), bytes: rest })
		[first, second, .. as rest] if first == 'v' and second == 'v' =>
			fold_pairs({ out: out.append('w'), bytes: rest })
		[byte, .. as rest] => fold_pairs({ out: out.append(byte), bytes: rest })
	}

# ── tests
## The skeleton of the name `text`, which a test's text always is.
skeleton_of : Str -> Str
skeleton_of = |text|
	NameSkeleton.of_name(Name.from_str(text) ?? crash "NameSkeleton's tests: a name").to_str()

## The skeleton of the channel's name `text`, which a test's text always is.
channel_skeleton_of : Str -> Str
channel_skeleton_of = |text|
	NameSkeleton.of_channel(ChannelName.from_str(text) ?? crash "NameSkeleton's tests: a channel's name").to_str()

# Case, accents and spaces fold away.
expect skeleton_of("Steve Howell") == "stevehowell"
expect skeleton_of("sTeVe HoWeLL") == skeleton_of("Steve Howell")
expect skeleton_of("Stéve Hówell") == skeleton_of("Steve Howell")
expect skeleton_of("Zoë") == "zoe"
expect skeleton_of("SteveHowell") == skeleton_of("Steve Howell")
# `i` and `l` look alike, and so do `rn` and `m`, and `vv` and `w`.
expect skeleton_of("Iris") == skeleton_of("Lrls")
expect skeleton_of("Steve HoweII") == skeleton_of("Steve Howell")
expect skeleton_of("rnod") == skeleton_of("mod")
expect skeleton_of("Vvalt") == skeleton_of("Walt")
expect skeleton_of("Ivy") == "lvy"
# A pair is folded once, left to right: `rnn` is `mn`, `vvv` is `wv`.
expect skeleton_of("rnn") == "mn"
expect skeleton_of("vvv") == "wv"
# A space between the pair's letters still makes it one: separators go
# first.
expect skeleton_of("r n") == "m"
# A strict name's digits and `-` fold too: `0` is `o`, `1` is `l`, and `-`
# is dropped.
expect channel_skeleton_of("r00t") == "root"
expect channel_skeleton_of("Roc-Chat") == "rocchat"
expect channel_skeleton_of("he1p") == skeleton_of("Help")
expect channel_skeleton_of("plans-2") == "plans2"
# Names that only look different keep different skeletons.
expect skeleton_of("Steve Howell") != skeleton_of("Steve Howel")
expect skeleton_of("Bob") != skeleton_of("Rob")
expect skeleton_of("Mia") != skeleton_of("Ria")
# Reserved: every word, in any case, with lookalikes and separators.
expect
	["Admin", "ADMINISTRATOR", "root", "System", "Support", "help", "Owner", "Moderator", "Mod", "Staff", "Security", "Roc Chat", "rocchat", "CC", "lc", "Adrnln", "Rnod", "Sec urity", "Ic"]
		.all(|text| NameSkeleton.of_name(Name.from_str(text) ?? crash "NameSkeleton's tests: a name").is_reserved())
expect
	["Admins", "Rooted", "Helper", "Modesto", "Steve", "Zoe", "C"]
		.all(|text| !NameSkeleton.of_name(Name.from_str(text) ?? crash "NameSkeleton's tests: a name").is_reserved())
