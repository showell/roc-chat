## A timestamp is a moment, in whole seconds since 1970-01-01T00:00:00Z, as the
## host's clock gives it: when a key was made, when an invite expires, when a
## session was signed. A length of time is a `Seconds`, and the two can't mix: a
## timestamp plus a length is a timestamp, and two timestamps subtract to a
## length. How a moment reads as a date is `DateTime`'s to say.
import FactFile
import Seconds

Timestamp :: I64.{

	## The moment `seconds` after the epoch.
	at_second : I64 -> Timestamp
	at_second = |seconds| Timestamp.(seconds)

	## The moment a file holds: its digits, at most the largest `I64`; unless
	## it holds anything else (`NotATime`), a sign included.
	from_file : List(U8) -> Try(Timestamp, [NotATime])
	from_file = |bytes|
		match FactFile.number_from_file(bytes) {
			Ok(number) if number <= I64.highest.to_u64_wrap() =>
				Ok(Timestamp.(number.to_i64_wrap()))
			_ => Err(NotATime)
		}

	## The moment as its file keeps it: its decimal digits.
	to_file : Timestamp -> List(U8)
	to_file = |moment| moment.to_str().to_utf8()

	to_seconds_since_epoch : Timestamp -> I64
	to_seconds_since_epoch = |Timestamp.(seconds)| seconds

	to_str : Timestamp -> Str
	to_str = |Timestamp.(seconds)| seconds.to_str()

	## The moment `length` after this one. A moment an `I64` can't hold is past
	## any clock, and crashes.
	plus : Timestamp, Seconds -> Timestamp
	plus = |Timestamp.(seconds), length| {
		sum = seconds.to_i128() + length.to_i128()
		Timestamp.(sum.to_i64_try() ?? crash "Timestamp.plus: past the last moment an I64 holds")
	}

	## How long after `earlier` this moment is, negative when it comes first.
	seconds_since : Timestamp, Timestamp -> Seconds
	seconds_since = |Timestamp.(seconds), Timestamp.(earlier)|
		Seconds.of(seconds.to_i128() - earlier.to_i128())

	## Whether this moment is at `from` or later, and before `until`.
	is_during : Timestamp, { from : Timestamp, until : Timestamp } -> Bool
	is_during = |Timestamp.(seconds), { from: Timestamp.(first), until: Timestamp.(end) }|
		seconds >= first and seconds < end

	is_eq : _
}

# ── tests
expect Timestamp.at_second(1761600000).to_file() == "1761600000".to_utf8()
expect Timestamp.from_file("1761600000\n".to_utf8()) == Ok(Timestamp.at_second(1761600000))
expect Timestamp.from_file("9223372036854775807".to_utf8()) == Ok(Timestamp.at_second(I64.highest))
expect Timestamp.from_file("9223372036854775808".to_utf8()) == Err(NotATime)
expect Timestamp.from_file("-1".to_utf8()) == Err(NotATime)
expect Timestamp.at_second(1761600000).to_seconds_since_epoch() == 1761600000
expect Timestamp.at_second(-1).to_str() == "-1"
expect Timestamp.at_second(1000).plus(Seconds.of(600)) == Timestamp.at_second(1600)
expect Timestamp.at_second(1000).plus(Seconds.of(-1)) == Timestamp.at_second(999)
expect Timestamp.at_second(1600).seconds_since(Timestamp.at_second(1000)) == Seconds.of(600)
expect Timestamp.at_second(1000).seconds_since(Timestamp.at_second(1600)) == Seconds.of(-600)
expect Timestamp.at_second(1000).seconds_since(Timestamp.at_second(1000)) == Seconds.of(0)
# The distance between the two furthest moments fits.
expect
	Timestamp.at_second(I64.highest).seconds_since(Timestamp.at_second(I64.lowest))
		== Seconds.of(18446744073709551615)
# A window holds its first second and not its last.
expect
	[
		(999, Bool.False),
		(1000, Bool.True),
		(1599, Bool.True),
		(1600, Bool.False),
	].all(
		|(second, inside)| {
			window = { from: Timestamp.at_second(1000), until: Timestamp.at_second(1600) }
			Timestamp.at_second(second).is_during(window) == inside
		},
	)
