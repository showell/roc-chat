## These are the tests of a device's sessions: a session started by a device
## code, marked in its cookie and in what it is signed over and limited to
## what such a session may do (`Session`, `SignedIn`, `FullSessionRoutes`);
## the session generation that signs every other device out
## (`Session.Material`); and the list of sign-ins by code, each device named
## coarsely (`DeviceSignIns`, `DeviceCodePage`).
import AgentsPage
import DeviceCodePage
import DeviceSignIns
import FirstStart
import FullSessionRoutes
import PasswordHash
import Route
import Session
import SignedIn
import Timestamp
import UserId
import Users

DeviceSessionsSpec :: [].{}

## Steve, the first start's founder.
steve : Users.Human
steve = FirstStart.first_directory.chat_owner()

## When a test's session is signed.
signed_at : Timestamp
signed_at = Timestamp.at_second(1_700_000_000)

## The material of a human whose password file keeps `text`.
material_of : Str -> Session.Material
material_of = |text|
	Session.Material.from_password({
		password_hash: PasswordHash.from_file(text.to_utf8()),
		github: NoGitHub,
	})

## Steve signed in by a session started as `origin` says, as a request's
## session admits him once its signature matched.
steve_by : Session.Origin -> SignedIn
steve_by = |origin| {
	value = Session.cookie_value({
		id: UserId.chat_owner,
		signed_at,
		origin,
		mac: List.repeat(7, 32),
	})
	claim = Session.claim_from_cookie_header("${Session.cookie_name}=${value}".to_utf8())
		?? crash "DeviceSessionsSpec: a claim"
	admitted = Session.admit({
		claim,
		verdict: Matches,
		now: signed_at,
		users: FirstStart.first_directory.users(),
	})
		?? crash "DeviceSessionsSpec: a session admits Steve"
	SignedIn.by_session(admitted)
}

## The route `method` and `path` choose in the first start's directory.
route_of : Str, Str -> Route.Choice
route_of = |method, path|
	Route.choose({
		method: method.to_utf8(),
		path: path.to_utf8(),
		directory: FirstStart.first_directory,
	})

## Whether `actor` is refused `method` and `path` for its session's origin.
is_refused_by_origin : SignedIn.Actor, (Str, Str) -> Bool
is_refused_by_origin = |actor, (method, path)|
	FullSessionRoutes.refusal_for({ choice: route_of(method, path), actor }) == StartedByDeviceCode

# A session started by a device code: a fourth part, `d`, in its cookie, and
# a mark in what it is signed over, so the two never share a signature; read
# back as such, and any other fourth part is no session.
expect
	Session.cookie_value({
		id: UserId.chat_owner,
		signed_at,
		origin: ByDeviceCode,
		mac: List.repeat(0, 32),
	})
		== "MQ.1700000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.d"
expect
	Session.signed_bytes({
		id: UserId.chat_owner,
		signed_at,
		origin: ByDeviceCode,
		material: material_of("$2b$10$x"),
	})
		== "1\n1700000000\nby-device-code\n$2b$10$x".to_utf8()
expect
	Session.signed_bytes({
		id: UserId.chat_owner,
		signed_at,
		origin: ByDeviceCode,
		material: material_of("h"),
	})
		!= Session.signed_bytes({
			id: UserId.chat_owner,
			signed_at,
			origin: Ordinary,
			material: material_of("h"),
		})
expect steve_by(ByDeviceCode).session_origin() == ByDeviceCode
expect steve_by(Ordinary).session_origin() == Ordinary
expect
	["x", "dd", "D", ""].all(
		|fourth| {
			value = "MQ.1700000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.${fourth}"
			header = "${Session.cookie_name}=${value}".to_utf8()
			Session.claim_from_cookie_header(header).map_ok(|_| {}) == Err(BadSession)
		},
	)

