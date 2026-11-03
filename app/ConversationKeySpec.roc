## **CONVERSATIONKEY'S AND ROUTE'S TESTS**: a conversation's URL and folder
## from its key, the key read back from a URL in the sample directory, each
## refusal on both sides, and the route each method and path choose.
import ChannelName
import ConversationKey
import Directory
import Route
import Sample
import UnvalidatedString

ConversationKeySpec :: [].{}

## The sample directory, with the channel `plans-room` created by Steve.
with_room : Directory
with_room = {
	name = ChannelName.from_str("plans-room") ?? crash "ConversationKeySpec: a channel's name"
	(Sample.directory.create_channel({ by: Sample.admin, name }) ?? crash "ConversationKeySpec: the name is free").directory
}

## The key whose stream `path` names in `with_room`, as its stream's URL
## path.
stream_read_back : Str -> Try(Str, _)
stream_read_back = |path| {
	unchecked = UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: a test's path is UTF-8"
	key = ConversationKey.from_stream_url_path({ path: unchecked, directory: with_room })?
	Ok(key.stream_url_path())
}

## The key whose upload `path` names in `with_room`, as its upload's URL
## path.
upload_read_back : Str -> Try(Str, _)
upload_read_back = |path| {
	unchecked = UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: a test's path is UTF-8"
	key = ConversationKey.from_upload_url_path({ path: unchecked, directory: with_room })?
	Ok(key.upload_url_path())
}

## The key whose send `path` names in `with_room`, as its send's URL path.
send_read_back : Str -> Try(Str, _)
send_read_back = |path| {
	unchecked = UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: a test's path is UTF-8"
	key = ConversationKey.from_send_url_path({ path: unchecked, directory: with_room })?
	Ok(key.send_url_path())
}

## The key and the image an uploaded image's `path` names in `with_room`,
## as the image's URL path.
image_read_back : Str -> Try(Str, _)
image_read_back = |path| {
	unchecked = UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: a test's path is UTF-8"
	found = ConversationKey.from_uploaded_image_url_path({ path: unchecked, directory: with_room })?
	Ok(found.key.uploaded_image_url_path(found.image))
}

## A name of an uploaded image's shape.
image_name : Str
image_name = "${"0a".repeat(16)}.png"

## The key `path` names in `with_room`, as its URL path and its parts
## between spaces.
read_back : Str -> Try({ url : Str, parts : Str }, _)
read_back = |path| {
	unchecked = UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: a test's path is UTF-8"
	key = ConversationKey.from_url_path({ path: unchecked, directory: with_room })?
	Ok({ url: key.url_path(), parts: Str.join_with(key.parts(), " ") })
}

# A channel's and a DM's conversation, the URL read back to the same parts.
expect
	read_back("/chat/channel/plans-room/plans")
		== Ok({ url: "/chat/channel/plans-room/plans", parts: "chat channel plans-room plans" })
expect read_back("/chat/dm/1_2/plans") == Ok({ url: "/chat/dm/1_2/plans", parts: "chat dm 1_2 plans" })
expect read_back("/chat/dm/1_1/other") == Ok({ url: "/chat/dm/1_1/other", parts: "chat dm 1_1 other" })
# Every refusal: a path of another shape, a part that is no name, no such
# channel, and a DM's member who is no human here (an agent, or nobody).
expect
	[
		"/chat/channel/plans-room",
		"/chat/channel/plans-room/plans/",
		"/chat/channel/plans-room/plans/x",
		"/chat/group/plans-room/plans",
		"/talk/channel/plans-room/plans",
		"chat/channel/plans-room/plans",
		"/",
		"",
	].all(|path| read_back(path) == Err(NotAConversationPath))
expect
	[
		"/chat/channel/plans-room/plans_2",
		"/chat/channel/plans_room/plans",
		"/chat/dm/2_1/plans",
		"/chat/dm/1_2/9lives",
	].all(|path| read_back(path) == Err(BadName))
expect read_back("/chat/channel/other-room/plans") == Err(NoSuchChannel)
expect
	[
		"/chat/dm/1_3/plans",
		"/chat/dm/1_9/plans",
		"/chat/dm/9_9/plans",
	].all(|path| read_back(path) == Err(NoSuchHuman))
# A stream's path: a conversation's page's, then `/stream`, read back to the
# same path; a page's path is no stream's, and a stream's no page's; each
# refusal of the conversation's parts as a page's.
expect stream_read_back("/chat/channel/plans-room/plans/stream") == Ok("/chat/channel/plans-room/plans/stream")
expect stream_read_back("/chat/dm/1_2/stream/stream") == Ok("/chat/dm/1_2/stream/stream")
expect read_back("/chat/dm/1_2/stream") == Ok({ url: "/chat/dm/1_2/stream", parts: "chat dm 1_2 stream" })
expect
	[
		"/chat/dm/1_2/plans",
		"/chat/dm/1_2/plans/stream/",
		"/chat/dm/1_2/plans/Stream",
		"/chat/dm/1_2/plans/streams",
		"/chat/dm/1_2/plans/stream/stream",
		"/talk/dm/1_2/plans/stream",
		"/chat/group/1_2/plans/stream",
	].all(|path| stream_read_back(path) == Err(NotAConversationPath))
