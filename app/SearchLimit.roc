## This module holds search's limit, as Gopher Chat's (angry-gopher's
## chat_search.zig, its limit of a second): at most `per_second_most` searches a
## second for each human, both of search's questions together, which the
## client's typing, a question after each pause, never meets. Each search
## is remembered in the server's memory, one key a slot (`slot_keys`),
## holding the second it was asked in; a restart forgets them. Past the
## limit a search is a 429.
import Timestamp
import UserId

SearchLimit :: [].{

	## The most searches one human asks in a second.
	per_second_most : U64
	per_second_most = 5

	## The keys the server's memory holds `human`'s searches' seconds under,
	## one a slot.
	slot_keys : UserId -> List(List(U8))
	slot_keys = |human|
		List.repeat({}, SearchLimit.per_second_most)
			.map_with_index(|{}, slot| "search/${human.to_str()}/${slot.to_str()}".to_utf8())

	## The slot a search at `now` takes, among `slots` in key order, each
	## the second its last search was asked in: the first that holds no
	## search of `now`'s second; else `TooFast`.
	slot_for_search : List([NeverUsed, UsedAt(Timestamp)]), Timestamp -> Try(U64, [TooFast])
	slot_for_search = |slots, now|
		match slots.find_first_index(|slot| is_free_at(slot, now)) {
			Ok(index) => Ok(index)
			Err(NotFound) => Err(TooFast)
		}
}

## Whether `slot` may take a search at `now`: one never used, or used in
## another second.
is_free_at : [NeverUsed, UsedAt(Timestamp)], Timestamp -> Bool
is_free_at = |slot, now|
	match slot {
		NeverUsed => Bool.True
		UsedAt(at) => at != now
	}

# ── tests
noon : Timestamp
noon = Timestamp.at_second(1_000_000)

a_second_on : Timestamp
a_second_on = Timestamp.at_second(1_000_001)

expect SearchLimit.slot_keys(UserId.chat_owner).len() == 5
expect SearchLimit.slot_keys(UserId.chat_owner).first() == Ok("search/1/0".to_utf8())
expect SearchLimit.slot_keys(UserId.chat_owner).last() == Ok("search/1/4".to_utf8())
# Five searches in a second, each a slot of its own; the sixth is refused
# until the next second, when the first slot is free again.
expect SearchLimit.slot_for_search(List.repeat(NeverUsed, 5), noon) == Ok(0)
expect SearchLimit.slot_for_search(
	[
		UsedAt(noon),
		UsedAt(noon),
		NeverUsed,
		NeverUsed,
		NeverUsed,
	],
	noon,
) == Ok(2)
expect SearchLimit.slot_for_search(
	[
		UsedAt(noon),
		UsedAt(noon),
		UsedAt(noon),
		UsedAt(noon),
		NeverUsed,
	],
	noon,
) == Ok(4)
expect SearchLimit.slot_for_search(List.repeat(UsedAt(noon), 5), noon) == Err(TooFast)
expect SearchLimit.slot_for_search(List.repeat(UsedAt(noon), 5), a_second_on) == Ok(0)
