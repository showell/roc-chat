## This module answers the two upload routes: a POST of an image from the
## compose box, and a GET of an uploaded image.
##
## A POST holds a form of one file (`MultipartForm`). The file must be an
## image by its opening bytes and at most 10 MiB (`UploadedImage`). Its
## bytes are then counted against the uploader's lifetime allowance
## (`UploadTotal`): the total is read, the image's size added, and the new
## total written, all before the image is stored, so no image is kept
## uncounted. The image is kept in its conversation's
## folder under a fresh name (`FileSystem.store_uploaded_image!`), and the
## answer is JSON giving its URL and the browser's name for it, which the
## compose box puts in the message as an `<img>`. An image that can't be
## stored gives its bytes back to the allowance, and its 500 says when they
## could not be given back.
##
## A refusal is a line of plain text saying why, which the compose
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
import JsonOut
import MultipartForm
import Page
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
	post_upload! = |{ key, acting, headers, body }|
		match keep_upload!({ key, acting, headers, body }) {
			Ok(answer_json) => HttpAnswer.json(answer_json)
			Err(why) => upload_refusal_response(why)
		}

	## GET: the conversation `key`'s uploaded `image`, as kept; a 404 when
	## the conversation has none of its name.
	serve_uploaded_image! : { key : ConversationKey, image : UploadedImage } => Http.Response
	serve_uploaded_image! = |{ key, image }|
		match FileSystem.read_uploaded_image!(key, image) {
			Ok(bytes) => HttpAnswer.image({ content_type: image.content_type(), bytes })
			Err(Missing) => HttpAnswer.page(
				404,
				Page.notice({ title: "Not found", text: "No such image." }),
			)
			Err(fault) => HttpAnswer.page(
				500,
				Page.notice({ title: "Failed", text: FileSystem.fault_words(fault) }),
			)
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
	[NoFile, NotAnImage, TooLarge],
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
	Ok({ kind, filename: file.filename, bytes: file.bytes })
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
	JsonOut,
	[
		NoFile,
		NotAnImage,
		TooLarge,
		LimitReached,
		NotANumber,
		FileSystem(FileSystem.Fault),
		Unrefunded(FileSystem.Fault),
	],
)
keep_upload! = |{ key, acting, headers, body }| {
	upload = image_upload_from_form({ headers, body })?
	folder = UserFolder.of(acting.user().id())
	before = reserve_upload_bytes!(folder, upload.bytes.len())?
	image = UploadedImage.with_random_name({
		random_bytes: Host.fill_with_random_bytes!(UploadedImage.random_bytes_per_name),
		kind: upload.kind,
	})
	match FileSystem.store_uploaded_image!(key, { image, bytes: upload.bytes }) {
		Ok({}) =>
			Ok(
				upload_answer_json({
					url: key.url_path(UploadedImage(image)),
					name: MultipartForm.display_name(upload.filename),
				}),
			)
		Err(fault) =>
		# The image's bytes go back to the allowance. The answer is the
		# image's 500 either way; it says so when the total stays spent.
			match FileSystem.replace_upload_total!(folder, before) {
				Ok({}) => Err(FileSystem(fault))
				Err(_) => Err(Unrefunded(fault))
			}
	}
}

## The user's upload total before an upload of `adding` bytes, once the
## total with them is written to their folder; unless that would pass the
## allowance (`LimitReached`), or the total can't be read or written.
reserve_upload_bytes! : UserFolder,
U64 => Try(
	UploadTotal,
	[LimitReached, NotANumber, FileSystem(FileSystem.Fault)],
)
reserve_upload_bytes! = |folder, adding| {
	before = FileSystem.read_upload_total!(folder)?
	after = before.with_upload(adding)?
	FileSystem.replace_upload_total!(folder, after) ? |fault| FileSystem(fault)
	Ok(before)
}

