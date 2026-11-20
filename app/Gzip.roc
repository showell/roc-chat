## This module wraps bytes in the gzip format (RFC 1952), as a `.tar.gz`
## holds its tar (`Tar`, `DownloadRoute`). The bytes are stored, not
## compressed: deflate's stored blocks (RFC 1951, 3.2.4), each at most
## 65,535 bytes, the last marked final. So the output is the input's size,
## 18 bytes of gzip's header and trailer, and 5 bytes a block. The trailer
## holds the input's CRC-32, which the caller asks the host for
## (`Host.crc32_of_bytes!`), and its size, so a reader checks it whole.
Gzip :: [].{

	## `bytes` in gzip, stored in deflate's uncompressed blocks, its trailer
	## holding `crc32`, the CRC-32 of `bytes`.
	stored_file : { bytes : List(U8), crc32 : U32 } -> List(U8)
	stored_file = |{ bytes, crc32 }| {
		blocks = bytes.chunks_of(Gzip.most_block_bytes)
		var $out = List.with_capacity(bytes.len() + 18 + 5 * (blocks.len() + 1))
		$out = List.concat($out, header)
		if blocks.is_empty() {
			$out = List.concat($out, block_head({ size: 0, last: Last }))
		} else {
			var $left = blocks.len()
			for block in blocks {
				$left = $left - 1
				last = if $left == 0 {
					Last
				} else {
					NotLast
				}
				$out = List.concat($out, block_head({ size: block.len(), last }))
				$out = List.concat($out, block)
			}
		}
		$out = List.concat($out, little_endian(crc32))
		List.concat($out, little_endian(bytes.len().to_u32_wrap()))
	}

	## The most bytes one stored block holds.
	most_block_bytes : U64
	most_block_bytes = 65535
}

## Gzip's header: its magic, deflate, no flags, no time, no extra flags,
## and an unknown system.
header : List(U8)
header = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255]

## A stored block's head: its type and whether it is the last (one byte,
## as each block starts on a byte), then its size and the size's
## complement, two bytes each.
block_head : { size : U64, last : [Last, NotLast] } -> List(U8)
block_head = |{ size, last }| {
	final_bit =
		match last {
			Last => 1
			NotLast => 0
		}
	low = (size % 256).to_u8_wrap()
	high = (size // 256).to_u8_wrap()
	[
		final_bit,
		low,
		high,
		255 - low,
		255 - high,
	]
}

## A number's four bytes, the lowest first.
little_endian : U32 -> List(U8)
little_endian = |number| [
	(number % 256).to_u8_wrap(),
	(number // 256 % 256).to_u8_wrap(),
	(number // 65536 % 256).to_u8_wrap(),
	(number // 16777216).to_u8_wrap(),
]

# ── tests
# A short input: the header, one final block, the CRC lowest byte first,
# and the size. `hi`'s CRC-32 is 0xD8932AAC.
expect {
	trailer = [0xAC, 0x2A, 0x93, 0xD8, 2, 0, 0, 0]
	block = [1, 2, 0, 253, 255, 'h', 'i']
	made = Gzip.stored_file({ bytes: "hi".to_utf8(), crc32: 0xD8932AAC })
	made == [header, block, trailer].join()
}
# None: one empty final block.
expect
	Gzip.stored_file({ bytes: [], crc32: 0 })
		== List.concat(header, [1, 0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0])
# At a block's size one block; one byte past it, two, the first not final.
expect {
	full = List.repeat(7, Gzip.most_block_bytes)
	at = Gzip.stored_file({ bytes: full, crc32: 0 })
	past = Gzip.stored_file({ bytes: full.append(7), crc32: 0 })
	at.len() == 10 + 5 + 65535 + 8
		and at.sublist({ start: 10, len: 5 }) == [1, 255, 255, 0, 0]
		and past.len() == 10 + 5 + 65535 + 5 + 1 + 8
		and past.sublist({ start: 10, len: 5 }) == [0, 255, 255, 0, 0]
		and past.sublist({ start: 10 + 5 + 65535, len: 6 }) == [1, 1, 0, 254, 255, 7]
		and past.sublist({ start: past.len() - 4, len: 4 }) == [0, 0, 1, 0]
}
# The trailer's numbers, lowest byte first, at each byte's edge.
expect little_endian(0x01020304) == [4, 3, 2, 1]
expect little_endian(0xFFFFFFFF) == [255, 255, 255, 255]
