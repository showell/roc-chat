## This module reads a single file in the form the compose box sends to
## upload an image.
##
## The form is `multipart/form-data`: its parts are split by a boundary,
## which its Content-Type header names (`boundary_from_content_type`). The
## compose box sends one part, named `file`, so the file is the first part
## and runs to the form's closing delimiter at the end of the body
## (`file_part`). In a form of that shape, only the opening delimiter and
## the part's headers are searched, so a large image's bytes are never
## scanned. A form of any other shape holds no file.
import Ascii

MultipartForm :: [].{

	## The bytes that split a form's parts: 1 to 70 of them, as RFC 2046
	## allows. Only `boundary_from_content_type` makes one.
	Boundary :: List(U8).{
		is_eq : _
	}

	## The boundary a form's Content-Type names
	## (`multipart/form-data; boundary=...`, quoted or not); unless it names
	## none, or one of a length RFC 2046 does not allow, when the form holds
	## no file this module reads (`NoFile`).
	boundary_from_content_type : List(U8) -> Try(MultipartForm.Boundary, [NoFile])
	boundary_from_content_type = |header| {
		key = "boundary=".to_utf8()
		at = index_of(header, { needle: key, from: 0 }) ? |NotFound| NoFile
		value = header.drop_first(at + key.len())
		candidate =
			match value {
				['"', .. as rest] =>
					match rest.find_first_index(|b| b == '"') {
						Ok(end) => rest.take_first(end)
						Err(NotFound) => []
					}
				_ => Ascii.trim_spaces(before_first(value, ';'))
			}
		if (candidate.is_empty() or candidate.len() > 70) Err(NoFile) else Ok(MultipartForm.Boundary.(candidate))
	}

	## The file in the form `body`, whose parts `boundary` splits: the
	## first part, which must be named `file`, with its filename (`image`
	## when it gives none) and its bytes, up to the form's closing delimiter
	## at the body's end; else `NoFile`.
	file_part : List(U8), MultipartForm.Boundary -> Try({ filename : List(U8), bytes : List(U8) }, [NoFile])
	file_part = |body, MultipartForm.Boundary.(boundary)| {
		delimiter = "--".to_utf8().concat(boundary)
		opening = index_of(body, { needle: delimiter, from: 0 }) ? |NotFound| NoFile
		headers_at = opening + delimiter.len() + 2
		if (body.sublist({ start: opening + delimiter.len(), len: 2 }) != "\r\n".to_utf8())
			Err(NoFile)
		else {
			headers_end = index_of(body, { needle: "\r\n\r\n".to_utf8(), from: headers_at }) ? |NotFound| NoFile
			headers = body.sublist({ start: headers_at, len: headers_end - headers_at })
			closing = "\r\n".to_utf8().concat(delimiter).concat("--".to_utf8())
			file_and_closing = body.drop_first(headers_end + 4).drop_last(trailing_line_breaks(body))
			if (quoted_attribute(headers, "name") != Ok("file".to_utf8()) or !file_and_closing.ends_with(closing))
				Err(NoFile)
			else {
				filename =
					match quoted_attribute(headers, "filename") {
						Ok(given) => given
						Err(Missing) => "image".to_utf8()
					}
				Ok({ filename, bytes: file_and_closing.drop_last(closing.len()) })
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

## How many CRs and LFs end `body`: a client may end the form with a line
## break after its closing delimiter.
trailing_line_breaks : List(U8) -> U64
trailing_line_breaks = |body| count_from_end(body, |b| b == '\r' or b == '\n')

## How many bytes from the end pass `passes`.
count_from_end : List(U8), (U8 -> Bool) -> U64
count_from_end = |bytes, passes|
	match bytes.find_last_index(|b| !passes(b)) {
		Ok(i) => bytes.len() - 1 - i
		Err(NotFound) => bytes.len()
	}

## A quoted `<name>="value"` in a part's headers. A letter just before `name` puts the match inside
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

## Does a letter come just before `at` in `headers`?
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

## The boundary a form's Content-Type names after `boundary=`, as a test
## reads it, or why there is none.
boundary_after : Str -> Try(Str, [NoFile])
boundary_after = |given|
	MultipartForm.boundary_from_content_type("multipart/form-data; boundary=${given}".to_utf8())
		.map_ok(|MultipartForm.Boundary.(bytes)| Str.from_utf8_lossy(bytes))

## The boundary `text`, from a Content-Type, as a form's would be.
boundary : Str -> MultipartForm.Boundary
boundary = |text| MultipartForm.boundary_from_content_type("multipart/form-data; boundary=${text}".to_utf8()) ?? crash "MultipartForm's tests: a test's boundary is one"

## The file in the form `body`, whose boundary is `XyZ`.
file_of : List(U8) -> Try({ filename : List(U8), bytes : List(U8) }, [NoFile])
file_of = |body| MultipartForm.file_part(body, boundary("XyZ"))

## A file part's headers, naming it `file` and no filename.
file_part_headers : Str
file_part_headers = "Content-Disposition: form-data; name=\"file\""

# The boundary, quoted or not, up to a `;`, with ASCII spaces trimmed.
expect boundary_after("XyZ") == Ok("XyZ")
expect boundary_after("\"a b\"; x=1") == Ok("a b")
expect boundary_after("XyZ; charset=x") == Ok("XyZ")
expect boundary_after(" XyZ\t; x=1") == Ok("XyZ")
expect boundary_after("\"a;b\"") == Ok("a;b")
# None, an empty one, an unclosed quote, or one past 70 bytes: no file.
expect MultipartForm.boundary_from_content_type("multipart/form-data".to_utf8()) == Err(NoFile)
expect boundary_after("") == Err(NoFile)
expect boundary_after("\"\"") == Err(NoFile)
expect boundary_after("\"XyZ") == Err(NoFile)
expect boundary_after("b".repeat(70)) == Ok("b".repeat(70))
expect boundary_after("b".repeat(71)) == Err(NoFile)
expect boundary_after("b") == Ok("b")
# The media type is not checked: a Content-Type that is no form, such as
# `text/plain`, still names a boundary.
expect
	MultipartForm.boundary_from_content_type("text/plain; boundary=x".to_utf8()).map_ok(|MultipartForm.Boundary.(bytes)| bytes)
		== Ok("x".to_utf8())
# The file: its name and its bytes exactly, a CR LF and a near delimiter
# inside them kept.
expect {
	data = png.concat("\r\n--Xy".to_utf8())
	got = file_of(
		form({
			headers: "${file_part_headers}; filename=\"cat.png\"\r\nContent-Type: image/png",
			file: data,
		}),
	)
	got == Ok({ filename: "cat.png".to_utf8(), bytes: data })
}
# No line break after the closing delimiter, or two: the same file.
expect {
	body = "--XyZ\r\n${file_part_headers}\r\n\r\n".to_utf8().concat(png).concat("\r\n--XyZ--".to_utf8())
	file_of(body) == Ok({ filename: "image".to_utf8(), bytes: png })
		and file_of(body.concat("\r\n\r\n".to_utf8())) == Ok({ filename: "image".to_utf8(), bytes: png })
}
# `name` is read past the one inside `filename`, and at the headers' very
# start; a `name` only inside `filename` is no name.
expect file_of(form({ headers: "Content-Disposition: form-data; filename=\"x\"; name=\"file\"", file: png })) == Ok({ filename: "x".to_utf8(), bytes: png })
expect file_of(form({ headers: "name=\"file\"", file: png })) == Ok({ filename: "image".to_utf8(), bytes: png })
expect file_of(form({ headers: "Content-Disposition: form-data; filename=\"file\"", file: png })) == Err(NoFile)
# An empty file is a file, of no bytes.
expect file_of(form({ headers: file_part_headers, file: [] })) == Ok({ filename: "image".to_utf8(), bytes: [] })
# Another field, another boundary, no closing delimiter, no empty line
# after the headers, no CR LF after the opening delimiter, nothing: no file.
expect file_of(form({ headers: "Content-Disposition: form-data; name=\"other\"", file: png })) == Err(NoFile)
expect MultipartForm.file_part(form({ headers: file_part_headers, file: png }), boundary("Abc")) == Err(NoFile)
expect file_of("--XyZ\r\n${file_part_headers}\r\n\r\n".to_utf8().concat(png)) == Err(NoFile)
expect file_of("--XyZ\r\n${file_part_headers}\r\n".to_utf8().concat(png)) == Err(NoFile)
expect file_of("--XyZ${file_part_headers}\r\n\r\n".to_utf8().concat(png).concat("\r\n--XyZ--".to_utf8())) == Err(NoFile)
expect file_of([]) == Err(NoFile)
# The browser's name: UTF-8 as it is; else ASCII kept and the rest U+FFFD.
expect MultipartForm.display_name("café.png".to_utf8()) == "café.png"
expect MultipartForm.display_name(['a', 0xFF, 'b']) == "a\u(FFFD)b"
expect MultipartForm.display_name([0xC3]) == "\u(FFFD)"
