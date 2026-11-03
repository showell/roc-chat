## The one file in the form the compose box sends to upload an image,
## read as the old Zig chat read it (its `parseMultipartFile`), by way of
## roc-chat's `Uploads`. Pure.
##
## The form is `multipart/form-data`, its parts split by the boundary its
## Content-Type names (`boundary_from_content_type`). The compose box sends
## one part, named `file`, so the file is the first part and runs to the
## form's closing delimiter at the end of the body (`file_part`). The image's
## bytes are never searched, so a large image costs no scan. A form of any
## other shape holds no file.
import Ascii

MultipartForm :: [].{

	## The boundary a form's parts are split by, from its Content-Type
	## (`multipart/form-data; boundary=...`, quoted or not): 1 to 70 bytes,
	## as RFC 2046 allows; else the form holds no file we read (`NoFile`).
	boundary_from_content_type : List(U8) -> Try(List(U8), [NoFile])
	boundary_from_content_type = |header| {
		at = index_of(header, { needle: "boundary=".to_utf8(), from: 0 }) ? |NotFound| NoFile
		value = header.drop_first(at + 9)
		bare =
			match value {
				['"', .. as rest] =>
					match rest.find_first_index(|b| b == '"') {
						Ok(end) => rest.take_first(end)
						Err(NotFound) => []
					}
				_ => trimmed_of_spaces(before_first(value, ';'))
			}
		if (bare.is_empty() or bare.len() > 70) Err(NoFile) else Ok(bare)
	}

	## The file in the form `body` whose parts `boundary` splits: the first
	## part, named `file`, its filename (`image` when it gives none) and its
	## bytes, up to the form's closing delimiter at the body's end; else
	## `NoFile`.
	file_part : List(U8), List(U8) -> Try({ filename : List(U8), bytes : List(U8) }, [NoFile])
	file_part = |body, boundary| {
		delimiter = "--".to_utf8().concat(boundary)
		opening = index_of(body, { needle: delimiter, from: 0 }) ? |NotFound| NoFile
		headers_at = opening + delimiter.len() + 2
		if (body.sublist({ start: opening + delimiter.len(), len: 2 }) != "\r\n".to_utf8())
			Err(NoFile)
		else {
			headers_end = index_of(body, { needle: "\r\n\r\n".to_utf8(), from: headers_at }) ? |NotFound| NoFile
			headers = body.sublist({ start: headers_at, len: headers_end - headers_at })
			closing = "\r\n".to_utf8().concat(delimiter).concat("--".to_utf8())
			kept = body.drop_first(headers_end + 4).drop_last(trailing_line_breaks(body))
			if (quoted_attribute(headers, "name") != Ok("file".to_utf8()) or !kept.ends_with(closing))
				Err(NoFile)
			else {
				filename =
					match quoted_attribute(headers, "filename") {
						Ok(given) => given
						Err(Missing) => "image".to_utf8()
					}
				Ok({ filename, bytes: kept.drop_last(closing.len()) })
			}
		}
	}

	## The browser's name for the file, as text: as sent when it is UTF-8;
	## else its ASCII bytes kept and each other byte U+FFFD, as the old
	## chat's `displayName` wrote it.
	display_name : List(U8) -> Str
	display_name = |raw|
		match Str.from_utf8(raw) {
			Ok(text) => text
			Err(_) =>
				Str.from_utf8(raw.join_map(|b| if (b < 0x80) [b] else "\u(FFFD)".to_utf8())) ?? crash "MultipartForm.display_name: ASCII and U+FFFD are UTF-8"
		}
}

## Where `needle` first starts in `bytes`, at `from` or after.
index_of : List(U8), { needle : List(U8), from : U64 } -> Try(U64, [NotFound])
index_of = |bytes, { needle, from }|
	if (from + needle.len() > bytes.len())
		Err(NotFound)
	else if (bytes.sublist({ start: from, len: needle.len() }) == needle)
		Ok(from)
	else
		index_of(bytes, { needle, from: from + 1 })

