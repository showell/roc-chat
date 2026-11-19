## This module judges a request from its head alone, before the host reads
## any body: a request from another origin is refused with a 403
## (`RequestOrigin`, a trust boundary), and any other is admitted with the
## room its body may take. Only someone signed in who may post in a
## conversation gets an upload's room there; everyone else gets a form's,
## so no one gets the large room or its time before their credential is
## checked. It also puts on every answer the resource policy that keeps
## other sites' pages from loading it.
import pf.Http
import Access
import ConversationKey
import Directory
import FirstStart
import HttpAnswer
import Name
import PageKit
import RequestOrigin
import Route
import SignedIn
import UploadedImage

Admission :: [].{

	## What `RequestOrigin` judges of a request's head.
	origin_of_head : Http.RequestHead -> {
		method : List(U8),
		headers : List(Http.Header),
		port : U16,
		public_origin : List(U8),
	}
	origin_of_head = |head| {
		method: head.method,
		headers: head.headers,
		port: head.port,
		public_origin: head.public_origin,
	}

	## What the host may do with a request, from its `head`, in `directory`,
	## `actor` acting: a request from elsewhere refused with a 403; any other
	## admitted, with the room `body_allowance` gives it.
	admission_in : {
		head : Http.RequestHead,
		directory : Directory,
		actor : SignedIn.Actor,
	} -> Http.Admission
	admission_in = |{ head, directory, actor }|
		match RequestOrigin.check(Admission.origin_of_head(head)) {
			Err(why) => Admission.head_refusal(Admission.origin_refusal(why))
			Ok({}) => {
				choice = Route.choose({ method: head.method, path: head.path, directory })
				Admit(body_allowance({ choice, directory, actor }))
			}
		}

	## The refusal of a request from its head, with `answer`, which no other
	## site's page may load.
	head_refusal : Http.Response -> Http.Admission
	head_refusal = |answer| Refuse(Admission.with_same_origin_resource_policy(answer))

	## The 403 for a request from elsewhere, saying why.
	origin_refusal : RequestOrigin.Refusal -> Http.Response
	origin_refusal = |why| HttpAnswer.page(
		403,
		PageKit.notice({ title: "Forbidden", text: RequestOrigin.words(why) }),
	)

	## `answer`, which no other site's page may load: a browser refuses to hand
	## a page elsewhere any answer of this server's (`Cross-Origin-Resource-Policy`),
	## an image, a script or a stream included.
	with_same_origin_resource_policy : Http.Response -> Http.Response
	with_same_origin_resource_policy = |answer| {
		..answer,
		headers: answer.headers.append({
			name: "cross-origin-resource-policy".to_utf8(),
			value: "same-origin".to_utf8(),
		}),
	}
}

## The body a request may have: an upload's room for an upload to a
## conversation by someone signed in who may post there, and a form's for
## any other request, an upload by anyone else included. So no one gets
## the large room or its time before their credential is checked.
body_allowance : {
	choice : Route.Choice,
	directory : Directory,
	actor : SignedIn.Actor,
} -> { body_most : U64, body_grace_ms : U32 }
body_allowance = |{ choice, directory, actor }|
	match (upload_asked(choice), actor) {
		(UploadTo(key), SignedIn(acting)) =>
			match Access.check({
				acting,
				place: key.place(),
				directory,
				act: Post,
			}) {
				Ok({}) => upload_body_allowance
				Err(NotAMember) => form_body_allowance
				Err(ScopeOff) => form_body_allowance
			}
		(UploadTo(_), Anonymous) => form_body_allowance
		(NoUpload, SignedIn(_)) => form_body_allowance
		(NoUpload, Anonymous) => form_body_allowance
	}

