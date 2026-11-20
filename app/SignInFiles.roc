## This module reads and writes what a human's sessions are signed over
## (`Session.Material`): their password file's hash and, for a human tied
## to GitHub, the word in their `github-session-secret`, and once they have
## signed their other devices out, their `session-generation`. `SignInRoute` signs
## and checks sessions over it, and `DeviceCodeRoute` holds a device code to
## it. Rewriting any of these files ends every session of the human. It also
## checks the device key a session started by a code is bound to
## (`check_session_key!`), which ends that one device's session alone.
import pf.Host
import AccountFiles
import DeviceKeyFiles
import FileFacts
import GitHubSessionWord
import GitHubSignIn
import PasswordHash
import Session
import UserId

SignInFiles :: [].{

	## What the sessions of the user `id` are signed over now, from their sign-in
	## files; unless they hold nothing to sign over (`NoMaterial`), their
	## `session-generation` file holds no count (`GenerationDamaged`, logged:
	## every session of theirs is refused until it is mended), or a file
	## can't be read.
	load_material! : UserId => Try(
		Session.Material,
		[NoMaterial, GenerationDamaged, FileSystem(FileFacts.Fault)],
	)
	load_material! = |id| {
		github = load_github_word!(id)?
		generation = load_generation!(id)?
		material =
			match (AccountFiles.read_password_hash!(id), github) {
				(Err(fault), _) => Err(FileSystem(fault))
				(Ok(File(password_hash)), _) =>
					Ok(Session.Material.from_password({ password_hash, github }))
				(Ok(NoFile), GitHub(word)) => Ok(Session.Material.from_github_alone(word))
				(Ok(NoFile), NoGitHub) => Err(NoMaterial)
			}
		Ok(material?.with_generation(generation))
	}

	## What a session of the user `id` is signed over when it starts from
	## `password_hash`, just checked or just written, not what the file holds by
	## now: a password rewritten meanwhile leaves a session that admits no one.
	load_material_with_password! : { id : UserId, password_hash : PasswordHash } => Try(
		Session.Material,
		[GenerationDamaged, FileSystem(FileFacts.Fault)],
	)
	load_material_with_password! = |{ id, password_hash }| {
		github = load_github_word!(id)?
		generation = load_generation!(id)?
		Ok(Session.Material.from_password({ password_hash, github }).with_generation(generation))
	}

	## `Ok` when a session of the human `id`, started as `origin` says, may
	## still admit them: always for an ordinary session, and for one a device
	## code started only while its key is active; else `SessionRefused` (a key
	## revoked, never made or cut short, or a `state` file that holds no
	## state or no UTF-8, logged); unless the host's read failed.
	check_session_key! : UserId,
	Session.Origin => Try(
		{},
		[SessionRefused, FileSystem(FileFacts.Fault)],
	)
	check_session_key! = |id, origin|
		match origin {
			Ordinary => Ok({})
			ByDeviceCode(key) =>
				match DeviceKeyFiles.read_device_key_state!(id, key) {
					Ok(Key(Active)) => Ok({})
					Ok(Key(Revoked)) | Ok(NoKey) => Err(SessionRefused)
					Err(FileSystem(Damaged)) | Err(FileSystem(NotUtf8)) => {
						said = "sessions: user ${id.to_str()}'s device key ${key.to_str()} holds no state; its device's session is refused"
						Host.write_line_to_server_log!(said.to_utf8())
						Err(SessionRefused)
					}
					Err(FileSystem(fault)) => Err(FileSystem(fault))
				}
		}

	## The human `id`'s other devices signed out: their session generation
	## raised by one, so every session signed over the one before, this
	## device's too until it is signed again, admits no one; a count at the
	## largest a U64 holds, which only a hand edit makes, is `Damaged`.
	advance_session_generation! : UserId => Try({}, [FileSystem(FileFacts.Fault)])
	advance_session_generation! = |id| {
		generation = AccountFiles.read_session_generation!(id) ? |fault| FileSystem(fault)
		next = SignInFiles.next_generation(generation) ? |Damaged| FileSystem(Damaged)
		AccountFiles.replace_session_generation!(id, next) ? |fault| FileSystem(fault)
		Ok({})
	}

	## The generation after `generation`; unless it is the largest a U64
	## holds (`Damaged`).
	next_generation : U64 -> Try(U64, [Damaged])
	next_generation = |generation|
		if generation == U64.highest {
			Err(Damaged)
		} else {
			Ok(generation + 1)
		}

	## The user `id`'s `github-session-secret`, made first when there is none
	## (`GitHubSessionWord`). Sessions are signed over it under the server's
	## secret, so whoever reads the file can't forge one; it needs only to change
	## when its owner rewrites it.
	make_github_session_secret! : UserId => Try({}, [FileSystem(FileFacts.Fault)])
	make_github_session_secret! = |id|
		match AccountFiles.read_github_session_secret!(id) {
			Err(fault) => Err(FileSystem(fault))
			Ok(File(_)) => Ok({})
			Ok(NoFile) => {
				word = generate_github_session_word!({})
				match AccountFiles.create_github_session_secret!(id, word) {
					Ok({}) => Ok({})
					Err(fault) => Err(FileSystem(fault))
				}
			}
		}

	## The files that tie `linked`'s human to GitHub: a new `github-session-secret`,
	## which says nothing until `github-id` is there, and then the `github-id`, so
	## a link cut short between the two binds no one.
	write_github_link! : GitHubSignIn.Linked => Try({}, [FileSystem(FileFacts.Fault)])
	write_github_link! = |linked| {
		id = linked.human().id()
		word = generate_github_session_word!({})
		AccountFiles.replace_github_session_secret!(id, word) ? |fault| FileSystem(fault)
		AccountFiles.create_github_id!(id, linked.github()) ? |fault| FileSystem(fault)
		Ok({})
	}
}

