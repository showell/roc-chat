## BYTES AS ZIG'S std.mem HANDLES THEM: the searches, scans and trims the
## chat's modules share, each in one place (`std.mem.indexOf`,
## `indexOfScalar`, `trim`, `trimRight`, `order`), on bytes, never Str; the
## splits and prefixes are List's own (`split_on`, `split_on_list`,
## `starts_with`), and a byte's class is Ascii's. Pure.

Bytes := [].{

	join_lines : List(List(U8)) -> List(U8)
	join_lines = |lines| List.join(List.intersperse(lines, ['\n']))

	## The bytes before and after the first `needle`.
	cut_seq : List(U8), List(U8) -> Try((List(U8), List(U8)), [NotFound])
	cut_seq = |s, needle| {
		i = find(s, { needle, at: 0 })?
		Ok((List.take_first(s, i), List.drop_first(s, i + List.len(needle))))
	}

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

	## std.mem.order of bytes: byte by byte, a prefix first.
	compare : List(U8),
	List(U8) -> [
		Before,
		Same,
		After,
	]
	compare = |a, b| match (a, b) {
		([x, .. as ra], [y, .. as rb]) => if x < y Before else if x > y After else compare(ra, rb)
		([], []) => Same
		([], _) => Before
		_ => After
	}

	## **A BYTE'S NEXT PLACE, REMEMBERED** (metal-vmm QUEUE 268): what one
	## search found (`At`), or that there is none (`Never`), answers every
	## later search from a place at or before it, so a scan that searches
	## from each of many openers (`<img ` after `<img `, `![` after `![`)
	## costs one pass of a message, not one per opener. `from` must not go
	## back between calls that share one.
	Seen : [
		Unknown,
		At(U64),
		Never,
	]

	find_seen : List(U8),
	{
		byte : U8,
		from : U64,
		seen : Seen,
	} -> (Try(U64, [NotFound]), Seen)
	find_seen = |
		s,
		{
			byte: b,
			from,
			seen,
		},
	|
		match seen {
			At(k) if k >= from => (Ok(k), seen)
			Never => (Err(NotFound), Never)
			_ =>
				match find_byte(s, { byte: b, at: from }) {
					Ok(k) => (Ok(k), At(k))
					Err(NotFound) => (Err(NotFound), Never)
				}
		}

	find_byte : List(U8), { byte : U8, at : U64 } -> Try(U64, [NotFound])
	find_byte = |s, { byte: b, at: i }| match List.get(s, i) {
		Ok(c) => if c == b Ok(i) else find_byte(s, { byte: b, at: i + 1 })
		Err(_) => Err(NotFound)
	}

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

	## `std.mem.trim(u8, s, set)`: the bytes in `set` off both ends.
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

	## `std.mem.trimRight(u8, s, set)`: the bytes in `set` off the end.
	trim_end : List(U8), List(U8) -> List(U8)
	trim_end = |s, set| List.drop_last(
		s,
		count_back(s, { keep: |c| List.contains(set, c), kept: 0 }),
	)

	## The four bytes the Zig's sidecar readers trim, `std.mem.trim(u8, s,
	## " \t\r\n")`: not `Ascii.is_whitespace`, which has VT and FF too.
	zig_spaces : List(U8)
	zig_spaces = [
		' ',
		'\t',
		'\r',
		'\n',
	]

}
