## An image uploaded to a conversation: what kind of image it is, and the
## name it is kept and served under. Pure.
##
## The kind is judged by the file's opening bytes (`kind_of_bytes`): PNG,
## JPEG, GIF or WebP, never what the browser's filename or type says, and
## anything else is refused. An image is at most 10 MiB (`most_bytes`).
##
## The name is 32 lowercase hex digits, from 16 random bytes, then `.` and
## the extension the kind gives (`fresh`), so no name a person chose reaches
## the disk or a URL. A name read back from a URL (`from_name`) must have
## exactly that shape, and its extension gives its kind. Where an image is
## kept and served is `ConversationKey`'s.
import Ascii

UploadedImage :: { kind : UploadedImage.Kind, name : Str }.{

	## The kinds of image an upload may be.
	Kind : [Png, Jpeg, Gif, Webp]

	## The most bytes one image may be.
	most_bytes : U64
	most_bytes = 10 * 1024 * 1024

	## The kind of image `bytes` are, by how they open; unless they open as
	## none of the four (`NotAnImage`).
	kind_of_bytes : List(U8) -> Try(UploadedImage.Kind, [NotAnImage])
	kind_of_bytes = |bytes|
		if (bytes.starts_with(png_signature))
			Ok(Png)
		else if (bytes.starts_with([0xFF, 0xD8, 0xFF]))
			Ok(Jpeg)
		else if (bytes.starts_with("GIF87a".to_utf8()) or bytes.starts_with("GIF89a".to_utf8()))
			Ok(Gif)
		else if (bytes.starts_with("RIFF".to_utf8()) and bytes.sublist({ start: 8, len: 4 }) == "WEBP".to_utf8())
			Ok(Webp)
		else
			Err(NotAnImage)

	## A fresh image of `kind`, named by `random_bytes`, which are 16 bytes
	## from the host's secure source.
	fresh : { random_bytes : List(U8), kind : UploadedImage.Kind } -> UploadedImage
	fresh = |{ random_bytes, kind }|
		if random_bytes.len() == name_random_bytes {
			digits = Str.from_utf8(random_bytes.join_map(hex_digits)) ?? crash "UploadedImage.fresh: hex digits are ASCII"
			UploadedImage.({ kind, name: "${digits}.${extension(kind)}" })
		} else
			crash "UploadedImage.fresh: a name takes 16 random bytes"

	## The image a name read back from a URL names: 32 lowercase hex digits,
	## `.`, and one kind's extension; anything else is `NotAnUploadName`.
	from_name : Str -> Try(UploadedImage, [NotAnUploadName])
	from_name = |text|
		match text.to_utf8().split_first('.') {
			Ok({ before, after }) if before.len() == name_random_bytes * 2 and before.all(is_lower_hex_digit) => {
				kind = kind_of_extension(after)?
				Ok(UploadedImage.({ kind, name: text }))
			}
			_ => Err(NotAnUploadName)
		}

	## Its name, as its file and its URL end.
	name : UploadedImage -> Str
	name = |UploadedImage.(image)| image.name

	## Its kind.
	kind : UploadedImage -> UploadedImage.Kind
	kind = |UploadedImage.(image)| image.kind

	## Its type, as it is served.
	content_type : UploadedImage -> Str
	content_type = |UploadedImage.(image)|
		match image.kind {
			Png => "image/png"
			Jpeg => "image/jpeg"
			Gif => "image/gif"
			Webp => "image/webp"
		}

	is_eq : _
}

## How many random bytes name an image.
name_random_bytes : U64
name_random_bytes = 16

## The eight bytes every PNG file opens with.
png_signature : List(U8)
png_signature = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n']

## The extension a name gives an image of `kind`.
extension : UploadedImage.Kind -> Str
extension = |kind|
	match kind {
		Png => "png"
		Jpeg => "jpg"
		Gif => "gif"
		Webp => "webp"
	}

## The kind whose extension `bytes` spell.
kind_of_extension : List(U8) -> Try(UploadedImage.Kind, [NotAnUploadName])
kind_of_extension = |bytes|
	[
		Png,
		Jpeg,
		Gif,
		Webp,
	].find_first(|kind| extension(kind).to_utf8() == bytes).map_err(|_| NotAnUploadName)

