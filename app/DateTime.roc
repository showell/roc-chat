## **A DATE AND TIME**: when a message was written, as ISO 8601 in UTC, in
## exactly one form, `YYYY-MM-DDTHH:MM:SSZ`, so two times compare as text
## and a transcript reads the same everywhere. Opaque, so `from_str` is the
## only way in, and every one names a second some calendar and clock show.
##
## **WHY IT IS OURS**: the pinned Roc's builtins (Str, List, Num, Dict, Set,
## Iter, Stream, Crypto, Hasher, Encoding and the rest) have no date or time
## type at all, so this module keeps to what the chat needs, the one form
## read and written and the calendar's check, and gives way to the builtins'
## once they have one.
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
				on_clock = number([
					h1,
					h2,
				]) <= 23 and number([n1, n2]) <= 59 and number([s1, s2]) <= 59
				if (in_calendar and on_clock) Ok(DateTime.(text)) else Err(OutOfRange)
			}
			_ => Err(WrongShape)
		}

	## The time as written.
	to_str : DateTime -> Str
	to_str = |DateTime.(text)| text

	is_eq : _
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
expect !is_leap(2026) and !is_leap(1900) and !is_leap(2100)