## An upload refused, as a line of plain text saying why; or
## one that couldn't be counted or kept, a 500 saying that the user's
## upload total is no number, or what the file system answered, and whether
## the image's bytes could not be given back to the total (`Unrefunded`).
upload_refusal_response : [
	NoFile,
	NotAnImage,
	TooLarge,
	LimitReached,
	NotANumber,
	FileSystem(FileSystem.Fault),
	Unrefunded(FileSystem.Fault),
] -> Http.Response
upload_refusal_response = |why|
	match why {
		NoFile => HttpAnswer.text(400, "no file")
		NotAnImage => HttpAnswer.text(415, "unsupported file type (images: png, jpeg, gif, webp)")
		TooLarge => HttpAnswer.text(
			413,
			"image too large — the limit is ${UploadedImage.most_mib.to_str()} MiB.",
		)
		LimitReached => HttpAnswer.text(
			403,
			"Upload limit reached — you've used your ${UploadTotal.most_gib.to_str()} GiB upload allowance.",
		)
		NotANumber => HttpAnswer.text(500, "Upload failed: your upload total is not a number.")
		FileSystem(fault) => HttpAnswer.text(500, "Upload failed. ${FileSystem.fault_words(fault)}")
		Unrefunded(fault) => HttpAnswer.text(
			500,
			"Upload failed, and your upload total could not be restored. ${FileSystem.fault_words(fault)}",
		)
	}

## The answer to an upload: the image's URL, the
## browser's name for it, its kind, and no size (0 and 0, so the compose
## box gives the image no width or height).
upload_answer_json : { url : Str, name : Str } -> JsonOut
upload_answer_json = |{ url, name }|
	JsonOut.json_object([
		("url", JsonOut.string(url)),
		("name", JsonOut.string(name)),
		("kind", JsonOut.string("image")),
		("width", JsonOut.zero),
		("height", JsonOut.zero),
	])

# ── tests
png : List(U8)
png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0]

## A form as the compose box sends one file, with its Content-Type.
form_of : { filename : Str, file : List(U8) } -> { headers : List(Http.Header), body : List(U8) }
form_of = |{ filename, file }| {
	headers: [
		{ name: "Content-Type".to_utf8(), value: "multipart/form-data; boundary=XyZ".to_utf8() },
	],
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
expect image_upload_from_form(
	form_of({ filename: "cat.txt", file: png }),
).map_ok(|u| u.kind) == Ok(Png)
# Refused: not an image, no form, no file in it.
expect image_upload_from_form(
	form_of({ filename: "cat.png", file: "hello, not an image".to_utf8() }),
) == Err(NotAnImage)
expect image_upload_from_form({
	headers: [],
	body: form_of({ filename: "cat.png", file: png }).body,
}) == Err(NoFile)
expect
	image_upload_from_form({
		headers: [
			{
				name: "content-type".to_utf8(),
				value: "multipart/form-data; boundary=XyZ".to_utf8(),
			},
			{
				name: "content-type".to_utf8(),
				value: "multipart/form-data; boundary=XyZ".to_utf8(),
			},
		],
		body: form_of({ filename: "cat.png", file: png }).body,
	})
		== Err(NoFile)
expect image_upload_from_form({
	headers: form_of({ filename: "c", file: png }).headers,
	body: "markdown=x".to_utf8(),
}) == Err(NoFile)
# Each refusal: its status and its words, a line of plain text; every
# fault of the file system among them.
expect
	[
		(NoFile, 400, "no file"),
		(NotAnImage, 415, "unsupported file type (images: png, jpeg, gif, webp)"),
		(TooLarge, 413, "image too large — the limit is 10 MiB."),
		(LimitReached, 403, "Upload limit reached — you've used your 1 GiB upload allowance."),
		(NotANumber, 500, "Upload failed: your upload total is not a number."),
		(FileSystem(AlreadyExists), 500, "Upload failed. The file system answered AlreadyExists."),
		(
			FileSystem(MissingDirectory),
			500,
			"Upload failed. The file system answered MissingDirectory.",
		),
		(FileSystem(NotUtf8), 500, "Upload failed. The file system answered NotUtf8."),
		(FileSystem(PathRefused), 500, "Upload failed. The file system answered PathRefused."),
		(FileSystem(Failed), 500, "Upload failed. The file system answered Failed."),
		(
			Unrefunded(Failed),
			500,
			"Upload failed, and your upload total could not be restored. The file system answered Failed.",
		),
	].all(
		|
			(why, status, words),
		| {
			response = upload_refusal_response(why)
			response.status == status and response.body == "${words}\n".to_utf8()
		},
	)
# The answer: the URL and the name, the name's quote, backslash and
# control bytes escaped, so it stays one JSON string.
expect
	upload_answer_json({
		url: "/chat/dm/1_1/plans/uploads/a.png",
		name: "c\"a\\t\n\u(1)é.png",
	}).bytes()
		== "{\"url\":\"/chat/dm/1_1/plans/uploads/a.png\",\"name\":\"c\\\"a\\\\t\\n\\u0001é.png\",\"kind\":\"image\",\"width\":0,\"height\":0}".to_utf8()
