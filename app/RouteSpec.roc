## These are the tests of `Route`: the route each method and path choose,
## in the sample directory with one channel added.
import ChannelName
import ConversationKey
import Directory
import Route
import Sample

RouteSpec :: [].{}

## The sample directory, with the channel `plans-room` created by Steve.
with_room : Directory
with_room = {
	name = ChannelName.from_str("plans-room") ?? crash "RouteSpec: a channel's name"
	(
		Sample.directory.create_channel({
			by: Sample.admin,
			name,
		}) ?? crash "RouteSpec: the name is free"
	).directory
}

## A name of an uploaded image's shape.
image_name : Str
image_name = "${"0a".repeat(16)}.png"

## The route `method` and `path` choose in `with_room`, as a test reads it:
## what it does, and `(open)` after a route anyone may use.
chosen_route : Str, List(U8) -> Str
chosen_route = |method, path|
	match Route.choose({ method: method.to_utf8(), path, directory: with_room }) {
		SignedInOnly(StartGitHubLink) => "off to GitHub to link it"
		SignedInOnly(ShowBrowse) => "browse"
		SignedInOnly(StartTopic(place)) => "start a topic in ${ConversationKey.place_url_path(place)}"
		SignedInOnly(ShowConversation(key)) => "show ${key.url_path(Page)}"
		SignedInOnly(AppendToConversation(key)) => "append ${key.url_path(Page)}"
		SignedInOnly(SendToConversation(key)) => "send ${key.url_path(Page)}"
		SignedInOnly(OpenConversationStream(key)) => "stream ${key.url_path(Page)}"
		SignedInOnly(UploadToConversation(key)) => "upload ${key.url_path(Page)}"
		SignedInOnly(ServeUploadedImage(found)) =>
			"image ${found.image.name()} of ${found.key.url_path(Page)}"
		SignedInOnly(ServeRawTranscript(key)) => "raw ${key.url_path(Page)}"
		SignedInOnly(ShowAgents) => "agents"
		SignedInOnly(MakeAgent) => "make an agent"
		SignedInOnly(InviteAgent(agent)) => "invite ${agent.to_str()}"
		SignedInOnly(
			RevokeInvite({ agent, invite }),
		) => "revoke invite ${invite.to_str()} of ${agent.to_str()}"
		SignedInOnly(RevokeKey({ agent, key })) => "revoke key ${key.to_str()} of ${agent.to_str()}"
		SignedInOnly(OpenAgentStream) => "the agents' stream"
		SignedInOnly(ShowChannels) => "channels"
		SignedInOnly(CreateChannel) => "create a channel"
		SignedInOnly(ShowChannelMembers(channel)) => "members of ${channel.to_str()}"
		SignedInOnly(
			AddChannelMember({ channel, member }),
		) => "add ${member.to_str()} to ${channel.to_str()}"
		SignedInOnly(
			RemoveChannelMember({ channel, member }),
		) => "remove ${member.to_str()} from ${channel.to_str()}"
		SignedInOnly(ShowInvites) => "invites"
		SignedInOnly(InviteHuman) => "invite a human"
		SignedInOnly(InviteHumanAgain(human)) => "invite ${human.to_str()} again"
		Open(GoToBrowse) => "the way in (open)"
		Open(ShowJoin) => "the join page (open)"
		Open(LookUpJoinName) => "the name to join under (open)"
		Open(Join) => "join (open)"
		Open(ServeScript(script)) => "the script at ${script.url_path()} (open)"
		Open(ServeFavicon) => "the icon (open)"
		Open(ShowLogin) => "the sign-in page (open)"
		Open(SignIn) => "sign in (open)"
		Open(SignOut) => "sign out (open)"
		Open(StartGitHubSignIn) => "off to GitHub (open)"
		Open(FinishGitHubSignIn) => "back from GitHub (open)"
		Open(FinishGitHubSignUp) => "a new human's name (open)"
		Open(WrongMethodToGitHub(GetOnly)) => "the wrong method to GitHub (open)"
		Open(WrongMethodToGitHub(PostOnly)) => "the wrong method for a name (open)"
		Open(WrongMethodToGitHub(GetAndPost)) => "no route takes this"
		Open(RedeemInvite) => "redeem (open)"
		NotFound => "not found"
		MethodNotAllowed(GetAndPost) => "not allowed: GET, POST"
		MethodNotAllowed(GetOnly) => "not allowed: GET"
		MethodNotAllowed(PostOnly) => "not allowed: POST"
	}

