## A date and time says when a message was written, as ISO 8601 in UTC, in
## exactly one form, `YYYY-MM-DDTHH:MM:SSZ`, so two times compare as text
## (`compare`) and a transcript reads the same everywhere. The type is
## opaque, so `from_str` and `from_seconds_since_epoch` are the only ways
## in, and every value names a second that a calendar and a clock can show.
##
## The chat has its own date type because the pinned Roc's builtins have
## none. This module keeps to what the chat needs, the one form read and
## written and the calendar's check, and should give way to the builtins'
## type once they have one.
import Ascii

DateTime :: Str.{

	## The time `text` names, or why it is refused: not the form, or a
	## month, day, hour, minute or second no calendar or clock shows (a
	## 31st of April, a 29th of February outside a leap year, a 24th hour).
	from_str : Str -> Try(DateTime, [WrongShape, OutOfRange])
	from_str = |text|
		match text.to_utf8() {
			[
				y1,
				y2,
				y3,
				y4,
				'-',
				m1,
				m2,
				'-',
				d1,
				d2,
				'T',
				h1,
				h2,
				':',
				n1,
				n2,
				':',
				s1,
				s2,
				'Z',
			] if [
				y1,
				y2,
				y3,
				y4,
				m1,
				m2,
				d1,
				d2,
				h1,
				h2,
				n1,
				n2,
				s1,
				s2,
			].all(Ascii.is_digit) => {
				year = number([
					y1,
					y2,
					y3,
					y4,
				])
				month = number([m1, m2])
				day = number([d1, d2])
				in_calendar = month >= 1 and month <= 12 and day >= 1 and day <= days_in({
					year,
					month,
				})
				hour = number([h1, h2])
				minute = number([n1, n2])
				second = number([s1, s2])
				on_clock = hour <= 23 and minute <= 59 and second <= 59
				if (in_calendar and on_clock) Ok(DateTime.(text)) else Err(OutOfRange)
			}
			_ => Err(WrongShape)
		}

	## The time `seconds` after 1970-01-01T00:00:00Z, as the host's clock
	## gives it. A time before then, or after the last second the form can
	## write, 9999-12-31T23:59:59Z, is `OutOfRange`. Days become a date in
	## the Gregorian calendar by Howard Hinnant's `civil_from_days`.
	from_seconds_since_epoch : I64 -> Try(DateTime, [OutOfRange])
	from_seconds_since_epoch = |seconds|
		if (seconds < 0 or seconds > last_second)
			Err(OutOfRange)
		else {
			days = seconds // 86400
			of_day = seconds % 86400
			date = civil_from_days(days)
			text =
				"${padded_digits(date.year, 4)}-${padded_digits(date.month, 2)}-${padded_digits(date.day, 2)}T${padded_digits(of_day // 3600, 2)}:${padded_digits((of_day % 3600) // 60, 2)}:${padded_digits(of_day % 60, 2)}Z"
			Ok(DateTime.(text))
		}

	## The time as written.
	to_str : DateTime -> Str
	to_str = |DateTime.(text)| text

	## Whether `time` is before, at or after `other`. Every time is
	## written in the one form, its fields from the year down to the
	## second, each a fixed width of digits, so the first byte that differs
	## decides.
	compare : DateTime, DateTime -> [Before, Same, After]
	compare = |DateTime.(time), DateTime.(other)| byte_order(time.to_utf8(), other.to_utf8())

	is_eq : _
}

## 9999-12-31T23:59:59Z, in seconds since the epoch: the last the form
## writes.
last_second : I64
last_second = 253402300799

