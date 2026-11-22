## This module keeps the directory's files in the server's memory between
## requests, as `DirectoryFiles` reads them, so a request reads them from
## disk only when something in their folders has changed since: the
## accounts root, each account folder in it, and the folder of channels
## (`DirectoryFiles.watch_directory_files!`). The host counts every change
## there, the server's own writes and an edit made by hand alike
## (`FileFacts.count_changes!`), and a request reads the disk again
## whenever the count has moved, so what it is given is never older than
## the disk.
##
## A read from disk watches the folders first, then takes the count, then
## reads, and keeps what it read under that count. A change after the count
## moves it, whether it came before the read or after, so none is missed.
## When a folder can't be watched, nothing is kept, and the next request
## reads the disk again.
import pf.Host
import ChannelName
import DirectoryFiles
import FileFacts
import UserId

DirectoryCache :: [].{

	## The directory's files: as kept, when no change was counted since they
	## were read; else read from disk, and kept.
	read_directory_files! : {} => Try(
		DirectoryFiles.Contents,
		[Missing, Damaged, NotUtf8, PathRefused, Failed],
	)
	read_directory_files! = |{}| {
		changes = FileFacts.count_changes!({})
		kept = Host.read_bytes_kept_under_key!(kept_key)
		match kept.status {
			Found => {
				record = kept_from_bytes(kept.bytes)
				if record.changes == changes {
					Ok(record.contents)
				} else {
					read_and_keep!({})
				}
			}
			Missing => read_and_keep!({})
		}
	}
}

## What is kept: the directory's files, and the count of changes taken
## before they were read.
Kept : { changes : U64, contents : DirectoryFiles.Contents }

## The key the directory's files are kept under.
kept_key : List(U8)
kept_key = "directory".to_utf8()

## The directory's files read from disk, their folders watched and the
## count taken first, then kept under that count; or, when a folder can't
## be watched, read and not kept.
read_and_keep! : {} => Try(DirectoryFiles.Contents, _)
read_and_keep! = |{}| {
	watched = DirectoryFiles.watch_directory_files!({})
	changes = FileFacts.count_changes!({})
	contents = DirectoryFiles.read_directory_files!({})?
	match watched {
		Ok({}) => Host.replace_bytes_kept_under_key!(kept_key, kept_to_bytes({ changes, contents }))
		Err(Missing) => {}
		Err(PathRefused) => {}
		Err(Failed) => {}
	}
	Ok(contents)
}

## The bytes a kept record is held as: each of its parts (`kept_parts`) as
## a netstring, its length's digits, `:`, then its bytes.
kept_to_bytes : Kept -> List(U8)
kept_to_bytes = |kept|
	kept_parts(kept).join_map(|part| List.concat("${part.len().to_str()}:".to_utf8(), part))

## A kept record's parts, in order: the count; the counter, `no file`, or
## `file` and its bytes; how many accounts, then each one's id, name, and
## `no owner`, or `owner` and its bytes; how many channels, then each
## one's name and members.
kept_parts : Kept -> List(List(U8))
kept_parts = |{ changes, contents }| {
	counter =
		match contents.counter {
			NoFile => [no_file_word]
			File(bytes) => [file_word, bytes]
		}
	accounts = contents.accounts.join_map(
		|account| {
			owner =
				match account.owner {
					NoOwner => [no_owner_word]
					Owner(bytes) => [owner_word, bytes]
				}
			List.concat([account.id.to_str().to_utf8(), account.name], owner)
		},
	)
	channels = contents.channels.join_map(
		|channel| [channel.name.to_str().to_utf8(), channel.members],
	)
	[
		[changes.to_str().to_utf8()],
		counter,
		[contents.accounts.len().to_str().to_utf8()],
		accounts,
		[contents.channels.len().to_str().to_utf8()],
		channels,
	].join()
}

