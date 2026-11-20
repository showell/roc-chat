## A human invite is how someone joins the chat. A human signed in by their
## own session invites them by a name, which a new account holds at once,
## and is shown a link holding the invite's one-time code once; the invited
## human redeems the code, with no other credential, choosing their name and
## their password as they do, and is signed in. The chat keeps the code's hash, never the code. An
## invite lives seven days (`lifetime_seconds`) and
## redeems once. Inviting someone again is a new invite for the same
## account (`HumanInvites.reinvite`), and redeeming it sets a new password.
##
## `InviteFiles` keeps each fact in a file of its own, in the invited
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
				.map_ok(|serial_number| HumanInvite.Id.(serial_number))
				.map_err(|NotASerialNumber| NotAnInviteId)

		## The number after the highest of `given`, 1 for none.
		next_after : List(HumanInvite.Id) -> Try(HumanInvite.Id, [Full])
		next_after = |given|
			SerialNumber.next_after(given.map(|HumanInvite.Id.(n)| n))
				.map_ok(|serial_number| HumanInvite.Id.(serial_number))

		to_str : HumanInvite.Id -> Str
		to_str = |HumanInvite.Id.(serial_number)| serial_number.to_str()

		is_eq : _
	}

	## Whether an invite may still be redeemed: `Live` until it is redeemed
	## (`Spent`).
	State : [Live, Spent]

	## An invite's facts, all but its number, as plain values: what a store
	## keeps of it.
	Facts : {
		created : Timestamp,
		expires : Timestamp,
		state : HumanInvite.State,
		by : UserId,
		hash : SecretHash,
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

	## Whether the invite is live and past its expiry at `now`: it was never
	## redeemed, and never will be.
	is_expired : HumanInvite, Timestamp -> Bool
	is_expired = |HumanInvite.(invite), now|
		match invite.state {
			Live => now.seconds_since(invite.expires).to_i128() >= 0
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

	## When the invite was made.
	made_at : HumanInvite -> Timestamp
	made_at = |HumanInvite.(invite)| invite.created

	expires : HumanInvite -> Timestamp
	expires = |HumanInvite.(invite)| invite.expires

	## Who made the invite.
	invite_maker : HumanInvite -> UserId
	invite_maker = |HumanInvite.(invite)| invite.by

	## The invite's facts, all but its number.
	to_facts : HumanInvite -> HumanInvite.Facts
	to_facts = |HumanInvite.(invite)| {
		created: invite.created,
		expires: invite.expires,
		state: invite.state,
		by: invite.by,
		hash: invite.hash,
	}

	## The invite numbered `id` whose facts are `facts`.
	from_facts : HumanInvite.Id, HumanInvite.Facts -> HumanInvite
	from_facts = |number, facts|
		HumanInvite.(
			{
				id: number,
				hash: facts.hash,
				created: facts.created,
				expires: facts.expires,
				state: facts.state,
				by: facts.by,
			},
		)

	is_eq : _
}