## The date `days` after 1970-01-01, for `days` of zero or more, by
## Hinnant's `civil_from_days`. It counts in 400-year eras from 0000-03-01,
## so February, with its leap day, ends each counted year.
civil_from_days : I64 -> {
	year : I64,
	month : I64,
	day : I64,
}
civil_from_days = |days| {
	from_era_start = days + 719468
	era = from_era_start // 146097
	day_of_era = from_era_start - era * 146097
	year_of_era =
		(day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
	day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
	month_from_march = (5 * day_of_year + 2) // 153
	day = day_of_year - (153 * month_from_march + 2) // 5 + 1
	month = if (month_from_march < 10) month_from_march + 3 else month_from_march - 9
	year = year_of_era + era * 400 + (if (month <= 2) 1 else 0)
	{
		year,
		month,
		day,
	}
}

## `n`, zero or more, in at least `width` digits, zeros before.
padded_digits : I64, U64 -> Str
padded_digits = |n, width| {
	written = n.to_str()
	"0".repeat(width - written.count_utf8_bytes()).concat(written)
}

## The order of two forms' bytes, by the first that differs.
byte_order : List(U8), List(U8) -> [Before, Same, After]
byte_order = |bytes, others|
	match (bytes, others) {
		(
			[byte, .. as rest],
			[other, .. as rest_of_others],
		) if byte == other => byte_order(rest, rest_of_others)
		([byte, ..], [other, ..]) => if (byte < other) Before else After
		_ => Same
	}

## The number the digits write, most significant first.
number : List(U8) -> U64
number = |digits| digits.fold(0, |n, d| n * 10 + (d - '0').to_u64())

## How many days `month` (1 to 12) has in `year`, by the Gregorian rule.
days_in : { year : U64, month : U64 } -> U64
days_in = |{ year, month }|
	match month {
		2 => if (is_leap(year)) 29 else 28
		4 | 6 | 9 | 11 => 30
		_ => 31
	}

## Every fourth year, but not every hundredth, unless every four-hundredth.
is_leap : U64 -> Bool
is_leap = |year| year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)

# ── tests
## The text of the time `text` names, if it is accepted.
ok : Str -> Try(Str, [WrongShape, OutOfRange])
ok = |text| DateTime.from_str(text).map_ok(DateTime.to_str)

expect ok("2026-11-02T19:11:32Z") == Ok("2026-11-02T19:11:32Z")
expect DateTime.from_str("") == Err(WrongShape)
expect DateTime.from_str("2026-11-02T19:11:32") == Err(WrongShape)
expect DateTime.from_str("2026-11-02T19:11:32z") == Err(WrongShape)
expect DateTime.from_str("2026-11-02 19:11:32Z") == Err(WrongShape)
expect DateTime.from_str("2026-11-02T19:11:32.5Z") == Err(WrongShape)
expect DateTime.from_str("2026-11-02T19:11:32+00:00") == Err(WrongShape)
expect DateTime.from_str("2026-1-02T19:11:32Z") == Err(WrongShape)
expect DateTime.from_str("2026-11-02T19:11:3xZ") == Err(WrongShape)
expect DateTime.from_str("2026-11-02T19:11:32Z\n") == Err(WrongShape)
expect DateTime.from_str("２026-11-02T19:11:32Z") == Err(WrongShape)
expect DateTime.from_str("2026/11-02T19:11:32Z") == Err(WrongShape)
# A digit's neighbours, in a digit's place.
expect DateTime.from_str("202/-11-02T19:11:32Z") == Err(WrongShape)
expect DateTime.from_str("202:-11-02T19:11:32Z") == Err(WrongShape)
# Each field at, and just past, each end of its range.
expect DateTime.from_str("2026-00-02T19:11:32Z") == Err(OutOfRange)
expect ok("2026-01-02T19:11:32Z") == Ok("2026-01-02T19:11:32Z")
expect ok("2026-12-02T19:11:32Z") == Ok("2026-12-02T19:11:32Z")
expect DateTime.from_str("2026-13-02T19:11:32Z") == Err(OutOfRange)
expect DateTime.from_str("2026-11-00T19:11:32Z") == Err(OutOfRange)
expect ok("2026-11-01T19:11:32Z") == Ok("2026-11-01T19:11:32Z")
expect ok("2026-11-02T00:00:00Z") == Ok("2026-11-02T00:00:00Z")
expect ok("2026-11-02T23:59:59Z") == Ok("2026-11-02T23:59:59Z")
expect DateTime.from_str("2026-11-02T24:11:32Z") == Err(OutOfRange)
expect DateTime.from_str("2026-11-02T19:60:32Z") == Err(OutOfRange)
expect DateTime.from_str("2026-11-02T19:11:60Z") == Err(OutOfRange)
expect ok("0000-01-01T00:00:00Z") == Ok("0000-01-01T00:00:00Z")
expect ok("9999-12-31T23:59:59Z") == Ok("9999-12-31T23:59:59Z")
expect DateTime.from_str("2026-99-99T99:99:99Z") == Err(OutOfRange)
# Each month's last day, and the day after it.
expect ok("2026-01-31T19:11:32Z") == Ok("2026-01-31T19:11:32Z")
expect DateTime.from_str("2026-01-32T19:11:32Z") == Err(OutOfRange)
expect ok("2026-04-30T19:11:32Z") == Ok("2026-04-30T19:11:32Z")
expect DateTime.from_str("2026-04-31T19:11:32Z") == Err(OutOfRange)
expect DateTime.from_str("2026-06-31T19:11:32Z") == Err(OutOfRange)
expect DateTime.from_str("2026-09-31T19:11:32Z") == Err(OutOfRange)
expect ok("2026-11-30T19:11:32Z") == Ok("2026-11-30T19:11:32Z")
expect DateTime.from_str("2026-11-31T19:11:32Z") == Err(OutOfRange)
expect ok("2026-12-31T19:11:32Z") == Ok("2026-12-31T19:11:32Z")
expect DateTime.from_str("2026-12-32T19:11:32Z") == Err(OutOfRange)
# February: 28 days, 29 in a leap year, by all three of the rule's parts.
expect ok("2026-02-28T19:11:32Z") == Ok("2026-02-28T19:11:32Z")
expect DateTime.from_str("2026-02-29T19:11:32Z") == Err(OutOfRange)
expect ok("2024-02-29T19:11:32Z") == Ok("2024-02-29T19:11:32Z")
expect DateTime.from_str("2024-02-30T19:11:32Z") == Err(OutOfRange)
expect DateTime.from_str("1900-02-29T19:11:32Z") == Err(OutOfRange)
expect ok("2000-02-29T19:11:32Z") == Ok("2000-02-29T19:11:32Z")
expect is_leap(2024) and is_leap(2000) and is_leap(0)
# The order: the same time, and a second either side of it, within a
# field and across each field's rollover, both ways round.
## A pair's order, both ways round, from the pair's text.
order : (Str, Str) -> ([Before, Same, After], [Before, Same, After])
order = |(earlier, later)| {
	first = DateTime.from_str(earlier) ?? crash "DateTime's tests: a time"
	second = DateTime.from_str(later) ?? crash "DateTime's tests: a time"
	(first.compare(second), second.compare(first))
}

