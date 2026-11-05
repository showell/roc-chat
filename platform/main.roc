## This is roc-chat's platform. It gives the host five entries into the
## app, and gives the app the host's primitives as effects (Host.roc).
##
## - `roc_page` (the demo, host/demo.zig): a topic's name and its transcript
##   in, the page out.
## - `roc_start` (the server, host/http.zig, once, before it listens): the
##   app makes its first data if there is none, and says whether it can
##   serve.
## - `roc_admission` (the server): a request's head in (Http.roc), before
##   any body is read; out comes how much body to read, or the refusal to
##   write instead.
## - `roc_handle_http_request` (the server): a request in (Http.roc), the
##   response out. The host routes nothing: the app does.
## - `roc_password_verdict` (`roc-chat hash-password`): a line's bytes in,
##   and out whether they are a password the sign-in form takes, so the
##   rule has one home, the app's.
##
## Each hosted function's symbol is its name in Host.roc, without the `!`.
platform ""
	requires {
		check_request_head! : Http.RequestHead => Http.Admission,
		handle_http_request! : Http.Request => Http.Response,
		page : List(U8), List(U8) -> List(U8),
		password_verdict : List(U8) -> [Accepted, Refused],
		start! : {} => [Failed, Ready]
	}
	exposes [
		Host,
		Http,
	]
	packages {}
	provides {
		"roc_admission": admission_for_host!,
		"roc_handle_http_request": handle_for_host!,
		"roc_page": page_for_host,
		"roc_password_verdict": password_verdict_for_host,
		"roc_start": start_for_host!,
	}
	hosted {
		"append_utf8_bytes_to_file": Host.append_utf8_bytes_to_file!,
		"bcrypt_hash_of_password": Host.bcrypt_hash_of_password!,
		"create_file_with_binary_bytes_unless_it_exists": Host.create_file_with_binary_bytes_unless_it_exists!,
		"create_file_with_utf8_bytes_unless_it_exists": Host.create_file_with_utf8_bytes_unless_it_exists!,
		"current_utc_seconds_since_epoch": Host.current_utc_seconds_since_epoch!,
		"end_every_stream_of_holder": Host.end_every_stream_of_holder!,
		"fill_with_random_bytes": Host.fill_with_random_bytes!,
		"github_identity_for_code": Host.github_identity_for_code!,
		"github_sign_in_settings": Host.github_sign_in_settings!,
		"hmac_sha256_with_server_secret": Host.hmac_sha256_with_server_secret!,
		"hmac_sha256_with_server_secret_matches": Host.hmac_sha256_with_server_secret_matches!,
		"list_names_in_directory": Host.list_names_in_directory!,
		"make_directory_and_its_parents": Host.make_directory_and_its_parents!,
		"password_matches_bcrypt_hash": Host.password_matches_bcrypt_hash!,
		"publish_bytes_to_streams_on_key": Host.publish_bytes_to_streams_on_key!,
		"read_binary_bytes_from_file": Host.read_binary_bytes_from_file!,
		"read_utf8_bytes_from_file": Host.read_utf8_bytes_from_file!,
		"replace_file_with_utf8_bytes_atomically": Host.replace_file_with_utf8_bytes_atomically!,
		"sha256_of_bytes": Host.sha256_of_bytes!,
	}
	targets: {
		x64musl: {
			inputs: [app],
			output: Archive,
		},
	}

import Host
import Http

page_for_host : List(U8), List(U8) -> List(U8)
page_for_host = |topic, transcript| page(topic, transcript)

password_verdict_for_host : List(U8) -> [Accepted, Refused]
password_verdict_for_host = |bytes| password_verdict(bytes)

start_for_host! : {} => [Failed, Ready]
start_for_host! = |{}| start!({})

handle_for_host! : Http.Request => Http.Response
handle_for_host! = |request| handle_http_request!(request)

## The app's `Http.Admission`, laid flat for the host: `verdict` says which
## tag it was, and only that tag's fields are read. An admission's
## `refusal` is an empty answer, which the host never reads or writes, and
## a refusal's body limits are zero.
admission_for_host! : Http.RequestHead => {
	verdict : [Admit, Refuse],
	body_most : U64,
	body_grace_ms : U32,
	refusal : Http.Response,
}
admission_for_host! = |head|
	match check_request_head!(head) {
		Admit({ body_most, body_grace_ms }) => {
			verdict: Admit,
			body_most,
			body_grace_ms,
			refusal: {
				status: 0,
				headers: [],
				body: [],
				kind: Whole,
				stream_key: [],
				stream_holder: [],
			},
		}
		Refuse(refusal) => {
			verdict: Refuse,
			body_most: 0,
			body_grace_ms: 0,
			refusal,
		}
	}
