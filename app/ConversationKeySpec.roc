## These are the tests of `ConversationKey`: a conversation's URLs and its
## folder from its key, each URL read back from a path in the sample
## directory to the same resource and path, and each refusal.
import ChannelName
import ConversationKey
import Directory
import Sample
import UnvalidatedString

ConversationKeySpec :: [].{}

## The sample directory, with the channel `plans-room` created by Steve.
with_room : Directory
with_room = {
	name = ChannelName.from_str("plans-room") ?? crash "ConversationKeySpec: a channel's name"
	(Sample.directory.create_channel({ by: Sample.admin, name }) ?? crash "ConversationKeySpec: the name is free").directory
}

## A name of an uploaded image's shape.
image_name : Str
image_name = "${"0a".repeat(16)}.png"

## What `path` names in `with_room`, as a test reads it: the resource, then
## the URL path the key writes for it.
read_back : Str -> Try(Str, _)
read_back = |path| {
	unvalidated_path = UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: a test's path is UTF-8"
	found = ConversationKey.from_url_path({ path: unvalidated_path, directory: with_room })?
	Ok("${resource_name(found.resource)} ${found.key.url_path(found.resource)}")
}

## A resource, as a test reads it.
resource_name : ConversationKey.Resource -> Str
resource_name = |resource|
	match resource {
		Page => "page"
		Stream => "stream"
		Send => "send"
		Upload => "upload"
		UploadedImage(image) => "image ${image.name()}"
	}

## The parts of the key `path` names in `with_room`, between spaces.
parts_at : Str -> Try(Str, _)
parts_at = |path| {
	unvalidated_path = UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: a test's path is UTF-8"
	found = ConversationKey.from_url_path({ path: unvalidated_path, directory: with_room })?
	Ok(Str.join_with(found.key.parts(), " "))
}

# A channel's and a DM's conversation: its page's path read back to the
# same path, and its parts, which its folder spells too.
expect read_back("/chat/channel/plans-room/plans") == Ok("page /chat/channel/plans-room/plans")
expect read_back("/chat/dm/1_2/plans") == Ok("page /chat/dm/1_2/plans")
expect read_back("/chat/dm/1_1/other") == Ok("page /chat/dm/1_1/other")
expect parts_at("/chat/channel/plans-room/plans") == Ok("chat channel plans-room plans")
expect parts_at("/chat/dm/1_2/plans") == Ok("chat dm 1_2 plans")
expect parts_at("/chat/dm/1_2/plans/uploads/${image_name}") == Ok("chat dm 1_2 plans")
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
# Each resource after a conversation's page: its path read back to the same
# resource and path. A topic may be a resource's own word, and is then a
# page's.
expect read_back("/chat/channel/plans-room/plans/stream") == Ok("stream /chat/channel/plans-room/plans/stream")
expect read_back("/chat/dm/1_2/stream/stream") == Ok("stream /chat/dm/1_2/stream/stream")
expect read_back("/chat/dm/1_2/stream") == Ok("page /chat/dm/1_2/stream")
expect read_back("/chat/channel/plans-room/plans/send") == Ok("send /chat/channel/plans-room/plans/send")
expect read_back("/chat/dm/1_2/send/send") == Ok("send /chat/dm/1_2/send/send")
expect read_back("/chat/dm/1_2/send") == Ok("page /chat/dm/1_2/send")
expect read_back("/chat/channel/plans-room/plans/upload") == Ok("upload /chat/channel/plans-room/plans/upload")
expect read_back("/chat/dm/1_2/upload/upload") == Ok("upload /chat/dm/1_2/upload/upload")
expect read_back("/chat/dm/1_2/upload") == Ok("page /chat/dm/1_2/upload")
expect read_back("/chat/dm/1_2/plans/uploads/${image_name}") == Ok("image ${image_name} /chat/dm/1_2/plans/uploads/${image_name}")
expect
	read_back("/chat/channel/plans-room/plans/uploads/${image_name}")
		== Ok("image ${image_name} /chat/channel/plans-room/plans/uploads/${image_name}")
# A suffix that is no resource's, by a byte, a case, a part too many or a
# name of another shape.
expect
	[
		"/chat/dm/1_2/plans/stream/",
		"/chat/dm/1_2/plans/Stream",
		"/chat/dm/1_2/plans/streams",
		"/chat/dm/1_2/plans/stream/stream",
		"/chat/dm/1_2/plans/send/",
		"/chat/dm/1_2/plans/Send",
		"/chat/dm/1_2/plans/send/x",
		"/chat/dm/1_2/plans/upload/",
		"/chat/dm/1_2/plans/Upload",
		"/chat/dm/1_2/plans/uploads",
		"/chat/dm/1_2/plans/uploads/cat.png",
		"/chat/dm/1_2/plans/uploads/${image_name}/",
		"/chat/dm/1_2/plans/uploads/",
		"/chat/dm/1_2/plans/upload/${image_name}",
		"/chat/dm/1_2/plans/Uploads/${image_name}",
		"/chat/dm/1_2/plans/${image_name}",
		"/chat/dm/1_2/plans/uploads/x/${image_name}",
		"/talk/dm/1_2/plans/stream",
		"/chat/group/1_2/plans/stream",
		"/talk/dm/1_2/plans/uploads/${image_name}",
	].all(|path| read_back(path) == Err(NotAConversationPath))
# Each refusal of a resource's conversation, as a page's.
expect
	[
		"/chat/dm/2_1/plans/stream",
		"/chat/dm/1_2/plans_2/stream",
		"/chat/dm/2_1/plans/send",
		"/chat/dm/2_1/plans/upload",
		"/chat/dm/2_1/plans/uploads/${image_name}",
	].all(|path| read_back(path) == Err(BadName))
expect
	[
		"/chat/channel/other-room/plans/stream",
		"/chat/channel/other-room/plans/send",
		"/chat/channel/other-room/plans/upload",
		"/chat/channel/other-room/plans/uploads/${image_name}",
	].all(|path| read_back(path) == Err(NoSuchChannel))
expect
	[
		"/chat/dm/1_3/plans/stream",
		"/chat/dm/1_3/plans/send",
		"/chat/dm/1_3/plans/upload",
		"/chat/dm/1_3/plans/uploads/${image_name}",
	].all(|path| read_back(path) == Err(NoSuchHuman))
# A key is its place and its topic: every resource's URL gives the key of
# its page, and another place or another topic gives another key.
expect {
	key = |path|
		ConversationKey.from_url_path({ path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: UTF-8", directory: with_room })
			.map_ok(|found| found.key)
	page = key("/chat/dm/1_2/plans")
	page.is_ok()
		and [
			"/chat/dm/1_2/plans/stream",
			"/chat/dm/1_2/plans/send",
			"/chat/dm/1_2/plans/upload",
			"/chat/dm/1_2/plans/uploads/${image_name}",
		].all(|path| key(path) == page)
		and key("/chat/dm/1_1/plans") != page
		and key("/chat/dm/1_2/other") != page
		and key("/chat/channel/plans-room/plans") != page
}
