## These are the tests of `FirstStart`, the directory a new chat starts
## with: Steve alone, a human, the one member of `general`, with the counter
## of ids at 2; and the routes that directory answers, a conversation's page,
## its stream and its uploaded images in a place it holds, and nothing in
## one it doesn't.
import FirstStart
import Route
import UserId

FirstStartSpec :: [].{}

## The page a GET of `path` shows, as a test reads it.
page_for_get : Str -> Str
page_for_get = |path|
	match Route.choose({
		method: "GET".to_utf8(),
		path: path.to_utf8(),
		directory: FirstStart.first_directory,
	}) {
		SignedInOnly(ShowConversation(key)) => key.url_path(Page)
		SignedInOnly(OpenConversationStream(key)) => "the stream of ${key.url_path(Page)}"
		SignedInOnly(ServeUploadedImage(found)) =>
			"the image ${found.image.name()} of ${found.key.url_path(Page)}"
		_ => "not found"
	}

# The first start: Steve, id 1, a human; `general`, its one member Steve;
# the counter at 2.
expect FirstStart.first_directory.users().to_list().map(|user| user.role()) == [Human]
expect FirstStart.first_directory.channels().to_list().map(
	|channel| (channel.name().to_str(), channel.members().map(UserId.to_str)),
) == [("general", ["1"])]
expect FirstStart.first_directory.users().counter_bytes() == "2\n".to_utf8()
expect page_for_get("/chat/channel/general/plans") == "/chat/channel/general/plans"
expect page_for_get("/chat/dm/1_1/plans") == "/chat/dm/1_1/plans"
expect page_for_get("/chat/channel/other/plans") == "not found"
expect page_for_get("/chat/dm/1_2/plans") == "not found"
expect page_for_get("/chat/dm/1_1/plans/stream") == "the stream of /chat/dm/1_1/plans"
expect page_for_get("/chat/dm/1_2/plans/stream") == "not found"
expect
	page_for_get("/chat/channel/general/plans/uploads/${"0".repeat(32)}.png")
		== "the image ${"0".repeat(32)}.png of /chat/channel/general/plans"
expect page_for_get("/chat/dm/1_2/plans/uploads/${"0".repeat(32)}.png") == "not found"
