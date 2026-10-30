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
##   a form field decoded.
## What is stored (the settings' record, the barred ids) is Store.roc's.
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
		line.to_utf8().concat(body)
	}

	## A token: the body, a `.`, the MAC in hex.
	token : List(U8), List(U8) -> List(U8)
	token = |body, mac| [
		body,
		['.'],
		hex(mac),
	].join()

	## A token's body and MAC, split at its last `.`.
	untoken : List(U8) -> Try({ body : List(U8), mac : List(U8) }, [Malformed])
	untoken = |text|
		match text.split_last('.') {
			Err(_) => Err(Malformed)
			Ok({ before, after }) =>
				match unhex(after) {
					Ok(mac) => Ok({ body: before, mac })
					Err(NotHex) => Err(Malformed)
				}
		}

	## A state's body: its nonce in hex, `.`, the time it was issued.
	state_body : OAuthState.Fields -> List(U8)
	state_body = |s| [
		hex(s.nonce),
		['.'],
		s.issued_at.to_str().to_utf8(),
	].join()

	## The fields a state's body holds.
	state_fields : List(U8) -> Try(OAuthState.Fields, [Malformed])
	state_fields = |body|
		match body.split_on('.') {
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
		[
			hex(p.nonce),
			p.github.to_str().to_utf8(),
			hex(p.login),
			p.issued_at.to_str().to_utf8(),
		].intersperse(['.']).join()

	## The fields a pending sign-up's body holds.
	pending_fields : List(U8) -> Try(GitHubSignIn.PendingFields, [Malformed])
	pending_fields = |body|
		match body.split_on('.') {
			[
				nonce_hex,
				github_text,
				login_hex,
				issued,
			] =>
				match (
					unhex(nonce_hex),
					Stored.count(github_text, "github"),
					unhex(login_hex),
					Stored.time(issued, "issued"),
				) {
					(
						Ok(nonce),
						Ok(github),
						Ok(login),
						Ok(issued_at),
					) => Ok({
						nonce,
						github,
						login,
						issued_at,
					})
					_ => Err(Malformed)
				}
			_ => Err(Malformed)
		}

	## **THE COOKIES' ONE POLICY**: the cookie `name` (behind `__Host-`)
	## holding `value` for `max_age` seconds; 0 ends it.
	set_cookie : {
		name : Str,
		contents : List(U8),
		max_age : I64,
	} -> List(U8)
	set_cookie = |
		{
			name,
			contents,
			max_age,
		},
	|
		[
			"__Host-${name}=".to_utf8(),
			contents,
			"; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${max_age.to_str()}".to_utf8(),
		].join()

	## The cookie `name` (behind `__Host-`) as the `cookie` headers sent it,
	## the first of that name.
	cookie : List(List(U8)), Str -> [Sent(List(U8)), Unsent]
	cookie = |headers, name| {
		wanted = "__Host-${name}".to_utf8()
		pairs = headers.join_map(|h| h.split_on(';'))
		found = List.find_first(
			List.map(pairs, |p| Bytes.trim(p, [' '])),
			|p| List.starts_with(p, List.append(wanted, '=')),
		)
		match found {
			Ok(p) => Sent(p.drop_first(wanted.len() + 1))
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
		wanted = name.to_utf8().append('=')
		match body.split_on('&').find_first(|f| f.starts_with(wanted)) {
			Err(_) => Err(Missing)
			Ok(field) => percent_decode(field.drop_first(wanted.len()))
		}
	}

	## Bytes for a URL's query value: unreserved bytes as they are, every
	## other as `%XX`.
	url_encode : List(U8) -> List(U8)
	url_encode = |bytes|
		bytes.join_map(
			|b|
				if (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '-' or b == '_' or b == '.' or b == '~' {
					[b]
				} else {
					[
						'%',
						upper_hex_digit(b // 16),
						upper_hex_digit(b % 16),
					]
				},
		)

	## Bytes as lower-case hex.
	hex : List(U8) -> List(U8)
	hex = |bytes| bytes.join_map(|b| [hex_digit(b // 16), hex_digit(b % 16)])

	## Lower-case hex as bytes.
	unhex : List(U8) -> Try(List(U8), [NotHex])
	unhex = |text|
		if text.len() % 2 != 0 {
			Err(NotHex)
		} else {
			match text.map_try(nibble) {
				Err(_) => Err(NotHex)
				Ok(ns) =>
					Ok(
						ns.chunks_of(2).map(
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
	u64_of = |bytes| bytes.take_first(8).fold(0, |n, b| n * 256 + b.to_u64())

}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

upper_hex_digit : U8 -> U8
upper_hex_digit = |n| if (n < 10) '0' + n else 'A' + n - 10

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
		['+', .. as rest] => percent_decode(rest).map_ok(|r| r.prepend(' '))
		[
			'%',
			high,
			low,
			.. as rest,
		] =>
			match (nibble(high), nibble(low)) {
				(Ok(h), Ok(l)) => percent_decode(rest).map_ok(|r| r.prepend(h * 16 + l))
				_ => Err(Malformed)
			}
		['%', ..] => Err(Malformed)
		[b, .. as rest] => percent_decode(rest).map_ok(|r| r.prepend(b))
	}

# ── tests

nonce : List(U8)
nonce = [
	0,
	1,
	2,
	254,
	255,
	16,
	32,
	64,
	128,
	9,
	10,
	11,
	12,
	13,
	14,
	15,
]

expect SignInWeb.hex([
	0,
	15,
	16,
	255,
]) == "000f10ff".to_utf8()
expect SignInWeb.unhex("000f10ff".to_utf8()) == Ok([
	0,
	15,
	16,
	255,
])
expect SignInWeb.unhex(SignInWeb.hex(nonce)) == Ok(nonce)
expect SignInWeb.unhex("0g".to_utf8()) == Err(NotHex)
expect SignInWeb.unhex("abc".to_utf8()) == Err(NotHex)

# A state's body round-trips; one with a part missing, or more, is malformed.
expect SignInWeb.state_fields(
	SignInWeb.state_body({
		nonce,
		issued_at: 1761600000,
	}),
) == Ok({ nonce, issued_at: 1761600000 })
expect SignInWeb.state_fields("00ff".to_utf8()) == Err(Malformed)
expect SignInWeb.state_fields("00ff.1.2".to_utf8()) == Err(Malformed)
expect SignInWeb.state_fields("00ff.-1".to_utf8()) == Err(Malformed)

# A pending sign-up's body round-trips, its login whatever its bytes.
pending : GitHubSignIn.PendingFields
pending = {
	nonce,
	github: 583231,
	login: "octo.cat".to_utf8(),
	issued_at: 1761600000,
}

expect SignInWeb.pending_fields(SignInWeb.pending_body(pending)) == Ok(pending)
expect SignInWeb.pending_fields(SignInWeb.state_body({ nonce, issued_at: 1 })) == Err(Malformed)

# A token splits at its last `.`, the MAC from hex.
expect SignInWeb.untoken(
	SignInWeb.token(
		"ab.12".to_utf8(),
		[
			1,
			2,
			255,
		],
	),
) == Ok({
	body: "ab.12".to_utf8(),
	mac: [
		1,
		2,
		255,
	],
})
expect SignInWeb.untoken("no-dot".to_utf8()) == Err(Malformed)
expect SignInWeb.untoken("ab.zz".to_utf8()) == Err(Malformed)

# The purposes sign different bytes for one body.
expect SignInWeb.signed_message(State, "x".to_utf8()) != SignInWeb.signed_message(
	Pending,
	"x".to_utf8(),
)

# The cookie, among others, with or without spaces; another name is not it.
expect SignInWeb.cookie(
	["a=1; __Host-state=00ff; b=2".to_utf8()],
	"state",
) == Sent("00ff".to_utf8())
expect SignInWeb.cookie(
	["a=1".to_utf8(), "__Host-state=7".to_utf8()],
	"state",
) == Sent("7".to_utf8())
expect SignInWeb.cookie(["state=00ff; __Host-statex=1".to_utf8()], "state") == Unsent
expect SignInWeb.cookie([], "state") == Unsent
expect SignInWeb.state_cookie(Sent("zz".to_utf8())) == Unsent

expect SignInWeb.set_cookie({
	name: "session",
	contents: "ab".to_utf8(),
	max_age: 60,
}) == "__Host-session=ab; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=60".to_utf8()

# A form field, decoded; a bad escape is malformed.
expect SignInWeb.form_field(
	"x=1&name=Ann+B%C3%A9".to_utf8(),
	"name",
) == Ok("Ann Bé".to_utf8())
expect SignInWeb.form_field("x=1".to_utf8(), "name") == Err(Missing)
expect SignInWeb.form_field("name=%G1".to_utf8(), "name") == Err(Malformed)
expect SignInWeb.form_field("name=%4".to_utf8(), "name") == Err(Malformed)

expect SignInWeb.url_encode("https://chat.example/login/github".to_utf8()) == "https%3A%2F%2Fchat.example%2Flogin%2Fgithub".to_utf8()

expect SignInWeb.u64_of([
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	2,
]) == 258
