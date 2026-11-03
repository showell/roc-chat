## These are the tests of the directory as its files keep it (`Users`,
## `Channels`, `Directory`): every user and channel written out and read
## back the same, and each way the files can fail to be a directory
## refused by name.
import ChannelName
import Channels
import Directory
import Sample
import UserId
import Users

StoredDirectorySpec :: [].{}

## The sample directory's users, with the channel `team` of Steve and CC.
with_team : Directory
with_team = {
	team = ChannelName.from_str("team") ?? crash "StoredDirectorySpec: a channel's name"
	created = (
		Sample.directory.create_channel({
			by: Sample.admin,
			name: team,
		}) ?? crash "StoredDirectorySpec: team is free"
	).directory
	with_steve = created.add_member({
		by: Sample.admin,
		channel: team,
		member: Sample.steve,
	}) ?? crash "StoredDirectorySpec: Steve joins"
	with_steve.add_member({
		by: Sample.admin,
		channel: team,
		member: Sample.user("CC"),
	}) ?? crash "StoredDirectorySpec: CC joins"
}

## The users' account files, as `FileSystem` reads them.
accounts_of : Users -> List(Users.StoredAccount)
accounts_of = |users| users.to_list().map(
	|user| {
		id: user.id(),
		files: Users.account_files(user),
	},
)

## The channels' members files, as `FileSystem` reads them.
channels_of : Channels -> List(Channels.StoredChannel)
channels_of = |channels| channels.to_list().map(
	|channel| {
		name: channel.name(),
		members: channel.members_file(),
	},
)

## The users the files hold, from `with_team`'s, with `counter`.
users_with : { counter : Str, accounts : List(Users.StoredAccount) } -> Try(Users, _)
users_with = |{ counter, accounts }| Users.from_files({ counter: counter.to_utf8(), accounts })

## An account's files, as a test writes them.
account : {
	id : Str,
	name : Str,
	owner : [NoFile, File(Str)],
} -> Users.StoredAccount
account = |
	{
		id,
		name,
		owner,
	},
| {
	id: UserId.from_str(id) ?? crash "StoredDirectorySpec: an id",
	files: {
		name: name.to_utf8(),
		owner: match owner {
			NoFile => NoFile
			File(text) => File(text.to_utf8())
		},
	},
}

# Each user's files: a human's name and no owner; an agent's name and its
# owner's digits. The counter: the next id's digits and a line end.
expect Users.account_files(Sample.steve) == { name: "Steve".to_utf8(), owner: NoFile }
expect Users.account_files(Sample.user("CC")) == {
	name: "CC".to_utf8(),
	owner: File("1".to_utf8()),
}
expect Sample.directory.users().counter_file() == "4\n".to_utf8()
expect Sample.crowded_directory(252).users().counter_file() == "256\n".to_utf8()
# Written out and read back, in any order, the same users, the next id
# included; and the same directory.
expect users_with({
	counter: "4\n",
	accounts: accounts_of(Sample.directory.users()),
}) == Ok(Sample.directory.users())
expect users_with({
	counter: "4\n",
	accounts: accounts_of(Sample.directory.users()).sort_with(|a, b| b.id.compare(a.id)),
}) == Ok(Sample.directory.users())
expect {
	users = Sample.crowded_directory(252).users()
	Users.from_files({ counter: users.counter_file(), accounts: accounts_of(users) }) == Ok(users)
}
expect {
	channels = Channels.from_files(channels_of(with_team.channels())) ?? crash "StoredDirectorySpec: the channels read back"
	Directory.from_files({ users: with_team.users(), channels }) == Ok(with_team)
}
# The counter may run ahead of the users, never behind or at them.
expect users_with({
	counter: "9",
	accounts: accounts_of(Sample.directory.users()),
}).map_ok(|users| users.next_id().map_ok(UserId.to_str)) == Ok(Ok("9"))
expect [
	"3",
	"1",
	"0",
	"",
	"x",
	"257",
	"-4",
].all(
	|counter| users_with({
		counter,
		accounts: accounts_of(Sample.directory.users()),
	}).map_ok(|_| {}) == Err(if (counter == "3") CounterBehind else BadCounter),
)
# A name that is no name, and an owner that is no id, or no human here.
expect
	users_with({
		counter: "3",
		accounts: [
			account({
				id: "1",
				name: "Steve",
				owner: NoFile,
			}),
			account({
				id: "2",
				name: "R2D2",
				owner: NoFile,
			}),
		],
	}).map_ok(|_| {})
		== Err(BadName(UserId.from_str("2") ?? crash "StoredDirectorySpec: an id"))
