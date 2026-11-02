## **TEXT FROM THE WIRE, NOT YET CHECKED**: whatever arrives from outside
## (a request, a file the host read) is an `UnvalidatedString` until a
## checking door says what it is. Opaque, with one way in, `from_utf8`, at
## main's door, and no way back to a `Str`: the only ways out are the
## checking doors below, each giving a checked type or a refusal's tags.
## So no `Name`, `Topic`, `ChannelName`, `UserId`, `UserPair`, `DateTime`
## or `Conversation` is ever built from outside text that skipped its
## check.
##
## **ONE OF THE TRUST BOUNDARIES**: this is the way in; `TrustedHtml` is
## the way out to a page, `SecureImageTag` rules which images a message
## may show, and `SignedIn` is who is acting. A security reader starts at
## any of the four.
import ChannelName
import Conversation
import DateTime
import Name
import Topic
import Transcript
import UserId
import UserPair

UnvalidatedString :: Str.{

	## **THE WAY IN**: the host's `bytes`, unless they are not UTF-8.
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

	## The time it writes, checked by `DateTime.from_str`.
	date_time : UnvalidatedString -> Try(DateTime, [WrongShape, OutOfRange])
	date_time = |UnvalidatedString.(text)| DateTime.from_str(text)

	## **A URL'S PATH, IN PARTS, STILL UNCHECKED**: the parts between its
	## `/`s (`/chat/dm/1_1` is `chat`, `dm` and `1_1`), each as unchecked
	## as the whole; unless it does not start with `/` (`NotAPath`). Nothing
	## is percent-decoded: every part a route takes is a strict name, which
	## holds no `%`.
	url_path_parts : UnvalidatedString -> Try(List(UnvalidatedString), [NotAPath])
	url_path_parts = |UnvalidatedString.(text)|
		if (text.starts_with("/"))
			Ok(text.drop_prefix("/").split_on("/").map(|part| UnvalidatedString.(part)))
		else
			Err(NotAPath)

	## **IS IT EXACTLY `word`**, a fixed word the code wrote (a URL's
	## `chat`)? Byte for byte, case and all.
	is_exactly : UnvalidatedString, Str -> Bool
	is_exactly = |UnvalidatedString.(text), word| text == word

	## **A MESSAGE'S MARKDOWN, AS A FORM SENT IT**: the text, each CRLF
	## made LF (a browser's form sends every newline as CRLF, and a
	## transcript's lines end in LF); unless it holds nothing but spaces,
	## tabs and newlines (`Blank`). Otherwise exactly as written.
	markdown : UnvalidatedString -> Try(Str, [Blank])
	markdown = |UnvalidatedString.(text)| {
		lf = Str.join_with(text.split_on("\r\n"), "\n")
		if (lf.to_utf8().all(|b| b == ' ' or b == '\t' or b == '\n' or b == '\r')) Err(Blank) else Ok(lf)
	}

	## The conversation under `named`, as the transcript it is, checked by
	## `Transcript.read`, its refusals as that reader names them.
	conversation : UnvalidatedString, Topic -> Try(Conversation, _)
	conversation = |UnvalidatedString.(text), named| Transcript.read(named, text)
}

# ── tests
## The text `bytes` hold, from the wire, which a test's always are.
wire : List(U8) -> UnvalidatedString
wire = |bytes| UnvalidatedString.from_utf8(bytes) ?? crash "UnvalidatedString's tests: a test's bytes are UTF-8"

# Only UTF-8 comes in: a stray byte, and a character cut short, refused.
## Whether `bytes` come in, or why not.
comes_in : List(U8) -> Try({}, [NotUtf8])
comes_in = |bytes| UnvalidatedString.from_utf8(bytes).map_ok(|_| {})

expect [
	[0xFF],
	[0xC3],
	"Zoë".to_utf8(),
	[],
].map(comes_in) == [
	Err(NotUtf8),
	Err(NotUtf8),
	Ok({}),
	Ok({}),
]
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
expect wire("2026-11-02T19:11:32Z".to_utf8()).date_time().map_ok(DateTime.to_str) == Ok("2026-11-02T19:11:32Z")
expect wire("2026-11-02".to_utf8()).date_time() == Err(WrongShape)
# A URL's path in parts, and a fixed word matched exactly, both sides.
## The parts of `path`, each as a test reads it, `chat` if it is exactly
## that, else `other`, between spaces.
chat_parts : Str -> Try(Str, [NotAPath])
chat_parts = |path| wire(path.to_utf8()).url_path_parts().map_ok(|parts| Str.join_with(parts.map(|p| if (p.is_exactly("chat")) "chat" else "other"), " "))

expect
	[
		"/chat/dm/1_1",
		"/",
		"/chat/",
		"chat/x",
		"",
		"/Chat",
	].map(chat_parts)
		== [
			Ok("chat other other"),
			Ok("other"),
			Ok("chat other"),
			Err(NotAPath),
			Err(NotAPath),
			Ok("other"),
		]
expect wire("/a/plans".to_utf8()).url_path_parts().map_ok(|parts| parts.map(|p| p.topic().map_ok(Topic.to_str))) == Ok([Ok("a"), Ok("plans")])
# Markdown: CRLF to LF, a lone CR and LF kept, blank refused.
expect
	[
		"a\r\nb\r\n",
		"a\nb",
		"a\rb",
		"  x  ",
		"",
		" \r\n\t\n",
		"\n",
	].map(|text| wire(text.to_utf8()).markdown())
		== [
			Ok("a\nb\n"),
			Ok("a\nb"),
			Ok("a\rb"),
			Ok("  x  "),
			Err(Blank),
			Err(Blank),
			Err(Blank),
		]
expect {
	plans = Topic.from_str("plans") ?? crash "UnvalidatedString's tests: a topic"
	[wire([]).conversation(plans), wire("\n".to_utf8()).conversation(plans)]
		== [Ok(Conversation.empty(plans)), Err(BadEnds)]
}
