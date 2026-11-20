## This module answers the device code routes (`DeviceCode`), which sign a
## second device in as a human signed in on another:
##
## - `GET /devices`, for a human signed in by a session: the page
##   (`DeviceCodePage`), saying what became of their last code.
## - `POST /devices`, for the same: a new code, its record replacing the one
##   before, so the old code is cancelled; the page shows the code once.
## - `POST /login/code`, for anyone but a request with an API key: the code
##   the form holds, redeemed. A code that a live record's HMAC matches, in
##   its life, spends the record, tells its human on their own stream that a
##   new device signed in, and starts a session marked as a code's
##   (`SignInRoute.start_session_by_device_code!`). An entry of no code's
##   shape is a 400 saying what a code looks like, counted as no guess.
##   Every other well-formed code is the same 401, after the same work: the
##   typed code's HMAC compared by the host, in constant time, with every
##   human's record, or a stand-in where a human has none. Each such failure
##   is counted (`DeviceCodeTallies`), and a client past its most finds the
##   form locked, a 429, with no code compared.
## - Signing out (`sign_out!`), setting a password (`revoke_device_code!`)
##   and signing other devices out (`DeviceSessionsRoute`) cancel a live
##   code, and signing out forgets the cookie that shows one.
##
## No answer may be kept by a browser or a proxy, and no answer, log or
## refusal holds a code but the page that shows a new one.
import pf.Host
import pf.Http
import DeviceCode
import DeviceCodeFiles
import DeviceCodeTallies
import DeviceSessionsRoute
import DeviceCodePage
import FileFacts
import Html
import HttpAnswer
import PageKit
import Presence
import RequestHeader
import SignInPage
import SignInFiles
import SignInRequest
import SignInRoute
import SignedIn
import Timestamp
import UserId
import Users

