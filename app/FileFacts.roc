## This module is the chat's only way to its files: the one module that
## calls the host's file primitives (platform/Host.roc). Each primitive here
## reads or writes one file or folder at a path, and answers what the host
## said as a named failure, so the host stays general and the chat's rules
## stay in the modules above it. Those modules, one per feature, are each
## the home of their own corner of the layout: `TranscriptFiles`,
## `AccountFiles`, `InviteFiles`, `AgentFiles` and `DirectoryFiles`. Only
## they build a path, each from a typed key, so no other caller can name a
## file outside the layout.
##
## Most of what the chat keeps is one small file per fact (a name, a hash, a
## state), and a record of several facts is written one file at a time, each
## made once, the file that makes it count written last (`create_facts!`).
##
## A file that may not exist yet is read as `NoFile` or `File(...)`. Every
## failure is named (`Fault`): `Missing` (no such file, for a read that
## needs one), `Damaged` (a file that holds no fact of its kind),
## `AlreadyExists` (a name taken), and the host's own, passed
## on as it said them (`NotUtf8`, `PathRefused`, `MissingDirectory`,
## `Failed`). Each function answers only the ones it can meet. Every one but `Missing` is a
## bug or a broken disk, and the caller answers it loudly, in `fault_words`.
import pf.Host

