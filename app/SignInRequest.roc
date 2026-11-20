## This module reads what a request to sign in asks for, as plain values, so
## a spec can test it (`SignInRequestSpec`); `SignInRoute` and `GitHubRoute`
## act on what it says. It answers where the browser goes once signed in
## (`next`, from the sign-in page's query or its form), whether the request
## may sign in at all (never by an API key), and whom a sign-in form's name
## and password claim to be, and the device code a code sign-in form holds.
import DeviceCode
import Html
import Password
import SignedIn
import UnvalidatedString
import UrlEncodedForm
import Users

SignInRequest :: [].{

	## Where to go once signed in when nothing says: Browse.
	default_next : Html.SitePath
	default_next =
		Html.SitePath.from_str("/chat") ?? crash "SignInRequest.default_next: /chat is a site path"

	## The `next` a sign-in page's `query` names: none, `default_next`; or `next=`
	## and a path on this site; else `BadNext`.
	next_from_query : List(U8) -> Try(Html.SitePath, [BadNext])
	next_from_query = |query|
		if query.is_empty() {
			Ok(SignInRequest.default_next)
		} else if query.starts_with(next_prefix) {
			unchecked =
				UnvalidatedString.from_utf8(query.drop_first(next_prefix.len())) ? |NotUtf8| BadNext
			unchecked.site_path().map_err(|NotASitePath| BadNext)
		} else {
			Err(BadNext)
		}

	## The `next` a sign-in form `body` holds: none, `default_next`; or a path
	## on this site; else `BadNext`.
	next_from_form : List(U8) -> Try(Html.SitePath, [BadNext])
	next_from_form = |body|
		match UrlEncodedForm.field({ body, name: "next" }) {
			Err(MissingField) => Ok(SignInRequest.default_next)
			Err(_) => Err(BadNext)
			Ok(unchecked) => unchecked.site_path().map_err(|NotASitePath| BadNext)
		}

	## `Ok` unless `viewer` holds an API key (`ByApiKey`), which never signs in.
	check_not_by_api_key : SignedIn.Actor -> Try({}, [ByApiKey])
	check_not_by_api_key = |viewer|
		match viewer {
			SignedIn(acting) =>
				match acting.credential() {
					ApiKey(_) => Err(ByApiKey)
					Session => Ok({})
				}
			Anonymous => Ok({})
		}

	## The password the sign-in form `body` holds, and whom its name names
	## among `users`: a human (`Human`), or no one a password signs in
	## (`NoHuman`: no such name, or an agent's), whose check takes as long;
	## unless `viewer` holds an API key (`ByApiKey`), or the form holds no
	## name or no password (`NoMatch`).
	password_claim : {
		viewer : SignedIn.Actor,
		users : Users,
		body : List(U8),
	} -> Try(
		{ password : Password, claimant : [Human(Users.Human), NoHuman] },
		[ByApiKey, NoMatch],
	)
	password_claim = |{ viewer, users, body }| {
		SignInRequest.check_not_by_api_key(viewer)?
		name_text = UrlEncodedForm.field({ body, name: "name" }) ? |_| NoMatch
		name = name_text.name() ? |_| NoMatch
		password_text = UrlEncodedForm.field({ body, name: "password" }) ? |_| NoMatch
		password = password_text.password() ? |NotAPassword| NoMatch
		claimant =
			match users.user_by_name(name) {
				Err(NoSuchUser) => NoHuman
				Ok(user) =>
					match user.as_human() {
						Err(Agent(_)) => NoHuman
						Ok(human) => Human(human)
					}
			}
		Ok({ password, claimant })
	}

	## The device code a code sign-in form `body` holds; unless it holds
	## none, or one that is not 8 characters of the code's alphabet once
	## spaces and dashes are left out (`NotACode`), which is no guess at a
	## code.
	device_code_from_form : List(U8) -> Try(DeviceCode.Code, [NotACode])
	device_code_from_form = |body|
		match UrlEncodedForm.field({ body, name: "code" }) {
			Ok(unchecked) => unchecked.device_code()
			Err(_) => Err(NotACode)
		}
}

next_prefix : List(U8)
next_prefix = "next=".to_utf8()
