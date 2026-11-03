## This module answers the two upload routes: a POST of an image from the
## compose box, and a GET of an uploaded image. It follows the old Zig
## chat's `handleUpload` and `serveUpload` (angry-gopher's chat_upload.zig),
## by way of roc-chat's.
##
## A POST holds a form of one file (`MultipartForm`). The file must be an
## image by its opening bytes and at most 10 MiB (`UploadedImage`). The
## image is kept in its conversation's folder under a fresh name
## (`FileSystem.store_uploaded_image!`), and the answer is JSON giving its
## URL and the browser's name for it, which the compose box puts in the
## message as an `<img>`. A refusal is a line of plain text in the old
## words, which the compose box shows as it is: no file is a 400, not an
## image a 415, and too large a 413.
##
## A GET answers an image of the conversation its URL names, by its name,
## with its type and `nosniff`. An image is only ever found under its own
## conversation, so a name under another conversation is a 404.
import pf.Host
import pf.Http
import ConversationKey
import FileSystem
import HttpAnswer
import MultipartForm
import RequestHeader
import UploadedImage

UploadRoute :: [].{

	## POST: the image in `body`, a form of the Content-Type in `headers`,
	## kept in the conversation `key`, and its URL answered as JSON.
	post_upload! : {
		key : ConversationKey,
		headers : List(Http.Header),
		body : List(U8),
	} => Http.Response
	post_upload! = |
		{
			key,
			headers,
			body,
		},
	|
		match image_upload_from_form({ headers, body }) {
			Err(why) => upload_refusal_response(why)
			Ok(upload) => {
				image = UploadedImage.fresh({ random_bytes: Host.fill_with_random_bytes!(16), kind: upload.kind })
				match FileSystem.store_uploaded_image!(key, { image, bytes: upload.bytes }) {
					Ok({}) =>
						HttpAnswer.json(
							200,
							upload_answer_json({
								url: key.uploaded_image_url_path(image),
								name: MultipartForm.display_name(upload.filename),
							}),
						)
					Err(fault) => upload_failure_response(fault)
				}
			}
		}

	## GET: the conversation `key`'s uploaded `image`, as kept; a 404 when
	## the conversation has none of its name.
	serve_uploaded_image! : { key : ConversationKey, image : UploadedImage } => Http.Response
	serve_uploaded_image! = |{ key, image }|
		match FileSystem.read_uploaded_image!(key, image) {
			Ok(bytes) => HttpAnswer.image({ content_type: image.content_type(), bytes })
			Err(Missing) => HttpAnswer.notice(404, { title: "Not found", said: "No such image." })
			Err(PathRefused) => HttpAnswer.notice(500, { title: "Failed", said: "The file system answered PathRefused." })
			Err(Failed) => HttpAnswer.notice(500, { title: "Failed", said: "The file system answered Failed." })
		}
}

## The image a POST's form holds: its kind, the browser's filename and its
## bytes; or why it is refused.
image_upload_from_form : { headers : List(Http.Header), body : List(U8) } -> Try(
	{
		kind : UploadedImage.Kind,
		filename : List(U8),
		bytes : List(U8),
	},
	[
		NoFile,
		NotAnImage,
		TooLarge,
	],
)
image_upload_from_form = |{ headers, body }| {
	content_type =
		match RequestHeader.sent(headers, "content-type") {
			Sent(value) => Ok(value)
			Unsent | Repeated => Err(NoFile)
		}?
	boundary = MultipartForm.boundary_from_content_type(content_type)?
	file = MultipartForm.file_part(body, boundary)?
	kind = UploadedImage.kind_of_bytes(file.bytes)?
	_ = image_size_checked(file.bytes.len())?
	Ok({
		kind,
		filename: file.filename,
		bytes: file.bytes,
	})
}

## An image's size, `count` bytes, unless it is over the most an image
## may be.
image_size_checked : U64 -> Try(U64, [TooLarge])
image_size_checked = |count| if (count > UploadedImage.most_bytes) Err(TooLarge) else Ok(count)

## An upload refused, in the old chat's words, as a line of plain text.
upload_refusal_response : [NoFile, NotAnImage, TooLarge] -> Http.Response
upload_refusal_response = |why|
	match why {
		NoFile => HttpAnswer.text(400, "no file")
		NotAnImage => HttpAnswer.text(415, "unsupported file type (images: png, jpeg, gif, webp)")
		TooLarge => HttpAnswer.text(413, "image too large — the limit is 10 MB.")
	}

## The file system failed to keep an upload: a 500, naming what the host
## answered (and the host's log says which file, and why).
upload_failure_response : [AlreadyExists, MissingDirectory, PathRefused, Failed] -> Http.Response
upload_failure_response = |fault| {
	said =
		match fault {
			AlreadyExists => "AlreadyExists"
			MissingDirectory => "MissingDirectory"
			PathRefused => "PathRefused"
			Failed => "Failed"
		}
	HttpAnswer.text(500, "Upload failed: the file system answered ${said}.")
}

