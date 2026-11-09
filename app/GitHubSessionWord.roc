## The random word in a human's `github-session-secret` file: 32 random bytes
## from the host, written as 64 lowercase hex digits. A session of a human
## tied to GitHub is signed over it (`Session.Material`), so rewriting the file
## ends their sessions. It is made only from the host's random bytes
## (`of_random_bytes`), or read from its file (`from_file`), which takes only
## that spelling, or an empty file, which holds no word.
import FactFile
import Hex

GitHubSessionWord :: List(U8).{

	## How many random bytes a word is made of.
	random_byte_count : U64
	random_byte_count = 32

	## The word the host's random `bytes` make. Any other count of bytes is
	## the caller's bug, and crashes.
	of_random_bytes : List(U8) -> GitHubSessionWord
	of_random_bytes = |bytes|
		if bytes.len() == GitHubSessionWord.random_byte_count {
			GitHubSessionWord.(Hex.to_hex(bytes).to_utf8())
		} else {
			crash "GitHubSessionWord.of_random_bytes: a word is made of ${GitHubSessionWord.random_byte_count.to_str()} bytes, not ${bytes.len().to_str()}"
		}

	## The word a `github-session-secret` file's `bytes` hold, with the spaces,
	## tabs and line ends at either end taken off (`FactFile`), or `Empty`;
	## unless they hold anything but 64 lowercase hex digits (`NotAWord`).
	from_file : List(U8) -> Try([Empty, Word(GitHubSessionWord)], [NotAWord])
	from_file = |bytes| {
		digits = FactFile.word_from_file(bytes)
		if digits.is_empty() {
			Ok(Empty)
		} else {
			text = Str.from_utf8(digits) ? |_| NotAWord
			match Hex.from_hex(text) {
				Ok(decoded) if decoded.len() == GitHubSessionWord.random_byte_count =>
					Ok(Word(GitHubSessionWord.(digits)))
				Ok(_) => Err(NotAWord)
				Err(NotHex) => Err(NotAWord)
			}
		}
	}

	## The word's digits: what its file keeps, and what a session is signed
	## over.
	bytes : GitHubSessionWord -> List(U8)
	bytes = |GitHubSessionWord.(digits)| digits

	is_eq : _
}

# ── tests
expect GitHubSessionWord.of_random_bytes(List.repeat(0xab, 32)).bytes() == "ab".repeat(32).to_utf8()
expect
	GitHubSessionWord.from_file("${"ab".repeat(32)}\n".to_utf8())
		== Ok(Word(GitHubSessionWord.of_random_bytes(List.repeat(0xab, 32))))
expect ["", " \n"].all(|text| GitHubSessionWord.from_file(text.to_utf8()) == Ok(Empty))
expect
	[
		"another word",
		"ab".repeat(31),
		"ab".repeat(33),
		"AB".repeat(32),
	].all(|text| GitHubSessionWord.from_file(text.to_utf8()) == Err(NotAWord))
expect GitHubSessionWord.from_file([0xff]) == Err(NotAWord)
