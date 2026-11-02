## **A TOPIC'S UPLOADED IMAGES** (the old app's, angry-gopher's
## chat_upload.zig; Steve, 2026-11-02: kept in the topic's own folder, read
## by its readers alone). Pure: what an upload is, how one is read out of
## the compose box's form, what it is named, where it is served, and what
## its uploader has spent.
##
## - **AN IMAGE IS WHAT ITS BYTES SAY** (the old `detectImageExt`): PNG,
##   JPEG, GIF or WebP by their opening bytes, never by the browser's
##   filename or type; anything else is refused in the old words.
## - **10 MiB AN IMAGE** (the old image cap), and **1 GiB IN ALL A HUMAN'S
##   LIFE** (the old `max_upload_lifetime_bytes`), kept as the old
##   `upload-bytes` file kept it: the bytes spent, in decimal.
## - **ITS NAME IS FRESH AND SAYS ITS KIND**: 32 lowercase hex digits (16
##   random bytes) and the extension its bytes give, so no name a person
##   chose reaches the disk or a URL.
## - **ITS URL NAMES ITS TOPIC BY KEYS**: `/chat/uploads/<channel>/<topic>/
##   <name>`, the same for every reader, where a DM's page path is the
##   viewer's (`/chat/dm/<the other>/…`); the old one named the
##   conversation, the same for both, too.
import Bytes
import JsonOut
import SignInWeb
import Topic

