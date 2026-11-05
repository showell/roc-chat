## A GitHub code is what GitHub sends a browser back with once its human
## agrees, good for one exchange at GitHub. It arrives in a URL, so it is
## held to what GitHub sends before the host carries it anywhere: 1 to 64
## bytes of letters, digits, `-` and `_`.
import Ascii

GitHubCode :: Str.{

	## The code `text` spells; unless it is anything else (`NotACode`).
	from_str : Str -> Try(GitHubCode, [NotACode])
	from_str = |text| {
		bytes = text.to_utf8()
		if bytes.is_empty() or bytes.len() > most_bytes or !bytes.all(is_code_byte) {
			Err(NotACode)
		} else {
			Ok(GitHubCode.(text))
		}
	}

	## The code's bytes, for the host to exchange at GitHub.
	bytes_to_exchange : GitHubCode -> List(U8)
	bytes_to_exchange = |GitHubCode.(text)| text.to_utf8()

	is_eq : _
}

most_bytes : U64
most_bytes = 64

is_code_byte : U8 -> Bool
is_code_byte = |byte|
	Ascii.is_letter(byte) or Ascii.is_digit(byte) or byte == '-' or byte == '_'

# ── tests
expect
	[
		"a",
		"0123456789abcdef0123",
		"user-id-7",
		"under_score",
		"x".repeat(64),
	].all(
		|text| GitHubCode.from_str(text).map_ok(GitHubCode.bytes_to_exchange) == Ok(text.to_utf8()),
	)
expect
	[
		"",
		"x".repeat(65),
		"a b",
		"a&b=c",
		"a\r\nb",
		"caf\u(E9)",
	].all(|text| GitHubCode.from_str(text) == Err(NotACode))