## The word in the user `id`'s `github-session-secret`, read only while their
## `github-id` ties them to GitHub, so removing that file ends their sessions
## too. An empty file holds no word.
load_github_word! : UserId => Try(
	[NoGitHub, GitHub(GitHubSessionWord)],
	[FileSystem(FileFacts.Fault)],
)
load_github_word! = |id|
	match AccountFiles.read_github_link!(id) {
		Err(fault) => Err(FileSystem(fault))
		Ok(NotLinked) => Ok(NoGitHub)
		Ok(Linked(_)) =>
			match AccountFiles.read_github_session_secret!(id) {
				Err(fault) => Err(FileSystem(fault))
				Ok(NoFile) | Ok(File(Empty)) => Ok(NoGitHub)
				Ok(File(Word(word))) => Ok(GitHub(word))
			}
	}

## A new GitHub word, of the host's random bytes.
generate_github_session_word! : {} => GitHubSessionWord
generate_github_session_word! = |{}| {
	random_bytes = Host.fill_with_random_bytes!(GitHubSessionWord.random_byte_count)
	GitHubSessionWord.of_random_bytes(random_bytes)
}

## The user `id`'s session generation, 0 with no file; unless the file holds
## no count (`GenerationDamaged`), which is logged, or can't be read.
load_generation! : UserId => Try(U64, [GenerationDamaged, FileSystem(FileFacts.Fault)])
load_generation! = |id|
	match AccountFiles.read_session_generation!(id) {
		Ok(generation) => Ok(generation)
		Err(Damaged) => {
			said = "sessions: user ${id.to_str()}'s session-generation file holds no count; their sessions are refused until it is mended"
			Host.write_line_to_server_log!(said.to_utf8())
			Err(GenerationDamaged)
		}
		Err(NotUtf8) => Err(FileSystem(NotUtf8))
		Err(PathRefused) => Err(FileSystem(PathRefused))
		Err(Failed) => Err(FileSystem(Failed))
	}

# ── tests
# The generation after a count, and none after the largest a U64 holds,
# which only a hand edit makes.
expect SignInFiles.next_generation(0) == Ok(1)
expect SignInFiles.next_generation(41) == Ok(42)
expect SignInFiles.next_generation(U64.highest - 1) == Ok(U64.highest)
expect SignInFiles.next_generation(U64.highest) == Err(Damaged)
