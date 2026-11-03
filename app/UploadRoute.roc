## This module answers the two upload routes: a POST of an image from the
## compose box, and a GET of an uploaded image. It follows the old Zig
## chat's `handleUpload` and `serveUpload` (angry-gopher's chat_upload.zig),
## by way of roc-chat's.
##
## A POST holds a form of one file (`MultipartForm`). The file must be an
## image by its opening bytes and at most 10 MiB (`UploadedImage`). Its
## bytes are then counted against the uploader's lifetime allowance
## (`UploadTotal`): the total is read, the image's size added, and the new
## total written, all before the image is stored, so no image is kept
## uncounted. The server answers one request at a time, so nothing comes
## between the read and the write. The image is kept in its conversation's
## folder under a fresh name (`FileSystem.store_uploaded_image!`), and the
## answer is JSON giving its URL and the browser's name for it, which the
## compose box puts in the message as an `<img>`. An image that can't be
## stored gives its bytes back to the allowance.
##
## A refusal is a line of plain text in the old words, which the compose
## box shows as it is: no file is a 400, not an image a 415, too large a
## 413, and an allowance used up a 403. A total that can't be read, or isn't
## a number, is a 500, and nothing is stored.
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
import SignedIn
import UploadTotal
import UploadedImage
import UserFolder

UploadRoute :: [].{

	## POST: the image in `body`, a form of the Content-Type in `headers`,
	## counted against the allowance of the user `acting`, kept in the
	## conversation `key`, and its URL answered as JSON.
	post_upload! : {
		key : ConversationKey,
		acting : SignedIn,
		headers : List(Http.Header),
		body : List(U8),
	} => Http.Response
	post_upload! = |
		{
			key,
			acting,
			headers,
			body,
		},
	|
		match keep_upload!({
			key,
			acting,
			headers,
			body,
		}) {
			Ok(answer_json) => HttpAnswer.json(200, answer_json)
			Err(why) => upload_refusal_response(why)
		}

	## GET: the conversation `key`'s uploaded `image`, as kept; a 404 when
	## the conversation has none of its name.
	serve_uploaded_image! : { key : ConversationKey, image : UploadedImage } => Http.Response
	serve_uploaded_image! = |{ key, image }|
		match FileSystem.read_uploaded_image!(key, image) {
			Ok(bytes) => HttpAnswer.image({ content_type: image.content_type(), bytes })
			Err(Missing) => HttpAnswer.notice(404, { title: "Not found", said: "No such image." })
			Err(fault) => HttpAnswer.notice(500, { title: "Failed", said: FileSystem.fault_words(fault) })
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
		match RequestHeader.header_value(headers, "content-type") {
			Sent(value) => Ok(value)
			Unsent | Repeated => Err(NoFile)
		}?
	boundary = MultipartForm.boundary_from_content_type(content_type)?
	file = MultipartForm.file_part(body, boundary)?
	kind = UploadedImage.checked_bytes(file.bytes)?
	Ok({
		kind,
		filename: file.filename,
		bytes: file.bytes,
	})
}

## The image in a POST's form, counted against the allowance of the user
## `acting` and kept in the conversation `key`: the JSON that answers it;
## or why it was refused, or couldn't be counted or kept.
keep_upload! : {
	key : ConversationKey,
	acting : SignedIn,
	headers : List(Http.Header),
	body : List(U8),
} => Try(
	List(U8),
	[
		NoFile,
		NotAnImage,
		TooLarge,
		LimitReached,
		NotANumber,
		FileSystem(FileSystem.Fault),
	],
)
keep_upload! = |
	{
		key,
		acting,
		headers,
		body,
	},
| {
	upload = image_upload_from_form({ headers, body })?
	folder = UserFolder.of(acting.user().id())
	before = reserve_upload_bytes!(folder, upload.bytes.len())?
	image = UploadedImage.fresh({ random_bytes: Host.fill_with_random_bytes!(UploadedImage.random_bytes_per_name), kind: upload.kind })
	match FileSystem.store_uploaded_image!(key, { image, bytes: upload.bytes }) {
		Ok({}) =>
			Ok(
				upload_answer_json({
					url: key.url_path(UploadedImage(image)),
					name: MultipartForm.display_name(upload.filename),
				}),
			)
		Err(fault) => {
			# The image's bytes go back to the allowance. The answer is the
			# image's 500 either way, and the host logs a failed write of the
			# total.
			_ = FileSystem.replace_upload_total!(folder, before)
			Err(FileSystem(fault))
		}
	}
}

## The user's upload total before an upload of `adding` bytes, once the
## total with them is written to their folder; unless that would pass the
## allowance (`LimitReached`), or the total can't be read or written.
reserve_upload_bytes! : UserFolder,
U64 => Try(
	UploadTotal,
	[
		LimitReached,
		NotANumber,
		FileSystem(FileSystem.Fault),
	],
)
reserve_upload_bytes! = |folder, adding| {
	before =
		match FileSystem.read_upload_total!(folder) {
			Ok(total) => Ok(total)
			Err(NotANumber) => Err(NotANumber)
			Err(NotUtf8) => Err(FileSystem(NotUtf8))
			Err(PathRefused) => Err(FileSystem(PathRefused))
			Err(Failed) => Err(FileSystem(Failed))
		}?
	after = before.with_upload(adding)?
	FileSystem.replace_upload_total!(folder, after) ? |fault| FileSystem(fault)
	Ok(before)
}

## An upload refused, in the old chat's words, as a line of plain text; or
## one that couldn't be counted or kept, a 500 saying that the user's
## upload total is no number, or what the file system answered.
upload_refusal_response : [
	NoFile,
	NotAnImage,
	TooLarge,
	LimitReached,
	NotANumber,
	FileSystem(FileSystem.Fault),
] -> Http.Response
upload_refusal_response = |why|
	match why {
		NoFile => HttpAnswer.text(400, "no file")
		NotAnImage => HttpAnswer.text(415, "unsupported file type (images: png, jpeg, gif, webp)")
		TooLarge => HttpAnswer.text(413, "image too large — the limit is 10 MB.")
		LimitReached => HttpAnswer.text(403, "Upload limit reached — you've used your ${UploadTotal.most_gib.to_str()} GB upload allowance.")
		NotANumber => HttpAnswer.text(500, "Upload failed: your upload total is not a number.")
		FileSystem(fault) => HttpAnswer.text(500, "Upload failed. ${FileSystem.fault_words(fault)}")
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
expect {
	answered = upload_refusal_response(LimitReached)
	answered.status == 403 and answered.body == "Upload limit reached — you've used your 1 GB upload allowance.\n".to_utf8()
}
expect {
	answered = upload_refusal_response(NotANumber)
	answered.status == 500 and answered.body == "Upload failed: your upload total is not a number.\n".to_utf8()
}
expect {
	answered = upload_refusal_response(FileSystem(AlreadyExists))
	answered.status == 500 and answered.body == "Upload failed. The file system answered AlreadyExists.\n".to_utf8()
}
# The answer: the URL and the name, the name's quote, backslash and
# control bytes escaped, so it stays one JSON string.
expect
	upload_answer_json({ url: "/chat/dm/1_1/plans/uploads/a.png", name: "c\"a\\t\n\u(1)é.png" })
		== "{\"url\":\"/chat/dm/1_1/plans/uploads/a.png\",\"name\":\"c\\\"a\\\\t\\n\\u0001é.png\",\"kind\":\"image\",\"width\":0,\"height\":0}".to_utf8()