DeviceCodeRoute :: [].{

	## A GET of `/devices` by `acting`, its `headers` holding the cookie of a
	## code just made, at `now`, at this server's `origin`, whose sign-in
	## page the page names: the page, showing that code when it is the
	## one their live record holds, else what became of their last code. A
	## cookie sent is forgotten, so a code is shown once. A damaged record is
	## logged and taken as none.
	show! : {
		acting : SignedIn,
		headers : List(Http.Header),
		now : Timestamp,
		origin : Str,
	} => Http.Response
	show! = |{ acting, headers, now, origin }| {
		cookie_header =
			match RequestHeader.header_value(headers, "cookie") {
				Sent(value) => value
				Unsent | Repeated => []
			}
		flash = DeviceCode.Code.from_cookie_header(cookie_header)
		answer =
			match acting.human_in_session() {
				Err(_) => session_only_answer
				Ok(human) =>
					{
						held = load_record_or_stand_in!(human.id())
						shown = load_shown!({ held, flash, now })
						sign_ins = DeviceSessionsRoute.load_sign_ins!(human.id())
						HttpAnswer.page(
							200,
							DeviceCodePage.page({
								viewer: acting,
								shown,
								sign_ins,
								sign_in_url: "${origin}/login",
							}),
						)
					}
			}
		forgotten = cookie_header_of(DeviceCode.clear_flash_cookie_text)
		HttpAnswer.never_stored(
			match flash {
				Ok(_) => HttpAnswer.with_header(answer, forgotten)
				Err(NoCode) => answer
			},
		)
	}

	## A POST of `/devices` by `acting` at `now`: a new code, its record
	## replacing the one before, and a 303 to the page, which shows it once,
	## from a cookie, so a reload of the page makes no new one.
	make! : { acting : SignedIn, users : Users, now : Timestamp } => Http.Response
	make! = |{ acting, users, now }| {
		answer =
			match acting.human_in_session() {
				Err(_) => session_only_answer
				Ok(human) =>
					match make_record!({ users, id: human.id(), now }) {
						Err(NoMaterial) => material_missing_answer
						Err(GenerationDamaged) => SignInRoute.fault_answer(Damaged)
						Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
						Ok({ code, record: _ }) =>
							HttpAnswer.with_header(
								HttpAnswer.see_other(DeviceCodePage.path),
								cookie_header_of(code.flash_cookie_text()),
							)
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## A POST of `/devices/cancel` by `acting`: their live code cancelled, the
	## cookie that shows it forgotten, and a 303 to the page.
	revoke! : SignedIn => Http.Response
	revoke! = |acting| {
		answer =
			match acting.human_in_session() {
				Err(_) => session_only_answer
				Ok(human) =>
					match DeviceCodeRoute.revoke_device_code!(human.id()) {
						Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
						Ok({}) =>
							HttpAnswer.with_header(
								HttpAnswer.see_other(DeviceCodePage.path),
								cookie_header_of(DeviceCode.clear_flash_cookie_text),
							)
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## A GET of `/devices/stream` by `acting`: their own stream, live only,
	## on which the page hears that their code was used.
	open_stream : SignedIn -> Http.Response
	open_stream = |acting|
		match acting.human_in_session() {
			Err(_) => session_only_answer
			Ok(human) =>
				HttpAnswer.stream({
					keys: [Presence.viewer_stream_key(human.id())],
					holder: human.id().to_str().to_utf8(),
					backlog: [],
				})
		}

	## A POST of `/login/code`, the form `body`, from `viewer`, among `users`,
	## its `headers` naming the client, at `now`: a session for the human the
	## code signs in, and a 303 to the form's `next`; or the sign-in page
	## again, a 401 that says only that the code didn't work, or a 429 while
	## the form is locked. A request with an API key may not sign in.
	redeem! : {
		viewer : SignedIn.Actor,
		users : Users,
		headers : List(Http.Header),
		body : List(U8),
		now : Timestamp,
		github : SignInPage.GitHubOffer,
	} => Http.Response
	redeem! = |request| {
		by_key = SignInRequest.check_not_by_api_key(request.viewer)
		answer =
			match (by_key, SignInRequest.next_from_form(request.body)) {
				(Err(ByApiKey), _) => SignInRoute.by_api_key_answer
				(Ok({}), Err(BadNext)) => SignInRoute.bad_next_answer
				(Ok({}), Ok(next)) => {
					tallies = DeviceCodeTallies.load_tallies!(request.headers, request.now)
					again = { viewer: request.viewer, github: request.github, next }
					if DeviceCodeTallies.is_locked(tallies) {
						sign_in_page_again(again, { status: 429, words: locked_words })
					} else {
						match SignInRequest.device_code_from_form(request.body) {
							Err(NotACode) =>
								sign_in_page_again(again, { status: 400, words: malformed_words })
							Ok(code) => {
								typed = { users: request.users, code, now: request.now }
								refused = { status: 401, words: no_match_words }
								match find_redemption!(typed) {
									Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
									Err(NoMatch) => {
										DeviceCodeTallies.count_failure!(tallies)
										sign_in_page_again(again, refused)
									}
									Ok(redemption) =>
										answer_redemption!(
											redemption,
											{ next, headers: request.headers, now: request.now },
										)
								}
							}
						}
					}
				}
			}
		HttpAnswer.never_stored(answer)
	}

	## A POST of `/logout` by `actor`: a live code of theirs cancelled, then
	## `SignInRoute.sign_out`, the cookie that shows a code forgotten too. A
	## code that can't be cancelled is logged and the sign-out goes on, as a
	## damaged record redeems nothing and a failed write leaves at most a
	## code's five minutes.
	sign_out! : SignedIn.Actor => Http.Response
	sign_out! = |actor| {
		signed_in_human =
			match actor {
				SignedIn(acting) => acting.human_in_session().map_err(|_| NoHuman)
				Anonymous => Err(NoHuman)
			}
		forgotten = cookie_header_of(DeviceCode.clear_flash_cookie_text)
		match signed_in_human {
			Err(NoHuman) => HttpAnswer.with_header(SignInRoute.sign_out, forgotten)
			Ok(human) => {
				DeviceCodeFiles.revoke_or_log!(human.id())
				HttpAnswer.with_header(SignInRoute.sign_out, forgotten)
			}
		}
	}

	## The human `id`'s code cancelled, when it is live.
	revoke_device_code! : UserId => Try({}, [FileSystem(FileFacts.Fault)])
	revoke_device_code! = |id| DeviceCodeFiles.revoke_live_device_code!(id)
}

## A new code, of the host's random bytes.
draw_code! : {} => DeviceCode.Code
draw_code! = |{}| {
	random_bytes = Host.fill_with_random_bytes!(DeviceCode.random_byte_count)
	match DeviceCode.Code.of_random_bytes(random_bytes) {
		Ok(code) => code
		Err(TooFewUsableBytes) =>
			crash "DeviceCodeRoute.draw_code!: fewer than 8 of 32 random bytes below 250, which happens about once in 10^34 draws"
	}
}

## A new code whose HMAC no record in `held` keeps, and that HMAC: drawn
## again until it is so.
draw_unheld_code! : List(DeviceCode) => { code : DeviceCode.Code, mac : List(U8) }
draw_unheld_code! = |held| {
	code = draw_code!({})
	mac = Host.hmac_sha256_with_server_secret!(code.bytes_to_sign())
	if DeviceCode.is_mac_held(mac, held) {
		draw_unheld_code!(held)
	} else {
		{ code, mac }
	}
}

## Every other human's record but the human `id`'s, among `users`.
other_records! : Users, UserId => List(DeviceCode)
other_records! = |users, id| {
	others = users.to_list().keep_oks(|user| user.as_human()).drop_if(|human| human.id() == id)
	var $records = []
	for human in others {
		$records =
			match load_record_or_stand_in!(human.id()) {
				Record(record) => $records.append(record)
				NoRecord => $records
			}
	}
	$records
}

## The redemption of `code`, a well-formed code, among every human's
## record; else `NoMatch`, after the same work whatever the code: every
## record's HMAC compared, then one material read and compared, a stand-in's
## when no record matched.
find_redemption! : {
	users : Users,
	code : DeviceCode.Code,
	now : Timestamp,
} => Try(DeviceCode.Redemption, [NoMatch, FileSystem(FileFacts.Fault)])
find_redemption! = |{ users, code, now }| {
	typed = code.bytes_to_sign()
	humans = users.to_list().keep_oks(|user| user.as_human())
	var $candidates = []
	for human in humans {
		held = load_record_or_stand_in!(human.id())
		kept_mac =
			match held {
				Record(record) => record.mac()
				NoRecord => no_record_mac
			}
		verdict = Host.hmac_sha256_with_server_secret_matches!(typed, kept_mac)
		$candidates =
			match held {
				Record(record) => $candidates.append({ owner: human, record, verdict })
				NoRecord => $candidates
			}
	}
	match DeviceCode.matching_candidate($candidates, now) {
		Ok(found) => {
			material_verdict = check_material!(found)?
			DeviceCode.redeem({ found, material_verdict, now })
		}
		Err(NoMatch) => {
			compare_stand_in_material!({})
			Err(NoMatch)
		}
	}
}

## The work `check_material!` does, for a code no record matched: the chat
## owner's material read and its HMAC compared with no record's, the verdict
## and any fault let go, so a code that matches nothing takes as long as one
## that matched a stale record.
compare_stand_in_material! : {} => {}
compare_stand_in_material! = |{}| {
	_ =
		match SignInFiles.load_material!(UserId.chat_owner) {
			Ok(material) =>
				Host.hmac_sha256_with_server_secret_matches!(
					DeviceCode.material_bytes_to_sign(material),
					no_record_mac,
				)
			Err(_) => DoesNotMatch
		}
	{}
}

## The host's verdict on whether what `found`'s owner's sessions are signed
## over now is what its record was made under: none at all is a change.
check_material! : DeviceCode.Found => Try([DoesNotMatch, Matches], [FileSystem(FileFacts.Fault)])
check_material! = |found|
	match SignInFiles.load_material!(found.owner.id()) {
		Ok(material) =>
			Ok(
				Host.hmac_sha256_with_server_secret_matches!(
					DeviceCode.material_bytes_to_sign(material),
					found.record.material_digest(),
				),
			)
		Err(NoMaterial) | Err(GenerationDamaged) => Ok(DoesNotMatch)
		Err(FileSystem(fault)) => Err(FileSystem(fault))
	}

## The human `id`'s record, or none; one that is damaged or can't be read
## is logged and taken as none, so one human's file never stops everyone's
## codes.
load_record_or_stand_in! : UserId => [NoRecord, Record(DeviceCode)]
load_record_or_stand_in! = |id|
	match DeviceCodeFiles.read_device_code!(id) {
		Ok(held) => held
		Err(FileSystem(fault)) => {
			said = "device codes: user ${id.to_str()}'s record taken as none: ${FileFacts.fault_words(fault)}"
			Host.write_line_to_server_log!(said.to_utf8())
			NoRecord
		}
	}

## A new code for the human `id` at `now`, and its record, written over the
## one before, holding the HMAC of what their sessions are signed over now;
## unless they have nothing to sign over (`NoMaterial`), or a file fails.
## The code is drawn again while its HMAC is one another human's record
## among `users` keeps, so no typed code matches two records. Every other
## record is only read; the one file written is still the human's own.
make_record! : { users : Users, id : UserId, now : Timestamp } => Try(
	{ code : DeviceCode.Code, record : DeviceCode },
	[NoMaterial, GenerationDamaged, FileSystem(FileFacts.Fault)],
)
make_record! = |{ users, id, now }| {
	material = SignInFiles.load_material!(id)?
	{ code, mac } = draw_unheld_code!(other_records!(users, id))
	record = DeviceCode.make({
		mac,
		material: Host.hmac_sha256_with_server_secret!(DeviceCode.material_bytes_to_sign(material)),
		now,
	})
	DeviceCodeFiles.replace_device_code!(id, record)?
	Ok({ code, record })
}

## The answer to `redemption` at `now`, from the device the request's
## `headers` name: its record written spent, so the code never works again,
## its human told, the sign-in noted in their list, and the session started,
## marked as a code's; or a
## 500 when the record can't be written, and no session.
answer_redemption! : DeviceCode.Redemption,
{
	next : Html.SitePath,
	headers : List(Http.Header),
	now : Timestamp,
} => Http.Response
answer_redemption! = |redemption, { next, headers, now }| {
	owner = redemption.owner().id()
	match DeviceCodeFiles.replace_device_code!(owner, redemption.spent_record()) {
		Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
		Ok({}) => {
			viewer_key = Presence.viewer_stream_key(owner)
			Host.publish_bytes_to_streams_on_key!(viewer_key, DeviceCodePage.new_device_frame)
			Host.publish_bytes_to_streams_on_key!(viewer_key, DeviceCodePage.used_frame(now))
			DeviceSessionsRoute.note_sign_in!({ id: owner, headers, now })
			SignInRoute.start_session_by_device_code!(redemption, { next, now })
		}
	}
}

## What the page shows of `held`, the human's record, at `now`: the code
## the cookie carries, `flash`, when its HMAC is the one a waiting record
## keeps, else the record's status.
load_shown! : {
	held : [NoRecord, Record(DeviceCode)],
	flash : Try(DeviceCode.Code, [NoCode]),
	now : Timestamp,
} => DeviceCodePage.Shown
load_shown! = |{ held, flash, now }| {
	status = DeviceCode.status(held, now)
	match (held, flash, status) {
		(
			Record(record),
			Ok(code),
			Waiting(expires),
		) =>
			match Host.hmac_sha256_with_server_secret_matches!(code.bytes_to_sign(), record.mac()) {
				Matches => Made({ code, expires })
				DoesNotMatch => Status(status)
			}
		_ => Status(status)
	}
}

## A `Set-Cookie` header of `text`.
cookie_header_of : Str -> Http.Header
cookie_header_of = |text| { name: "set-cookie".to_utf8(), value: text.to_utf8() }

## The sign-in page again for `viewer`, going on to `next`, offering GitHub
## as `github` says, with `status`, saying `words`.
sign_in_page_again : {
	viewer : SignedIn.Actor,
	github : SignInPage.GitHubOffer,
	next : Html.SitePath,
},
{ status : U16, words : Str } -> Http.Response
sign_in_page_again = |{ viewer, github, next }, { status, words }| {
	problem = CodeProblem(words)
	HttpAnswer.page(status, SignInPage.login({ viewer, next, problem, github }))
}

## The 403 for a device code page asked for by an API key, or an agent.
session_only_answer : Http.Response
session_only_answer = HttpAnswer.page(
	403,
	PageKit.notice({
		title: "Refused",
		text: "Only a human signed in on this device makes a device code.",
	}),
)

## The 500 for a human whose files hold nothing a session is signed over.
material_missing_answer : Http.Response
material_missing_answer = HttpAnswer.page(
	500,
	PageKit.notice({ title: "Failed", text: "This account has nothing to sign a session over." }),
)

## What a stand-in for a record is compared with: no code's HMAC.
no_record_mac : List(U8)
no_record_mac = List.repeat(0, 32)

## The one refusal of every well-formed code that doesn't sign in.
no_match_words : Str
no_match_words = "That code didn't work. Check it and try again; a code lasts five minutes."

## The refusal of an entry that is no code's shape, which counts no guess.
malformed_words : Str
malformed_words = "A code is 8 digits, like 1234 5678."

## What the locked form says.
locked_words : Str
locked_words = "Too many codes have been tried. Wait 15 minutes, then try again, or sign in another way."
