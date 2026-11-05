## Text that arrives from outside, such as a request's path or a form's
## field, is an `UnvalidatedString` until a check says what it is. The type
## is opaque. Its one way in is `from_utf8`, and it has no way back to a
## `Str`: each way out runs a check and gives a checked type (a `Name`, a
## `Topic`, a `UserId` and so on) or the check's refusal. So no checked
## value is built from outside text that skipped its check. A transcript
## file's bytes have their own type, `Transcript.Utf8Transcript`, which only
## `Transcript.decode` opens.
##
## This module is one of the program's five trust boundaries, and the way
## text comes in. The others are `TrustedHtml`, the way markup goes out to a
## page; `SecureImageTag`, which images a message may show; `SignedIn`, who
## is acting; and `RequestOrigin`, which refuses a request from any origin
## but the server's own. A security reader can start at any of the five.
import Ascii
import AgentInvite
import AgentKey
import ChannelName
import DateTime
import GitHubCode
import GitHubState
import Html
import KeyScope
import Name
import Password
import SecretToken
import Topic
import UploadedImage
import UserId
import UserPair

UnvalidatedString :: Str.{

	## The text `bytes` hold, unless they are not UTF-8.
	from_utf8 : List(U8) -> Try(UnvalidatedString, [NotUtf8])
	from_utf8 = |bytes|
		match Str.from_utf8(bytes) {
			Ok(text) => Ok(UnvalidatedString.(text))
			Err(_) => Err(NotUtf8)
		}

	## The permanent name it spells, checked by `Name.from_str`.
	name : UnvalidatedString -> Try(Name, [Empty, TooLong, ForbiddenCharacter, BadSpacing])
	name = |UnvalidatedString.(text)| Name.from_str(text)

	## The topic it names, checked by `Topic.from_str`.
	topic : UnvalidatedString -> Try(Topic, [Empty, StartsWithNonLetter, TooLong, ForbiddenByte])
	topic = |UnvalidatedString.(text)| Topic.from_str(text)

	## The channel it names, as a URL carries it, checked by
	## `ChannelName.from_str`.
	channel_name : UnvalidatedString -> Try(
		ChannelName,
		[
			Empty,
			StartsWithNonLetter,
			TooLong,
			ForbiddenByte,
		],
	)
	channel_name = |UnvalidatedString.(text)| ChannelName.from_str(text)

	## The user's id it spells, as a URL carries it, checked by
	## `UserId.from_str`.
	user_id : UnvalidatedString -> Try(UserId, [NotAUserId])
	user_id = |UnvalidatedString.(text)| UserId.from_str(text)

	## The DM's pair it spells, as a URL and a folder's name carry it,
	## checked by `UserPair.from_str`.
	user_pair : UnvalidatedString -> Try(UserPair, [NotAUserPair])
	user_pair = |UnvalidatedString.(text)| UserPair.from_str(text)

	## The uploaded image it names, as a URL carries its name, checked by
	## `UploadedImage.from_name`.
	uploaded_image : UnvalidatedString -> Try(UploadedImage, [NotAnUploadName])
	uploaded_image = |UnvalidatedString.(text)| UploadedImage.from_name(text)

	## The number of an agent's key it spells, as a URL carries it, checked
	## by `AgentKey.Id.from_str`.
	key_id : UnvalidatedString -> Try(AgentKey.Id, [NotAKeyId])
	key_id = |UnvalidatedString.(text)| AgentKey.Id.from_str(text)

	## The number of an agent's invite it spells, as a URL carries it,
	## checked by `AgentInvite.Id.from_str`.
	invite_id : UnvalidatedString -> Try(AgentInvite.Id, [NotAnInviteId])
	invite_id = |UnvalidatedString.(text)| AgentInvite.Id.from_str(text)

	## The secret token it spells, as an invite's code is posted, checked by
	## `SecretToken.from_str`.
	secret_token : UnvalidatedString -> Try(SecretToken, [NotAToken])
	secret_token = |UnvalidatedString.(text)| SecretToken.from_str(text)

	## The secret token an `Authorization` header's value names as a
	## bearer, checked by `SecretToken.from_bearer`.
	bearer_token : UnvalidatedString -> Try(SecretToken, [NotABearer])
	bearer_token = |UnvalidatedString.(text)| SecretToken.from_bearer(text)

	## The reach of a key's scope it names, as a form's `read` or `post`
	## field holds it, checked by `KeyScope.reach_from_word`.
	reach : UnvalidatedString -> Try(KeyScope.Reach, [NotAReach])
	reach = |UnvalidatedString.(text)| KeyScope.reach_from_word(text)

	## The password it is, as the sign-in form sends it, checked by
	## `Password.from_str`.
	password : UnvalidatedString -> Try(Password, [NotAPassword])
	password = |UnvalidatedString.(text)| Password.from_str(text)

	## The path on this site it names, as a sign-in's `next` carries it,
	## checked by `Html.SitePath.from_str`.
	site_path : UnvalidatedString -> Try(Html.SitePath, [NotASitePath])
	site_path = |UnvalidatedString.(text)| Html.SitePath.from_str(text).map_err(|_| NotASitePath)

	## GitHub's code it holds, as GitHub's way back carries it, checked by
	## `GitHubCode.from_str`.
	github_code : UnvalidatedString -> Try(GitHubCode, [NotACode])
	github_code = |UnvalidatedString.(text)| GitHubCode.from_str(text)

	## The claim of the state it holds, as GitHub hands it back, read by
	## `GitHubState.Claim.from_str`.
	github_state_claim : UnvalidatedString -> Try(GitHubState.Claim, [NotAClaim])
	github_state_claim = |UnvalidatedString.(text)| GitHubState.Claim.from_str(text)

	## The time it writes, checked by `DateTime.from_str`.
	date_time : UnvalidatedString -> Try(DateTime, [WrongShape, OutOfRange])
	date_time = |UnvalidatedString.(text)| DateTime.from_str(text)

	## A URL's path, split at its `/`s (`/chat/dm/1_1` is `chat`, `dm` and
	## `1_1`), each part as unchecked as the whole; unless it does not start
	## with `/` (`NotAPath`). Nothing is percent-decoded, because every part
	## a route takes is a strict name, which holds no `%`.
	url_path_parts : UnvalidatedString -> Try(List(UnvalidatedString), [NotAPath])
	url_path_parts = |UnvalidatedString.(text)|
		if (text.starts_with("/"))
			Ok(text.drop_prefix("/").split_on("/").map(|part| UnvalidatedString.(part)))
		else
			Err(NotAPath)

	## Is it exactly `word`, a fixed word the code wrote (a URL's `chat`),
	## byte for byte and case and all?
	is_exactly : UnvalidatedString, Str -> Bool
	is_exactly = |UnvalidatedString.(text), word| text == word

	## A message's markdown, as a form sent it: the text with each CRLF made
	## LF, and otherwise exactly as written; unless it holds nothing but
	## ASCII spaces (`Ascii.is_space`: spaces, tabs, CRs and LFs), when it
	## is `Blank`. A browser's form sends every
	## newline as CRLF, and a transcript's lines end in LF.
	markdown : UnvalidatedString -> Try(Str, [Blank])
	markdown = |UnvalidatedString.(text)| {
		lf = Str.join_with(text.split_on("\r\n"), "\n")
		if (lf.to_utf8().all(Ascii.is_space)) Err(Blank) else Ok(lf)
	}
}