expect
	["x", "0", "9", "2"].all(
		|owner|
			users_with({
				counter: "3",
				accounts: [
					account({
						id: "1",
						name: "Steve",
						owner: NoFile,
					}),
					account({
						id: "2",
						name: "CC",
						owner: File(owner),
					}),
				],
			}).map_ok(|_| {})
				== Err(BadOwner(UserId.from_str("2") ?? crash "StoredDirectorySpec: an id")),
	)
expect
	users_with({
		counter: "3",
		accounts: [
			account({
				id: "1",
				name: "Steve",
				owner: NoFile,
			}),
			account({
				id: "2",
				name: "CC",
				owner: File("1\n"),
			}),
		],
	}).map_ok(|users| users.to_list().len())
		== Ok(2)
# No founder: none at all, or id 1 an agent.
expect users_with({ counter: "2", accounts: [] }).map_ok(|_| {}) == Err(NoFounder)
expect users_with({
	counter: "3",
	accounts: [
		account({
			id: "1",
			name: "Bot",
			owner: File("1"),
		}),
	],
}).map_ok(|_| {}) == Err(NoFounder)
expect users_with({
	counter: "3",
	accounts: [
		account({
			id: "2",
			name: "Steve",
			owner: NoFile,
		}),
	],
}).map_ok(|_| {}) == Err(NoFounder)

## The channel `team` whose members file is `text`, read.
team_read : Str -> Try(List(Str), _)
team_read = |text| {
	team = ChannelName.from_str("team") ?? crash "StoredDirectorySpec: a channel's name"
	channels = Channels.from_files([{ name: team, members: text.to_utf8() }])?
	Ok(channels.to_list().join_map(|channel| channel.members().map(UserId.to_str)))
}

# A members file: one id a line, lowest first; read with spaces off each
# line, blank lines and `#` lines skipped.
expect (with_team.channels().channel(ChannelName.from_str("team") ?? crash "a name") ?? crash "team").members_file() == "1\n3\n".to_utf8()
expect team_read("1\n3\n") == Ok(["1", "3"])
expect team_read("# the team\n\n 3 \r\n1") == Ok(["1", "3"])
expect team_read("") == Ok([])
# A line that is no id, or an id twice: the file is refused.
expect [
	"1\n1\n",
	"x\n",
	"01\n",
	"1 # Steve\n",
	"0\n",
].all(|text| team_read(text).map_ok(|_| {}) == Err(BadMembers(ChannelName.from_str("team") ?? crash "a name")))
# The directory: names one namespace across users and channels, and every
# member a user.
expect {
	stray = ChannelName.from_str("team") ?? crash "a name"
	channels = Channels.from_files([
		{
			name: stray,
			members: "1\n9\n".to_utf8(),
		},
	]) ?? crash "StoredDirectorySpec: the file is ids"
	Directory.from_files({ users: Sample.directory.users(), channels }) == Err(UnknownMember(stray))
}
expect {
	clash = ChannelName.from_str("cc") ?? crash "a name"
	channels = Channels.from_files([
		{
			name: clash,
			members: "1\n".to_utf8(),
		},
	]) ?? crash "StoredDirectorySpec: the file is ids"
	Directory.from_files({ users: Sample.directory.users(), channels }) == Err(NameTaken)
}
expect Directory.from_files({
	users: Sample.directory.users(),
	channels: Channels.empty,
}).map_ok(|directory| directory.founder()) == Ok(Sample.steve)
