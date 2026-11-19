## This module is a DM's pair: the ids of the two users in a DM, lowest
## first. A DM's folder and URL are named by its pair's spelling, `9_10`,
## never `10_9`. A user's DM with themself is the pair `5_5`.
##
## Only `of`, which sorts its two ids, and `from_str`, which reads only the
## spellings `to_str` writes, make a pair, so every pair is in order.
import UserId

UserPair :: { low : UserId, high : UserId }.{

	## The pair of `one` and `other`, given in either order.
	of : { one : UserId, other : UserId } -> UserPair
	of = |{ one, other }|
		match UserId.compare(one, other) {
			After => UserPair.({ low: other, high: one })
			_ => UserPair.({ low: one, high: other })
		}

	## The pair `text` spells, or `NotAUserPair`. A pair is spelled as
	## `to_str` writes it: two ids (`UserId.from_str`), lowest first, joined
	## by one `_`.
	from_str : Str -> Try(UserPair, [NotAUserPair])
	from_str = |text|
		match text.split_on("_") {
			[first, second] =>
				match (UserId.from_str(first), UserId.from_str(second)) {
					(
						Ok(low),
						Ok(high),
					) if UserId.compare(low, high) != After => Ok(UserPair.({ low, high }))
					_ => Err(NotAUserPair)
				}
			_ => Err(NotAUserPair)
		}

	## The pair's spelling, as a folder's name and a URL take it: the ids,
	## lowest first, joined by `_`.
	to_str : UserPair -> Str
	to_str = |UserPair.({ low, high })| "${low.to_str()}_${high.to_str()}"

	## The pair's users' ids, lowest first: two, or one for a user's DM with
	## themself.
	members : UserPair -> List(UserId)
	members = |UserPair.({ low, high })|
		if low == high {
			[low]
		} else {
			[low, high]
		}

	is_eq : _
	to_hash : _
}

# ── tests
## The id `text` spells, which a test's text always does.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "UserPair's tests: a test's id is an id"

## The pair of the ids `one` and `other` spell.
pair_of : { one : Str, other : Str } -> UserPair
pair_of = |{ one, other }| UserPair.of({ one: id_of(one), other: id_of(other) })

# Either order makes one pair, lowest first, by number rather than by text.
expect pair_of({ one: "1", other: "2" }).to_str() == "1_2"
expect pair_of({ one: "2", other: "1" }).to_str() == "1_2"
expect pair_of({ one: "9", other: "10" }).to_str() == "9_10"
expect pair_of({ one: "10", other: "9" }).to_str() == "9_10"
expect pair_of({ one: "10", other: "9" }) == pair_of({ one: "9", other: "10" })
expect pair_of({ one: "1", other: "2" }) != pair_of({ one: "1", other: "3" })
# A user's DM with themself: one id, written twice, one member.
expect pair_of({ one: "5", other: "5" }).to_str() == "5_5"
expect pair_of({ one: "5", other: "5" }).members() == [id_of("5")]
expect pair_of({ one: "11", other: "7" }).members() == [id_of("7"), id_of("11")]
# Read back from its spelling, at the ends of the ids' range.
expect
	[
		"9_10",
		"5_5",
		"1_2",
		"1_255",
		"255_255",
	].all(|text| UserPair.from_str(text).map_ok(UserPair.to_str) == Ok(text))
# Every other spelling refused: out of order, no id, a side missing, an
# id spelled another way, one `_` too many, or a space.
expect
	[
		"10_9",
		"2_1",
		"0_3",
		"3_0",
		"a_b",
		"3_",
		"_3",
		"3",
		"",
		"_",
		"3_4_5",
		"3__4",
		"03_4",
		"3_04",
		"1_65536",
		" 1_2",
		"1_2 ",
		"1-2",
	].all(|text| UserPair.from_str(text) == Err(NotAUserPair))
# Equal pairs are one key of a set.
expect {
	pairs = Set.empty().insert(
		pair_of({ one: "2", other: "1" }),
	).insert(pair_of({ one: "1", other: "2" }))
	pairs.len() == 1
}
