## **A CHANNEL'S NAME** (production's rule, which roc-webbox's chat ported
## as `ChannelName`): a letter, then letters, digits and hyphens, 1 to 40
## bytes, all ASCII. Opaque, so a name that passed is the only kind there
## is, and every path built from one (ChannelLayout) is built from a name
## the rule took.
##
## **TWO NAMES ARE ONE CHANNEL WHEN THEY DIFFER ONLY IN CASE**: `==` is
## ASCII-caseless, so `Cobblestone` and `cobblestone` name the same
## channel, wherever names are compared (a list's `contains`, a record's
## `==`). The name keeps the spelling it was made with, for display, and
## its `key` (lowercase) is the one spelling a path uses. Pure.
import Ascii

ChannelName :: Str.{

	## The name `text` is, when the rule takes it.
	from_str : Str -> Try(ChannelName, [NotAChannelName])
	from_str = |text|
		match text.to_utf8() {
			[first, .. as more] =>
				if text.count_utf8_bytes() <= max_bytes and Ascii.is_letter(first) and more.all(|c| Ascii.is_alphanumeric(c) or c == '-') {
					Ok(ChannelName.(text))
				} else {
					Err(NotAChannelName)
				}
			[] => Err(NotAChannelName)
		}

	## The name as it was made, for display and URLs.
	to_str : ChannelName -> Str
	to_str = |ChannelName.(name)| name

	## **THE ONE SPELLING OF THE CHANNEL**: its name in lowercase, the same
	## for every name `==` to it, and what a path names (ChannelLayout).
	key : ChannelName -> Str
	key = |ChannelName.(name)| lowercase(name)

	## **A PAIR OF HUMANS' DM** (Steve, 2026-11-02: almost a channel built
	## in for every pair, the same machinery and layout): `<lower id>_<higher
	## id>`, the ids in NUMBER order (`7_11`, never `11_7`), one name for the
	## pair whichever of them asks; `5_5` is human 5's self-DM. Ids are no
	## secret (Steve's call). The rule above never takes one (a channel's
	## name starts with a letter and holds no `_`), so no channel is ever
	## named as a DM.
	dm_of : U64, U64 -> ChannelName
	dm_of = |a, b| {
		(lo, hi) = if (a <= b) (a, b) else (b, a)
		ChannelName.("${lo.to_str()}_${hi.to_str()}")
	}

	## **THE DM A PATH OR A RECORD NAMES**: exactly the name `dm_of` gives
	## its pair (each id a number with no leading zero, never 0, the lower
	## first), so `11_7`, `07_11` and `7_011` name no DM.
	dm_from : Str -> Try(ChannelName, [NotADm])
	dm_from = |text| {
		pair = ChannelName.dm_pair(ChannelName.(text))?
		if (ChannelName.dm_of(pair.lo, pair.hi).to_str() == text) Ok(ChannelName.(text)) else Err(NotADm)
	}

	## **THE PAIR A DM'S NAME IS**, its lower id first; a channel's name is
	## no pair.
	dm_pair : ChannelName -> Try({ lo : U64, hi : U64 }, [NotADm])
	dm_pair = |ChannelName.(name)|
		match name.to_utf8().split_on('_') {
			[a, b] =>
				match (id_of(a), id_of(b)) {
					(Ok(lo), Ok(hi)) if lo <= hi => Ok({ lo, hi })
					_ => Err(NotADm)
				}
			_ => Err(NotADm)
		}

	## **A NAME AS STORED**: a channel's, by the rule, or a DM's, by
	## `dm_from`: what a record that names where it is reads back.
	from_stored : Str -> Try(ChannelName, [NotAChannelName])
	from_stored = |text|
		match ChannelName.from_str(text) {
			Ok(name) => Ok(name)
			Err(NotAChannelName) => ChannelName.dm_from(text).map_err(|_| NotAChannelName)
		}

	## Whether the name is a DM's.
	is_dm : ChannelName -> Bool
	is_dm = |name| ChannelName.dm_pair(name).is_ok()

	## Two names are one channel when they differ only in ASCII case.
	is_eq : ChannelName, ChannelName -> Bool
	is_eq = |ChannelName.(a), ChannelName.(b)| a.caseless_ascii_equals(b)
}

## The longest name, in bytes.
max_bytes : U64
max_bytes = 40

