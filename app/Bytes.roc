## BYTE SEARCHES AND TRIMS THE CODECS SHARE: finding a run of bytes,
## counting the bytes that keep a test from either end, and trimming a set
## off both ends, on bytes, never Str (a stored line or a name is bytes
## until it is checked). Splits and prefix tests are List's own
## (`split_on`, `starts_with`), and a byte's class is Ascii's. Pure.

Bytes := [].{

	## Where `needle` first starts in `s`, from `at` on.
	find : List(U8), { needle : List(U8), at : U64 } -> Try(U64, [NotFound])
	find = |s, { needle, at: i }|
		if i + List.len(needle) > List.len(s) {
			Err(NotFound)
		} else if List.get(s, i) == List.first(needle) and List.sublist(
			s,
			{ start: i, len: List.len(needle) },
		) == needle {
			Ok(i)
		} else {
			find(s, { needle, at: i + 1 })
		}

	## The bytes after `prefix`, when `l` starts with it: no length is
	## written beside the literal it belongs to.
	strip_prefix : List(U8), List(U8) -> Try(List(U8), [NoMatch])
	strip_prefix = |l, prefix| if List.starts_with(l, prefix) Ok(
		List.drop_first(
			l,
			List.len(prefix),
		),
	) else Err(NoMatch)

	## How many bytes from `i` on keep `keep`.
	count_while : List(U8), { keep : (U8 -> Bool), at : U64 } -> U64
	count_while = |s, { keep, at: i }| match List.get(s, i) {
		Ok(c) if keep(c) => count_while(s, { keep, at: i + 1 })
		_ => i
	}

	## How many bytes from the end keep `keep`.
	count_back : List(U8), { keep : (U8 -> Bool), kept : U64 } -> U64
	count_back = |s, { keep, kept: n }|
		if n >= List.len(s) {
			n
		} else {
			match List.get(s, List.len(s) - 1 - n) {
				Ok(c) if keep(c) => count_back(s, { keep, kept: n + 1 })
				_ => n
			}
		}

	## The bytes in `set` off both ends.
	trim : List(U8), List(U8) -> List(U8)
	trim = |s, set| {
		in_set = |c| List.contains(set, c)
		front = List.drop_first(
			s,
			count_while(s, { keep: in_set, at: 0 }),
		)
		List.drop_last(
			front,
			count_back(front, { keep: in_set, kept: 0 }),
		)
	}
}

expect Bytes.find(Str.to_utf8("a=b=c"), { needle: Str.to_utf8("="), at: 2 }) == Ok(3)
expect Bytes.find(Str.to_utf8("abc"), { needle: Str.to_utf8("cd"), at: 0 }) == Err(NotFound)
expect Bytes.trim(Str.to_utf8("  x y \n"), Str.to_utf8(" \n")) == Str.to_utf8("x y")
expect Bytes.trim(Str.to_utf8("   "), Str.to_utf8(" ")) == []
