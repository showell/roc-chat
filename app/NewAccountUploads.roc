## This module holds the tighter upload limit on new accounts: a human in
## their first `first_days` days may upload at most `most_mib` MiB in all,
## counted in the same lifetime total as every upload (`UploadTotal`).
## Sign-up by GitHub is open to anyone, so without it a fresh account could
## spend its whole 1 GiB allowance on its first day, and a few of them fill
## the disk. Past it, an upload is the allowance's own refusal, a 403
## (`UploadRoute`), saying the limit is a new account's. The days are few
## (Steve, 2026-11-20: "We can reduce the trial period to two days. I'm on
## it everyday."): the chat's owner reads it daily, and friction is kept
## low.
##
## **WHEN AN ACCOUNT IS NEW.** A human is new for `first_days` days from
## when they joined, as their `joined` file says (`JoinedFiles`), written
## when an invited human first joins or a GitHub sign-up gets its name. A
## human with no `joined` file is established: every account made before
## the file was, the first start's owner, and one the server's owner made
## by hand; so is every agent (made by the admin alone,
## `Agents.agent_keeper`), and agents have none. A `joined` file that can't
## be read refuses the upload (`UploadRoute`'s 500), never reads as
## established.
import JoinedFiles
import Seconds
import Timestamp
import UploadTotal
import UserId

NewAccountUploads :: [].{

	## How many days an account is new for.
	first_days : I64
	first_days = 2

	## How long an account is new for, from when it joined, in seconds.
	first_period_seconds : I128
	first_period_seconds = 2 * 24 * 60 * 60

	## The most a new account uploads, in MiB, as the refusal words it.
	most_mib : U64
	most_mib = 100

	## The most bytes a new account uploads in all.
	most_bytes : U64
	most_bytes = NewAccountUploads.most_mib * 1024 * 1024

	## What an upload past the new account's limit says.
	limit_words : Str
	limit_words = "Upload limit reached — a new account may upload ${NewAccountUploads.most_mib.to_str()} MiB in its first ${NewAccountUploads.first_days.to_str()} days."

	## Whether an account is new at `now`, from when it joined
	## (`JoinedAt`), or `NotJoined` for an account with no `joined` file:
	## new while it joined less than the first period ago, or ahead of the
	## clock.
	standing_at : [NotJoined, JoinedAt(Timestamp)], Timestamp -> [New, Established]
	standing_at = |joined, now|
		match joined {
			NotJoined => Established
			JoinedAt(at) =>
				if now.seconds_since(at).is_at_least(first_period) {
					Established
				} else {
					New
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

	## Whether the user `uploader` is new at `now`, from their `joined`
	## file; unless it can't be read, in words.
	load_standing! : UserId, Timestamp => Try([New, Established], [JoinedUnreadable(Str)])
	load_standing! = |uploader, now|
		match JoinedFiles.read_joined!(uploader) {
			Ok(NoFile) => Ok(Established)
			Ok(Joined(at)) => Ok(NewAccountUploads.standing_at(JoinedAt(at), now))
			Err(Damaged) => Err(JoinedUnreadable("its joined file holds no time"))
			Err(NotUtf8) => Err(JoinedUnreadable("its joined file is not UTF-8"))
			Err(PathRefused) => Err(JoinedUnreadable("its joined file's path was refused"))
			Err(Failed) => Err(JoinedUnreadable("its joined file could not be read"))
		}
}

## The first period, as a span.
first_period : Seconds
first_period = Seconds.of(NewAccountUploads.first_period_seconds)

# ── tests
noon : Timestamp
noon = Timestamp.at_second(1_763_640_000)

## The standing at noon of an account that joined `ago` seconds before.
joined_ago : I64 -> [New, Established]
joined_ago = |ago| {
	at = Timestamp.at_second(1_763_640_000 - ago)
	NewAccountUploads.standing_at(JoinedAt(at), noon)
}

## Two days, in seconds.
two_days : I64
two_days = 2 * day

## A day, in seconds.
day : I64
day = 24 * 60 * 60

## A total of `bytes`, as its file would hold it.
total_of : U64 -> UploadTotal
total_of = |bytes| UploadTotal.from_file(File(bytes.to_str().to_utf8())) ?? crash "NewAccountUploads' tests: a total"

expect NewAccountUploads.most_bytes == 104_857_600
# No `joined` file: established, whatever the clock.
expect NewAccountUploads.standing_at(NotJoined, noon) == Established
# Joined less than two days ago: new, a second short of them too; two days
# ago exactly, or before: established.
expect [0, 60, two_days - 1].all(|ago| joined_ago(ago) == New)
expect [two_days, two_days + 1, 365 * day].all(|ago| joined_ago(ago) == Established)
# Joined ahead of the clock is new.
expect joined_ago(-3600) == New
# A new account: a total landing exactly on 100 MiB passes, a byte more is
# refused; an established one may pass it.
expect NewAccountUploads.check(New, total_of(104_857_600)) == Ok({})
expect NewAccountUploads.check(New, total_of(104_857_601)) == Err(NewAccountLimitReached)
expect NewAccountUploads.check(New, total_of(0)) == Ok({})
expect NewAccountUploads.check(Established, total_of(104_857_601)) == Ok({})
expect NewAccountUploads.limit_words == "Upload limit reached — a new account may upload 100 MiB in its first 2 days."