## An id as a DM's name writes it: digits, no leading zero, not 0.
id_of : List(U8) -> Try(U64, [NotADm])
id_of = |digits|
	match digits {
		[first, ..] if first >= '1' and first <= '9' and digits.all(|b| b >= '0' and b <= '9') =>
			U64.from_int_digits(digits.map(|b| b - '0')).map_err(|_| NotADm)
		_ => Err(NotADm)
	}

## ASCII's lowercase of a name the rule took (ASCII alone).
lowercase : Str -> Str
lowercase = |name|
	match Str.from_utf8(name.to_utf8().map(Ascii.to_lowercase)) {
		Ok(lower) => lower
		Err(_) => crash "ChannelName.lowercase: ASCII lowercased is UTF-8"
	}

# ── tests
## The name `text` is, in a test where the rule takes it.
named : Str -> ChannelName
named = |text|
	match ChannelName.from_str(text) {
		Ok(name) => name
		Err(NotAChannelName) => crash "named: a test's channel name is one"
	}

# The rule: a letter, then letters, digits and hyphens, 1 to 40 bytes.
expect ChannelName.from_str("general").is_ok()
# Production's two channels, made by hand: the rule must take them.
expect ChannelName.from_str("Cobblestone").is_ok()
expect ChannelName.from_str("General").is_ok()
expect ChannelName.from_str("a-1-").is_ok()
expect ChannelName.from_str("a--b").is_ok()
expect ChannelName.from_str(Str.repeat("a", 40)).is_ok()
expect ChannelName.from_str(Str.repeat("a", 41)) == Err(NotAChannelName)
expect ChannelName.from_str("") == Err(NotAChannelName)
expect ChannelName.from_str("1abc") == Err(NotAChannelName)
expect ChannelName.from_str("-abc") == Err(NotAChannelName)
expect ChannelName.from_str("..") == Err(NotAChannelName)
expect ChannelName.from_str("a/b") == Err(NotAChannelName)
expect ChannelName.from_str("a.b") == Err(NotAChannelName)
expect ChannelName.from_str("a_b") == Err(NotAChannelName)
expect ChannelName.from_str("a b") == Err(NotAChannelName)
expect ChannelName.from_str("caf\u(e9)") == Err(NotAChannelName)
expect ChannelName.from_str("\u(c9)cole") == Err(NotAChannelName)

# Case: one channel, its spelling kept, one key.
expect named("Cobblestone") == named("cOBBLESTONE")
expect named("Cobblestone") != named("Cobblestones")
expect named("Cobblestone").to_str() == "Cobblestone"
expect named("Cobblestone").key() == "cobblestone"
expect named("cOBBLE-stone-9").key() == named("Cobble-Stone-9").key()
expect [named("General")].contains(named("general"))

# A DM's name: the ids in NUMBER order, whichever asks; 7 before 11.
expect ChannelName.dm_of(11, 7).to_str() == "7_11" and ChannelName.dm_of(7, 11).to_str() == "7_11"
expect ChannelName.dm_of(2, 7) == ChannelName.dm_of(7, 2) and ChannelName.dm_of(5, 5).to_str() == "5_5"
expect ChannelName.dm_of(7, 11).is_dm() and ChannelName.dm_pair(ChannelName.dm_of(11, 7)) == Ok({ lo: 7, hi: 11 })
expect !named("Lobby").is_dm() and !named("dm-2-7").is_dm() and named("Lobby").dm_pair() == Err(NotADm)
# Read back: only the one spelling of a pair.
expect ChannelName.dm_from("7_11") == Ok(ChannelName.dm_of(7, 11)) and ChannelName.dm_from("5_5").is_ok()
expect
	[
		"11_7",
		"07_11",
		"7_011",
		"0_1",
		"7_",
		"_7",
		"7_11_12",
		"7-11",
		"a_1",
		"7_1a",
		"+7_11",
		"",
		"99999999999999999999_99999999999999999999",
	].all(|text| ChannelName.dm_from(text) == Err(NotADm))
# No channel is ever named as a DM: the rule refuses every `<number>_<number>`.
expect ["7_11", "5_5", "1_2"].all(|text| ChannelName.from_str(text) == Err(NotAChannelName))
# As stored: a channel's name or a DM's; anything else neither.
expect ChannelName.from_stored("Lobby") == Ok(named("Lobby")) and ChannelName.from_stored("7_11") == Ok(ChannelName.dm_of(7, 11))
expect ChannelName.from_stored("11_7") == Err(NotAChannelName) and ChannelName.from_stored("a_b") == Err(NotAChannelName)
