## This module holds the tighter upload limit on new accounts: a human in
## their first `first_days` days may upload at most `most_mib` MiB in all,
## counted in the same lifetime total as every upload (`UploadTotal`).
## Sign-up by GitHub is open to anyone, so without it a fresh account could
## spend its whole 1 GiB allowance on its first day, and a few of them fill
## the disk. Past it, an upload is the allowance's own refusal, a 403
## (`UploadRoute`), saying the limit is a new account's.
##
## **WHEN AN ACCOUNT IS NEW.** No account file holds when it was made, so
## the account's age is read from its welcome (`Welcome`): the first
## message of the DM between the chat's owner and the human, under
## `Welcome.topic`, which every account made by an invite or by GitHub
## sign-up gets as it is made, before its name, dated by the server's
## clock. A transcript is only appended to, so that date never changes, and
## no request can write a message dated in the past (`Conversation`). A
## human is new while their welcome is less than `first_days` days old.
##
## A human with no welcome (an account older than welcomes, or one the
## server's owner made by hand), the chat's owner, and every agent (made by
## the admin alone, `Agents.agent_keeper`) are established, and keep the
## lifetime allowance alone. A welcome that can't be read or decoded
## refuses the upload (`UploadRoute`'s 500), never reads as established.
import ConversationKey
import DateTime
import Directory
import DirectoryStore
import FileFacts
import Seconds
import Timestamp
import Transcript
import TranscriptFiles
import TranscriptRefusal
import UploadTotal
import UserId
import Users
import Welcome

NewAccountUploads :: [].{

	## How many days an account is new for.
	first_days : I64
	first_days = 7

	## How long an account is new for, from its welcome, in seconds.
	first_period_seconds : I128
	first_period_seconds = 7 * 24 * 60 * 60

	## The most a new account uploads, in MiB, as the refusal words it.
	most_mib : U64
	most_mib = 100

	## The most bytes a new account uploads in all.
	most_bytes : U64
	most_bytes = NewAccountUploads.most_mib * 1024 * 1024

	## What an upload past the new account's limit says.
	limit_words : Str
	limit_words = "Upload limit reached — a new account may upload ${NewAccountUploads.most_mib.to_str()} MiB in its first ${NewAccountUploads.first_days.to_str()} days."

	## Whether an account is new at `now`, from its welcome's date
	## (`WelcomedAt`), or `NotWelcomed` for an account with none.
	standing_at : [NotWelcomed, WelcomedAt(DateTime)], Timestamp -> [New, Established]
	standing_at = |welcomed, now|
		match welcomed {
			NotWelcomed => Established
			WelcomedAt(time) =>
				match DateTime.from_timestamp(now.plus(first_period_back)) {
					# A clock this early can't be, and the tighter limit holds.
					Err(OutOfRange) => New
					Ok(cutoff) =>
						match DateTime.compare(time, cutoff) {
							After => New
							Same | Before => Established
						}
				}
		}

	## Whether an account of `standing` may hold the upload total `after`,
	## the one an upload would leave it with.
	check : [New, Established], UploadTotal -> Try({}, [NewAccountLimitReached])
	check = |standing, after|
		match standing {
			Established => Ok({})
			New if after.bytes() > NewAccountUploads.most_bytes => Err(NewAccountLimitReached)
			New => Ok({})
		}

	## Whether the user `uploader` is new at `now`: read from their welcome's
	## first message, in the directory as the disk holds it; unless the
	## directory or the welcome can't be read.
	load_standing! : UserId, Timestamp => Try([New, Established], [WelcomeUnreadable(Str)])
	load_standing! = |uploader, now| {
		directory = DirectoryStore.load_directory!({}) ? |_| WelcomeUnreadable("the chat's accounts could not be read")
		user = directory.users().user(uploader) ? |NoSuchUser| WelcomeUnreadable("no such user")
		match user.as_human() {
			Err(Agent(_)) => Ok(Established)
			Ok(_) if uploader == UserId.chat_owner => Ok(Established)
			Ok(human) => {
				welcomed = load_welcome!(directory, human)?
				Ok(NewAccountUploads.standing_at(welcomed, now))
			}
		}
	}
}