# Such a session may not hand out a credential or take one from the human's
# other devices: link GitHub, by its button or through GitHub; make, invite
# or revoke for an agent; invite a human or invite one again; make or cancel
# a code; sign the other devices out; use the channels' admin pages,
# create a channel or add or remove its members. It reads and posts as any session
# does. An ordinary session may do all of it, and no
# one is left to the routes' own refusals.
## The routes a session started by a code may not use.
full_session_routes : List((Str, Str))
full_session_routes = [
	("POST", "/login/github/link"),
	("GET", "/login/github/start"),
	("GET", "/login/github"),
	("POST", "/agents"),
	("POST", "/agents/2/invites"),
	("POST", "/agents/2/invites/1/revoke"),
	("POST", "/agents/2/keys/1/revoke"),
	("POST", "/invites"),
	("POST", "/invites/2/again"),
	("POST", "/devices"),
	("POST", "/devices/cancel"),
	("POST", "/devices/sign-out-others"),
	("GET", "/channels"),
	("POST", "/channels"),
	("GET", "/channels/general"),
	("POST", "/channels/general/members/2/add"),
	("POST", "/channels/general/members/2/remove"),
]

## Routes every session may use.
any_session_routes : List((Str, Str))
any_session_routes = [
	("GET", "/chat"),
	("GET", "/chat/dm/1_1/plans"),
	("POST", "/chat/dm/1_1/plans"),
	("POST", "/chat/dm/1_1/plans/react"),
	("GET", "/chat/msg/plans_1"),
	("GET", "/chat/msg/general.plans_1"),
	("GET", "/invites"),
	("GET", "/agents"),
	("GET", "/devices"),
	("POST", "/logout"),
	("GET", "/login"),
]

expect full_session_routes.all(
	|route| is_refused_by_origin(SignedIn(steve_by(ByDeviceCode)), route),
)
expect any_session_routes.all(
	|route| !is_refused_by_origin(SignedIn(steve_by(ByDeviceCode)), route),
)
expect
	List.concat(full_session_routes, any_session_routes).all(
		|route| !is_refused_by_origin(
			SignedIn(steve_by(Ordinary)),
			route,
		) and !is_refused_by_origin(Anonymous, route),
	)
expect steve_by(ByDeviceCode).check_full_session() == Err(StartedByDeviceCode)
expect steve_by(Ordinary).check_full_session() == Ok({})

# The session generation: none, 0, is the material as it was, so no session
# ends until a human signs their other devices out; each one after is other
# bytes, which no hash or word holds.
expect material_of("h").with_generation(0).bytes_to_sign() == "h".to_utf8()
expect material_of("h").with_generation(1).bytes_to_sign() == "h\ngeneration 1".to_utf8()
expect
	material_of("h").with_generation(1).bytes_to_sign()
		!= material_of("h").with_generation(2).bytes_to_sign()

# A device named by its `User-Agent`, as coarsely as a browser's family and
# a system's: Edge and Opera, which say Chrome too, as themselves; an iPad,
# which says Mac, as iOS; anything unknown, as the other of each.
## The words for the device a `User-Agent` names.
device_text : Str -> Str
device_text = |header| {
	device = DeviceSignIns.device_of_user_agent(header.to_utf8())
	DeviceSignIns.device_words(device)
}

expect
	[
		(
			"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
			"Safari on iOS",
		),
		(
			"Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0 Mobile/15E148 Safari/604.1",
			"Chrome on iOS",
		),
		(
			"Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36",
			"Chrome on Android",
		),
		(
			"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36 Edg/120.0",
			"Edge on Windows",
		),
		(
			"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
			"Safari on macOS",
		),
		(
			"Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0",
			"Firefox on Linux",
		),
		(
			"Mozilla/5.0 (X11; CrOS x86_64 15633.69.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0 Safari/537.36 OPR/105.0",
			"Opera on ChromeOS",
		),
		("curl/8.5.0", "a browser on another system"),
		("", "a browser on another system"),
	].all(|(header, words)| device_text(header) == words)

# The list: the newest first, at most ten, and the eleventh oldest gone; its
# file read back as written, and any other line is damaged.
## A sign-in at `second` from Safari on iOS.
sign_in_from_safari : I64 -> DeviceSignIns.SignIn
sign_in_from_safari = |second| {
	at: Timestamp.at_second(second),
	device: { browser: Safari, system: IPhone },
}