expect read_back("/chat/dm/1_2/plans/stream") == Err(NotAConversationPath)
expect stream_read_back("/chat/dm/2_1/plans/stream") == Err(BadName)
expect stream_read_back("/chat/dm/1_2/plans_2/stream") == Err(BadName)
expect stream_read_back("/chat/channel/other-room/plans/stream") == Err(NoSuchChannel)
expect stream_read_back("/chat/dm/1_3/plans/stream") == Err(NoSuchHuman)
# An upload's path: a conversation's page's, then `/upload`, read back to
# the same path; each refusal of the conversation's parts as a page's.
expect upload_read_back("/chat/channel/plans-room/plans/upload") == Ok("/chat/channel/plans-room/plans/upload")
expect upload_read_back("/chat/dm/1_2/upload/upload") == Ok("/chat/dm/1_2/upload/upload")
expect read_back("/chat/dm/1_2/upload") == Ok({ url: "/chat/dm/1_2/upload", parts: "chat dm 1_2 upload" })
expect
	[
		"/chat/dm/1_2/plans",
		"/chat/dm/1_2/plans/upload/",
		"/chat/dm/1_2/plans/Upload",
		"/chat/dm/1_2/plans/uploads",
		"/chat/dm/1_2/plans/stream",
		"/talk/dm/1_2/plans/upload",
	].all(|path| upload_read_back(path) == Err(NotAConversationPath))
expect upload_read_back("/chat/dm/2_1/plans/upload") == Err(BadName)
expect upload_read_back("/chat/channel/other-room/plans/upload") == Err(NoSuchChannel)
expect upload_read_back("/chat/dm/1_3/plans/upload") == Err(NoSuchHuman)
# A script's send path: a conversation's page's, then `/send`, read back to
# the same path; each refusal of the conversation's parts as a page's.
expect send_read_back("/chat/channel/plans-room/plans/send") == Ok("/chat/channel/plans-room/plans/send")
expect send_read_back("/chat/dm/1_2/send/send") == Ok("/chat/dm/1_2/send/send")
expect read_back("/chat/dm/1_2/send") == Ok({ url: "/chat/dm/1_2/send", parts: "chat dm 1_2 send" })
expect
	[
		"/chat/dm/1_2/plans",
		"/chat/dm/1_2/plans/send/",
		"/chat/dm/1_2/plans/Send",
		"/chat/dm/1_2/plans/upload",
		"/chat/dm/1_2/plans/send/x",
		"/talk/dm/1_2/plans/send",
	].all(|path| send_read_back(path) == Err(NotAConversationPath))
expect send_read_back("/chat/dm/2_1/plans/send") == Err(BadName)
expect send_read_back("/chat/channel/other-room/plans/send") == Err(NoSuchChannel)
expect send_read_back("/chat/dm/1_3/plans/send") == Err(NoSuchHuman)
# An uploaded image's path: a conversation's page's, `/uploads/` and an
# image's name, read back to the same path; a name of another shape, or
# another path, is none; each refusal of the conversation's parts.
expect image_read_back("/chat/dm/1_2/plans/uploads/${image_name}") == Ok("/chat/dm/1_2/plans/uploads/${image_name}")
expect image_read_back("/chat/channel/plans-room/plans/uploads/${image_name}") == Ok("/chat/channel/plans-room/plans/uploads/${image_name}")
expect
	[
		"/chat/dm/1_2/plans/uploads/cat.png",
		"/chat/dm/1_2/plans/uploads/${image_name}/",
		"/chat/dm/1_2/plans/uploads/",
		"/chat/dm/1_2/plans/upload/${image_name}",
		"/chat/dm/1_2/plans/Uploads/${image_name}",
		"/chat/dm/1_2/plans/${image_name}",
		"/chat/dm/1_2/plans/uploads/x/${image_name}",
		"/talk/dm/1_2/plans/uploads/${image_name}",
	].all(|path| image_read_back(path) == Err(NotAConversationPath))
