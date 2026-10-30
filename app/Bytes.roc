## BYTE SEARCHES AND TRIMS THE CODECS SHARE: finding a run of bytes,
## counting the bytes that keep a test from either end, and trimming a set
## off both ends, on bytes, never Str (a stored line or a name is bytes
## until it is checked). Splits and prefix tests are List's own
## (`split_on`, `starts_with`), and a byte's class is Ascii's. Pure.

Bytes := [].{

	## Where `needle` first starts in `s`, from `at` on.
	find : List(U8), { needle : List(U8), at : U64 } -> Try(U64, [NotFound])
	find = |s, { needle, at: i }|
		if i + needle.len() > s.len() {
			Err(NotFound)
		} else if s.get(i) == needle.first() and s.sublist({ start: i, len: needle.len() }) == needle {
			Ok(i)
		} else {
			find(s, { needle, at: i + 1 })
		}

	## The bytes after `prefix`, when `l` starts with it: no length is
	## written beside the literal it belongs to.
	strip_prefix : List(U8), List(U8) -> Try(List(U8), [NoMatch])
	strip_prefix = |l, prefix| if (l.starts_with(prefix)) Ok(
		l.drop_first(prefix.len()),
	) else Err(NoMatch)

	## How many bytes from the start keep `keep`.
	count_while : List(U8), (U8 -> Bool) -> U64
	count_while = |s, keep| count_while_from(s, { keep, at: 0 })

	## How many bytes from the end keep `keep`.
	count_back : List(U8), (U8 -> Bool) -> U64
	count_back = |s, keep| count_back_from(s, { keep, kept: 0 })

	## The bytes in `set` off both ends.
	trim : List(U8), List(U8) -> List(U8)
	trim = |s, set| {
		in_set = |c| set.contains(c)
		front = s.drop_first(count_while(s, in_set))
		front.drop_last(count_back(front, in_set))
	}
}

## How many bytes from `i` on keep `keep`, plus `i`.
count_while_from : List(U8), { keep : (U8 -> Bool), at : U64 } -> U64
count_while_from = |s, { keep, at: i }| match s.get(i) {
	Ok(c) if keep(c) => count_while_from(s, { keep, at: i + 1 })
	_ => i
}

## How many bytes from the end, past the last `kept`, keep `keep`, plus `kept`.
count_back_from : List(U8), { keep : (U8 -> Bool), kept : U64 } -> U64
count_back_from = |s, { keep, kept: n }|
	if n >= s.len() {
		n
	} else {
		match s.get(s.len() - 1 - n) {
			Ok(c) if keep(c) => count_back_from(s, { keep, kept: n + 1 })
			_ => n
		}
	}

expect Bytes.find("a=b=c".to_utf8(), { needle: "=".to_utf8(), at: 2 }) == Ok(3)
expect Bytes.find("abc".to_utf8(), { needle: "cd".to_utf8(), at: 0 }) == Err(NotFound)
expect Bytes.trim("  x y \n".to_utf8(), " \n".to_utf8()) == "x y".to_utf8()
expect Bytes.trim("   ".to_utf8(), " ".to_utf8()) == []
