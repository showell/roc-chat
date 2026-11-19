## These are the tests of `LastConversation`: its file, and where `/` sends
## a human by it.
import ConversationKey
import Directory
import LastConversation
import Sample
import SignedIn
import UnvalidatedString

LastConversationSpec :: [].{}

## The sample's users, with the channel `general`, which holds Steve alone.
directory : Directory
directory = Sample.with_default_channel(Sample.directory)

## Where `/` sends the sample's user named `name`, whose file is `file`.
resumed_path : Str, [NoFile, File(List(U8))] -> Str
resumed_path = |name, file|
	LastConversation.way_in({
		file,
		acting: SignedIn.dangerously_assume(Sample.user(name)),
		directory,
	})

## Where `/` sends Steve, whose file holds `text`.
steves_way_in : Str -> Str
steves_way_in = |text| resumed_path("Steve", File(text.to_utf8()))

# The file is the conversation's page's path, bare.
expect {
	key = ConversationKey.from_url_path({
		path: UnvalidatedString.from_utf8("/chat/channel/general/roc-chat".to_utf8())
			?? crash "LastConversationSpec: a path is UTF-8",
		directory,
	}).map_ok(|found| found.key) ?? crash "LastConversationSpec: general is a place"
	LastConversation.of(key).to_file() == "/chat/channel/general/roc-chat".to_utf8()
}
# A conversation the human may read, in a DM or a channel, the file edited by
# hand or not: its page.
expect
	[
		("/chat/dm/1_1/plans", "/chat/dm/1_1/plans"),
		("/chat/dm/1_2/plans", "/chat/dm/1_2/plans"),
		("/chat/channel/general/roc-chat", "/chat/channel/general/roc-chat"),
		(" /chat/dm/1_1/plans\r\n", "/chat/dm/1_1/plans"),
	].all(|(text, path)| steves_way_in(text) == path)
# No file, a file that names no conversation's page, and a conversation the
# human may not read: Browse.
expect resumed_path("Steve", NoFile) == "/chat"
expect resumed_path("Steve", File([0xff])) == "/chat"
expect
	[
		"",
		"plans",
		"/chat/dm/1_1",
		"/chat/dm/1_1/plans/stream",
		"/chat/dm/1_1/plans/raw",
		"/chat/dm/1_1/plans_2",
		"/chat/channel/gone/plans",
		"/chat/dm/1_9/plans",
		"/chat/dm/2_2/plans",
	].all(|text| steves_way_in(text) == "/chat")
# A channel the human is no member of: Browse for Apoorva, the page for
# Steve.
expect resumed_path("Apoorva", File("/chat/channel/general/roc-chat".to_utf8())) == "/chat"
expect resumed_path("Apoorva", File("/chat/dm/1_2/plans".to_utf8())) == "/chat/dm/1_2/plans"