## Whether a route uploads to a conversation, and to which.
upload_asked : Route.Choice -> [UploadTo(ConversationKey), NoUpload]
upload_asked = |choice|
	match choice {
		SignedInOnly(UploadToConversation(key)) => UploadTo(key)
		SignedInOnly(StartGitHubLink) => NoUpload
		SignedInOnly(ShowBrowse) => NoUpload
		SignedInOnly(ShowRecent) => NoUpload
		SignedInOnly(OpenRecentStream) => NoUpload
		SignedInOnly(StartTopic(_)) => NoUpload
		SignedInOnly(ShowConversation(_)) => NoUpload
		SignedInOnly(AppendToConversation(_)) => NoUpload
		SignedInOnly(SendToConversation(_)) => NoUpload
		SignedInOnly(OpenConversationStream(_)) => NoUpload
		SignedInOnly(ServeRawTranscript(_)) => NoUpload
		SignedInOnly(ServeUploadedImage(_)) => NoUpload
		SignedInOnly(ReactInConversation(_)) => NoUpload
		SignedInOnly(ShowAgents) => NoUpload
		SignedInOnly(MakeAgent) => NoUpload
		SignedInOnly(InviteAgent(_)) => NoUpload
		SignedInOnly(RevokeInvite(_)) => NoUpload
		SignedInOnly(RevokeKey(_)) => NoUpload
		SignedInOnly(OpenAgentStream) => NoUpload
		SignedInOnly(ShowChannels) => NoUpload
		SignedInOnly(CreateChannel) => NoUpload
		SignedInOnly(ShowChannelMembers(_)) => NoUpload
		SignedInOnly(AddChannelMember(_)) => NoUpload
		SignedInOnly(RemoveChannelMember(_)) => NoUpload
		SignedInOnly(ShowInvites) => NoUpload
		SignedInOnly(InviteHuman) => NoUpload
		SignedInOnly(InviteHumanAgain(_)) => NoUpload
		Open(ResumeOrBrowse) => NoUpload
		Open(ShowJoin) => NoUpload
		Open(LookUpJoinName) => NoUpload
		Open(Join) => NoUpload
		Open(ServeScript(_)) => NoUpload
		Open(ServeFavicon) => NoUpload
		Open(ShowLogin) => NoUpload
		Open(SignIn) => NoUpload
		Open(SignOut) => NoUpload
		Open(StartGitHubSignIn) => NoUpload
		Open(FinishGitHubSignIn) => NoUpload
		Open(FinishGitHubSignUp) => NoUpload
		Open(WrongMethodToGitHub(_)) => NoUpload
		Open(RedeemInvite) => NoUpload
		NotFound => NoUpload
		MethodNotAllowed(_) => NoUpload
	}

## The body a form may have: a message as the compose box posts it, 64 KiB
## with room to spare, read within the request's own time.
form_body_allowance : { body_most : U64, body_grace_ms : U32 }
form_body_allowance = { body_most: 64 * 1024, body_grace_ms: 0 }

## The body an upload may have: an image at its largest
## (`UploadedImage.most_bytes`), with 64 KiB for the multipart form around
## it. It has five minutes more to arrive, the compose box's patience for
## a large image on a slow link.
upload_body_allowance : { body_most : U64, body_grace_ms : U32 }
upload_body_allowance = {
	body_most: UploadedImage.most_bytes + 64 * 1024,
	body_grace_ms: 5 * 60 * 1000,
}

# ── tests
## Steve, the first start's founder, signed in.
steve : SignedIn
steve = SignedIn.dangerously_assume(FirstStart.first_directory.chat_owner().user())

## The head of a request whose request line is `line` (`POST /a`), its Host
## this server's at port 9611, with `more_headers` (name, value).
head_of : Str, List((Str, Str)) -> Http.RequestHead
head_of = |line, more_headers| {
	(method, path) =
		match line.split_on(" ") {
			[method_text, path_text] => (method_text, path_text)
			_ => crash "Admission's tests: a request line is a method and a path"
		}
	{
		method: method.to_utf8(),
		path: path.to_utf8(),
		headers: List.concat([("Host", "localhost:9611")], more_headers).map(
			|(name, value)| { name: name.to_utf8(), value: value.to_utf8() },
		),
		port: 9611,
		public_origin: [],
	}
}

## What `admission_in` makes of `head` in `directory`, `actor` acting, as a
## test reads it: the allowance it admits it with, or its refusal's status
## and headers.
admission_verdict_for : {
	head : Http.RequestHead,
	directory : Directory,
	actor : SignedIn.Actor,
} -> [
	Admitted({ body_most : U64, body_grace_ms : U32 }),
	Refused(U16, List((Str, Str))),
]
admission_verdict_for = |admission|
	match Admission.admission_in(admission) {
		Admit(allowance) => Admitted(allowance)
		Refuse(answer) => Refused(
			answer.status,
			answer.headers.map(|h| (Str.from_utf8_lossy(h.name), Str.from_utf8_lossy(h.value))),
		)
	}

## What `admission_in` makes of `head` in the first directory, Steve
## signed in, as a test reads it.
admission_verdict : Http.RequestHead -> [
	Admitted({ body_most : U64, body_grace_ms : U32 }),
	Refused(U16, List((Str, Str))),
]
admission_verdict = |head|
	admission_verdict_for({
		head,
		directory: FirstStart.first_directory,
		actor: SignedIn(steve),
	})

## The first directory with a second human, Apoorva, id 2, whose own DM,
## `2_2`, Steve may not post in.
with_apoorva : Directory
with_apoorva = {
	apoorva = Name.from_str("Apoorva") ?? crash "Admission's tests: a name"
	(FirstStart.first_directory.add_human(apoorva) ?? crash "Admission's tests: Apoorva joins").directory
}