FileFacts :: [].{

	## Every failure a function of the chat's files answers, as `fault_words`
	## takes it.
	Fault : [
		Missing,
		Damaged,
		AlreadyExists,
		NotUtf8,
		PathRefused,
		MissingDirectory,
		Failed,
	]

	## What the file system answered, in words for a refusal. The host's
	## log says which file, and why.
	fault_words : FileFacts.Fault -> Str
	fault_words = |fault| "The file system answered ${fault_name(fault)}."

	## A next number's failure, for a route whose refusals hold `Full`: that
	## refusal, or the file system's fault as it is.
	refusal_when_full : [Full, FileSystem(FileFacts.Fault)] -> [
		Refused([Full]),
		FileSystem(FileFacts.Fault),
	]
	refusal_when_full = |why|
		match why {
			Full => Refused(Full)
			FileSystem(fault) => FileSystem(fault)
		}

	## A fact file's bytes, or `NoFile` when there is none; unless the host's
	## read failed.
	read_fact! : Str => Try([NoFile, File(List(U8))], [NotUtf8, PathRefused, Failed])
	read_fact! = |path| {
		read = Host.read_utf8_bytes_from_file!(path.to_utf8())
		match read.status {
			Found => Ok(File(read.bytes))
			Missing => Ok(NoFile)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## A fact file a record needs: its bytes, or `Missing`.
	read_needed_fact! : Str => Try(List(U8), [Missing, NotUtf8, PathRefused, Failed])
	read_needed_fact! = |path|
		match FileFacts.read_fact!(path)? {
			File(bytes) => Ok(bytes)
			NoFile => Err(Missing)
		}

	## The names in the folder `path`, as text, or none when there is no such
	## folder.
	list_names_in! : Str => Try(List(Str), [NotUtf8, PathRefused, Failed])
	list_names_in! = |path| {
		listed = Host.list_names_in_directory!(path.to_utf8())
		match listed.status {
			Found => Ok(listed.names.keep_oks(|name| Str.from_utf8(name)))
			Missing => Ok([])
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## A fact file made holding `bytes`, once: one already there is
	## `AlreadyExists`, and nothing is changed.
	create_fact! : Str,
	List(U8) => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_fact! = |path, bytes|
		match Host.create_file_with_utf8_bytes_unless_it_exists!(path.to_utf8(), bytes) {
			Created => Ok({})
			AlreadyExists => Err(AlreadyExists)
			MissingDirectory => Err(MissingDirectory)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}

	## A fact file written whole over the one before, atomically.
	replace_fact! : Str, List(U8) => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
	replace_fact! = |path, bytes|
		match Host.replace_file_with_utf8_bytes_atomically!(path.to_utf8(), bytes) {
			Replaced => Ok({})
			MissingDirectory => Err(MissingDirectory)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}

	## Each of `facts`, a name and its bytes, made once in the folder `folder`,
	## in order, the folder made first; stopping at the first that fails.
	create_facts! : Str,
	List((Str, List(U8))) => Try(
		{},
		[AlreadyExists, MissingDirectory, NotUtf8, PathRefused, Failed],
	)
	create_facts! = |folder, facts| {
		FileFacts.make_folder!(folder)?
		create_facts_from!({ folder, facts })
	}

	## `bytes` added at the end of the text file `path`, the file made when
	## there is none; unless the host refused.
	append_to_file! : Str, List(U8) => Try({}, [MissingDirectory, NotUtf8, PathRefused, Failed])
	append_to_file! = |path, bytes|
		match Host.append_utf8_bytes_to_file!(path.to_utf8(), bytes) {
			Appended => Ok({})
			MissingDirectory => Err(MissingDirectory)
			NotUtf8 => Err(NotUtf8)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}

	## A file of any bytes made at `path`, once: one already there is
	## `AlreadyExists`, and nothing is changed.
	create_binary_file! : Str,
	List(U8) => Try(
		{},
		[AlreadyExists, MissingDirectory, PathRefused, Failed],
	)
	create_binary_file! = |path, bytes|
		match Host.create_file_with_binary_bytes_unless_it_exists!(path.to_utf8(), bytes) {
			Created => Ok({})
			AlreadyExists => Err(AlreadyExists)
			MissingDirectory => Err(MissingDirectory)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}

	## The bytes of the file at `path`, as they are; unless there is none
	## (`Missing`), or the host's read failed.
	read_binary_file! : Str => Try(List(U8), [Missing, PathRefused, Failed])
	read_binary_file! = |path| {
		read = Host.read_binary_bytes_from_file!(path.to_utf8())
		match read.status {
			Found => Ok(read.bytes)
			Missing => Err(Missing)
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
	}

	## The folder `path`, and those above it, made as needed.
	make_folder! : Str => Try({}, [PathRefused, Failed])
	make_folder! = |path|
		match Host.make_directory_and_its_parents!(path.to_utf8()) {
			Made => Ok({})
			PathRefused => Err(PathRefused)
			Failed => Err(Failed)
		}
}

create_facts_from! : { folder : Str, facts : List((Str, List(U8))) } => Try({}, _)
create_facts_from! = |{ folder, facts }|
	match facts {
		[] => Ok({})
		[(name, bytes), .. as rest] => {
			FileFacts.create_fact!("${folder}/${name}", bytes)?
			create_facts_from!({ folder, facts: rest })
		}
	}

## A fault, by its tag's name.
fault_name : FileFacts.Fault -> Str
fault_name = |fault|
	match fault {
		Missing => "Missing"
		Damaged => "Damaged"
		AlreadyExists => "AlreadyExists"
		NotUtf8 => "NotUtf8"
		PathRefused => "PathRefused"
		MissingDirectory => "MissingDirectory"
		Failed => "Failed"
	}

# ── tests
# Every fault, in words.
expect
	[
		(Missing, "Missing"),
		(Damaged, "Damaged"),
		(AlreadyExists, "AlreadyExists"),
		(NotUtf8, "NotUtf8"),
		(PathRefused, "PathRefused"),
		(MissingDirectory, "MissingDirectory"),
		(Failed, "Failed"),
	].all(|(fault, name)| FileFacts.fault_words(fault) == "The file system answered ${name}.")
# A folder full of numbers is a route's refusal; a fault stays the fault.
expect FileFacts.refusal_when_full(Full) == Refused(Full)
expect FileFacts.refusal_when_full(FileSystem(Failed)) == FileSystem(Failed)
