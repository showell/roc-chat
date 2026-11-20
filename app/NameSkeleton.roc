## This module is a name's skeleton: what is left of it once everything that
## lets one name pass for another is folded away. A new human's name is
## refused when its skeleton is another name's (`Directory`), so no one signs
## up as `Steve HoweII` beside `Steve Howell`, or as `rnod` beside `mod`.
##
## The skeleton of a name is made in this order:
##
## - its letters case-folded, and each accented letter written as the plain
##   letters it is written on (`NameAlphabet.plain_folded`): `Zoë` is `zoe`;
## - its separators dropped, the spaces a name holds and the `-` a strict
##   name holds: `Roc Chat` and `roc-chat` are both `rocchat`;
## - the digits and letters that look alike made one: `0` is `o`, and `1`
##   and `i` are `l`;
## - then each letter that looks like two written as those two: `m` is
##   `rn`, `w` is `vv`, and `d` is `cl`. Expanding, rather than collapsing
##   pairs, brings every spelling to one form: `vw`, `wv` and `vvv` are all
##   `vvv`, where a left-to-right collapse would leave `vw` apart.
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
	is_reserved = |skeleton|
		NameSkeleton.reserved_words.any(|word| NameSkeleton.of_word(word) == skeleton)

	## The words no new human's name may hold anywhere, as any one of its
	## words (Steve, 2026-11-20: "Admin is clearly off limits"): `Chat
	## Admin` and `Bob the Sysadmin` are refused, where the other reserved
	## words only refuse a whole name, so `Help` is refused and `Helen Help`
	## is not.
	admin_words : List(Str)
	admin_words = [
		"admin",
		"admins",
		"administrator",
		"administrators",
		"sysadmin",
		"sysadmins",
	]

	## Whether `name` may not be a new human's: its skeleton is a reserved
	## word's (`is_reserved`) or an admin word's, or one of its words'
	## skeleton is an admin word's, a word being what lies between its
	## spaces.
	is_reserved_name : Name -> Bool
	is_reserved_name = |name| {
		admin_skeletons = NameSkeleton.admin_words.map(NameSkeleton.of_word)
		name_words = name.plain_folded().split_on(" ")
		whole = NameSkeleton.of_name(name)
		whole.is_reserved()
			or admin_skeletons.contains(whole)
			or name_words.any(|word| admin_skeletons.contains(of_plain(word)))
	}

	## The skeleton's text, for the tests.
	to_str : NameSkeleton -> Str
	to_str = |NameSkeleton.(text)| text

	is_eq : _
	to_hash : _
}

## The skeleton of `text`, ASCII already lowercased: its separators dropped,
## then its lookalike characters folded, then its two-looking letters
## expanded.
of_plain : Str -> NameSkeleton
of_plain = |text| {
	singles =
		text.to_utf8()
			.drop_if(|byte| byte == ' ' or byte == '-')
			.map(fold_single)
	folded = singles.join_map(expand_double)
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

## The letters `byte` looks like: `m` is `rn`, `w` is `vv`, `d` is `cl`;
## any other is itself.
expand_double : U8 -> List(U8)
expand_double = |byte|
	if byte == 'm' {
		['r', 'n']
	} else if byte == 'w' {
		['v', 'v']
	} else if byte == 'd' {
		['c', 'l']
	} else {
		[byte]
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
expect skeleton_of("Steve Howell") == "stevehovvell"
expect skeleton_of("sTeVe HoWeLL") == skeleton_of("Steve Howell")
expect skeleton_of("Stéve Hówell") == skeleton_of("Steve Howell")
expect skeleton_of("Zoë") == "zoe"
expect skeleton_of("SteveHowell") == skeleton_of("Steve Howell")
# `i` and `l` look alike, and so do `rn` and `m`, `vv` and `w`, and `cl`
# and `d`.
expect skeleton_of("Iris") == skeleton_of("Lrls")
expect skeleton_of("Steve HoweII") == skeleton_of("Steve Howell")
expect skeleton_of("rnod") == skeleton_of("mod")
expect skeleton_of("Vvalt") == skeleton_of("Walt")
expect skeleton_of("Clara") == skeleton_of("Dara")
expect skeleton_of("Ivy") == "lvy"
# Every spelling of a run reaches one form: `vw`, `wv` and `vvv` are one,
# and so are `rnm`, `mrn` and `rnrn`.
expect skeleton_of("vw") == skeleton_of("vvv")
expect skeleton_of("wv") == skeleton_of("vvv")
expect skeleton_of("vvv") == "vvv"
expect skeleton_of("rnm") == skeleton_of("mrn") and skeleton_of("mrn") == skeleton_of("rnrn")
expect skeleton_of("Mm") == "rnrn"
# A space between a pair's letters still makes it one: separators go first.
expect skeleton_of("r n") == skeleton_of("M")
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
	[
		"Admin",
		"ADMINISTRATOR",
		"root",
		"System",
		"Support",
		"help",
		"Owner",
		"Moderator",
		"Mod",
		"Staff",
		"Security",
		"Roc Chat",
		"rocchat",
		"CC",
		"lc",
		"Adrnln",
		"Rnod",
		"Sec urity",
		"Ic",
	]
		.all(|text| NameSkeleton.of_name(Name.from_str(text) ?? crash "NameSkeleton's tests: a name").is_reserved())
expect
	["Admins", "Rooted", "Helper", "Modesto", "Steve", "Zoe", "C"]
		.all(|text| !NameSkeleton.of_name(Name.from_str(text) ?? crash "NameSkeleton's tests: a name").is_reserved())
# An admin word anywhere in a name, as any one of its words, refuses it; the
# other reserved words refuse only a whole name. (A name holds no digit, so
# `Adm1n` is no name at all: `Name.from_str` refuses it.)
expect
	["Chat Admin", "Chat AdmIn", "Bob the Sysadmin", "Site Administrator", "AD MINS", "Zoe Adrnin"]
		.all(|text| NameSkeleton.is_reserved_name(Name.from_str(text) ?? crash "NameSkeleton's tests: a name"))
expect
	["Steve", "Howell", "Steve Howell", "Helen Help", "Badminton", "Admiral", "Ad Minh"]
		.all(|text| !NameSkeleton.is_reserved_name(Name.from_str(text) ?? crash "NameSkeleton's tests: a name"))
expect NameSkeleton.is_reserved_name(Name.from_str("Root") ?? crash "NameSkeleton's tests: a name")
