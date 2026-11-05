## This module chooses the page a human lands on as they join, by a GitHub
## sign-up or an invite. A channel has no page of its own for its members, so
## a page they can read is a conversation, and a conversation is there only
## once it has a message.
##
## A human goes where they were heading when that is a conversation they may
## read and it exists, as a link someone shared to it. Anywhere else, their DM
## with the chat's owner (`Welcome`), which is written before their account. A
## human whose account is older than their welcome has no such DM, and lands on
## `SignInRoute.default_next`, a page every human may read.
import Access
import ChannelName
import Channels
import ConversationKey
import Directory
import FileSystem
import Html
import Name
import Place
import SignInRoute
import UnvalidatedString
import Users
import Welcome

FirstPage :: [].{

	## Where `human` lands, in `directory`, heading for `wanted`.
	load! : {
		directory : Directory,
		human : Users.Human,
		wanted : Html.SitePath,
	} => Try(Html.SitePath, [FileSystem(FileSystem.Fault)])
	load! = |
		{
			directory,
			human,
			wanted,
		},
	|
		match readable_conversation({
			directory,
			human,
			path: wanted,
		}) {
			NotReadable => load_welcome_page!({ directory, human })
			Readable(key) =>
				match load_conversation_state!(key)? {
					Begun => Ok(wanted)
					NotBegun => load_welcome_page!({ directory, human })
				}
		}
}

## The conversation page `path` names, when `human` is one of its place's
## members in `directory`.
readable_conversation : {
	directory : Directory,
	human : Users.Human,
	path : Html.SitePath,
} -> [Readable(ConversationKey), NotReadable]
readable_conversation = |
	{
		directory,
		human,
		path,
	},
| {
	unchecked =
		UnvalidatedString.from_utf8(path.to_str().to_utf8())
			?? crash "FirstPage.readable_conversation: a site path is text"
	match ConversationKey.from_url_path({ path: unchecked, directory }) {
		Ok({ key, resource: Page }) if is_member({
			directory,
			human,
			place: key.place(),
		}) =>
			Readable(key)
		_ => NotReadable
	}
}

## Whether `human` may read and post at `place`.
is_member : {
	directory : Directory,
	human : Users.Human,
	place : Place,
} -> Bool
is_member = |
	{
		directory,
		human,
		place,
	},
| Access.members({ place, directory }).contains(human.id())

## The page of `human`'s DM with the chat's owner, or `SignInRoute.default_next`
## when it has not begun.
load_welcome_page! : { directory : Directory, human : Users.Human } => Try(
	Html.SitePath,
	[FileSystem(FileSystem.Fault)],
)
load_welcome_page! = |request| {
	key = Welcome.conversation_key(request)
	match load_conversation_state!(key)? {
		Begun => Ok(page_of(key))
		NotBegun => Ok(SignInRoute.default_next)
	}
}

## Whether the conversation `key` has begun, by its transcript.
load_conversation_state! : ConversationKey => Try([Begun, NotBegun], [FileSystem(FileSystem.Fault)])
load_conversation_state! = |key|
	match FileSystem.read_transcript!(key) {
		Ok(File(_)) => Ok(Begun)
		Ok(NoFile) => Ok(NotBegun)
		Err(fault) => Err(FileSystem(fault))
	}

## The site path of the conversation `key`'s page.
page_of : ConversationKey -> Html.SitePath
page_of = |key|
	Html.SitePath.from_str(key.url_path(Page))
		?? crash "FirstPage.page_of: a conversation's page is a site path"

# ── tests
## Steve (1), who is in the default channel, Zoe (2), who is in `plans`, and
## Bob (3), who is in neither.
tests_directory : Directory
tests_directory = {
	founded = Directory.with_founder(tests_name("Steve"))
	with_zoe = (founded.add_human(tests_name("Zoe")) ?? crash "FirstPage's tests: room").directory
	with_bob = (with_zoe.add_human(tests_name("Bob")) ?? crash "FirstPage's tests: room").directory
	plans = ChannelName.from_str("plans") ?? crash "FirstPage's tests: a channel's name"
	channels =
		Channels.from_files([
			{ name: Channels.default_name, members: "1\n".to_utf8() },
			{ name: plans, members: "2\n".to_utf8() },
		]) ?? crash "FirstPage's tests: the members files read"
	Directory.from_files({ users: with_bob.users(), channels })
		?? crash "FirstPage's tests: the channels' members are users"
}

tests_name : Str -> Name
tests_name = |text| Name.from_str(text) ?? crash "FirstPage's tests: a name"

## The human `text` names.
human_named : Str -> Users.Human
human_named = |text| {
	user =
		tests_directory.users().user_by_name(tests_name(text))
			?? crash "FirstPage's tests: a user"
	user.as_human() ?? crash "FirstPage's tests: a human"
}

## What `readable_conversation` says of `path` for the human `name`, as a test
## reads it.
reading : Str, Str -> Try(Str, [NotReadable])
reading = |name, text| {
	path = Html.SitePath.from_str(text) ?? crash "FirstPage's tests: a site path"
	asked = readable_conversation({
		directory: tests_directory,
		human: human_named(name),
		path,
	})
	match asked {
		Readable(key) => Ok(key.url_path(Page))
		NotReadable => Err(NotReadable)
	}
}

# A conversation of a channel they are in, and their own DM.
expect reading("Steve", "/chat/channel/general/hello") == Ok("/chat/channel/general/hello")
expect reading("Zoe", "/chat/channel/plans/hello") == Ok("/chat/channel/plans/hello")
expect reading("Zoe", "/chat/dm/2_3/hello") == Ok("/chat/dm/2_3/hello")
# Another channel's, another's DM, and no channel at all.
expect reading("Zoe", "/chat/channel/general/hello") == Err(NotReadable)
expect reading("Bob", "/chat/dm/1_2/hello") == Err(NotReadable)
expect reading("Steve", "/chat/channel/nowhere/hello") == Err(NotReadable)
# A page that is no conversation's, and a conversation's other resources.
expect
	[
		"/agents",
		"/channels",
		"/chat/channel/general/hello/raw",
		"/chat/channel/general/hello/stream",
	].all(|path| reading("Steve", path) == Err(NotReadable))
# The page a new human's welcome starts is a page they may read, as a
# conversation of theirs, and the owner may too.
expect {
	page = page_of(Welcome.conversation_key({ directory: tests_directory, human: human_named("Zoe") }))
	reading("Zoe", page.to_str()) == Ok("/chat/dm/1_2/ChitChat")
		and reading("Steve", page.to_str()) == Ok("/chat/dm/1_2/ChitChat")
		and reading("Bob", page.to_str()) == Err(NotReadable)
}