## The bytes before the first `stop`, or all of them.
before_first : List(U8), U8 -> List(U8)
before_first = |bytes, stop|
	match bytes.find_first_index(|b| b == stop) {
		Ok(i) => bytes.take_first(i)
		Err(NotFound) => bytes
	}

## `bytes` with the ASCII spaces, tabs, CRs and LFs off both ends: a
## header's value, whose spaces are ASCII alone.
trimmed_of_spaces : List(U8) -> List(U8)
trimmed_of_spaces = |bytes| {
	is_space = |b| b == ' ' or b == '\t' or b == '\r' or b == '\n'
	front = bytes.drop_first(count_from_start(bytes, is_space))
	front.drop_last(count_from_end(front, is_space))
}

## How many CRs and LFs end `body`: a client may end the form with a line
## break after its closing delimiter.
trailing_line_breaks : List(U8) -> U64
trailing_line_breaks = |body| count_from_end(body, |b| b == '\r' or b == '\n')

## How many bytes from the start pass `test`.
count_from_start : List(U8), (U8 -> Bool) -> U64
count_from_start = |bytes, passes|
	match bytes.find_first_index(|b| !passes(b)) {
		Ok(i) => i
		Err(NotFound) => bytes.len()
	}

## How many bytes from the end pass `test`.
count_from_end : List(U8), (U8 -> Bool) -> U64
count_from_end = |bytes, passes|
	match bytes.find_last_index(|b| !passes(b)) {
		Ok(i) => bytes.len() - 1 - i
		Err(NotFound) => bytes.len()
	}

## A quoted `<name>="value"` in a part's headers, as the old chat's
## `attrVal` read one. A letter just before `name` puts the match inside
## another attribute's name (`name` in `filename`), so the search goes on.
quoted_attribute : List(U8), Str -> Try(List(U8), [Missing])
quoted_attribute = |headers, name| quoted_attribute_from(headers, { needle: name.to_utf8().concat("=\"".to_utf8()), from: 0 })

quoted_attribute_from : List(U8), { needle : List(U8), from : U64 } -> Try(List(U8), [Missing])
quoted_attribute_from = |headers, { needle, from }|
	match index_of(headers, { needle, from }) {
		Err(NotFound) => Err(Missing)
		Ok(i) => {
			if (is_inside_another_name(headers, i))
				quoted_attribute_from(headers, { needle, from: i + 1 })
			else {
				value = headers.drop_first(i + needle.len())
				match value.find_first_index(|b| b == '"') {
					Ok(end) => Ok(value.take_first(end))
					Err(NotFound) => Err(Missing)
				}
			}
		}
	}

## Whether a letter comes just before `at` in `headers`.
is_inside_another_name : List(U8), U64 -> Bool
is_inside_another_name = |headers, at|
	if (at == 0)
		Bool.False
	else
		match headers.get(at - 1) {
			Ok(before) => Ascii.is_letter(before)
			Err(OutOfBounds) => crash "MultipartForm.is_inside_another_name: a match is inside the headers"
		}

# ── tests
png : List(U8)
png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0]

## A form as a browser sends one file: its boundary `XyZ`, the part's
## headers, the bytes, the closing delimiter and a line break.
form : { headers : Str, file : List(U8) } -> List(U8)
form = |{ headers, file }|
	"--XyZ\r\n${headers}\r\n\r\n".to_utf8().concat(file).concat("\r\n--XyZ--\r\n".to_utf8())

