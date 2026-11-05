## A GitHub login is the name a GitHub account goes by, such as `octocat`.
## The chat says it back to someone refused, and keys nothing by it: GitHub
## lets an account rename its login and another take the freed one, so an
## account is found by its number (`GitHubId`). The rule is what GitHub's
## `/user` may answer and a page may show whole: 1 to 39 bytes, each an ASCII
## letter, a digit or `-`. GitHub's finer rules are GitHub's to keep.
import Ascii

GitHubLogin :: Str.{

	## The login the bytes spell, as the host read them from GitHub's answer.
	from_utf8 : List(U8) -> Try(GitHubLogin, [NotALogin])
	from_utf8 = |bytes|
		if bytes.is_empty() or bytes.len() > most_bytes or !bytes.all(is_login_byte) {
			Err(NotALogin)
		} else {
			match Str.from_utf8(bytes) {
				Ok(text) => Ok(GitHubLogin.(text))
				Err(_) => crash "GitHubLogin.from_utf8: ASCII is UTF-8"
			}
		}

	to_str : GitHubLogin -> Str
	to_str = |GitHubLogin.(text)| text

	is_eq : _
}

## GitHub's longest login, in bytes.
most_bytes : U64
most_bytes = 39

is_login_byte : U8 -> Bool
is_login_byte = |byte| Ascii.is_letter(byte) or Ascii.is_digit(byte) or byte == '-'

# ── tests
## What `text` reads as, as a test reads it.
login_of : Str -> Try(Str, [NotALogin])
login_of = |text| GitHubLogin.from_utf8(text.to_utf8()).map_ok(GitHubLogin.to_str)

expect
	[
		"octocat",
		"a",
		"Mona-Lisa-99",
		"-old--style-",
		"x".repeat(39),
	].all(|text| login_of(text) == Ok(text))
expect
	[
		"",
		"x".repeat(40),
		"octo cat",
		"octo_cat",
		"octo/cat",
		"octocat\n",
		"<b>",
		"oct\u(F6)cat",
	].all(|text| login_of(text) == Err(NotALogin))
expect GitHubLogin.from_utf8([0x61, 0xff]) == Err(NotALogin)
