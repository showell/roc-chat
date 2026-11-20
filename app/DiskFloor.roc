## This module keeps the chat from filling its disk: while the data root's
## file system has under `floor_bytes` free (`Host.free_bytes_on_data_disk!`),
## every request that adds data is refused from its head, before its body
## is read, with a 507 saying the server is low on disk (`refusal`), and
## nothing is written. A disk that fills up would leave half-written
## records and refuse every write at random; this refuses them cleanly,
## with room to spare, while the server's owner frees space.
##
## **WHAT ADDS DATA** is decided route by route (`adds_data`), every route
## written out, so a new route is a decision here: a message, an edit (a
## message), an upload, a reaction, a new account (an invite, a join, a
## GitHub sign-up and its name), an agent and its invites and keys, a
## channel and its members, and a device code. Reads keep working, and so
## does what only rewrites a small file or ends something: signing in and
## out, redeeming a device code (`RedeemDeviceCode`, a sign-in, which
## rewrites the human's short list of sign-ins), revoking, removing a
## member, cancelling a code and signing other devices out, and GitHub's
## way back, which signs in.
##
## The host is asked only for a request that adds data, so a read costs no
## system call.
import pf.Host
import pf.Http
import Directory
import HttpAnswer
import Name
import Route

DiskFloor :: [].{

	## The least free space the chat writes into: 2 GiB, far past the
	## largest request (a 10 MiB upload) and a transcript's 16 MiB.
	floor_bytes : U64
	floor_bytes = 2 * 1024 * 1024 * 1024

	## What a refused request says.
	low_words : Str
	low_words = "The server is low on disk space, so nothing new can be saved for now. Reading still works; please try again later."

	## The refusal: a 507, its words in plain text, asking the client to
	## try again in five minutes (`Retry-After`).
	refusal : Http.Response
	refusal = HttpAnswer.with_header(
		HttpAnswer.text(507, DiskFloor.low_words),
		{ name: "retry-after".to_utf8(), value: "300".to_utf8() },
	)

	## Whether a disk with `free_bytes` free takes data: only at the floor
	## or above.
	room_for : U64 -> Try({}, [LowOnDisk])
	room_for = |free_bytes|
		if free_bytes < DiskFloor.floor_bytes {
			Err(LowOnDisk)
		} else {
			Ok({})
		}

	## Whether the data root's disk takes data now, the host asked.
	check_room! : {} => Try({}, [LowOnDisk])
	check_room! = |{}| DiskFloor.room_for(Host.free_bytes_on_data_disk!({}))

	## Whether a request routed to `choice` adds data to the disk, so the
	## floor holds it (`check_room!`); the head check asks the host only
	## then, so a read costs no system call.
	adds_data : Route.Choice -> Bool
	adds_data = |choice|
		match choice {
			SignedInOnly(AppendToConversation(_)) => Bool.True
			SignedInOnly(SendToConversation(_)) => Bool.True
			SignedInOnly(UploadToConversation(_)) => Bool.True
			SignedInOnly(ReactInConversation(_)) => Bool.True
			SignedInOnly(MakeAgent) => Bool.True
			SignedInOnly(InviteAgent(_)) => Bool.True
			SignedInOnly(CreateChannel) => Bool.True
			SignedInOnly(AddChannelMember(_)) => Bool.True
			SignedInOnly(InviteHuman) => Bool.True
			SignedInOnly(InviteHumanAgain(_)) => Bool.True
			SignedInOnly(MakeDeviceCode) => Bool.True
			Open(GitHubSignUpStep(SubmitName)) => Bool.True
			Open(Join) => Bool.True
			Open(RedeemInvite) => Bool.True
			SignedInOnly(StartGitHubLink) => Bool.False
			SignedInOnly(ShowBrowse) => Bool.False
			SignedInOnly(ShowRecent) => Bool.False
			SignedInOnly(OpenRecentStream) => Bool.False
			SignedInOnly(SearchEveryTopic(_)) => Bool.False
			SignedInOnly(FollowTopicLink(_)) => Bool.False
			SignedInOnly(FollowConversationLink(_)) => Bool.False
			SignedInOnly(StartTopic(_)) => Bool.False
			SignedInOnly(ShowConversation(_)) => Bool.False
			SignedInOnly(OpenConversationStream(_)) => Bool.False
			SignedInOnly(ServeRawTranscript(_)) => Bool.False
			SignedInOnly(ServeDownload(_)) => Bool.False
			SignedInOnly(ServeUploadedImage(_)) => Bool.False
			SignedInOnly(ShowAgents) => Bool.False
			SignedInOnly(RevokeInvite(_)) => Bool.False
			SignedInOnly(RevokeKey(_)) => Bool.False
			SignedInOnly(OpenAgentStream) => Bool.False
			SignedInOnly(ShowChannels) => Bool.False
			SignedInOnly(ShowChannelMembers(_)) => Bool.False
			SignedInOnly(RemoveChannelMember(_)) => Bool.False
			SignedInOnly(ShowInvites) => Bool.False
			SignedInOnly(ShowDeviceCode) => Bool.False
			SignedInOnly(CancelDeviceCode) => Bool.False
			SignedInOnly(OpenDevicesStream) => Bool.False
			SignedInOnly(SignOutOtherDevices) => Bool.False
			Open(GitHubSignUpStep(ShowForm)) => Bool.False
			Open(RedeemDeviceCode) => Bool.False
			Open(ResumeOrBrowse) => Bool.False
			Open(ShowJoin) => Bool.False
			Open(LookUpJoinName) => Bool.False
			Open(ServeScript(_)) => Bool.False
			Open(ServeFavicon) => Bool.False
			Open(ServeAlertIcon) => Bool.False
			Open(ShowLogin) => Bool.False
			Open(SignIn) => Bool.False
			Open(SignOut) => Bool.False
			Open(StartGitHubSignIn) => Bool.False
			Open(FinishGitHubSignIn) => Bool.False
			Open(WrongMethodToGitHub(_)) => Bool.False
			NotFound => Bool.False
			MethodNotAllowed(_) => Bool.False
		}
}

