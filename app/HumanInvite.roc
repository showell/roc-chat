## A human invite is how someone joins the chat. A human signed in by their
## own session invites them by a name, which a new account holds at once,
## and is shown a link holding the invite's one-time code once; the invited
## human redeems the code, with no other credential, choosing their name and
## their password as they do, and is signed in. The chat keeps the code's hash, never the code. An
## invite lives seven days (`lifetime_seconds`) and
## redeems once. Inviting someone again is a new invite for the same
## account (`HumanInvites.reinvite`), and redeeming it sets a new password.
##
## `FileSystem` keeps each fact in a file of its own, in the invited
## human's folder under `human-invites/<number>/`: `created` and `expires`
## (seconds since the epoch), `state` (`live` or `spent`), `by` (the id of
## the human who made it, the inviter or the admin inviting them again), and
## `hash` (the code's hash), written last.
##
## Redeeming one is two steps: `find_redeemable` finds the invite a code's
## hash names, open at that moment, and `redeem` spends it for its human,
## once the caller has settled their name. It ends in an `Admission`, which
## only `redeem` makes, and
## which `SignInRoute.start_session_by_invite!` takes to sign the human in:
## no other route mints a session without a password checked or GitHub's word
## (`GitHubSignIn`). This module
## is a trust boundary with `SignedIn`, `AgentKey` and `AgentInvite`: an
## invite's code is a credential for exactly one human's password.
import FactFile
import Seconds
import SecretHash
import SerialNumber
import Timestamp
import UserId
import Users