## The kept record `bytes` hold, as `kept_to_bytes` wrote them. Only this
## module writes them, so bytes that hold anything else are a broken
## promise, and crash.
kept_from_bytes : List(U8) -> Kept
kept_from_bytes = |bytes| {
	parts = parts_of(bytes)
	changes = number_of(part_at(parts, 0))
	(counter, accounts_at) =
		if part_at(parts, 1) == file_word {
			(File(part_at(parts, 2)), 3)
		} else {
			(NoFile, 2)
		}
	account_count = number_of(part_at(parts, accounts_at))
	var $at = accounts_at + 1
	var $accounts = []
	for _ in List.from_iter(U64.until(0, account_count)) {
		id = UserId.from_str(Str.from_utf8_lossy(part_at(parts, $at))) ?? crash "DirectoryCache.kept_from_bytes: an account's id"
		(owner, width) =
			if part_at(parts, $at + 2) == owner_word {
				(Owner(part_at(parts, $at + 3)), 4)
			} else {
				(NoOwner, 3)
			}
		name = part_at(parts, $at + 1)
		$accounts = $accounts.append({ id, name, owner })
		$at = $at + width
	}
	channel_count = number_of(part_at(parts, $at))
	$at = $at + 1
	var $channels = []
	for _ in List.from_iter(U64.until(0, channel_count)) {
		name = ChannelName.from_str(Str.from_utf8_lossy(part_at(parts, $at))) ?? crash "DirectoryCache.kept_from_bytes: a channel's name"
		$channels = $channels.append({ name, members: part_at(parts, $at + 1) })
		$at = $at + 2
	}
	{ changes, contents: { counter, accounts: $accounts, channels: $channels } }
}

## The parts of `bytes`, netstrings one after another.
parts_of : List(U8) -> List(List(U8))
parts_of = |bytes| {
	var $parts = []
	var $at = 0
	while $at < bytes.len() {
		rest = bytes.drop_first($at)
		colon = rest.find_first_index(|byte| byte == ':') ?? crash "DirectoryCache.parts_of: a part's length ends with `:`"
		length = number_of(rest.take_first(colon))
		$parts = $parts.append(rest.sublist({ start: colon + 1, len: length }))
		$at = $at + colon + 1 + length
	}
	$parts
}

## The part numbered `at`, from 0.
part_at : List(List(U8)), U64 -> List(U8)
part_at = |parts, at| parts.get(at) ?? crash "DirectoryCache.part_at: a kept record holds every part it names"

## The number decimal `digits` spell, 0 included.
number_of : List(U8) -> U64
number_of = |digits|
	if digits.is_empty() or !digits.all(|byte| byte >= '0' and byte <= '9') {
		crash "DirectoryCache.number_of: a kept number is its digits"
	} else {
		digits.fold(0, |so_far, digit| so_far * 10 + (digit - '0').to_u64())
	}

no_file_word : List(U8)
no_file_word = "no file".to_utf8()

file_word : List(U8)
file_word = "file".to_utf8()

no_owner_word : List(U8)
no_owner_word = "no owner".to_utf8()

owner_word : List(U8)
owner_word = "owner".to_utf8()

# ── tests
## A channel's name, as a test gives it.
channel_named : Str -> ChannelName
channel_named = |text| ChannelName.from_str(text) ?? crash "DirectoryCache's tests: a channel's name"

## An id, as a test gives it.
id_of : Str -> UserId
id_of = |text| UserId.from_str(text) ?? crash "DirectoryCache's tests: an id"

## Files of every kind a record holds: a counter, a human and an agent,
## names and members holding `:` and digits, and an empty members file.
full_files : DirectoryFiles.Contents
full_files = {
	counter: File("12\n".to_utf8()),
	accounts: [
		{
			id: id_of("1"),
			name: "Steve".to_utf8(),
			owner: NoOwner,
		},
		{
			id: id_of("10"),
			name: "12:34".to_utf8(),
			owner: Owner("1\n".to_utf8()),
		},
		{
			id: id_of("11"),
			name: [],
			owner: Owner([]),
		},
	],
	channels: [
		{ name: channel_named("general"), members: "1\n10\n".to_utf8() },
		{ name: channel_named("quiet"), members: [] },
	],
}

# Each record read back is the one written: the count, every file, in
# order, a counter there or not, and none of either kind.
expect {
	kept = { changes: 0, contents: full_files }
	kept_from_bytes(kept_to_bytes(kept)) == kept
}
expect {
	kept = { changes: 4_000_000_000, contents: full_files }
	kept_from_bytes(kept_to_bytes(kept)) == kept
}
expect {
	kept = { changes: 7, contents: { counter: NoFile, accounts: [], channels: [] } }
	kept_from_bytes(kept_to_bytes(kept)) == kept
}
# A part is its length's digits, `:`, then its bytes, so a `:` inside one
# is just a byte.
expect {
	contents = { counter: File("a:b".to_utf8()), accounts: [], channels: [] }
	kept_to_bytes({ changes: 3, contents }) == "1:34:file3:a:b1:01:0".to_utf8()
}
expect parts_of("0:3:abc2:::".to_utf8()) == [[], "abc".to_utf8(), "::".to_utf8()]
