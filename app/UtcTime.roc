## **A TIME IN UTC, AS TEXT**: unix seconds written as HTML and the old
## app's records name a time (`iso`, `2026-11-01T12:54:30Z`), and as a page
## without a script shows one (`fallback`); and `iso`'s text read back
## (`from_iso`), one spelling of one second. The proleptic Gregorian
## calendar (Howard Hinnant's `civil_from_days` and `days_from_civil`).
## Pure.

UtcTime := [].{

	## **A TIME AS HTML NAMES IT**, `2026-11-01T12:54:30Z`: the `datetime` a
	## `<time>` carries, and the `at` of the old app's reaction line.
	iso : I64 -> Str
	iso = |at| {
		t = utc(at)
		"${t.date}T${t.clock}:${t.second}Z"
	}

	## **A TIME WITH NO SCRIPT TO SHOW IT**, `2026-11-01 12:54 UTC`: the
	## text a `<time>` holds until the page's script writes it in the
	## viewer's zone, so a page without JavaScript still says when.
	fallback : I64 -> Str
	fallback = |at| {
		t = utc(at)
		"${t.date} ${t.clock} UTC"
	}

	## **`iso`'S TEXT READ BACK**: exactly `YYYY-MM-DDTHH:MM:SSZ`, a real
	## day and time of day, so the text is the one `iso` writes for its
	## second; anything else (another zone, a fraction, the 30th of
	## February) is not one.
	from_iso : List(U8) -> Try(I64, [NotIso])
	from_iso = |text|
		if text.len() != 20 or !iso_marks.all(|(i, mark)| text.get(i) == Ok(mark)) {
			Err(NotIso)
		} else {
			days = days_from_civil({
				y: part(text, { start: 0, len: 4 })?,
				m: part(text, { start: 5, len: 2 })?,
				d: part(text, { start: 8, len: 2 })?,
			})
			clock = part(text, { start: 11, len: 2 })? * 3600 + part(text, { start: 14, len: 2 })? * 60 + part(text, { start: 17, len: 2 })?
			at = days * 86400 + clock
			if (UtcTime.iso(at).to_utf8() == text) Ok(at) else Err(NotIso)
		}
}

## Where `iso`'s text has its separators, and which.
iso_marks : List((U64, U8))
iso_marks = [
	(4, '-'),
	(7, '-'),
	(10, 'T'),
	(13, ':'),
	(16, ':'),
	(19, 'Z'),
]

## The number written at `start`, `len` digits long.
part : List(U8), { start : U64, len : U64 } -> Try(I64, [NotIso])
part = |text, span| digits(text.sublist(span))

## **UNIX SECONDS AS A UTC DATE AND CLOCK** (`civil_from_days`): its date,
## its hour and minute, its seconds, each zero-padded.
utc : I64 -> {
	date : Str,
	clock : Str,
	second : Str,
}
utc = |at| {
	days = if (at >= 0) at // 86400 else (at - 86399) // 86400
	rest = at - days * 86400
	z = days + 719468
	era = if (z >= 0) z // 146097 else (z - 146096) // 146097
	doe = z - era * 146097
	yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	mp = (5 * doy + 2) // 153
	d = doy - (153 * mp + 2) // 5 + 1
	m = if (mp < 10) mp + 3 else mp - 9
	y = yoe + era * 400 + (if (m <= 2) 1 else 0)
	{
		date: "${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}",
		clock: "${pad(rest // 3600, 2)}:${pad((rest % 3600) // 60, 2)}",
		second: pad(rest % 60, 2),
	}
}

## **A DATE AS DAYS SINCE 1970-01-01** (`days_from_civil`); a month or day
## out of range gives some day, which `from_iso`'s round trip refuses.
days_from_civil : {
	y : I64,
	m : I64,
	d : I64,
} -> I64
days_from_civil = |
	{
		y,
		m,
		d,
	},
| {
	year = if (m <= 2) y - 1 else y
	era = if (year >= 0) year // 400 else (year - 399) // 400
	yoe = year - era * 400
	doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) // 5 + d - 1
	doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	era * 146097 + doe - 719468
}

## ASCII digits as a whole number; anything else is no time.
digits : List(U8) -> Try(I64, [NotIso])
digits = |bytes|
	if bytes.all(|b| b >= '0' and b <= '9') {
		Ok(bytes.fold(0, |n, b| n * 10 + (b - '0').to_i64()))
	} else {
		Err(NotIso)
	}

## A whole number in decimal, zeros before it to `width` digits.
pad : I64, U64 -> Str
pad = |n, width| {
	digits_of = n.to_str()
	zeros = if (digits_of.to_utf8().len() < width) width - digits_of.to_utf8().len() else 0
	Str.concat(Str.repeat("0", zeros), digits_of)
}

# ── tests
expect UtcTime.iso(0) == "1970-01-01T00:00:00Z"
expect UtcTime.iso(1793537670) == "2026-11-01T12:54:30Z"
expect UtcTime.iso(951782400) == "2000-02-29T00:00:00Z"
expect UtcTime.iso(-1) == "1969-12-31T23:59:59Z"
expect UtcTime.fallback(1793537670) == "2026-11-01 12:54 UTC"

# Read back: each `iso` text is its second, around the edges of a day, a
# leap day and the epoch.
expect
	[
		0,
		-1,
		1,
		86399,
		86400,
		951782400,
		951868799,
		1793537670,
	].all(|at| UtcTime.from_iso(UtcTime.iso(at).to_utf8()) == Ok(at))
# Not `iso`'s spelling, or no real time: refused.
expect UtcTime.from_iso("2026-11-01T12:54:30".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2026-11-01T12:54:30.5Z".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2026-11-01 12:54:30Z".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2026-11-01T12:54:3xZ".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2026-02-30T00:00:00Z".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2026-13-01T00:00:00Z".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2026-11-01T24:00:00Z".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2026-11-01T23:60:00Z".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2025-02-29T00:00:00Z".to_utf8()) == Err(NotIso)
expect UtcTime.from_iso("2024-02-29T00:00:00Z".to_utf8()).is_ok()
expect UtcTime.from_iso([]) == Err(NotIso)
