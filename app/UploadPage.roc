## **AN UPLOADED IMAGE, SERVED**, `GET /chat/uploads/<channel>/<topic>/<name>`
## (the old `serveUpload`): the image a topic's compose box uploaded
## (TopicPage's `upload`, Uploads.roc), to whoever reads the topic
## (Topics.verdict!, the topic's own rule, a session's or a key's), its type
## by its name's extension, the browser never guessing another (`nosniff`),
## and kept by the browser for good (the old `private, max-age=31536000,
## immutable`: a name is never given twice, so its bytes never change).
## Signed out, a 401; every other miss (no such channel, topic or image,
## one the viewer may not read, a name no upload has) the one 404, so no
## stranger learns what is there.
import pf.Chat
import ChannelName
import Store
import Topic
import TopicName
import Topics
import Uploads
import Wire

UploadPage := [].{

	## An upload a path names: its topic, its name, and what its name says it is.
	Route : {
		at : Topic.At,
		name : Str,
		image : Uploads.Image,
	}

	## The upload a path names, if it names one.
	route : List(U8) -> Try(UploadPage.Route, [NotAnUpload])
	route = |path|
		match path.split_on('/') {
			[
				[],
				chat,
				uploads,
				c,
				t,
				file,
			] if chat == "chat".to_utf8() and uploads == "uploads".to_utf8() => {
				channel = ChannelName.from_str(Str.from_utf8(c).map_err(|_| NotAnUpload)?).map_err(|_| NotAnUpload)?
				topic = TopicName.from_str(Str.from_utf8(t).map_err(|_| NotAnUpload)?).map_err(|_| NotAnUpload)?
				image = Uploads.image_named(file)?
				name = Str.from_utf8(file).map_err(|_| NotAnUpload)?
				Ok({
					at: { channel, topic },
					name,
					image,
				})
			}
			_ => Err(NotAnUpload)
		}

	## **ANSWER IT**: a GET or a HEAD.
	answer! : Chat.Request, UploadPage.Route => Chat.Answer
	answer! = |req, r|
		if req.method != Get and req.method != Head {
			Chat.not_allowed(Get)
		} else {
			match serve!(r) {
				Ok(answer) => answer
				Err(answer) => answer
			}
		}
}

serve! : UploadPage.Route => Try(Chat.Answer, Chat.Answer)
serve! = |route| {
	at = route.at
	v = Topics.load_viewer!({})?
	match v.viewer.who() {
		SignedOut => Err(Wire.refused(401, "not signed in"))
		Key(_) | Session(_) =>
			match Topics.verdict!(v, at) {
				Err(SignedOut) => Err(Wire.refused(401, "not signed in"))
				Err(Failed) => Err(Chat.failed)
				Err(NotYours) | Err(NoTopic) => Err(no_such_upload)
				Ok(_) => {
					read = Store.load_upload!(at, route.name)
					match read.status {
						Missing => Err(no_such_upload)
						Failed => Err(Chat.failed)
						Found => Ok(
							Chat.with_header(
								{ ..Chat.respond(200, { content_type: Uploads.content_type(route.image), body: read.bytes }), sniff: Forbid },
								"cache-control",
								"private, max-age=31536000, immutable".to_utf8(),
							),
						)
					}
				}
			}
	}
}

no_such_upload : Chat.Answer
no_such_upload = Wire.refused(404, "no such upload")

# ── tests
expect
	match UploadPage.route("/chat/uploads/rocchatdev/initial-work/${Str.repeat("a", 32)}.png".to_utf8()) {
		Ok(r) => r.at.channel.key() == "rocchatdev" and r.at.topic.key() == "initial-work" and r.name == "${Str.repeat("a", 32)}.png" and r.image == Png
		_ => Bool.False
	}
# A DM's channel by its key: the same for both of its humans.
expect UploadPage.route("/chat/uploads/dm-1-2/Talk/${Str.repeat("0", 32)}.jpg".to_utf8()).is_ok()
# No upload's name, a name past the folder, a part too many or too few, no `/chat/uploads`.
expect
	[
		"/chat/uploads/a/b/x.png",
		"/chat/uploads/a/b/${Str.repeat("0", 32)}.svg",
		"/chat/uploads/a/b/c/${Str.repeat("0", 32)}.png",
		"/chat/uploads/a/${Str.repeat("0", 32)}.png",
		"/chat/uploads/a/../${Str.repeat("0", 32)}.png",
		"/chat/upload/a/b/${Str.repeat("0", 32)}.png",
		"/user_uploads/a/b/${Str.repeat("0", 32)}.png",
	].all(|path| UploadPage.route(path.to_utf8()).is_err())
