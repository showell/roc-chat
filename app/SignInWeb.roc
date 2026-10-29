## **SIGN-IN ON THE WIRE**: the bytes the sign-in routes (main.roc) send and
## read back, and nothing they decide. Every verdict is the auth core's
## (GitHubSignIn, OAuthState, Session); this is how its facts travel:
## - **the signed tokens**: GitHub's `state` and the pending sign-up's
##   cookie, each `<body>.<hex MAC>`, the MAC the host's (`sign!`) over the
##   body behind a purpose line, so a state is never taken for a pending
##   sign-up, nor one for the other;
## - **the cookies**: their one policy (`__Host-`, Secure, HttpOnly,
##   SameSite=Lax, Path=/), and reading one back from the `cookie` header;
## - **the query and the form**: GitHub's `code` and `state` as written, and
##   a form field decoded;
## - **the settings' record** (the generation counter) and the barred ids,
##   which the core's Settings hold and no codec of the core stores.
## Pure.
import Bytes
import Cast
import GitHubSignIn
import OAuthState
import Principal
import Stored

SignInWeb := [].{

	## What a signed token is for, written before its body in what is
	## signed.
	Purpose : [State, Pending]

	## **WHAT THE HOST SIGNS**: the purpose's line, then the body.
	signed_message : SignInWeb.Purpose, List(U8) -> List(U8)
	signed_message = |purpose, body| {
		line =
			match purpose {
				State => "roc-chat oauth state\n"
				Pending => "roc-chat pending sign-up\n"
			}
		List.concat(Str.to_utf8(line), body)
	}

	## A token: the body, a `.`, the MAC in hex.
	token : List(U8), List(U8) -> List(U8)
	token = |body, mac| List.join([body, ['.'], hex(mac)])

	## A token's body and MAC, split at its last `.`.
	untoken : List(U8) -> Try({ body : List(U8), mac : List(U8) }, [Malformed])
	untoken = |text|
		match List.split_last(text, '.') {
			Err(_) => Err(Malformed)
			Ok({ before, after }) =>
				match unhex(after) {
					Ok(mac) => Ok({ body: before, mac })
					Err(NotHex) => Err(Malformed)
				}
		}

	## A state's body: its nonce in hex, `.`, the time it was issued.
	state_body : OAuthState.Fields -> List(U8)
	state_body = |s| List.join([hex(s.nonce), ['.'], Str.to_utf8(s.issued_at.to_str())])

	## The fields a state's body holds.
	state_fields : List(U8) -> Try(OAuthState.Fields, [Malformed])
	state_fields = |body|
		match List.split_on(body, '.') {
			[nonce_hex, issued] =>
				match (unhex(nonce_hex), Stored.time(issued, "issued")) {
					(Ok(nonce), Ok(issued_at)) => Ok({ nonce, issued_at })
					_ => Err(Malformed)
				}
			_ => Err(Malformed)
		}

	## A pending sign-up's body: the nonce and the login in hex, the GitHub
	## id and the time it was issued, `.` between.
	pending_body : GitHubSignIn.PendingFields -> List(U8)
	pending_body = |p|
		List.join(
			List.intersperse(
				[hex(p.nonce), Str.to_utf8(p.github.to_str()), hex(p.login), Str.to_utf8(p.issued_at.to_str())],
				['.'],
			),
		)

	## The fields a pending sign-up's body holds.
	pending_fields : List(U8) -> Try(GitHubSignIn.PendingFields, [Malformed])
	pending_fields = |body|
		match List.split_on(body, '.') {
			[nonce_hex, github_text, login_hex, issued] =>
				match (unhex(nonce_hex), Stored.count(github_text, "github"), unhex(login_hex), Stored.time(issued, "issued")) {
					(Ok(nonce), Ok(github), Ok(login), Ok(issued_at)) => Ok({ nonce, github, login, issued_at })
					_ => Err(Malformed)
				}
			_ => Err(Malformed)
		}

	## **THE COOKIES' ONE POLICY**: the cookie `name` (behind `__Host-`)
	## holding `value` for `max_age` seconds; 0 ends it.
	set_cookie : Str, List(U8), I64 -> List(U8)
	set_cookie = |name, value, max_age|
		List.join([
			Str.to_utf8("__Host-${name}="),
			value,
			Str.to_utf8("; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${max_age.to_str()}"),
		])

	## The cookie `name` (behind `__Host-`) as the `cookie` headers sent it,
	## the first of that name.
	cookie : List(List(U8)), Str -> [Sent(List(U8)), Unsent]
	cookie = |headers, name| {
		wanted = Str.to_utf8("__Host-${name}")
		pairs = List.join_map(headers, |h| List.split_on(h, ';'))
		found = List.find_first(
			List.map(pairs, |p| Bytes.trim(p, [' '])),
			|p| List.starts_with(p, List.append(wanted, '=')),
		)
		match found {
			Ok(p) => Sent(List.drop_first(p, List.len(wanted) + 1))
			Err(_) => Unsent
		}
	}

	## The state cookie's nonce, as OAuthState checks it: a value that is
	## not hex is no nonce of ours.
	state_cookie : [Sent(List(U8)), Unsent] -> OAuthState.Cookie
	state_cookie = |sent|
		match sent {
			Unsent => Unsent
			Sent(value) =>
				match unhex(value) {
					Ok(nonce) => Sent(nonce)
					Err(NotHex) => Unsent
				}
		}

	## Form field `name` of an `application/x-www-form-urlencoded` body,
	## decoded (`+` a space, `%XX` a byte): the first of that name.
	form_field : List(U8), Str -> Try(List(U8), [Missing, Malformed])
	form_field = |body, name| {
		wanted = List.append(Str.to_utf8(name), '=')
		match List.find_first(List.split_on(body, '&'), |f| List.starts_with(f, wanted)) {
			Err(_) => Err(Missing)
			Ok(field) => percent_decode(List.drop_first(field, List.len(wanted)))
		}
	}

	## Bytes for a URL's query value: unreserved bytes as they are, every
	## other as `%XX`.
	url_encode : List(U8) -> List(U8)
	url_encode = |bytes|
		List.join_map(
			bytes,
			|b|
				if (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '-' or b == '_' or b == '.' or b == '~' {
					[b]
				} else {
					['%', upper_hex_digit(b // 16), upper_hex_digit(b % 16)]
				},
		)

	## Bytes as lower-case hex.
	hex : List(U8) -> List(U8)
	hex = |bytes| List.join_map(bytes, |b| [hex_digit(b // 16), hex_digit(b % 16)])

	## Lower-case hex as bytes.
	unhex : List(U8) -> Try(List(U8), [NotHex])
	unhex = |text|
		if List.len(text) % 2 != 0 {
			Err(NotHex)
		} else {
			match List.map_try(text, nibble) {
				Err(_) => Err(NotHex)
				Ok(ns) =>
					Ok(
						List.map(
							List.chunks_of(ns, 2),
							|pair|
								match pair {
									[high, low] => high * 16 + low
									_ => 0
								},
						),
					)
			}
		}

	## A U64 of eight bytes, the first the highest: a session's public
	## number from the host's entropy. (Only the first eight are taken.)
	u64_of : List(U8) -> U64
	u64_of = |bytes| List.fold(List.take_first(bytes, 8), 0, |n, b| n * 256 + b.to_u64())

	## **THE SETTINGS' RECORD**: the generation the next account is given.
	##
	##     settings v1 next=3
	settings_line : Principal.Generation -> List(U8)
	settings_line = |next| Stored.line("settings", [("next", next.to_u64().to_str())])

	## The next generation the settings' record holds.
	settings_next : List(U8) -> Try(Principal.Generation, Stored.Problem)
	settings_next = |raw| {
		fields = Stored.Reader.open(raw, "settings")?
		next_field = fields.field("next")?
		next = Stored.id(next_field.value, { name: "next", make: Principal.Generation.from_u64 })?
		next_field.rest.close()?
		Ok(next)
	}

	## **THE BARRED IDS**, one line each:
	##
	##     barred v1 github=583231
	barred_line : Principal.GitHubId -> List(U8)
	barred_line = |id| Stored.line("barred", [("github", id.to_u64().to_str())])

	## The barred ids a store of their lines holds.
	barred : List(U8) -> Try(List(Principal.GitHubId), Stored.Problem)
	barred = |raw|
		List.map_try(
			List.drop_last(List.split_on(raw, '\n'), 1),
			|line| {
				fields = Stored.Reader.open(List.append(line, '\n'), "barred")?
				github_field = fields.field("github")?
				github = Stored.id(github_field.value, { name: "github", make: Principal.GitHubId.from_u64 })?
				github_field.rest.close()?
				Ok(github)
			},
		)
}

hex_digit : U8 -> U8
hex_digit = |n| if n < 10 '0' + n else 'a' + n - 10

upper_hex_digit : U8 -> U8
upper_hex_digit = |n| if n < 10 '0' + n else 'A' + n - 10

nibble : U8 -> Try(U8, [NotHex])
nibble = |c|
	if c >= '0' and c <= '9' {
		Ok(c - '0')
	} else if c >= 'a' and c <= 'f' {
		Ok(c - 'a' + 10)
	} else if c >= 'A' and c <= 'F' {
		Ok(c - 'A' + 10)
	} else {
		Err(NotHex)
	}

percent_decode : List(U8) -> Try(List(U8), [Missing, Malformed])
percent_decode = |bytes|
	match bytes {
		[] => Ok([])
		['+', .. as rest] => percent_decode(rest).map_ok(|r| List.prepend(r, ' '))
		['%', high, low, .. as rest] =>
			match (nibble(high), nibble(low)) {
				(Ok(h), Ok(l)) => percent_decode(rest).map_ok(|r| List.prepend(r, h * 16 + l))
				_ => Err(Malformed)
			}
		['%', ..] => Err(Malformed)
		[b, .. as rest] => percent_decode(rest).map_ok(|r| List.prepend(r, b))
	}

# ── tests

nonce : List(U8)
nonce = [0, 1, 2, 254, 255, 16, 32, 64, 128, 9, 10, 11, 12, 13, 14, 15]

expect SignInWeb.hex([0, 15, 16, 255]) == Str.to_utf8("000f10ff")
expect SignInWeb.unhex(Str.to_utf8("000f10ff")) == Ok([0, 15, 16, 255])
expect SignInWeb.unhex(SignInWeb.hex(nonce)) == Ok(nonce)
expect SignInWeb.unhex(Str.to_utf8("0g")) == Err(NotHex)
expect SignInWeb.unhex(Str.to_utf8("abc")) == Err(NotHex)

# A state's body round-trips; one with a part missing, or more, is malformed.
expect SignInWeb.state_fields(SignInWeb.state_body({ nonce, issued_at: 1761600000 })) == Ok({ nonce, issued_at: 1761600000 })
expect SignInWeb.state_fields(Str.to_utf8("00ff")) == Err(Malformed)
expect SignInWeb.state_fields(Str.to_utf8("00ff.1.2")) == Err(Malformed)
expect SignInWeb.state_fields(Str.to_utf8("00ff.-1")) == Err(Malformed)

# A pending sign-up's body round-trips, its login whatever its bytes.
pending : GitHubSignIn.PendingFields
pending = { nonce, github: 583231, login: Str.to_utf8("octo.cat"), issued_at: 1761600000 }

expect SignInWeb.pending_fields(SignInWeb.pending_body(pending)) == Ok(pending)
expect SignInWeb.pending_fields(SignInWeb.state_body({ nonce, issued_at: 1 })) == Err(Malformed)

# A token splits at its last `.`, the MAC from hex.
expect SignInWeb.untoken(SignInWeb.token(Str.to_utf8("ab.12"), [1, 2, 255])) == Ok({ body: Str.to_utf8("ab.12"), mac: [1, 2, 255] })
expect SignInWeb.untoken(Str.to_utf8("no-dot")) == Err(Malformed)
expect SignInWeb.untoken(Str.to_utf8("ab.zz")) == Err(Malformed)

# The purposes sign different bytes for one body.
expect SignInWeb.signed_message(State, Str.to_utf8("x")) != SignInWeb.signed_message(Pending, Str.to_utf8("x"))

# The cookie, among others, with or without spaces; another name is not it.
expect SignInWeb.cookie([Str.to_utf8("a=1; __Host-state=00ff; b=2")], "state") == Sent(Str.to_utf8("00ff"))
expect SignInWeb.cookie([Str.to_utf8("a=1"), Str.to_utf8("__Host-state=7")], "state") == Sent(Str.to_utf8("7"))
expect SignInWeb.cookie([Str.to_utf8("state=00ff; __Host-statex=1")], "state") == Unsent
expect SignInWeb.cookie([], "state") == Unsent
expect SignInWeb.state_cookie(Sent(Str.to_utf8("zz"))) == Unsent

expect SignInWeb.set_cookie("session", Str.to_utf8("ab"), 60) == Str.to_utf8("__Host-session=ab; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=60")

# A form field, decoded; a bad escape is malformed.
expect SignInWeb.form_field(Str.to_utf8("x=1&name=Ann+B%C3%A9"), "name") == Ok(Str.to_utf8("Ann Bé"))
expect SignInWeb.form_field(Str.to_utf8("x=1"), "name") == Err(Missing)
expect SignInWeb.form_field(Str.to_utf8("name=%G1"), "name") == Err(Malformed)
expect SignInWeb.form_field(Str.to_utf8("name=%4"), "name") == Err(Malformed)

expect SignInWeb.url_encode(Str.to_utf8("https://chat.example/login/github")) == Str.to_utf8("https%3A%2F%2Fchat.example%2Flogin%2Fgithub")

expect SignInWeb.u64_of([0, 0, 0, 0, 0, 0, 1, 2]) == 258

# The settings' record and the barred ids, round trips and refusals.
expect SignInWeb.settings_next(SignInWeb.settings_line(Cast.gen(3))) == Ok(Cast.gen(3))
expect SignInWeb.settings_next(Str.to_utf8("settings v1 next=0\n")) == Err(BadValue("next"))

barred_ids : List(Principal.GitHubId)
barred_ids = [Cast.gid(7), Cast.gid(583231)]

expect SignInWeb.barred(List.join_map(barred_ids, SignInWeb.barred_line)) == Ok(barred_ids)
expect SignInWeb.barred([]) == Ok([])
expect SignInWeb.barred(Str.to_utf8("barred v1 github=x\n")) == Err(BadNumber("github"))