Uploads := [].{

	## The images an upload may be.
	Image : [Png, Jpeg, Gif, Webp]

	## The most one image may be.
	image_most : U64
	image_most = 10 * 1024 * 1024

	## **THE MOST A FORM HOLDING ONE MAY BE**: the image and room for the
	## form around it; the host reads an upload's body to the same
	## (host/server.zig, `upload_most`).
	body_most : U64
	body_most = Uploads.image_most + 64 * 1024

	## The most a human may upload in all.
	allowance : U64
	allowance = 1024 * 1024 * 1024

	## **WHAT IMAGE THE BYTES ARE**, by how they open.
	sniff : List(U8) -> Try(Uploads.Image, [NotAnImage])
	sniff = |bytes|
		if bytes.starts_with([0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n']) {
			Ok(Png)
		} else if bytes.starts_with([0xFF, 0xD8, 0xFF]) {
			Ok(Jpeg)
		} else if bytes.starts_with("GIF87a".to_utf8()) or bytes.starts_with("GIF89a".to_utf8()) {
			Ok(Gif)
		} else if bytes.starts_with("RIFF".to_utf8()) and bytes.sublist({ start: 8, len: 4 }) == "WEBP".to_utf8() {
			Ok(Webp)
		} else {
			Err(NotAnImage)
		}

	## Its extension, as its name ends.
	ext : Uploads.Image -> Str
	ext = |image|
		match image {
			Png => "png"
			Jpeg => "jpg"
			Gif => "gif"
			Webp => "webp"
		}

	## Its type, as it is served.
	content_type : Uploads.Image -> List(U8)
	content_type = |image|
		match image {
			Png => "image/png".to_utf8()
			Jpeg => "image/jpeg".to_utf8()
			Gif => "image/gif".to_utf8()
			Webp => "image/webp".to_utf8()
		}

	## **THE BOUNDARY A FORM'S PARTS ARE SPLIT BY**, from its Content-Type
	## (`multipart/form-data; boundary=…`, quoted or not): 1 to 70 bytes
	## (RFC 2046), or no form we read.
	boundary_of : List(U8) -> Try(List(U8), [NoFile])
	boundary_of = |header| {
		at = Bytes.find(header, { needle: "boundary=".to_utf8(), at: 0 }).map_err(|_| NoFile)?
		value = header.drop_first(at + 9)
		bare =
			match value {
				['"', .. as rest] =>
					match rest.find_first_index(|b| b == '"') {
						Ok(end) => rest.take_first(end)
						Err(NotFound) => []
					}
				_ => Bytes.trim(up_to(value, ';'), " \t\r\n".to_utf8())
			}
		if (bare.is_empty() or bare.len() > 70) Err(NoFile) else Ok(bare)
	}

	## **THE FILE IN THE COMPOSE BOX'S FORM** (the old `parseMultipartFile`,
	## for the one field the box sends): its first part, named `file`, its
	## filename (`image` when it gives none) and its bytes, to the form's
	## closing delimiter at its end. A form of any other shape is no file.
	file_of : List(U8), List(U8) -> Try({ filename : List(U8), uploaded : List(U8) }, [NoFile])
	file_of = |body, boundary| {
		delim = "--".to_utf8().concat(boundary)
		opening = Bytes.find(body, { needle: delim, at: 0 }).map_err(|_| NoFile)?
		heads_at = opening + delim.len() + 2
		if body.sublist({ start: opening + delim.len(), len: 2 }) != "\r\n".to_utf8() {
			Err(NoFile)
		} else {
			heads_end = Bytes.find(body, { needle: "\r\n\r\n".to_utf8(), at: heads_at }).map_err(|_| NoFile)?
			heads = body.sublist({ start: heads_at, len: heads_end - heads_at })
			data_at = heads_end + 4
			closing = "\r\n".to_utf8().concat(delim).concat("--".to_utf8())
			kept = body.drop_first(data_at).drop_last(trailing_crlf(body))
			if attr_of(heads, "name") != Ok("file".to_utf8()) or !kept.ends_with(closing) {
				Err(NoFile)
			} else {
				Ok({
					filename: attr_of(heads, "filename") ?? "image".to_utf8(),
					uploaded: kept.drop_last(closing.len()),
				})
			}
		}
	}

	## **THE BROWSER'S NAME, AS TEXT** (the old `displayName`): as sent when
	## it is UTF-8; else its ASCII bytes kept and each other byte U+FFFD.
	display_name : List(U8) -> Str
	display_name = |raw|
		match Str.from_utf8(raw) {
			Ok(text) => text
			Err(_) =>
				Str.from_utf8(raw.join_map(|b| if (b < 0x80) [b] else "\u(FFFD)".to_utf8())) ?? "image"
		}

	## **A FRESH NAME** for an image: `random` (16 bytes) in hex, and its
	## extension.
	name_of : List(U8), Uploads.Image -> Str
	name_of = |random, image|
		match Str.from_utf8(SignInWeb.hex(random)) {
			Ok(digits) => "${digits}.${Uploads.ext(image)}"
			Err(_) => crash "Uploads.name_of: hex is ASCII"
		}

	## **THE IMAGE A NAME IN A PATH SAYS IT IS**: 32 lowercase hex digits,
	## a `.`, and an image's extension; anything else names no upload.
	image_named : List(U8) -> Try(Uploads.Image, [NotAnUpload])
	image_named = |name|
		match name.split_first('.') {
			Ok({ before, after }) if before.len() == 32 and before.all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')) =>
				if after == "png".to_utf8() {
					Ok(Png)
				} else if after == "jpg".to_utf8() {
					Ok(Jpeg)
				} else if after == "gif".to_utf8() {
					Ok(Gif)
				} else if after == "webp".to_utf8() {
					Ok(Webp)
				} else {
					Err(NotAnUpload)
				}
			_ => Err(NotAnUpload)
		}

	## **WHERE AN UPLOAD IS SERVED**, the same for every reader.
	url : Topic.At, Str -> Str
	url = |at, name| "${Uploads.prefix}${at.channel.key()}/${at.topic.key()}/${name}"

	## The path every upload's URL starts with: the renderer's rule for
	## where a message's image may load from (Render.markdown).
	prefix : Str
	prefix = "/chat/uploads/"

	## **THE UPLOAD'S ANSWER** (the old one's): its URL, the browser's name
	## for it, its kind, and no size (0 and 0: the page's script then gives
	## the image no width or height).
	answer : { url : Str, name : Str } -> JsonOut
	answer = |{ url: at, name }|
		JsonOut.object([
			("url", JsonOut.string(at)),
			("name", JsonOut.string(name)),
			("kind", JsonOut.string("image")),
			("width", JsonOut.number(0)),
			("height", JsonOut.number(0)),
		])

	## **WHAT A HUMAN HAS SPENT, AS KEPT**: decimal digits, space around
	## them passed over, as the old file was read.
	uploaded_from : List(U8) -> Try(U64, [Unreadable])
	uploaded_from = |kept| {
		digits = Bytes.trim(kept, " \t\r\n".to_utf8())
		if digits.is_empty() or !digits.all(|b| b >= '0' and b <= '9') {
			Err(Unreadable)
		} else {
			U64.from_int_digits(digits.map(|b| b - '0')).map_err(|_| Unreadable)
		}
	}

	## What a human has spent, as it is kept: decimal, nothing else.
	uploaded_text : U64 -> List(U8)
	uploaded_text = |n| n.to_str().to_utf8()
}

## The bytes before the first `stop`, or all of them.
up_to : List(U8), U8 -> List(U8)
up_to = |bytes, stop|
	match bytes.find_first_index(|b| b == stop) {
		Ok(i) => bytes.take_first(i)
		Err(NotFound) => bytes
	}

## How many bytes of CR and LF end `body`.
trailing_crlf : List(U8) -> U64
trailing_crlf = |body| Bytes.count_back(body, |b| b == '\r' or b == '\n')

## **A QUOTED `<attr>="value"` IN A PART'S HEADERS** (the old `attrVal`):
## where a letter comes just before `attr`, it is inside another's name
## (`name` in `filename`), and the next one is looked for.
attr_of : List(U8), Str -> Try(List(U8), [Missing])
attr_of = |heads, attr| attr_from(heads, { needle: attr.to_utf8().concat("=\"".to_utf8()), at: 0 })

attr_from : List(U8), { needle : List(U8), at : U64 } -> Try(List(U8), [Missing])
attr_from = |heads, { needle, at }|
	match Bytes.find(heads, { needle, at }) {
		Err(NotFound) => Err(Missing)
		Ok(i) => {
			before = if (i > 0) heads.get(i - 1) ?? ' ' else ' '
			inside = is_letter(before)
			value = heads.drop_first(i + needle.len())
			if inside {
				attr_from(heads, { needle, at: i + 1 })
			} else {
				match value.find_first_index(|b| b == '"') {
					Ok(end) => Ok(value.take_first(end))
					Err(NotFound) => Err(Missing)
				}
			}
		}
	}

is_letter : U8 -> Bool
is_letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

# ── tests
png : List(U8)
png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0]