HumanInvite :: {
	id : HumanInvite.Id,
	hash : SecretHash,
	created : Timestamp,
	expires : Timestamp,
	state : HumanInvite.State,
	by : UserId,
}.{

	## An invite's number among its human's invites (`SerialNumber`).
	Id :: U32.{

		## The number `text` spells, as a folder's name carries it.
		from_str : Str -> Try(HumanInvite.Id, [NotAnInviteId])
		from_str = |text|
			SerialNumber.from_str(text)
				.map_ok(|n| HumanInvite.Id.(n))
				.map_err(|NotASerialNumber| NotAnInviteId)

		## The number after the highest of `given`, 1 for none.
		next_after : List(HumanInvite.Id) -> Try(HumanInvite.Id, [Full])
		next_after = |given|
			SerialNumber.next_after(given.map(|HumanInvite.Id.(n)| n))
				.map_ok(|n| HumanInvite.Id.(n))

		to_str : HumanInvite.Id -> Str
		to_str = |HumanInvite.Id.(n)| n.to_str()

		is_eq : _
	}

	## Whether an invite may still be redeemed: `Live` until it is redeemed
	## (`Spent`).
	State : [Live, Spent]

	## An invite's facts as their files hold them, one file each.
	Files : {
		created : List(U8),
		expires : List(U8),
		state : List(U8),
		by : List(U8),
		hash : List(U8),
	}

	## How long an invite lives: seven days.
	lifetime_seconds : Seconds
	lifetime_seconds = Seconds.of(7 * 24 * 60 * 60)

	## A new invite, made by `by`, live from `now` for `lifetime_seconds`,
	## its code's hash `hash`.
	make : {
		id : HumanInvite.Id,
		hash : SecretHash,
		now : Timestamp,
		by : UserId,
	} -> HumanInvite
	make = |{ id, hash, now, by }|
		HumanInvite.(
			{
				id,
				hash,
				created: now,
				expires: now.plus(HumanInvite.lifetime_seconds),
				state: Live,
				by,
			},
		)

	## Whether the invite may be redeemed at `now`: live, made by then, and
	## not yet expired.
	is_open : HumanInvite, Timestamp -> Bool
	is_open = |HumanInvite.(invite), now|
		match invite.state {
			Live => now.is_during({ from: invite.created, until: invite.expires })
			Spent => Bool.False
		}

	## The invite among `invites` whose code's hash is `hash`, open for
	## redemption at `now`. Refused when none has the hash (`NoSuchInvite`),
	## when it is spent (`Spent`), or when `now` is at or past its expiry, or
	## before its making (`Expired`).
	find_redeemable : List(HumanInvite),
	{ hash : SecretHash, now : Timestamp } -> Try(
		HumanInvite.Redeemable,
		[NoSuchInvite, Spent, Expired],
	)
	find_redeemable = |invites, { hash, now }|
		match invites.find_first(|HumanInvite.(invite)| invite.hash == hash) {
			Err(NotFound) => Err(NoSuchInvite)
			Ok(HumanInvite.(invite)) => {
				lifetime = { from: invite.created, until: invite.expires }
				match invite.state {
					Spent => Err(Spent)
					Live if !now.is_during(lifetime) => Err(Expired)
					Live => Ok(HumanInvite.Redeemable.(HumanInvite.(invite)))
				}
			}
		}

	## An invite `find_redeemable` found open. Only it makes one.
	Redeemable :: HumanInvite.{}

	## The redeemable invite spent, and `human` admitted: the human among
	## whose invites it was found, as named once they chose their name.
	redeem : HumanInvite.Redeemable,
	Users.Human -> {
		spent : HumanInvite,
		admission : HumanInvite.Admission,
	}
	redeem = |HumanInvite.Redeemable.(HumanInvite.(invite)), human| {
		spent: HumanInvite.({ ..invite, state: Spent }),
		admission: HumanInvite.Admission.(human),
	}

	## A human an invite's redemption admitted. Only `redeem` makes one.
	Admission :: Users.Human.{

		## The human it admits.
		human : HumanInvite.Admission -> Users.Human
		human = |HumanInvite.Admission.(admitted)| admitted
	}

	id : HumanInvite -> HumanInvite.Id
	id = |HumanInvite.(invite)| invite.id

	state : HumanInvite -> HumanInvite.State
	state = |HumanInvite.(invite)| invite.state

	expires : HumanInvite -> Timestamp
	expires = |HumanInvite.(invite)| invite.expires

	## Who made the invite.
	by : HumanInvite -> UserId
	by = |HumanInvite.(invite)| invite.by

	## The invite's facts as their files keep them.
	to_files : HumanInvite -> HumanInvite.Files
	to_files = |HumanInvite.(invite)| {
		created: invite.created.to_file(),
		expires: invite.expires.to_file(),
		state: state_to_file(invite.state),
		by: invite.by.to_str().to_utf8(),
		hash: invite.hash.to_file(),
	}

	## The invite numbered `id` whose facts `files` hold; unless one of them
	## holds no such fact (`BadFact`, naming the file).
	from_files : HumanInvite.Id, HumanInvite.Files -> Try(HumanInvite, [BadFact(Str)])
	from_files = |number, files| {
		made_at = Timestamp.from_file(files.created) ? |_| BadFact("created")
		ends_at = Timestamp.from_file(files.expires) ? |_| BadFact("expires")
		held_state = state_from_file(files.state) ? |_| BadFact("state")
		maker = user_id_from_file(files.by) ? |_| BadFact("by")
		hash = SecretHash.from_file(files.hash) ? |_| BadFact("hash")
		Ok(
			HumanInvite.(
				{
					id: number,
					hash,
					created: made_at,
					expires: ends_at,
					state: held_state,
					by: maker,
				},
			),
		)
	}

	is_eq : _
}

state_to_file : HumanInvite.State -> List(U8)
state_to_file = |state|
	match state {
		Live => "live".to_utf8()
		Spent => "spent".to_utf8()
	}

state_from_file : List(U8) -> Try(HumanInvite.State, [NotAState])
state_from_file = |bytes| {
	word = FactFile.word_from_file(bytes)
	if word == "live".to_utf8() {
		Ok(Live)
	} else if word == "spent".to_utf8() {
		Ok(Spent)
	} else {
		Err(NotAState)
	}
}

## The user's id a fact file holds, its digits.
user_id_from_file : List(U8) -> Try(UserId, [NotAUserId])
user_id_from_file = |bytes|
	match Str.from_utf8(FactFile.word_from_file(bytes)) {
		Ok(digits) => UserId.from_str(digits)
		Err(_) => Err(NotAUserId)
	}