## The span from a moment back to the start of its first period.
first_period_back : Seconds
first_period_back = Seconds.of(0 - NewAccountUploads.first_period_seconds)

## The date of `human`'s welcome, the first message of their DM with the
## owner under `Welcome.topic`, or `NotWelcomed` when it has no transcript;
## unless it can't be read or decoded.
load_welcome! : Directory,
Users.Human => Try(
	[NotWelcomed, WelcomedAt(DateTime)],
	[WelcomeUnreadable(Str)],
)
load_welcome! = |directory, human| {
	key = welcome_key(directory, human)
	match TranscriptFiles.read_transcript!(key) {
		Err(fault) => Err(WelcomeUnreadable(FileFacts.fault_words(fault)))
		Ok(NoFile) => Ok(NotWelcomed)
		Ok(File(utf8)) =>
			match Transcript.decode(key.topic(), utf8) {
				Err(why) => Err(WelcomeUnreadable(TranscriptRefusal.words(why)))
				Ok(conversation) =>
					match conversation.messages().first() {
						Ok(first) => Ok(WelcomedAt(first.time()))
						Err(ListWasEmpty) => Ok(NotWelcomed)
					}
			}
	}
}

## The conversation that welcomed `human`: `Welcome.conversation_key`.
welcome_key : Directory, Users.Human -> ConversationKey
welcome_key = |directory, human| Welcome.conversation_key({ directory, human })

# ── tests
## The time `text` names, as a test writes it.
time_of : Str -> DateTime
time_of = |text| DateTime.from_str(text) ?? crash "NewAccountUploads' tests: a time"

## 2026-11-20T12:00:00Z.
noon : Timestamp
noon = Timestamp.at_second(1_763_640_000)

## A total of `bytes`, as its file would hold it.
total_of : U64 -> UploadTotal
total_of = |bytes| UploadTotal.from_file(File(bytes.to_str().to_utf8())) ?? crash "NewAccountUploads' tests: a total"

expect NewAccountUploads.most_bytes == 104_857_600
expect DateTime.from_timestamp(noon) == Ok(time_of("2025-11-20T12:00:00Z"))
# No welcome: established, whatever the clock.
expect NewAccountUploads.standing_at(NotWelcomed, noon) == Established
# Welcomed less than seven days ago: new, a second short of them too; seven
# days ago exactly, or before: established.
expect NewAccountUploads.standing_at(WelcomedAt(time_of("2025-11-20T11:59:59Z")), noon) == New
expect NewAccountUploads.standing_at(WelcomedAt(time_of("2025-11-13T12:00:01Z")), noon) == New
expect NewAccountUploads.standing_at(WelcomedAt(time_of("2025-11-13T12:00:00Z")), noon) == Established
expect NewAccountUploads.standing_at(WelcomedAt(time_of("2025-01-01T00:00:00Z")), noon) == Established
# A welcome dated ahead of the clock is new.
expect NewAccountUploads.standing_at(WelcomedAt(time_of("2025-11-21T00:00:00Z")), noon) == New
# A new account: a total landing exactly on 100 MiB passes, a byte more is
# refused; an established one may pass it.
expect NewAccountUploads.check(New, total_of(104_857_600)) == Ok({})
expect NewAccountUploads.check(New, total_of(104_857_601)) == Err(NewAccountLimitReached)
expect NewAccountUploads.check(New, total_of(0)) == Ok({})
expect NewAccountUploads.check(Established, total_of(104_857_601)) == Ok({})
expect NewAccountUploads.limit_words == "Upload limit reached — a new account may upload 100 MiB in its first 7 days."
