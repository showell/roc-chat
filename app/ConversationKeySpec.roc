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
	[
		"/chat/channel/plans-room/plans",
		"/chat/dm/1_2/plans",
		"/chat/dm/1_1/other",
	].map(read_back)
		== [
			Ok({ url: "/chat/channel/plans-room/plans", parts: "chat channel plans-room plans" }),
			Ok({ url: "/chat/dm/1_2/plans", parts: "chat dm 1_2 plans" }),
			Ok({ url: "/chat/dm/1_1/other", parts: "chat dm 1_1 other" }),
		]
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
	].map(read_back)
		== List.repeat(Err(NotAConversationPath), 8)
expect
	[
		"/chat/channel/plans-room/plans_2",
		"/chat/channel/plans_room/plans",
		"/chat/dm/2_1/plans",
		"/chat/dm/1_2/9lives",
	].map(read_back)
		== List.repeat(Err(BadName), 4)
expect read_back("/chat/channel/other-room/plans") == Err(NoSuchChannel)
expect
	[
		"/chat/dm/1_3/plans",
		"/chat/dm/1_9/plans",
		"/chat/dm/9_9/plans",
	].map(read_back)
		== List.repeat(Err(NoSuchHuman), 3)
# A key is its place and its topic: the same URL gives equal keys.
expect {
	key = |path| ConversationKey.from_url_path({ path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "ConversationKeySpec: UTF-8", directory: with_room })
	key("/chat/dm/1_2/plans") == key("/chat/dm/1_2/plans") and key("/chat/dm/1_2/plans") != key("/chat/dm/1_1/plans")
}

## The route `method` and `path` choose in `with_room`, as a test reads it.
chosen : Str, List(U8) -> Str
chosen = |method, path|
	match Route.choose({
		method: method.to_utf8(),
		path,
		directory: with_room,
	}) {
		ShowConversation(key) => "show ${key.url_path()}"
		AppendToConversation(key) => "append ${key.url_path()}"
		NotFound => "not found"
		MethodNotAllowed => "not allowed"
	}

expect
	[
		chosen("GET", "/chat/dm/1_2/plans".to_utf8()),
		chosen("POST", "/chat/dm/1_2/plans".to_utf8()),
		chosen("PUT", "/chat/dm/1_2/plans".to_utf8()),
		chosen("get", "/chat/dm/1_2/plans".to_utf8()),
		chosen("GET", "/chat/dm/1_3/plans".to_utf8()),
		chosen("POST", "/nowhere".to_utf8()),
		chosen("GET", [0x2f, 0xff]),
	]
		== [
			"show /chat/dm/1_2/plans",
			"append /chat/dm/1_2/plans",
			"not allowed",
			"not allowed",
			"not found",
			"not found",
			"not found",
		]
