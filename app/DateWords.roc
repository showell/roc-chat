## A moment as a page says it to a reader, never as raw digits: its date in
## words and how many days off it is, "Nov 27 (in 7 days)". The invites page
## says when a link expires so (`PeoplePages`). The date is UTC's, the
## server's clock, and the days are calendar days between the two dates.
import DateTime
import Timestamp

DateWords :: [].{

	## `moment`'s date as "Nov 27", with its year when that isn't `now`'s
	## ("Jan 3, 2027"), then how far it is from `now`'s date: "(today)",
	## "(tomorrow)", "(in 7 days)", "(yesterday)", "(3 days ago)". A moment
	## out of a date's range is its seconds.
	phrase : { moment : Timestamp, now : Timestamp } -> Str
	phrase = |{ moment, now }|
		match (DateTime.from_timestamp(moment), DateTime.from_timestamp(now)) {
			(Ok(then), Ok(today)) => {
				date = month_day(then.date_to_str(), today.date_to_str())
				days = epoch_day(moment) - epoch_day(now)
				"${date} (${distance(days)})"
			}
			_ => "at ${moment.to_str()} seconds"
		}
}

## The day `moment` falls on, counted from 1970-01-01.
epoch_day : Timestamp -> I64
epoch_day = |moment| moment.to_seconds_since_epoch() // 86400

## `days` from today in words.
distance : I64 -> Str
distance = |days|
	if days == 0 {
		"today"
	} else if days == 1 {
		"tomorrow"
	} else if days == -1 {
		"yesterday"
	} else if days > 1 {
		"in ${days.to_str()} days"
	} else {
		"${(-days).to_str()} days ago"
	}

## The date `date` (`2026-11-27`) as "Nov 27", with its year when it isn't
## that of `today`, the same form.
month_day : Str, Str -> Str
month_day = |date, today|
	match (date.split_on("-"), today.split_on("-")) {
		([year, month, day], [this_year, ..]) => {
			short = "${month_name(month)} ${day.drop_prefix("0")}"
			if year == this_year {
				short
			} else {
				"${short}, ${year}"
			}
		}
		_ => crash "DateWords.month_day: a DateTime's date is YYYY-MM-DD"
	}

## A month's short name, from its two digits.
month_name : Str -> Str
month_name = |digits|
	match digits {
		"01" => "Jan"
		"02" => "Feb"
		"03" => "Mar"
		"04" => "Apr"
		"05" => "May"
		"06" => "Jun"
		"07" => "Jul"
		"08" => "Aug"
		"09" => "Sep"
		"10" => "Oct"
		"11" => "Nov"
		"12" => "Dec"
		_ => crash "DateWords.month_name: a DateTime's month is 01 to 12"
	}

# ── tests
## The words for `moment` seen at `now`, both in seconds.
words : I64, I64 -> Str
words = |moment, now| {
	time = Timestamp.at_second
	DateWords.phrase({ moment: time(moment), now: time(now) })
}

# 2025-11-20T12:00:00Z is 1763640000; a day is 86400.
expect words(1763640000 + 7 * 86400, 1763640000) == "Nov 27 (in 7 days)"
expect words(1763640000, 1763640000) == "Nov 20 (today)"
expect words(1763640000 + 86400, 1763640000) == "Nov 21 (tomorrow)"
expect words(1763640000 - 86400, 1763640000) == "Nov 19 (yesterday)"
expect words(1763640000 - 3 * 86400, 1763640000) == "Nov 17 (3 days ago)"
# Calendar days: a minute before midnight to a minute after is a day.
expect words(1763683260, 1763683140) == "Nov 21 (tomorrow)"
# Another year says its year; a day under ten has one digit.
expect words(1763640000 + 44 * 86400, 1763640000) == "Jan 3, 2026 (in 44 days)"
expect words(-1, 0) == "at -1 seconds"
