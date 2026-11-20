## This module writes a tar archive in the ustar format (POSIX.1-1988), as
## a conversation's download holds its files (`DownloadRoute`, which wraps
## it in `Gzip`). Each entry is a regular file: a 512-byte header, then its
## bytes padded with zeros to a multiple of 512. Two zero blocks end the
## archive.
##
## A header holds a path of up to 256 bytes as a name of up to 100 and a
## prefix of up to 155, split at a `/`. A path no header can hold is
## refused (`PathTooLong`), never cut: two paths cut to the same bytes would
## unpack one over the other. Each file is dated `mtime`, mode 0644, owned
## by user and group 0.
Tar :: [].{

	## One file of an archive: its path in the archive, and its bytes.
	Entry : { path : Str, bytes : List(U8) }

	## The archive of `entries`, in order, each dated `mtime` (seconds since
	## 1970); unless a path is one no header can hold.
	archive : { entries : List(Tar.Entry), mtime : U64 } -> Try(List(U8), [PathTooLong(Str)])
	archive = |{ entries, mtime }| {
		size = entries.fold(1024, |so_far, entry| so_far + 512 + padded_size(entry.bytes.len()))
		var $out = List.with_capacity(size)
		for entry in entries {
			parts = path_parts(entry.path.to_utf8()) ? |PathTooLong| PathTooLong(entry.path)
			$out = $out
				.concat(header({ parts, size: entry.bytes.len(), mtime }))
				.concat(entry.bytes)
				.concat(List.repeat(0, padded_size(entry.bytes.len()) - entry.bytes.len()))
		}
		Ok($out.concat(List.repeat(0, 1024)))
	}
}

## `size` rounded up to a multiple of 512.
padded_size : U64 -> U64
padded_size = |size| (size + 511) // 512 * 512

## A path as a header holds it: all name when it is at most 100 bytes, else
## a prefix and a name split at the last `/` that leaves a name of at most
## 100 bytes, not empty, and a prefix of at most 155.
path_parts : List(U8) -> Try({ prefix : List(U8), name : List(U8) }, [PathTooLong])
path_parts = |path|
	if path.len() <= 100 {
		Ok({ prefix: [], name: path })
	} else {
		var $at = path.len()
		var $found = Err(PathTooLong)
		while $at > 0 {
			$at = $at - 1
			if path.get($at) == Ok('/') {
				name_size = path.len() - $at - 1
				if name_size > 100 {
					$at = 0
				} else if $at <= 155 and name_size > 0 {
					$found = Ok({ prefix: path.take_first($at), name: path.drop_first($at + 1) })
					$at = 0
				} else {
					{}
				}
			} else {
				{}
			}
		}
		$found
	}

## A regular file's header: its parts, size and time.
header : { parts : { prefix : List(U8), name : List(U8) }, size : U64, mtime : U64 } -> List(U8)
header = |{ parts, size, mtime }| {
	before_sum = List.join([
		field(parts.name, 100),
		octal({ value: 0o644, width: 8 }),
		octal({ value: 0, width: 8 }),
		octal({ value: 0, width: 8 }),
		octal({ value: size, width: 12 }),
		octal({ value: mtime, width: 12 }),
	])
	after_sum = List.join([
		['0'],
		List.repeat(0, 100),
		"ustar".to_utf8().append(0),
		"00".to_utf8(),
		List.repeat(0, 32 + 32 + 8 + 8),
		field(parts.prefix, 155),
		List.repeat(0, 12),
	])
	# The sum counts the checksum's own eight bytes as spaces.
	sum = List.concat(before_sum, after_sum).fold(8 * 32, |so_far, byte| so_far + byte.to_u64())
	List.join([before_sum, octal_digits({ value: sum, width: 6 }), [0, ' '], after_sum])
}

## `bytes` in a field of `width`, the rest zeros.
field : List(U8), U64 -> List(U8)
field = |bytes, width| bytes.concat(List.repeat(0, width - bytes.len()))

## `value` as a numeric field: `width` less one octal digits, zero-padded,
## then a NUL.
octal : { value : U64, width : U64 } -> List(U8)
octal = |{ value, width }| octal_digits({ value, width: width - 1 }).append(0)

## `value` as exactly `width` octal digits, zero-padded.
octal_digits : { value : U64, width : U64 } -> List(U8)
octal_digits = |{ value, width }| {
	var $digits = List.repeat('0', width)
	var $left = value
	var $at = width
	while $at > 0 {
		$at = $at - 1
		$digits = $digits.set($at, '0' + ($left % 8).to_u8_wrap()) ?? crash "Tar.octal_digits: an index inside the field"
		$left = $left // 8
	}
	$digits
}

# ── tests
# A tiny archive, byte for byte: one file `a/b.md` holding `hi`, dated 1.
expect {
	made = Tar.archive({ entries: [{ path: "a/b.md", bytes: "hi".to_utf8() }], mtime: 1 })
	expected_header = List.join([
		field("a/b.md".to_utf8(), 100),
		"0000644".to_utf8().append(0),
		"0000000".to_utf8().append(0),
		"0000000".to_utf8().append(0),
		"00000000002".to_utf8().append(0),
		"00000000001".to_utf8().append(0),
		"006721".to_utf8(),
		[0, ' ', '0'],
		List.repeat(0, 100),
		"ustar".to_utf8().append(0),
		"00".to_utf8(),
		List.repeat(0, 247),
	])
	made
		== Ok(
			List.join([expected_header, "hi".to_utf8(), List.repeat(0, 510), List.repeat(0, 1024)]),
		)
}
# None: the two zero blocks alone.
expect Tar.archive({ entries: [], mtime: 0 }) == Ok(List.repeat(0, 1024))
# A file's bytes padded to 512: none, one, 512 and 513 bytes.
expect [(0, 0), (1, 512), (512, 512), (513, 1024)].all(|(size, padded)| padded_size(size) == padded)
# A path of 100 bytes is all name; one of 101 splits at its last `/`.
expect path_parts(List.repeat('n', 100)) == Ok({ prefix: [], name: List.repeat('n', 100) })
expect path_parts(List.repeat('n', 101)) == Err(PathTooLong)
expect
	path_parts("d/".to_utf8().concat(List.repeat('n', 99)))
		== Ok({ prefix: ['d'], name: List.repeat('n', 99) })
# A name after the `/` of 100 bytes fits, of 101 does not; nor an empty one.
expect path_parts("d/".to_utf8().concat(List.repeat('n', 100))).is_ok()
expect path_parts("d/".to_utf8().concat(List.repeat('n', 101))) == Err(PathTooLong)
expect path_parts(List.repeat('p', 101).append('/')) == Err(PathTooLong)
# A prefix of 155 fits, of 156 does not.
expect path_parts(List.repeat('p', 155).concat("/n".to_utf8())).is_ok()
expect path_parts(List.repeat('p', 156).concat("/n".to_utf8())) == Err(PathTooLong)
# A path too long is refused by name, nothing made.
expect
	Tar.archive({ entries: [{ path: Str.repeat("p", 300), bytes: [] }], mtime: 0 })
		== Err(PathTooLong(Str.repeat("p", 300)))
# The longest download path of a topic of 60 bytes: its reactions file.
expect {
	topic = Str.repeat("t", 60)
	path_parts("${topic}/${topic}.reactions.jsonl".to_utf8()).is_ok()
}