# ── tests
## The text `bytes` hold, from the wire, which a test's always are.
wire : List(U8) -> UnvalidatedString
wire = |bytes|
	UnvalidatedString.from_utf8(bytes)
		?? crash "UnvalidatedString's tests: a test's bytes are UTF-8"

# Only UTF-8 comes in: a stray byte, and a character cut short, refused.
## Whether `bytes` come in, or why not.
comes_in : List(U8) -> Try({}, [NotUtf8])
comes_in = |bytes| UnvalidatedString.from_utf8(bytes).map_ok(|_| {})

expect comes_in([0xFF]) == Err(NotUtf8)
expect comes_in([0xC3]) == Err(NotUtf8)
expect comes_in("Zoë".to_utf8()) == Ok({})
expect comes_in([]) == Ok({})
# Each way out checks, both sides.
expect wire("Zoë".to_utf8()).name().map_ok(Name.to_str) == Ok("Zoë")
expect wire("Zoë!".to_utf8()).name() == Err(ForbiddenCharacter)
expect wire("plans".to_utf8()).topic().map_ok(Topic.to_str) == Ok("plans")
expect wire("plans_2".to_utf8()).topic() == Err(ForbiddenByte)
expect wire("plans".to_utf8()).channel_name().map_ok(ChannelName.to_str) == Ok("plans")
expect wire("1_2".to_utf8()).channel_name() == Err(StartsWithNonLetter)
expect wire("255".to_utf8()).user_id().map_ok(UserId.to_str) == Ok("255")
expect wire("256".to_utf8()).user_id() == Err(NotAUserId)
expect wire("9_10".to_utf8()).user_pair().map_ok(UserPair.to_str) == Ok("9_10")
expect wire("10_9".to_utf8()).user_pair() == Err(NotAUserPair)
expect
	wire("2026-11-02T19:11:32Z".to_utf8()).date_time().map_ok(DateTime.to_str)
		== Ok("2026-11-02T19:11:32Z")