## A form as a browser sends one file: its boundary, the part's headers,
## the bytes, the closing delimiter.
form : { heads : Str, file : List(U8) } -> List(U8)
form = |{ heads, file }|
	"--XyZ\r\n${heads}\r\n\r\n".to_utf8().concat(file).concat("\r\n--XyZ--\r\n".to_utf8())

# An image is what its bytes say; anything else is none.
expect Uploads.sniff(png) == Ok(Png)
expect Uploads.sniff([0xFF, 0xD8, 0xFF, 0xE0]) == Ok(Jpeg)
expect Uploads.sniff("GIF89a..".to_utf8()) == Ok(Gif) and Uploads.sniff("GIF87a".to_utf8()) == Ok(Gif)
expect Uploads.sniff("RIFF\u(0)\u(0)\u(0)\u(0)WEBPVP8 ".to_utf8()) == Ok(Webp)
expect
	[
		"",
		"PNG",
		"GIF88a",
		"RIFF....WAVE",
		"<svg>",
		"%PDF-1.4",
	].all(|bytes| Uploads.sniff(bytes.to_utf8()) == Err(NotAnImage))
expect Uploads.sniff([0x89, 'P', 'N', 'G']) == Err(NotAnImage)

# The boundary, quoted or not, up to a `;`; none, or one past 70 bytes, no form.
expect Uploads.boundary_of("multipart/form-data; boundary=XyZ".to_utf8()) == Ok("XyZ".to_utf8())
expect Uploads.boundary_of("multipart/form-data; boundary=\"a b\"; x=1".to_utf8()) == Ok("a b".to_utf8())
expect Uploads.boundary_of("multipart/form-data; boundary=XyZ; charset=x".to_utf8()) == Ok("XyZ".to_utf8())
expect Uploads.boundary_of("multipart/form-data".to_utf8()) == Err(NoFile)
expect Uploads.boundary_of("multipart/form-data; boundary=".to_utf8()) == Err(NoFile)
expect Uploads.boundary_of("multipart/form-data; boundary=${Str.repeat("b", 71)}".to_utf8()) == Err(NoFile)
expect Uploads.boundary_of("multipart/form-data; boundary=${Str.repeat("b", 70)}".to_utf8()).is_ok()

