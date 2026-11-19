## This module keeps the chat's directory, its users and channels, in the
## data folder, through `FileSystem`. It prepares the folder when the server
## starts, writing the first start's directory (`FirstStart`) into an empty
## one, and reads the directory back on each request, refusing a folder
## that holds only part of one. It is the module to swap, with
## `FileSystem`, for a chat kept somewhere other than files.
import pf.Http
import ChannelName
import Channels
import Directory
import FileSystem
import FirstStart
import HttpAnswer
import Page
import UserId
import Users

DirectoryStore :: [].{

	## Whether the server may start on its data folder: `Ready` when the folder
	## holds a whole chat, or held none and now holds the first
	## (`FirstStart`); else `Failed`.
	prepare_directory! : {} => [Failed, Ready]
	prepare_directory! = |{}|
		match FileSystem.read_directory_files!({}) {
			Err(_) => Failed
			Ok(files) =>
				match files.counter {
					File(_) =>
						match directory_from_files(files) {
							Ok(_) => Ready
							Err(_) => Failed
						}
					NoFile if files.accounts.is_empty() and files.channels.is_empty() =>
						match write_first_directory!({}) {
							Ok({}) => Ready
							Err(_) => Failed
						}
					NoFile => Failed
				}
		}

	## The directory as the data folder holds it now; or why not.
	load_directory! : {} => Try(Directory, [FileSystem(FileSystem.Fault), StoredDirectory(Str)])
	load_directory! = |{}| {
		files = FileSystem.read_directory_files!({}) ? |fault| FileSystem(fault)
		directory_from_files(files)
	}

	## The 500 for a directory that can't be read.
	directory_refusal : [FileSystem(FileSystem.Fault), StoredDirectory(Str)] -> Http.Response
	directory_refusal = |why| {
		said =
			match why {
				FileSystem(fault) => FileSystem.fault_words(fault)
				StoredDirectory(words) => "The chat's directory on disk is not whole: ${words}."
			}
		HttpAnswer.page(500, Page.notice({ title: "Failed", text: said }))
	}
}

## The first directory written: the founder's account, `general`'s members,
## then the counter of ids, which says the chat exists, last.
write_first_directory! : {} => Try({}, _)
write_first_directory! = |{}| {
	FileSystem.create_account!(FirstStart.first_directory.chat_owner().user())?
	for channel in FirstStart.first_directory.channels().to_list() {
		FileSystem.replace_channel_members!(channel)?
	}
	FileSystem.replace_user_counter!(FirstStart.first_directory.users())?
	Ok({})
}

## The directory the files hold; or why not, in words.
directory_from_files : FileSystem.DirectoryFiles -> Try(Directory, [StoredDirectory(Str)])
directory_from_files = |files| {
	counter =
		match files.counter {
			File(bytes) => Ok(bytes)
			NoFile => Err(StoredDirectory("there is no counter of user ids"))
		}?
	users = Users.from_files({
		counter,
		accounts: files.accounts,
	}) ? |why| StoredDirectory(users_words(why))
	channels =
		Channels.from_files(files.channels) ? |BadMembers(name)| StoredDirectory("the members of #${name.to_str()} are not one id a line")
	directory = Directory.from_files({
		users,
		channels,
	}) ? |why| StoredDirectory(directory_words(why))
	Ok(directory)
}

users_words : [
	BadCounter,
	BadName(UserId),
	BadOwner(UserId),
	NoFounder,
	CounterBehind,
] -> Str
users_words = |why|
	match why {
		BadCounter => "the counter of user ids is not one"
		BadName(id) => "user ${id.to_str()}'s name is not a name"
		BadOwner(id) => "user ${id.to_str()}'s owner is no human"
		NoFounder => "there is no founder, a human of id 1"
		CounterBehind => "the counter of user ids is behind a user's id"
	}

directory_words : [NameTaken, UnknownMember(ChannelName)] -> Str
directory_words = |why|
	match why {
		NameTaken => "two names are the same name"
		UnknownMember(name) => "#${name.to_str()} has a member who is no user"
	}

# ── tests
## The directory files of the first start, as the disk holds them.
first_files : FileSystem.DirectoryFiles
first_files = {
	founder = FirstStart.first_directory.chat_owner().user()
	{
		counter: File(FirstStart.first_directory.users().counter_file()),
		accounts: [{ id: founder.id(), files: Users.account_files(founder) }],
		channels: FirstStart.first_directory.channels().to_list().map(
			|channel| { name: channel.name(), members: channel.members_file() },
		),
	}
}

# The first start's files read back are the first directory; with no
# counter, or a counter that is no number, the files are no chat's.
expect directory_from_files(first_files) == Ok(FirstStart.first_directory)
expect directory_from_files({
	..first_files,
	counter: NoFile,
}) == Err(StoredDirectory("there is no counter of user ids"))
expect directory_from_files({
	..first_files,
	counter: File("x".to_utf8()),
}) == Err(StoredDirectory("the counter of user ids is not one"))
expect
	directory_from_files({
		..first_files,
		channels: [
			{
				name: ChannelName.from_str("general") ?? crash "DirectoryStore's tests: a name",
				members: "1\n2\n".to_utf8(),
			},
		],
	})
		== Err(StoredDirectory("#general has a member who is no user"))
expect
	directory_from_files({
		..first_files,
		channels: [
			{
				name: ChannelName.from_str("steve") ?? crash "DirectoryStore's tests: a name",
				members: "1\n".to_utf8(),
			},
		],
	})
		== Err(StoredDirectory("two names are the same name"))
