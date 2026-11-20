## This module answers for the sessions a human's devices hold, from the
## device code page (`DeviceCodeRoute`):
##
## - `POST /devices/sign-out-others`, for a human signed in by a session:
##   their session generation raised (`SignInFiles`), so every session of
##   theirs signed before admits no one, then this device's session signed
##   again, as it was started, and a 303 back to the page, the cookie that
##   shows a code forgotten. A live device code is cancelled first.
## - The page's list of their last sign-ins by code (`DeviceSignIns`): read,
##   and a file that is damaged or can't be read logged and taken as none;
##   and each redemption noted in it, a failure to note one logged, as the
##   sign-in it tells of has happened.
import pf.Host
import pf.Http
import DeviceCode
import DeviceCodeFiles
import DeviceCodePage
import DeviceSignIns
import FileFacts
import HttpAnswer
import PageKit
import RequestHeader
import SignInFiles
import SignInRoute
import SignedIn
import Timestamp
import UserId

DeviceSessionsRoute :: [].{

	## A POST of `/devices/sign-out-others` by `acting` at `now`: every other
	## device of theirs signed out, and a 303 to the page with this device's
	## session signed again.
	sign_out_other_devices! : { acting : SignedIn, now : Timestamp } => Http.Response
	sign_out_other_devices! = |{ acting, now }| {
		answer =
			match acting.human_in_session() {
				Err(_) => session_only_answer
				Ok(human) =>
					match sign_out_others!(human.id()) {
						Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
						Ok({}) => {
							origin = acting.session_origin()
							match SignInRoute.sign_session_again!({ human, origin, now }) {
								Ok(cookie) => {
									onward = HttpAnswer.with_header(
										HttpAnswer.see_other(DeviceCodePage.path),
										cookie,
									)
									forgotten = DeviceCode.clear_flash_cookie_text
									HttpAnswer.with_header(
										onward,
										{
											name: "set-cookie".to_utf8(),
											value: forgotten.to_utf8(),
										},
									)
								}
								Err(NoMaterial) => material_missing_answer
								Err(GenerationDamaged) => SignInRoute.fault_answer(Damaged)
								Err(FileSystem(fault)) => SignInRoute.fault_answer(fault)
							}
						}
					}
			}
		HttpAnswer.never_stored(answer)
	}

	## The human `id`'s last sign-ins by code, newest first; a file that is
	## damaged or can't be read is logged and taken as none.
	load_sign_ins! : UserId => List(DeviceSignIns.SignIn)
	load_sign_ins! = |id|
		match DeviceCodeFiles.read_sign_ins!(id) {
			Ok(sign_ins) => sign_ins
			Err(FileSystem(fault)) => {
				log_fault!({ id, fault, what: "sign-ins by code taken as none" })
				[]
			}
		}

	## A sign-in by code of the human `id` at `now`, from the device the
	## request's `headers` name, noted first among their last ones; a failure
	## to write it is logged.
	note_sign_in! : {
		id : UserId,
		headers : List(Http.Header),
		now : Timestamp,
	} => {}
	note_sign_in! = |{ id, headers, now }| {
		user_agent =
			match RequestHeader.header_value(headers, "user-agent") {
				Sent(value) => value
				Unsent | Repeated => []
			}
		sign_in = { at: now, device: DeviceSignIns.device_of_user_agent(user_agent) }
		sign_ins = DeviceSignIns.with_sign_in(DeviceSessionsRoute.load_sign_ins!(id), sign_in)
		match DeviceCodeFiles.replace_sign_ins!(id, sign_ins) {
			Ok({}) => {}
			Err(FileSystem(fault)) => log_fault!({ id, fault, what: "sign-in by code not noted" })
		}
	}
}

## The human `id`'s other devices signed out: their live code cancelled, so
## the page never shows a dead one as waiting, then their session
## generation advanced.
sign_out_others! : UserId => Try({}, [FileSystem(FileFacts.Fault)])
sign_out_others! = |id| {
	DeviceCodeFiles.revoke_live_device_code!(id)?
	SignInFiles.advance_session_generation!(id)
}

## The log's line for the human `id`'s sign-ins file and `fault`, saying
## `what` became of it.
log_fault! : {
	id : UserId,
	fault : FileFacts.Fault,
	what : Str,
} => {}
log_fault! = |{ id, fault, what }| {
	said = "device codes: user ${id.to_str()}'s ${what}: ${FileFacts.fault_words(fault)}"
	Host.write_line_to_server_log!(said.to_utf8())
}

## The 403 for the page's sessions asked for by an API key, or an agent.
session_only_answer : Http.Response
session_only_answer = HttpAnswer.page(
	403,
	PageKit.notice({
		title: "Refused",
		text: "Only a human signed in on this device signs their other devices out.",
	}),
)

## The 500 for a human whose files hold nothing a session is signed over.
material_missing_answer : Http.Response
material_missing_answer = HttpAnswer.page(
	500,
	PageKit.notice({ title: "Failed", text: "This account has nothing to sign a session over." }),
)