# The way in: GET alone, open, and exactly its path.
expect chosen_route("GET", "/".to_utf8()) == "the way in (open)"
expect chosen_route("POST", "/".to_utf8()) == "not allowed: GET"
expect chosen_route("PUT", "/".to_utf8()) == "not allowed: GET"
expect ["", "//", "/ "].all(|path| chosen_route("GET", path.to_utf8()) == "not found")
# Browse: GET alone, and exactly its path.
expect chosen_route("GET", "/chat".to_utf8()) == "browse"
expect chosen_route("POST", "/chat".to_utf8()) == "not allowed: GET"
expect chosen_route("PUT", "/chat".to_utf8()) == "not allowed: GET"
expect
	[
		"/chat/",
		"/Chat",
		"/chats",
		"/chat/dm",
		"/chat/channel",
	].all(|path| chosen_route("GET", path.to_utf8()) == "not found")
# A new topic: POST alone, to a place that exists.
expect chosen_route("POST", "/chat/dm/1_2".to_utf8()) == "start a topic in /chat/dm/1_2"
expect chosen_route(
	"POST",
	"/chat/channel/plans-room".to_utf8(),
) == "start a topic in /chat/channel/plans-room"
expect chosen_route("GET", "/chat/dm/1_2".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/chat/channel/plans-room".to_utf8()) == "not allowed: POST"
expect
	[
		"/chat/dm/1_3",
		"/chat/dm/2_1",
		"/chat/dm/x",
		"/chat/channel/no-such-room",
		"/chat/channel/1_2",
		"/chat/other/plans-room",
		"/chat/dm/1_2/",
	].all(|path| chosen_route("POST", path.to_utf8()) == "not found")
# A conversation's page: GET and POST, under a place that exists.
expect chosen_route("GET", "/chat/dm/1_2/plans".to_utf8()) == "show /chat/dm/1_2/plans"
expect chosen_route("POST", "/chat/dm/1_2/plans".to_utf8()) == "append /chat/dm/1_2/plans"
expect chosen_route("PUT", "/chat/dm/1_2/plans".to_utf8()) == "not allowed: GET, POST"
expect chosen_route("get", "/chat/dm/1_2/plans".to_utf8()) == "not allowed: GET, POST"
expect chosen_route(
	"GET",
	"/chat/channel/plans-room/plans".to_utf8(),
) == "show /chat/channel/plans-room/plans"
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
expect chosen_route(
	"GET",
	"/chat/dm/1_2/plans/uploads/${image_name}".to_utf8(),
) == "image ${image_name} of /chat/dm/1_2/plans"
expect chosen_route(
	"POST",
	"/chat/dm/1_2/plans/uploads/${image_name}".to_utf8(),
) == "not allowed: GET"
expect chosen_route(
	"PUT",
	"/chat/dm/1_2/plans/uploads/${image_name}".to_utf8(),
) == "not allowed: GET"
expect chosen_route("GET", "/chat/dm/1_3/plans/uploads/${image_name}".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/dm/1_2/plans/uploads/cat.png".to_utf8()) == "not found"
# Each script's path: GET alone, and exactly its path.
expect
	["palette.js", "chrome.js", "compose.js", "feed.js", "panel.js"].all(
		|name| {
			path = "/chat/assets/${name}".to_utf8()
			chosen_route("GET", path) == "the script at /chat/assets/${name} (open)"
				and chosen_route("POST", path) == "not allowed: GET"
				and chosen_route("HEAD", path) == "not allowed: GET"
		},
	)
expect chosen_route("GET", "/chat/assets/compose.js/".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/assets/Compose.js".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/assets/other.js".to_utf8()) == "not found"
expect chosen_route("GET", "/chat/assets".to_utf8()) == "not found"
# The icon's path: GET alone, by anyone, and exactly its path.
expect chosen_route("GET", "/favicon.ico".to_utf8()) == "the icon (open)"
expect chosen_route("POST", "/favicon.ico".to_utf8()) == "not allowed: GET"
expect chosen_route("HEAD", "/favicon.ico".to_utf8()) == "not allowed: GET"
expect
	[
		"/favicon.ico/",
		"/Favicon.ico",
		"/favicon.png",
		"/chat/favicon.ico",
		"/chat/assets/favicon.ico",
	].all(|path| chosen_route("GET", path.to_utf8()) == "not found")
# A conversation's transcript as plain text: GET alone, under a place that
# exists.
expect chosen_route("GET", "/chat/dm/1_2/plans/raw".to_utf8()) == "raw /chat/dm/1_2/plans"
expect chosen_route(
	"GET",
	"/chat/channel/plans-room/plans/raw".to_utf8(),
) == "raw /chat/channel/plans-room/plans"
expect chosen_route("POST", "/chat/dm/1_2/plans/raw".to_utf8()) == "not allowed: GET"
expect chosen_route("PUT", "/chat/dm/1_2/plans/raw".to_utf8()) == "not allowed: GET"
expect chosen_route("GET", "/chat/dm/1_3/plans/raw".to_utf8()) == "not found"
# The agents' page: GET and POST.
expect chosen_route("GET", "/agents".to_utf8()) == "agents"
expect chosen_route("POST", "/agents".to_utf8()) == "make an agent"
expect chosen_route("PUT", "/agents".to_utf8()) == "not allowed: GET, POST"
# An invite, and each revoke: POST alone.
expect chosen_route("POST", "/agents/3/invites".to_utf8()) == "invite 3"
expect chosen_route("GET", "/agents/3/invites".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/agents/3/invites".to_utf8()) == "not allowed: POST"
expect chosen_route("POST", "/agents/3/invites/2/revoke".to_utf8()) == "revoke invite 2 of 3"
expect chosen_route("GET", "/agents/3/invites/2/revoke".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/agents/3/invites/2/revoke".to_utf8()) == "not allowed: POST"
expect chosen_route("POST", "/agents/3/keys/1/revoke".to_utf8()) == "revoke key 1 of 3"
expect chosen_route("GET", "/agents/3/keys/1/revoke".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/agents/3/keys/1/revoke".to_utf8()) == "not allowed: POST"
# A redemption: POST alone. The agents' stream: GET alone.
expect chosen_route("POST", "/agents/redeem".to_utf8()) == "redeem (open)"
expect chosen_route("GET", "/agents/redeem".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/agents/redeem".to_utf8()) == "not allowed: POST"
expect chosen_route("GET", "/agents/stream".to_utf8()) == "the agents' stream"
expect chosen_route("POST", "/agents/stream".to_utf8()) == "not allowed: GET"
expect chosen_route("PUT", "/agents/stream".to_utf8()) == "not allowed: GET"
# Signing in: the page by GET and the sign-in by POST to /login; signing
# out by POST alone; each open; no other spelling.
expect chosen_route("GET", "/login".to_utf8()) == "the sign-in page (open)"
expect chosen_route("POST", "/login".to_utf8()) == "sign in (open)"
expect chosen_route("PUT", "/login".to_utf8()) == "not allowed: GET, POST"
# GitHub's two GETs, and every other method there a refusal the route gives,
# as a server with no GitHub settings answers those with a 404.
expect chosen_route("GET", "/login/github/start".to_utf8()) == "off to GitHub (open)"
expect chosen_route("GET", "/login/github".to_utf8()) == "back from GitHub (open)"
expect
	[
		("POST", "/login/github/start"),
		("PUT", "/login/github/start"),
		("POST", "/login/github"),
		("PUT", "/login/github"),
	].all(
		|(method, path)| chosen_route(
			method,
			path.to_utf8(),
		) == "the wrong method to GitHub (open)",
	)
# A new human's name: a POST, and every other method a refusal the route gives.
expect chosen_route("POST", "/login/github/name".to_utf8()) == "a new human's name (open)"
expect chosen_route("POST", "/login/github/link".to_utf8()) == "off to GitHub to link it"
expect
	[
		("GET", "/login/github/name"),
		("PUT", "/login/github/name"),
		("GET", "/login/github/link"),
		("PUT", "/login/github/link"),
	].all(
		|(method, path)| chosen_route(
			method,
			path.to_utf8(),
		) == "the wrong method for a name (open)",
	)
expect chosen_route("POST", "/logout".to_utf8()) == "sign out (open)"
expect chosen_route("GET", "/logout".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/logout".to_utf8()) == "not allowed: POST"
expect
	[
		"/login/",
		"/Login",
		"/login/x",
		"/logouts",
		"login",
	].all(|path| chosen_route("POST", path.to_utf8()) == "not found")
# Joining: the page by GET and the join by POST to /join; the name to join
# under by POST alone to /join/name; each open; no other spelling.
expect chosen_route("GET", "/join".to_utf8()) == "the join page (open)"
expect chosen_route("POST", "/join".to_utf8()) == "join (open)"
expect chosen_route("PUT", "/join".to_utf8()) == "not allowed: GET, POST"
expect chosen_route("POST", "/join/name".to_utf8()) == "the name to join under (open)"
expect chosen_route("GET", "/join/name".to_utf8()) == "not allowed: POST"
expect chosen_route("PUT", "/join/name".to_utf8()) == "not allowed: POST"
expect
	[
		"/join/",
		"/Join",
		"/join/names",
		"/join/name/x",
		"/joins",
		"/invites/redeem",
	].all(|path| chosen_route("POST", path.to_utf8()) == "not found")
# Not the agents' routes: an id or a number of another spelling, another
# kind, another word, a part too many or too few.
expect
	[
		"/agents/",
		"/Agents",
		"/agents/03/invites",
		"/agents/0/invites",
		"/agents/x/invites",
		"/agents/3/invite",
		"/agents/3/invites/0/revoke",
		"/agents/3/invites/02/revoke",
		"/agents/3/keys/x/revoke",
		"/agents/3/tokens/1/revoke",
		"/agents/3/keys/1/remove",
		"/agents/3/keys/1",
		"/agents/3/keys/1/revoke/x",
		"/agents/redeem/x",
		"/agents/3",
	].all(|path| chosen_route("POST", path.to_utf8()) == "not found")