expect wire("2026-11-02".to_utf8()).date_time() == Err(WrongShape)
expect
	wire("${"0a".repeat(16)}.png".to_utf8()).uploaded_image().map_ok(UploadedImage.name)
		== Ok("${"0a".repeat(16)}.png")
expect wire("cat.png".to_utf8()).uploaded_image() == Err(NotAnUploadName)
expect
	wire("hunter2".to_utf8()).password().map_ok(Password.bytes_to_check) == Ok("hunter2".to_utf8())
expect wire("".to_utf8()).password().map_ok(|_| {}) == Err(NotAPassword)
expect wire("abc-1".to_utf8()).github_code().map_ok(|_| {}) == Ok({})
expect wire("a b".to_utf8()).github_code() == Err(NotACode)
expect wire("a.b.c.AAAA".to_utf8()).github_state_claim().map_ok(|_| {}) == Ok({})
expect wire("a.b".to_utf8()).github_state_claim().map_ok(|_| {}) == Err(NotAClaim)
expect
	wire("/chat/dm/1_1/plans".to_utf8()).site_path().map_ok(Html.SitePath.to_str)
		== Ok("/chat/dm/1_1/plans")
expect [
	"//evil.example",
	"https://evil.example",
	"/a/../b",
	"",
].all(|text| wire(text.to_utf8()).site_path() == Err(NotASitePath))
# A URL's path in parts, and a fixed word matched exactly, both sides.
## The parts of `path`, each as a test reads it, `chat` if it is exactly
## that, else `other`, between spaces.
chat_parts : Str -> Try(Str, [NotAPath])
chat_parts = |path| {
	parts = wire(path.to_utf8()).url_path_parts()?
	Ok(Str.join_with(parts.map(|p| if (p.is_exactly("chat")) "chat" else "other"), " "))
}

expect chat_parts("/chat/dm/1_1") == Ok("chat other other")
expect chat_parts("/") == Ok("other")
expect chat_parts("/chat/") == Ok("chat other")
expect chat_parts("chat/x") == Err(NotAPath)
expect chat_parts("") == Err(NotAPath)
expect chat_parts("/Chat") == Ok("other")
expect
	wire("/a/plans".to_utf8())
		.url_path_parts()
		.map_ok(|parts| parts.map(|p| p.topic().map_ok(Topic.to_str)))
		== Ok([
			Ok("a"),
			Ok("plans"),
		])
# Markdown: CRLF to LF, a lone CR and LF kept.
expect wire("a\r\nb\r\n".to_utf8()).markdown() == Ok("a\nb\n")
expect wire("a\nb".to_utf8()).markdown() == Ok("a\nb")
expect wire("a\rb".to_utf8()).markdown() == Ok("a\rb")
expect wire("  x  ".to_utf8()).markdown() == Ok("  x  ")
# Blank is nothing, or only spaces, tabs, CRs and LFs; any other space,
# such as a form feed or a no-break space, is text.
expect
	[
		"",
		" ",
		"\t",
		"\r",
		"\n",
		" \r\n\t\n",
	].all(|text| wire(text.to_utf8()).markdown() == Err(Blank))
expect wire("\u(c)".to_utf8()).markdown() == Ok("\u(c)")
expect wire("\u(a0)".to_utf8()).markdown() == Ok("\u(a0)")
