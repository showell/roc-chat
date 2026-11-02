## **A DM'S PAIR**: two users' ids in numeric order, the one home of that
## spelling, which a DM's folder and URL take: `9_10`, never `10_9`, and
## one user alone, in their own DM, `5_5`. Opaque, so its doors keep the
## order: `of` sorts two ids, and `from_str` reads only the spellings
## `to_str` writes. A pair's spelling starts with a digit and holds a `_`,
## and a strict name never does (`StrictName`), so no pair's is a
## channel's.
import UserId

UserPair :: { low : UserId, high : UserId }.{

	## The pair of `a` and `b`, in either order, lowest first; one user
	## alone, if they are the same.
	of : { a : UserId, b : UserId } -> UserPair
	of = |{ a, b }|
		match a.compare(b) {
			After => UserPair.({ low: b, high: a })
			_ => UserPair.({ low: a, high: b })
		}

	## The pair `text` spells, as `to_str` writes it: two ids
	## (`UserId.from_str`), lowest first, joined by one `_`; unless it spells
	## none.
	from_str : Str -> Try(UserPair, [NotAUserPair])
	from_str = |text|
		match text.split_on("_") {
			[first, second] =>
				match (UserId.from_str(first), UserId.from_str(second)) {
					(
						Ok(low),
						Ok(high),
					) if low.compare(high) != After => Ok(UserPair.({ low, high }))
					_ => Err(NotAUserPair)
				}
			_ => Err(NotAUserPair)
		}

	## **ITS SPELLING**, as a folder's name and a URL take it: the ids,
	## lowest first, joined by `_`.
	to_str : UserPair -> Str
	to_str = |UserPair.({ low, high })| "${low.to_str()}_${high.to_str()}"

	## Its users' ids, lowest first: two, or one for one user alone.
	members : UserPair -> List(UserId)
	members = |UserPair.({ low, high })| if (low == high) [low] else [low, high]

	is_eq : _
	to_hash : _
}

# ── tests
## The id `text` spells, which a test's always does.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "UserPair's tests: a test's id is an id"

## The spelling of the pair of `a` and `b`.
spelled : Str, Str -> Str
spelled = |a, b| UserPair.of({ a: id_of(a), b: id_of(b) }).to_str()

# Either order, one pair, lowest first; numeric, not the text's order.
expect [spelled("1", "2"), spelled("2", "1")] == ["1_2", "1_2"]
expect [spelled("9", "10"), spelled("10", "9")] == ["9_10", "9_10"]
expect UserPair.of({
	a: id_of("10"),
	b: id_of("9"),
}) == UserPair.of({ a: id_of("9"), b: id_of("10") })
expect UserPair.of({
	a: id_of("1"),
	b: id_of("2"),
}) != UserPair.of({ a: id_of("1"), b: id_of("3") })
# One user alone: their own pair, one member.
expect spelled("5", "5") == "5_5"
expect UserPair.of({ a: id_of("5"), b: id_of("5") }).members() == [id_of("5")]
expect UserPair.of({ a: id_of("11"), b: id_of("7") }).members() == [id_of("7"), id_of("11")]
# Read back from its spelling, at the ends of the ids' range.
expect
	[
		"9_10",
		"5_5",
		"1_2",
		"1_255",
		"255_255",
	].map(|text| UserPair.from_str(text).map_ok(UserPair.to_str))
		== [
			Ok("9_10"),
			Ok("5_5"),
			Ok("1_2"),
			Ok("1_255"),
			Ok("255_255"),
		]
# Every other spelling refused: out of order, no id, a side missing, an
# id spelled another way, one `_` too many or a space.
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
		"1_256",
		" 1_2",
		"1_2 ",
		"1-2",
	].map(UserPair.from_str)
		== List.repeat(Err(NotAUserPair), 18)
# A pair keys a set: equal pairs are one.
expect Set.empty().insert(
	UserPair.of({
		a: id_of("2"),
		b: id_of("1"),
	}),
).insert(UserPair.of({ a: id_of("1"), b: id_of("2") })).len() == 1
