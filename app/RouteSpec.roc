## These are the tests of `Route`: the route each method and path choose,
## in the sample directory with one channel added.
import ChannelName
import Directory
import Route
import Sample

RouteSpec :: [].{}

## The sample directory, with the channel `plans-room` created by Steve.
with_room : Directory
with_room = {
	name = ChannelName.from_str("plans-room") ?? crash "RouteSpec: a channel's name"
	(Sample.directory.create_channel({ by: Sample.admin, name }) ?? crash "RouteSpec: the name is free").directory
}

## A name of an uploaded image's shape.
image_name : Str
image_name = "${"0a".repeat(16)}.png"

## The route `method` and `path` choose in `with_room`, as a test reads it.
chosen_route : Str, List(U8) -> Str
chosen_route = |method, path|
	match Route.choose({
		method: method.to_utf8(),
		path,
		directory: with_room,
	}) {
		ShowConversation(key) => "show ${key.url_path(Page)}"
		AppendToConversation(key) => "append ${key.url_path(Page)}"
		SendToConversation(key) => "send ${key.url_path(Page)}"
		OpenConversationStream(key) => "stream ${key.url_path(Page)}"
		UploadToConversation(key) => "upload ${key.url_path(Page)}"
		ServeUploadedImage(found) => "image ${found.image.name()} of ${found.key.url_path(Page)}"
		ServeScript(Palette) => "the script palette.js"
		ServeScript(Chrome) => "the script chrome.js"
		ServeScript(Compose) => "the script compose.js"
		ServeScript(Feed) => "the script feed.js"
		NotFound => "not found"
		MethodNotAllowed(GetAndPost) => "not allowed: GET, POST"
		MethodNotAllowed(GetOnly) => "not allowed: GET"
		MethodNotAllowed(PostOnly) => "not allowed: POST"
	}

# A conversation's page: GET and POST, under a place that exists.
expect chosen_route("GET", "/chat/dm/1_2/plans".to_utf8()) == "show /chat/dm/1_2/plans"
expect chosen_route("POST", "/chat/dm/1_2/plans".to_utf8()) == "append /chat/dm/1_2/plans"
expect chosen_route("PUT", "/chat/dm/1_2/plans".to_utf8()) == "not allowed: GET, POST"
expect chosen_route("get", "/chat/dm/1_2/plans".to_utf8()) == "not allowed: GET, POST"
expect chosen_route("GET", "/chat/channel/plans-room/plans".to_utf8()) == "show /chat/channel/plans-room/plans"
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
expect chosen_route("PUT", "/chat/dm/1_2/plans/uploads/${image_name}".to_utf8()) == "not allowed: GET"
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