# The boundary, quoted or not, up to a `;`; none, or one past 70 bytes, is no form.
expect MultipartForm.boundary_from_content_type("multipart/form-data; boundary=XyZ".to_utf8()) == Ok("XyZ".to_utf8())
expect MultipartForm.boundary_from_content_type("multipart/form-data; boundary=\"a b\"; x=1".to_utf8()) == Ok("a b".to_utf8())
expect MultipartForm.boundary_from_content_type("multipart/form-data; boundary=XyZ; charset=x".to_utf8()) == Ok("XyZ".to_utf8())
expect MultipartForm.boundary_from_content_type("multipart/form-data".to_utf8()) == Err(NoFile)
expect MultipartForm.boundary_from_content_type("multipart/form-data; boundary=".to_utf8()) == Err(NoFile)
expect MultipartForm.boundary_from_content_type("multipart/form-data; boundary=\"\"".to_utf8()) == Err(NoFile)
expect MultipartForm.boundary_from_content_type("multipart/form-data; boundary=${"b".repeat(71)}".to_utf8()) == Err(NoFile)
expect MultipartForm.boundary_from_content_type("multipart/form-data; boundary=${"b".repeat(70)}".to_utf8()) == Ok("b".repeat(70).to_utf8())
# The file: its name and its bytes exactly, a CR LF and a near delimiter
# inside them kept.
expect {
	data = png.concat("\r\n--Xy".to_utf8())
	got = MultipartForm.file_part(
		form({
			headers: "Content-Disposition: form-data; name=\"file\"; filename=\"cat.png\"\r\nContent-Type: image/png",
			file: data,
		}),
		"XyZ".to_utf8(),
	)
	got == Ok({ filename: "cat.png".to_utf8(), bytes: data })
}
# No line break after the closing delimiter, or two: the same file.
expect {
	body = "--XyZ\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\n".to_utf8().concat(png).concat("\r\n--XyZ--".to_utf8())
	MultipartForm.file_part(body, "XyZ".to_utf8()) == Ok({ filename: "image".to_utf8(), bytes: png })
		and MultipartForm.file_part(body.concat("\r\n\r\n".to_utf8()), "XyZ".to_utf8()) == Ok({ filename: "image".to_utf8(), bytes: png })
}
# `name` read past the one inside `filename`.
expect {
	got = MultipartForm.file_part(form({ headers: "Content-Disposition: form-data; filename=\"x\"; name=\"file\"", file: png }), "XyZ".to_utf8())
	got == Ok({ filename: "x".to_utf8(), bytes: png })
}
# An empty file is a file, of no bytes.
expect MultipartForm.file_part(form({ headers: "Content-Disposition: form-data; name=\"file\"", file: [] }), "XyZ".to_utf8()) == Ok({ filename: "image".to_utf8(), bytes: [] })
# Another field, another boundary, no closing delimiter, no blank line, nothing: no file.
expect MultipartForm.file_part(form({ headers: "Content-Disposition: form-data; name=\"other\"", file: png }), "XyZ".to_utf8()) == Err(NoFile)
expect MultipartForm.file_part(form({ headers: "Content-Disposition: form-data; name=\"file\"", file: png }), "Abc".to_utf8()) == Err(NoFile)
expect MultipartForm.file_part("--XyZ\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\n".to_utf8().concat(png), "XyZ".to_utf8()) == Err(NoFile)
expect MultipartForm.file_part("--XyZ\r\nContent-Disposition: form-data; name=\"file\"\r\n".to_utf8().concat(png), "XyZ".to_utf8()) == Err(NoFile)
expect MultipartForm.file_part("--XyZContent-Disposition: form-data; name=\"file\"\r\n\r\n".to_utf8().concat(png).concat("\r\n--XyZ--".to_utf8()), "XyZ".to_utf8()) == Err(NoFile)
expect MultipartForm.file_part([], "XyZ".to_utf8()) == Err(NoFile)
# The browser's name: UTF-8 as it is; else ASCII kept and the rest U+FFFD.
expect MultipartForm.display_name("café.png".to_utf8()) == "café.png"
expect MultipartForm.display_name(['a', 0xFF, 'b']) == "a\u(FFFD)b"
expect MultipartForm.display_name([0xC3]) == "\u(FFFD)"