## A byte as two lowercase hex digits.
hex_digits : U8 -> List(U8)
hex_digits = |byte| [hex_digit(byte // 16), hex_digit(byte % 16)]

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

is_lower_hex_digit : U8 -> Bool
is_lower_hex_digit = |b| Ascii.is_digit(b) or (b >= 'a' and b <= 'f')

# ── tests
# An image is what its bytes say: each kind at its opening bytes.
expect UploadedImage.kind_of_bytes(png_signature.concat([0, 0])) == Ok(Png)
expect UploadedImage.kind_of_bytes(png_signature) == Ok(Png)
expect UploadedImage.kind_of_bytes([0xFF, 0xD8, 0xFF, 0xE0]) == Ok(Jpeg)
expect UploadedImage.kind_of_bytes("GIF89a..".to_utf8()) == Ok(Gif)
expect UploadedImage.kind_of_bytes("GIF87a".to_utf8()) == Ok(Gif)
expect UploadedImage.kind_of_bytes("RIFF\u(0)\u(0)\u(0)\u(0)WEBPVP8 ".to_utf8()) == Ok(Webp)
# Anything else is none, a kind's opening cut short or one byte off among it.
expect
	[
		"",
		"PNG",
		"GIF88a",
		"RIFF....WAVE",
		"RIFF....WEB",
		"<svg>",
		"%PDF-1.4",
		"hello, not an image",
	].all(|text| UploadedImage.kind_of_bytes(text.to_utf8()) == Err(NotAnImage))
expect UploadedImage.kind_of_bytes([0x89, 'P', 'N', 'G']) == Err(NotAnImage)
expect UploadedImage.kind_of_bytes([0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, 'x']) == Err(NotAnImage)
expect UploadedImage.kind_of_bytes([0xFF, 0xD8]) == Err(NotAnImage)
expect UploadedImage.most_bytes == 10485760
# A fresh name: the random bytes in lowercase hex, and its kind's extension.
expect
	UploadedImage.fresh({ random_bytes: List.repeat(0xAB, 16), kind: Webp }).name()
		== "${"ab".repeat(16)}.webp"
expect
	UploadedImage.fresh({ random_bytes: List.from_iter(U8.until(0, 16)), kind: Png }).name()
		== "000102030405060708090a0b0c0d0e0f.png"

## A fresh image of `kind`, as a test reads it: its name, then its type.
fresh_said : UploadedImage.Kind -> Str
fresh_said = |kind| {
	image = UploadedImage.fresh({ random_bytes: List.repeat(0xF0, 16), kind })
	"${image.name()} ${image.content_type()}"
}

expect fresh_said(Png) == "${"f0".repeat(16)}.png image/png"
expect fresh_said(Jpeg) == "${"f0".repeat(16)}.jpg image/jpeg"
expect fresh_said(Gif) == "${"f0".repeat(16)}.gif image/gif"
expect fresh_said(Webp) == "${"f0".repeat(16)}.webp image/webp"
expect UploadedImage.fresh({ random_bytes: List.repeat(0, 16), kind: Jpeg }).kind() == Jpeg
# A name read back: exactly a fresh name's shape, its kind by its extension.
expect {
	image = UploadedImage.fresh({ random_bytes: List.repeat(0x5C, 16), kind: Gif })
	UploadedImage.from_name(image.name()) == Ok(image)
}
expect UploadedImage.from_name("${"0".repeat(32)}.jpg").map_ok(UploadedImage.kind) == Ok(Jpeg)
expect UploadedImage.from_name("${"9".repeat(32)}.webp").map_ok(UploadedImage.kind) == Ok(Webp)
expect
	[
		"${"0".repeat(31)}.png",
		"${"0".repeat(33)}.png",
		"${"A".repeat(32)}.png",
		"${"g".repeat(32)}.png",
		"${"0".repeat(32)}.svg",
		"${"0".repeat(32)}.PNG",
		"${"0".repeat(32)}.jpeg",
		"${"0".repeat(32)}.png.png",
		"${"0".repeat(32)}.",
		"${"0".repeat(32)}",
		"../${"0".repeat(29)}.png",
		"cat.png",
		"",
	].all(|text| UploadedImage.from_name(text) == Err(NotAnUploadName))
