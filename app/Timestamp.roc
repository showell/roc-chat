## **A TIMESTAMP**: when a message was written, as ISO 8601 in UTC, in
## exactly one form, `YYYY-MM-DDTHH:MM:SSZ`, so two times compare as text
## and a transcript reads the same everywhere. Opaque, so `from_str` is the
## only way in.
Timestamp :: Str.{

	## The time `text` names, or why it is refused: not the form, or a month,
	## day, hour, minute or second no clock shows.
	from_str : Str -> Try(Timestamp, [WrongShape, OutOfRange])
	from_str = |text| {
		bytes = text.to_utf8()
		shape = bytes.map(|b| if (b >= '0' and b <= '9') '9' else b)
		if (shape != "9999-99-99T99:99:99Z".to_utf8())
			Err(WrongShape)
		else {
			month = two_digits(bytes, 5)
			day = two_digits(bytes, 8)
			hour = two_digits(bytes, 11)
			minute = two_digits(bytes, 14)
			second = two_digits(bytes, 17)
			if (month >= 1 and month <= 12 and day >= 1 and day <= 31 and hour <= 23 and minute <= 59 and second <= 59)
				Ok(Timestamp.(text))
			else
				Err(OutOfRange)
		}
	}

	## The time as written.
	to_str : Timestamp -> Str
	to_str = |Timestamp.(text)| text

	is_eq : _
}

## The number written by the two digits at `at`; the shape has put digits
## there.
two_digits : List(U8), U64 -> U8
two_digits = |bytes, at| {
	tens = bytes.get(at) ?? crash "Timestamp.two_digits: the shape has a digit here"
	ones = bytes.get(at + 1) ?? crash "Timestamp.two_digits: the shape has a digit here"
	(tens - '0') * 10 + (ones - '0')
}

# ── tests
ok : Str -> Try(Str, [WrongShape, OutOfRange])
ok = |text| Timestamp.from_str(text).map_ok(Timestamp.to_str)

expect ok("2026-11-02T19:11:32Z") == Ok("2026-11-02T19:11:32Z")
expect ok("") == Err(WrongShape)
expect ok("2026-11-02T19:11:32") == Err(WrongShape)
expect ok("2026-11-02T19:11:32z") == Err(WrongShape)
expect ok("2026-11-02 19:11:32Z") == Err(WrongShape)
expect ok("2026-11-02T19:11:32.5Z") == Err(WrongShape)
expect ok("2026-11-02T19:11:32+00:00") == Err(WrongShape)
expect ok("2026-1-02T19:11:32Z") == Err(WrongShape)
expect ok("2026-11-02T19:11:3xZ") == Err(WrongShape)
expect ok("2026-11-02T19:11:32Z\n") == Err(WrongShape)
expect ok("２026-11-02T19:11:32Z") == Err(WrongShape)
# Each field at, and just past, each end of its range.
expect ok("2026-00-02T19:11:32Z") == Err(OutOfRange)
expect ok("2026-01-02T19:11:32Z") == Ok("2026-01-02T19:11:32Z")
expect ok("2026-12-02T19:11:32Z") == Ok("2026-12-02T19:11:32Z")
expect ok("2026-13-02T19:11:32Z") == Err(OutOfRange)
expect ok("2026-11-00T19:11:32Z") == Err(OutOfRange)
expect ok("2026-11-01T19:11:32Z") == Ok("2026-11-01T19:11:32Z")
expect ok("2026-10-31T19:11:32Z") == Ok("2026-10-31T19:11:32Z")
expect ok("2026-10-32T19:11:32Z") == Err(OutOfRange)
expect ok("2026-11-02T00:00:00Z") == Ok("2026-11-02T00:00:00Z")
expect ok("2026-11-02T23:59:59Z") == Ok("2026-11-02T23:59:59Z")
expect ok("2026-11-02T24:11:32Z") == Err(OutOfRange)
expect ok("2026-11-02T19:60:32Z") == Err(OutOfRange)
expect ok("2026-11-02T19:11:60Z") == Err(OutOfRange)
expect ok("0000-11-02T19:11:32Z") == Ok("0000-11-02T19:11:32Z")
expect ok("2026-99-99T99:99:99Z") == Err(OutOfRange)
