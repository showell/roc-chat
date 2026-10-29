## **A GITHUB LOGIN** (the Roc chat's auth design, section 1): the name a
## GitHub account goes by, kept for display and for the link to its GitHub
## page. Never the key of an account: a login can be renamed, and a freed
## login taken by another account, so an account is its numeric GitHub id
## (Principal.GitHubId) and its login only says what GitHub last called it.
## The rule is what fits a stored line and a URL whole: 1 to 39 bytes (GitHub's
## own limit), each an ASCII letter, a digit or `-`. GitHub's finer rules (no
## `-` first, last or doubled) are left to GitHub, so an old login made
## before them is still taken. Opaque, so a login that passed is the only
## kind there is. Pure.
import Ascii

GitHubLogin :: Str.{

	## The login the bytes spell, as GitHub's `/user` gave them.
	from_utf8 : List(U8) -> Try(GitHubLogin, [NotALogin])
	from_utf8 = |bytes|
		if bytes == [] or List.len(bytes) > max_bytes or !List.all(bytes, is_login_byte) {
			Err(NotALogin)
		} else {
			match Str.from_utf8(bytes) {
				Ok(text) => Ok(GitHubLogin.(text))
				Err(_) => crash "GitHubLogin.from_utf8: ASCII is UTF-8"
			}
		}

	## The login `text` spells.
	from_str : Str -> Try(GitHubLogin, [NotALogin])
	from_str = |text| GitHubLogin.from_utf8(Str.to_utf8(text))

	## The login's text.
	to_str : GitHubLogin -> Str
	to_str = |GitHubLogin.(s)| s

	is_eq : _
}

## GitHub's longest login, in bytes.
max_bytes : U64
max_bytes = 39

is_login_byte : U8 -> Bool
is_login_byte = |c| Ascii.is_alphanumeric(c) or c == '-'

# ── tests

login : Str -> Try(Str, [NotALogin])
login = |text| GitHubLogin.from_str(text).map_ok(GitHubLogin.to_str)

expect login("octocat") == Ok("octocat")
expect login("showell") == Ok("showell")
expect login("a") == Ok("a")
expect login("Mona-Lisa-99") == Ok("Mona-Lisa-99")
expect login("-old--style-") == Ok("-old--style-")
expect login(Str.repeat("x", 39)) == Ok(Str.repeat("x", 39))
expect
	List.all(
		[
			"",
			Str.repeat("x", 40),
			"octo cat",
			"octo_cat",
			"octo.cat",
			"octo/cat",
			"octocat\n",
			"oct\u(F6)cat",
			"login=x",
		],
		|bad| login(bad) == Err(NotALogin),
	)
expect GitHubLogin.from_utf8([0x61, 0xff]).map_ok(GitHubLogin.to_str) == Err(NotALogin)