## The answer to an upload, as the old chat's was: the image's URL, the
## browser's name for it, its kind, and no size (0 and 0, so the compose
## box gives the image no width or height).
upload_answer_json : { url : Str, name : Str } -> List(U8)
upload_answer_json = |{ url, name }|
	"{\"url\":${json_string(url)},\"name\":${json_string(name)},\"kind\":\"image\",\"width\":0,\"height\":0}".to_utf8()

## Text as a JSON string: quoted, its `"` and `\` escaped, a line feed as
## `\n`, and every other control byte as `\u00XX`, as roc-chat's `JsonOut`
## writes one.
json_string : Str -> Str
json_string = |text| {
	escaped = text.to_utf8().join_map(
		|b|
			if (b == '"')
				['\\', '"']
			else if (b == '\\')
				['\\', '\\']
			else if (b == '\n')
				['\\', 'n']
			else if (b < 0x20 or b == 0x7F)
				"\\u00".to_utf8().concat([hex_digit(b // 16), hex_digit(b % 16)])
			else
				[b],
	)
	"\"${Str.from_utf8(escaped) ?? crash "UploadRoute.json_string: escaping UTF-8 keeps it UTF-8"}\""
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

# ── tests
png : List(U8)
png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0]

## A form as the compose box sends one file, with its Content-Type.
form_of : { filename : Str, file : List(U8) } -> { headers : List(Http.Header), body : List(U8) }
form_of = |{ filename, file }| {
	headers: [{ name: "Content-Type".to_utf8(), value: "multipart/form-data; boundary=XyZ".to_utf8() }],
	body: "--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"${filename}\"\r\nContent-Type: image/png\r\n\r\n"
		.to_utf8()
		.concat(file)
		.concat("\r\n--XyZ--\r\n".to_utf8()),
}

# An image, by its bytes whatever its name.
expect
	image_upload_from_form(form_of({ filename: "cat.png", file: png }))
		== Ok({
			kind: Png,
			filename: "cat.png".to_utf8(),
			bytes: png,
		})
expect image_upload_from_form(form_of({ filename: "cat.txt", file: png })).map_ok(|u| u.kind) == Ok(Png)
# Its size: at the most and under it, and one byte over. (The end to end
# sends both whole.)
expect image_size_checked(UploadedImage.most_bytes) == Ok(UploadedImage.most_bytes)
expect image_size_checked(1) == Ok(1)
expect image_size_checked(UploadedImage.most_bytes + 1) == Err(TooLarge)
# Refused: not an image, no form, no file in it.
expect image_upload_from_form(form_of({ filename: "cat.png", file: "hello, not an image".to_utf8() })) == Err(NotAnImage)
expect image_upload_from_form({ headers: [], body: form_of({ filename: "cat.png", file: png }).body }) == Err(NoFile)
expect
	image_upload_from_form({
		headers: [
			{ name: "content-type".to_utf8(), value: "multipart/form-data; boundary=XyZ".to_utf8() },
			{ name: "content-type".to_utf8(), value: "multipart/form-data; boundary=XyZ".to_utf8() },
		],
		body: form_of({ filename: "cat.png", file: png }).body,
	})
		== Err(NoFile)
expect image_upload_from_form({ headers: form_of({ filename: "c", file: png }).headers, body: "markdown=x".to_utf8() }) == Err(NoFile)
# Each refusal: its status and its words, a line of plain text.
expect {
	answered = upload_refusal_response(NoFile)
	answered.status == 400 and answered.body == "no file\n".to_utf8()
}
expect {
	answered = upload_refusal_response(NotAnImage)
	answered.status == 415 and answered.body == "unsupported file type (images: png, jpeg, gif, webp)\n".to_utf8()
}
expect {
	answered = upload_refusal_response(TooLarge)
	answered.status == 413 and answered.body == "image too large — the limit is 10 MB.\n".to_utf8()
}
expect upload_failure_response(Failed).status == 500
expect upload_failure_response(AlreadyExists).body == "Upload failed: the file system answered AlreadyExists.\n".to_utf8()
# The answer: the URL and the name, the name's quote, backslash and
# control bytes escaped, so it stays one JSON string.
expect
	upload_answer_json({ url: "/chat/dm/1_1/plans/uploads/a.png", name: "c\"a\\t\n\u(1)é.png" })
		== "{\"url\":\"/chat/dm/1_1/plans/uploads/a.png\",\"name\":\"c\\\"a\\\\t\\n\\u0001é.png\",\"kind\":\"image\",\"width\":0,\"height\":0}".to_utf8()