expect order(("2026-11-02T19:11:32Z", "2026-11-02T19:11:32Z")) == (Same, Same)
expect
	[
		("2026-11-02T19:11:31Z", "2026-11-02T19:11:32Z"),
		("2026-11-02T19:11:59Z", "2026-11-02T19:12:00Z"),
		("2026-11-02T19:59:59Z", "2026-11-02T20:00:00Z"),
		("2026-11-02T23:59:59Z", "2026-11-03T00:00:00Z"),
		("2026-10-31T23:59:59Z", "2026-11-01T00:00:00Z"),
		("2025-12-31T23:59:59Z", "2026-01-01T00:00:00Z"),
		("0999-12-31T23:59:59Z", "1000-01-01T00:00:00Z"),
	].all(|pair| order(pair) == (Before, After))
expect !is_leap(2026) and !is_leap(1900) and !is_leap(2100)
# The clock's seconds: the epoch, its last second and the one past it, a
# second either side of a day, a month, a year and a leap day, and either
# end of the range.
## The time `seconds` names, as written.
from_clock : I64 -> Try(Str, [OutOfRange])
from_clock = |seconds| DateTime.from_seconds_since_epoch(seconds).map_ok(DateTime.to_str)

expect from_clock(0) == Ok("1970-01-01T00:00:00Z")
expect from_clock(59) == Ok("1970-01-01T00:00:59Z")
expect from_clock(86399) == Ok("1970-01-01T23:59:59Z")
expect from_clock(86400) == Ok("1970-01-02T00:00:00Z")
expect from_clock(951782399) == Ok("2000-02-28T23:59:59Z")
expect from_clock(951782400) == Ok("2000-02-29T00:00:00Z")
expect from_clock(951868800) == Ok("2000-03-01T00:00:00Z")
expect from_clock(1709251199) == Ok("2024-02-29T23:59:59Z")
expect from_clock(1709251200) == Ok("2024-03-01T00:00:00Z")
expect from_clock(1798761599) == Ok("2026-12-31T23:59:59Z")
expect from_clock(1798761600) == Ok("2027-01-01T00:00:00Z")
expect from_clock(1793646692) == Ok("2026-11-02T19:11:32Z")
expect from_clock(253402300799) == Ok("9999-12-31T23:59:59Z")
expect from_clock(-1) == Err(OutOfRange)
expect from_clock(253402300800) == Err(OutOfRange)
# Every time the clock gives is one `from_str` accepts.
expect
	[0, 951782400, 1793560292, 253402300799].all(
		|seconds|
			match DateTime.from_seconds_since_epoch(seconds) {
				Ok(time) => DateTime.from_str(time.to_str()) == Ok(time)
				Err(_) => Bool.False
			},
	)