expect image_read_back("/chat/dm/2_1/plans/uploads/${image_name}") == Err(BadName)
expect image_read_back("/chat/channel/other-room/plans/uploads/${image_name}") == Err(NoSuchChannel)
expect image_read_back("/chat/dm/1_3/plans/uploads/${image_name}") == Err(NoSuchHuman)
# A key is its place and its topic: the same URL gives equal keys.
expect {
	key = |path| ConversationKey.from_url_path({ path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: UTF-8", directory: with_room })
	key("/chat/dm/1_2/plans") == key("/chat/dm/1_2/plans") and key("/chat/dm/1_2/plans") != key("/chat/dm/1_1/plans")
}

## The route `method` and `path` choose in `with_room`, as a test reads it.
chosen_route : Str, List(U8) -> Str
chosen_route = |method, path|
	match Route.choose({
		method: method.to_utf8(),
		path,
		directory: with_room,
	}) {
		ShowConversation(key) => "show ${key.url_path()}"
		AppendToConversation(key) => "append ${key.url_path()}"
		SendToConversation(key) => "send ${key.url_path()}"
		OpenConversationStream(key) => "stream ${key.url_path()}"
		UploadToConversation(key) => "upload ${key.url_path()}"
		ServeUploadedImage(found) => "image ${found.image.name()} of ${found.key.url_path()}"
		ServeScript(Palette) => "the script palette.js"
		ServeScript(Chrome) => "the script chrome.js"
		ServeScript(Compose) => "the script compose.js"
		ServeScript(Feed) => "the script feed.js"
		NotFound => "not found"
		MethodNotAllowed(GetAndPost) => "not allowed: GET, POST"
		MethodNotAllowed(GetOnly) => "not allowed: GET"
		MethodNotAllowed(PostOnly) => "not allowed: POST"
	}

expect chosen_route("GET", "/chat/dm/1_2/plans".to_utf8()) == "show /chat/dm/1_2/plans"
expect chosen_route("POST", "/chat/dm/1_2/plans".to_utf8()) == "append /chat/dm/1_2/plans"
expect chosen_route("PUT", "/chat/dm/1_2/plans".to_utf8()) == "not allowed: GET, POST"
expect chosen_route("get", "/chat/dm/1_2/plans".to_utf8()) == "not allowed: GET, POST"
expect chosen_route("GET", "/chat/dm/1_3/plans".to_utf8()) == "not found"
expect chosen_route("POST", "/nowhere".to_utf8()) == "not found"
expect chosen_route("GET", [0x2f, 0xff]) == "not found"
# A conversation's stream: GET alone.
expect chosen_route("GET", "/chat/dm/1_2/plans/stream".to_utf8()) == "stream /chat/dm/1_2/plans"
expect chosen_route("POST", "/chat/dm/1_2/plans/stream".to_utf8()) == "not allowed: GET"
expect chosen_route("HEAD", "/chat/dm/1_2/plans/stream".to_utf8()) == "not allowed: GET"
expect chosen_route("GET", "/chat/dm/1_3/plans/stream".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/dm/1_2/plans/stream/x".to_utf8()) == "not found"
# A script's send: POST alone, under a place that exists.
expect chosen_route("POST", "/chat/dm/1_2/plans/send".to_utf8()) == "send /chat/dm/1_2/plans"
expect chosen_route("GET", "/chat/dm/1_2/plans/send".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/chat/dm/1_2/plans/send".to_utf8()) == "not allowed: POST"
expect chosen_route("POST", "/chat/dm/1_3/plans/send".to_utf8()) == "not found"
# An upload: POST alone. An uploaded image: GET alone, under a place that
# exists.
expect chosen_route("POST", "/chat/dm/1_2/plans/upload".to_utf8()) == "upload /chat/dm/1_2/plans"
expect chosen_route("GET", "/chat/dm/1_2/plans/upload".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/chat/dm/1_2/plans/upload".to_utf8()) == "not allowed: POST"
expect chosen_route("POST", "/chat/dm/1_3/plans/upload".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/dm/1_2/plans/uploads/${image_name}".to_utf8()) == "image ${image_name} of /chat/dm/1_2/plans"
expect chosen_route("POST", "/chat/dm/1_2/plans/uploads/${image_name}".to_utf8()) == "not allowed: GET"
expect chosen_route("GET", "/chat/dm/1_3/plans/uploads/${image_name}".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/dm/1_2/plans/uploads/cat.png".to_utf8()) == "not found"
# Each script's path: GET alone, and exactly its path.
expect
	[
		"palette.js",
		"chrome.js",
		"compose.js",
		"feed.js",
	].all(
		|name| {
			path = "/chat/assets/${name}".to_utf8()
			chosen_route("GET", path) == "the script ${name}"
				and chosen_route("POST", path) == "not allowed: GET"
				and chosen_route("HEAD", path) == "not allowed: GET"
		},
	)
expect chosen_route("GET", "/chat/assets/compose.js/".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/assets/Compose.js".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/assets/other.js".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/assets".to_utf8()) == "not found"