# ── tests
## The route `line` (`POST /a`) asks for in the first start's directory.
route_of : Str -> Route.Choice
route_of = |line|
	match line.split_on(" ") {
		[method, path] =>
			Route.choose({
				method: method.to_utf8(),
				path: path.to_utf8(),
				directory: Directory.with_founder(Name.from_str("Steve") ?? crash "DiskFloor's tests: a name"),
			})
		_ => crash "DiskFloor's tests: a request line is a method and a path"
	}

## The writes the tests hold to the floor: a message, the script's send, an
## upload, a reaction, an invite, a join, a GitHub sign-up's name, an agent
## and its invite and redemption, a channel, and a device code.
writes : List(Str)
writes = [
	"POST /chat/dm/1_1/plans",
	"POST /chat/dm/1_1/plans/send",
	"POST /chat/dm/1_1/plans/upload",
	"POST /chat/dm/1_1/plans/react",
	"POST /invites",
	"POST /join",
	"POST /login/github/name",
	"POST /agents",
	"POST /agents/1/invites",
	"POST /agents/redeem",
	"POST /channels",
	"POST /devices",
]

## Reads, and what rewrites or ends: the page, its stream, Browse, the
## sign-in page and signing in and out, a key's revoke, a code's cancel.
not_writes : List(Str)
not_writes = [
	"GET /chat/dm/1_1/plans",
	"GET /chat/dm/1_1/plans/stream",
	"GET /chat",
	"GET /login",
	"POST /login",
	"POST /logout",
	"GET /login/github/name",
	"POST /agents/1/keys/1/revoke",
	"POST /devices/cancel",
	"GET /nowhere",
]

expect DiskFloor.floor_bytes == 2_147_483_648
# Each write adds data, and nothing else does.
expect writes.all(|line| DiskFloor.adds_data(route_of(line)))
expect not_writes.all(|line| !DiskFloor.adds_data(route_of(line)))
# Refused a byte under the floor and with nothing free; at the floor
# exactly, and above it, there is room.
expect [2_147_483_647, 0].all(|free| DiskFloor.room_for(free) == Err(LowOnDisk))
expect DiskFloor.room_for(2_147_483_648) == Ok({}) and DiskFloor.room_for(U64.highest) == Ok({})
expect {
	answer = DiskFloor.refusal
	answer.status
		== 507
		and answer.body == "${DiskFloor.low_words}\n".to_utf8()
		and answer.headers.contains({ name: "retry-after".to_utf8(), value: "300".to_utf8() })
}
