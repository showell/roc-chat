## This module keeps the chat's directory on disk: who the users are, and
## which channels there are with their members. It reads the whole
## directory as files (`read_directory_files!`), for `DirectoryStore` to
## check, writes a channel's members, and lists a place's topics. It works
## through `FileFacts`, and builds every path from a typed key, so no
## caller names a file.
##
## The users' part is `AccountFiles`' layout: the counter of user ids and
## each account folder. A channel's members are its file beside its folder
## of topics (`Channels`), `chat/channel/<name>.channel`, and the folder
## holds a folder for each of the channel's conversations.
import AccountFiles
import ChannelName
import Channels
import ConversationKey
import FileFacts
import Place
import Topic
import UserStreams
import Users

DirectoryFiles :: [].{

	## The files the directory is kept in, as read: the counter of user ids,
	## every account folder's, and every channel's members file.
	Contents : {
		counter : [NoFile, File(List(U8))],
		accounts : List(Users.AccountFacts),
		channels : List(Channels.ChannelFacts),
	}

	## The files the directory is kept in, unchecked, for `Users.from_stored`
	## and `Channels.from_stored` to read: the counter of user ids (`NoFile`
	## before the first start), each account folder's facts
	## (`AccountFiles.read_accounts!`), and each channel's members file. No
	## folder of channels holds none.
	read_directory_files! : {} => Try(
		DirectoryFiles.Contents,
		[Missing, Damaged, NotUtf8, PathRefused, Failed],
	)
	read_directory_files! = |{}| {
		counter = AccountFiles.read_user_counter!({})?
		accounts = AccountFiles.read_accounts!({})?
		channel_names = FileFacts.list_names_in!(channels_folder_path)?.keep_oks(
			|file_name|
				if file_name.ends_with(channel_members_suffix) {
					ChannelName.from_str(file_name.drop_suffix(channel_members_suffix))
				} else {
					Err(NotAMembersFile)
				},
		)
		var $channels = []
		for name in channel_names {
			members = FileFacts.read_needed_fact!(channel_members_path(name))?
			$channels = $channels.append({ name, members })
		}
		Ok({ counter, accounts, channels: $channels })
	}

	## Every folder that holds a file `read_directory_files!` reads, watched
	## for changes (`FileFacts.watch_folder!`), with each folder above it:
	## the accounts root, each account folder in it, and the folder of
	## channels, for their members files alone. A folder that is not there
	## is no failure: none of channels holds no channel, and the host
	## watches the folders above it, so its making is a change.
	watch_directory_files! : {} => Try({}, [PathRefused, Failed])
	watch_directory_files! = |{}| {
		absent_allowed(AccountFiles.watch_account_folders!({}))?
		absent_allowed(FileFacts.watch_folder!(channels_folder_path, Alone))
	}

	## A channel's members file, written whole as `channel` holds them.
	replace_channel_members! : Channels.Channel => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_channel_members! = |channel| {
		FileFacts.make_folder!(channels_folder_path)?
		FileFacts.replace_fact!(channel_members_path(channel.name()), channel.members_bytes())
	}

	## A channel's members file, written whole as `channel` holds them, once
	## the user `revoker` names is removed from it: `channel` must not hold
	## them.
	replace_channel_members_without! : UserStreams.Revoker,
	Channels.Channel => Try(
		{},
		[MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	replace_channel_members_without! = |revoker, channel|
		if channel.members().contains(revoker.user()) {
			crash "DirectoryFiles.replace_channel_members_without!: the channel still holds the revoker's user"
		} else {
			DirectoryFiles.replace_channel_members!(channel)
		}

	## The topics of `place`'s conversations, by its folders, in byte order;
	## a folder whose name is no topic is left out. A place with no
	## conversation yet has none.
	list_place_topics! : Place => Try(List(Topic), [NotUtf8, PathRefused, Failed])
	list_place_topics! = |place| {
		names = FileFacts.list_names_in!(Str.join_with(ConversationKey.place_parts(place), "/"))?
		Ok(names.keep_oks(Topic.from_str))
	}
}

## A watch's answer, a folder not there taken as watched (`watch_directory_files!`).
absent_allowed : Try({}, [Missing, PathRefused, Failed]) -> Try({}, [PathRefused, Failed])
absent_allowed = |watched|
	match watched {
		Ok({}) => Ok({})
		Err(Missing) => Ok({})
		Err(PathRefused) => Err(PathRefused)
		Err(Failed) => Err(Failed)
	}

## The folder of the channels: what holds each channel's folder and its
## members file.
channels_folder_path : Str
channels_folder_path = Str.join_with(ConversationKey.channels_folder_parts, "/")

## The channel `name`'s folder, which holds its conversations' folders.
channel_folder_path : ChannelName -> Str
channel_folder_path = |name| Str.join_with(ConversationKey.channel_folder_parts(name), "/")

## The channel `name`'s members file, beside its folder.
channel_members_path : ChannelName -> Str
channel_members_path = |name| "${channel_folder_path(name)}${channel_members_suffix}"

channel_members_suffix : Str
channel_members_suffix = ".channel"

# ── tests
# The paths each builder makes, under the folder of channels.
expect channels_folder_path == "chat/channel"
expect {
	general = ChannelName.from_str("general") ?? crash "DirectoryFiles' tests: a channel's name"
	channel_folder_path(general)
		== "chat/channel/general" and channel_members_path(general)
		== "chat/channel/general.channel"
}
