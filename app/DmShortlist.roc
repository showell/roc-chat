## This module picks the DMs a sidebar shows. Every human is a DM of the
## reader's (`Browse`), but most people talk to one or two others, so the
## DMs group shows only those the reader has lately been talking to, and the
## rest wait behind one row, "N more people…", that app/sidebar.js opens. It
## errs on less clutter, even when that costs a click (Steve, 2026-11-20).
##
## A DM shows when one of its topics had a message in the last
## `recent_window` (14 days, its edge inside), and it is among the
## `shown_most` (3) newest of those. The page's own DM always shows, whatever
## its time, and takes no one's place among the three, so the same three
## show on every page. The rest wait, all in the sidebar's order. In a DM
## only its two people write, so a message there is the two of them
## talking. This is an inference from what the chat already keeps, and
## should give way to a buddy list once there is one.
import DateTime
import Place
import Seconds
import SidebarOrder
import Timestamp

DmShortlist :: [].{

	## How long ago a DM's last message may be for the DM to show: 14 days,
	## two weeks of anyone's working rhythm.
	recent_window : Seconds
	recent_window = Seconds.of(14 * 24 * 60 * 60)

	## How many DMs show at most, besides the page's own.
	shown_most : U64
	shown_most = 3

	## The DMs a sidebar shows, and those that wait behind its "more" row,
	## each in the order they were given.
	Split : {
		shown_places : List(SidebarOrder.OrderedPlace),
		waiting_places : List(SidebarOrder.OrderedPlace),
	}

	## `dm_places`, in the sidebar's order, split into those shown on the page of
	## `current` at `now` and those that wait.
	split : {
		dm_places : List(SidebarOrder.OrderedPlace),
		current : Place,
		now : Timestamp,
	} -> DmShortlist.Split
	split = |{ dm_places, current, now }| {
		back_to_window = Seconds.of(0 - DmShortlist.recent_window.to_i128())
		window_start = DateTime.from_timestamp(now.plus(back_to_window))
		by_newest = |one, other| newest_first((one.time, one.at), (other.time, other.at))
		recent =
			dm_places
				.map_with_index(
					|dm, at| {
						place: dm.place,
						time: recent_time(dm.latest, window_start),
						at,
					},
				)
				.keep_if(|candidate| candidate.place != current and candidate.time != NotRecent)
				.sort_with(by_newest)
				.take_first(DmShortlist.shown_most)
				.map(|candidate| candidate.place)
		is_shown = |dm| dm.place == current or recent.contains(dm.place)
		{ shown_places: dm_places.keep_if(is_shown), waiting_places: dm_places.drop_if(is_shown) }
	}
}

## When a DM's last message was, if it is in the window.
RecentTime : [Recent(DateTime), NotRecent]

## When `latest` was, if it is at `window_start` or later. A window that
## starts before 1970 (`OutOfRange`) holds every message, since none is
## older.
recent_time : SidebarOrder.Latest, Try(DateTime, [OutOfRange]) -> RecentTime
recent_time = |latest, window_start|
	match (latest, window_start) {
		(NoMessages, _) => NotRecent
		(At(time), Err(OutOfRange)) => Recent(time)
		(At(time), Ok(start)) =>
			if DateTime.compare(time, start) == Before {
				NotRecent
			} else {
				Recent(time)
			}
	}

## Newest first; two of one second by where they were given (`at`).
newest_first : (RecentTime, U64), (RecentTime, U64) -> [Before, Same, After]
newest_first = |(one, one_at), (other, other_at)|
	match (one, other) {
		(Recent(one_time), Recent(other_time)) =>
			match DateTime.compare(one_time, other_time) {
				After => Before
				Before => After
				Same => given_order(one_at, other_at)
			}
		_ => given_order(one_at, other_at)
	}

## `one` and `other` in the order they were given.
given_order : U64, U64 -> [Before, Same, After]
given_order = |one, other|
	if one < other {
		Before
	} else if one > other {
		After
	} else {
		Same
	}