expect {
	eleven = List.from_iter(I64.to(1, 11)).fold(
		[],
		|kept, second| DeviceSignIns.with_sign_in(kept, sign_in_from_safari(second)),
	)
	eleven.len() == 10
		and eleven.first() == Ok(sign_in_from_safari(11))
		and eleven.last() == Ok(sign_in_from_safari(2))
}
expect {
	sign_ins = [
		sign_in_from_safari(20),
		{ at: Timestamp.at_second(10), device: { browser: OtherBrowser, system: OtherSystem } },
	]
	file = DeviceSignIns.sign_ins_to_file(sign_ins)
	file == "20 safari ios\n10 other other\n".to_utf8()
		and DeviceSignIns.sign_ins_from_file(file) == Ok(sign_ins)
}
expect DeviceSignIns.sign_ins_from_file([]) == Ok([])
expect
	[
		"20 safari",
		"20 safari ios x",
		"x safari ios",
		"20 netscape ios",
		"20 safari beos",
		"20  safari ios",
	].all(|line| DeviceSignIns.sign_ins_from_file("${line}\n".to_utf8()) == Err(Damaged))

# The page: the sign-ins listed, each when and from what, or a line saying
# there are none; the button that signs every other device out, under the
# id the notice of a new device links to.
## The device code page for Steve with `sign_ins`, as a test reads it.
page_with : List(DeviceSignIns.SignIn) -> Str
page_with = |sign_ins|
	Str.from_utf8_lossy(
		DeviceCodePage.page({
			viewer: SignedIn.dangerously_assume(steve.user()),
			shown: Status(NoCode),
			sign_ins,
		}).to_utf8(),
	)

expect page_with([sign_in_from_safari(0)]).contains("<li>1970-01-01T00:00:00Z: Safari on iOS</li>")
expect page_with([]).contains("No device has signed in with a code yet.")
expect
	page_with([]).contains(
		"<form id=\"sign-out-others\" method=\"post\" action=\"/devices/sign-out-others\"><button>Sign out other devices</button></form>",
	)
expect
	Str.from_utf8_lossy(DeviceCodePage.new_device_frame).contains("<a href=\"/devices#sign-out-others\">")

# A device whose session a code started sees no button it couldn't use: on
# its device code page none that makes or cancels a code or signs other
# devices out, on its agents page none but the top bar's "Sign out", and a
# line saying why in each; a session started otherwise sees them all.
## The device code page for `viewer`, with a code waiting, as a test reads it.
devices_page_for : SignedIn -> Str
devices_page_for = |viewer|
	Str.from_utf8_lossy(
		DeviceCodePage.page({
			viewer,
			shown: Status(Waiting(signed_at)),
			sign_ins: [],
		}).to_utf8(),
	)

## The agents page for `viewer`, the admin's, as a test reads it.
agents_page_for : SignedIn -> Str
agents_page_for = |viewer|
	Str.from_utf8_lossy(
		AgentsPage.agents({
			viewer,
			agents: Kept([]),
			shown: NoCode,
			github_link: LinkOffered,
		}).to_utf8(),
	)

expect {
	by_code = devices_page_for(steve_by(ByDeviceCode))
	!by_code.contains("action=\"/devices\"")
		and !by_code.contains("action=\"/devices/cancel\"")
		and !by_code.contains("action=\"/devices/sign-out-others\"")
		and by_code.contains("This device signed in with a code, so it can&#39;t make codes")
}
expect {
	ordinary = devices_page_for(steve_by(Ordinary))
	ordinary.contains("action=\"/devices\"")
		and ordinary.contains("action=\"/devices/cancel\"")
		and ordinary.contains("action=\"/devices/sign-out-others\"")
		and !ordinary.contains("This device signed in with a code, so it can&#39;t make codes")
}
expect {
	by_code = agents_page_for(steve_by(ByDeviceCode))
	panel = by_code.split_on("</header>").drop_first(1)
	signs_out = by_code.contains("<form class=\"sign-out\" method=\"post\" action=\"/logout\"><button>Sign out</button></form>")
	signs_out and !Str.join_with(panel, "").contains("<button>") and by_code.contains("This device signed in with a code, so it can&#39;t manage agents")
}
expect {
	ordinary = agents_page_for(steve_by(Ordinary))
	ordinary.contains("<button>Make an agent</button>")
		and ordinary.contains("action=\"/login/github/link\"")
		and !ordinary.contains("This device signed in with a code, so it can&#39;t manage agents")
}
# After a reload, a waiting code is not shown again, and the page says how
# to see one.
expect devices_page_for(steve_by(Ordinary)).contains("It is shown only once; make a new code to see one.")