# An upload's room goes to someone signed in who may post there, and to no
# one else: not to no one, and not to one who may not post in the place.
expect
	admission_verdict_for({
		head: head_of("POST /chat/dm/2_2/plans/upload", []),
		directory: with_apoorva,
		actor: SignedIn(steve),
	})
		== Admitted(form_body_allowance)
expect
	admission_verdict_for({
		head: head_of("POST /chat/dm/1_1/plans/upload", []),
		directory: with_apoorva,
		actor: SignedIn(steve),
	})
		== Admitted(upload_body_allowance)
expect
	[
		"POST /chat/dm/1_1/plans/upload",
		"POST /chat/channel/general/plans/upload",
		"POST /chat/dm/1_1/plans",
	].all(
		|line|
			admission_verdict_for({
				head: head_of(line, []),
				directory: FirstStart.first_directory,
				actor: Anonymous,
			})
				== Admitted(form_body_allowance),
	)
# A public origin reaches the admission: its Host is this server's when the
# server has it, and a stranger's when it has none.
expect {
	public_head = {
		..head_of("POST /chat/dm/1_1/plans/upload", []),
		headers: [
			{ name: "Host".to_utf8(), value: "chat.example.com".to_utf8() },
			{ name: "Origin".to_utf8(), value: "https://chat.example.com".to_utf8() },
		],
	}
	admission_verdict({
		..public_head,
		public_origin: "https://chat.example.com".to_utf8(),
	}) == Admitted(upload_body_allowance)
		and admission_verdict(public_head) == Refused(403, forbidden_headers)
}
# The allowances: a form's 64 KiB in the request's own time; an upload's
# image at its largest and 64 KiB of form, with five minutes more.
expect form_body_allowance == { body_most: 65_536, body_grace_ms: 0 }
expect upload_body_allowance == { body_most: 10_551_296, body_grace_ms: 300_000 }
# Admitted from its head: a routed upload with an upload's room, from curl
# or this server's own page; any other request with a form's, a path ending
# `/upload` that is no conversation's, or an upload's path by GET or PUT,
# included.
expect
	[
		head_of("POST /chat/dm/1_1/plans/upload", []),
		head_of(
			"POST /chat/channel/general/plans/upload",
			[("Origin", "http://localhost:9611"), ("Sec-Fetch-Site", "same-origin")],
		),
	].all(|head| admission_verdict(head) == Admitted(upload_body_allowance))
expect
	[
		head_of("POST /chat/dm/1_1/plans", []),
		head_of("POST /x/upload", []),
		head_of("POST /chat/dm/1_2/plans/upload", []),
		head_of("GET /chat/dm/1_1/plans/upload", []),
		head_of("PUT /chat/dm/1_1/plans/upload", []),
		head_of(
			"GET /chat/dm/1_1/plans/stream",
			[("Sec-Fetch-Site", "cross-site"), ("Sec-Fetch-Mode", "navigate")],
		),
		head_of("POST /agents/redeem", []),
	].all(|head| admission_verdict(head) == Admitted(form_body_allowance))
# Refused from its head, whatever its route: a 403 that no other site's page
# may load.
## The headers of the 403 a request from elsewhere is refused with.
forbidden_headers : List((Str, Str))
forbidden_headers = [
	("content-type", "text/html; charset=utf-8"),
	(
		"content-security-policy",
		"default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; img-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; connect-src 'self'",
	),
	("x-content-type-options", "nosniff"),
	("cross-origin-resource-policy", "same-origin"),
]

## An EventSource's headers, from another site's page.
elsewhere_event_source_headers : List((Str, Str))
elsewhere_event_source_headers = [
	("Origin", "http://evil.example"),
	("Sec-Fetch-Site", "cross-site"),
	("Sec-Fetch-Mode", "cors"),
]

expect
	[
		head_of("POST /chat/dm/1_1/plans/upload", [("Origin", "http://evil.example")]),
		head_of("POST /chat/dm/1_1/plans/upload", [("Sec-Fetch-Site", "cross-site")]),
		head_of("GET /chat/dm/1_1/plans/stream", elsewhere_event_source_headers),
		head_of(
			"GET /chat/dm/1_1/plans/stream",
			[("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "no-cors")],
		),
		head_of("POST /agents", [("Origin", "http://evil.example")]),
		{ ..head_of("POST /chat/dm/1_1/plans/upload", []), port: 9612 },
	].all(|head| admission_verdict(head) == Refused(403, forbidden_headers))
# Every answer ends with its resource policy, after its own headers.
expect
	Admission.with_same_origin_resource_policy(HttpAnswer.see_other("/a")).headers
		== [
			{ name: "location".to_utf8(), value: "/a".to_utf8() },
			{ name: "cross-origin-resource-policy".to_utf8(), value: "same-origin".to_utf8() },
		]
