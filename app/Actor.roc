## This module finds who is acting on a request, from the request alone.
## A request with an `Authorization` header is judged by that header
## alone: the agent its key admits (`AgentsRoute.sign_in_by_key!`), or a
## 401, so a key refused never falls back to a session. Any other is the
## human its session cookie admits (`SignInRoute.sign_in_by_session!`), or
## no one (`SignedIn.Actor`'s `Anonymous`). It is the module to swap for
## another way of signing in.
import pf.Http
import AgentsRoute
import Clock
import Directory
import FileFacts
import HttpAnswer
import RequestHeader
import SignInRoute
import SignedIn
import Timestamp
import UnvalidatedString

Actor :: [].{

	## Who is acting. With `Authorization: Bearer <id>-<secret>`, the agent its
	## key admits (`AgentsRoute.sign_in_by_key!`); any other `Authorization` is
	## refused, and a request with one is never judged by its cookie, so a key
	## refused never falls back to a session. With none, the human the session
	## cookie admits (`load_session_actor!`), or no one.
	load_actor! : { headers : List(Http.Header), directory : Directory } => Try(
		SignedIn.Actor,
		[BadBearer, KeyRefused, FileSystem(FileFacts.Fault)],
	)
	load_actor! = |{ headers, directory }| {
		now = Clock.read_clock!({})
		match RequestHeader.header_value(headers, "authorization") {
			Unsent => load_session_actor!({ headers, directory, now })
			Repeated => Err(BadBearer)
			Sent(value) => {
				bearer_text = UnvalidatedString.from_utf8(value) ? |NotUtf8| BadBearer
				token = bearer_text.bearer_token() ? |NotABearer| BadBearer
				signed_in_by_key = AgentsRoute.sign_in_by_key!({ token, directory, now })?
				Ok(SignedIn(signed_in_by_key))
			}
		}
	}

	## A request whose credential is refused: one 401 that says no more, or a
	## 500 when the keys can't be read.
	identity_refusal : [BadBearer, KeyRefused, FileSystem(FileFacts.Fault)] -> Http.Response
	identity_refusal = |why|
		match why {
			BadBearer => HttpAnswer.text(401, key_refusal_words)
			KeyRefused => HttpAnswer.text(401, key_refusal_words)
			FileSystem(fault) => HttpAnswer.text(500, FileFacts.fault_words(fault))
		}
}

## Who a request with no `Authorization` header is: the human its session
## cookie admits at `now`, or no one (`Anonymous`) when it carries none, or
## one that admits no one. Only a sign-in file that can't be read fails the
## request.
load_session_actor! : {
	headers : List(Http.Header),
	directory : Directory,
	now : Timestamp,
} => Try(SignedIn.Actor, [FileSystem(FileFacts.Fault)])
load_session_actor! = |{ headers, directory, now }|
	match RequestHeader.header_value(headers, "cookie") {
		Unsent => Ok(Anonymous)
		Repeated => Ok(Anonymous)
		Sent(cookie) =>
			match SignInRoute.sign_in_by_session!({ cookie, users: directory.users(), now }) {
				Ok(signed_in_by_session) => Ok(SignedIn(signed_in_by_session))
				Err(NoSession) => Ok(Anonymous)
				Err(BadSession) => Ok(Anonymous)
				Err(SessionRefused) => Ok(Anonymous)
				Err(NoMaterial) => Ok(Anonymous)
				Err(FileSystem(fault)) => Err(FileSystem(fault))
			}
	}

key_refusal_words : Str
key_refusal_words =
	"The API key is not accepted: send Authorization: Bearer <id>-<secret>, a live key."

# ── tests
# A credential refused is one 401 in plain text, whatever was wrong with it.
expect
	[BadBearer, KeyRefused].all(
		|why| {
			answered = Actor.identity_refusal(why)
			answered.status == 401 and answered.body == "${key_refusal_words}\n".to_utf8()
		},
	)