# The file: its name and its bytes, exactly, a CR LF inside them kept.
expect {
	data = png.concat("\r\n--Xy".to_utf8())
	got = Uploads.file_of(
		form({
			heads: "Content-Disposition: form-data; name=\"file\"; filename=\"cat.png\"\r\nContent-Type: image/png",
			file: data,
		}),
		"XyZ".to_utf8(),
	)
	got == Ok({ filename: "cat.png".to_utf8(), uploaded: data })
}
# No filename: "image"; `name` read past the one inside `filename`.
expect {
	got = Uploads.file_of(form({ heads: "Content-Disposition: form-data; filename=\"x\"; name=\"file\"", file: png }), "XyZ".to_utf8())
	got == Ok({ filename: "x".to_utf8(), uploaded: png })
}
expect Uploads.file_of(form({ heads: "Content-Disposition: form-data; name=\"file\"", file: png }), "XyZ".to_utf8()) == Ok({ filename: "image".to_utf8(), uploaded: png })
# Another field, another boundary, no closing delimiter, no blank line: no file.
expect Uploads.file_of(form({ heads: "Content-Disposition: form-data; name=\"other\"", file: png }), "XyZ".to_utf8()) == Err(NoFile)
expect Uploads.file_of(form({ heads: "Content-Disposition: form-data; name=\"file\"", file: png }), "Abc".to_utf8()) == Err(NoFile)
expect Uploads.file_of("--XyZ\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\n".to_utf8().concat(png), "XyZ".to_utf8()) == Err(NoFile)
expect Uploads.file_of("--XyZ\r\nContent-Disposition: form-data; name=\"file\"\r\n".to_utf8().concat(png), "XyZ".to_utf8()) == Err(NoFile)
expect Uploads.file_of([], "XyZ".to_utf8()) == Err(NoFile)

# A browser's name: UTF-8 as is; else ASCII kept and the rest U+FFFD.
expect Uploads.display_name("café.png".to_utf8()) == "café.png"
expect Uploads.display_name(['a', 0xFF, 'b']) == "a\u(FFFD)b"

# A fresh name: the random bytes in hex, its extension; read back, its kind.
expect {
	name = Uploads.name_of(List.repeat(0xAB, 16), Webp)
	name == "${Str.repeat("ab", 16)}.webp" and Uploads.image_named(name.to_utf8()) == Ok(Webp)
}
expect Uploads.image_named("${Str.repeat("0", 32)}.jpg".to_utf8()) == Ok(Jpeg)
expect
	[
		"${Str.repeat("0", 31)}.png",
		"${Str.repeat("0", 33)}.png",
		"${Str.repeat("A", 32)}.png",
		"${Str.repeat("0", 32)}.svg",
		"${Str.repeat("0", 32)}.png.png",
		"${Str.repeat("0", 32)}",
		"../${Str.repeat("0", 29)}.png",
	].all(|name| Uploads.image_named(name.to_utf8()) == Err(NotAnUpload))

# What was spent: decimal, space around it passed over; else unreadable.
expect Uploads.uploaded_from("1234".to_utf8()) == Ok(1234) and Uploads.uploaded_from(" 7\n".to_utf8()) == Ok(7)
expect Uploads.uploaded_from("".to_utf8()) == Err(Unreadable) and Uploads.uploaded_from("-1".to_utf8()) == Err(Unreadable) and Uploads.uploaded_from("1e3".to_utf8()) == Err(Unreadable)
expect Uploads.uploaded_from(Uploads.uploaded_text(Uploads.allowance)) == Ok(Uploads.allowance)
expect Uploads.answer({ url: "/chat/uploads/a/b/c.png", name: "a\"b" }).bytes() == "{\"url\":\"/chat/uploads/a/b/c.png\",\"name\":\"a\\\"b\",\"kind\":\"image\",\"width\":0,\"height\":0}".to_utf8()
