## These are the tests of `AgentKey` and `AgentInvite`: a key admits only
## its own agent, by the hash of its secret, while active and before its
## expiry; an invite redeems once, while live and before its expiry; each
## is revoked once; and each is kept as its files and read back. A key's
## door into `SignedIn` is tested here too.
import AgentInvite
import AgentKey
import KeyScope
import Seconds
import SecretHash
import SignedIn
import Sample
import Timestamp
import UserId
import Users

AgentKeySpec :: [].{}

## The hash whose every byte is `b`.
hash_of : U8 -> SecretHash
hash_of = |b| SecretHash.of_digest(List.repeat(b, 32))

## A key's number, `n`.
key_id : Str -> AgentKey.Id
key_id = |n| AgentKey.Id.from_str(n) ?? crash "AgentKeySpec: a key's number"

## An invite's number, `n`.
invite_id : Str -> AgentInvite.Id
invite_id = |n| AgentInvite.Id.from_str(n) ?? crash "AgentKeySpec: an invite's number"

## When the tests' keys and invites are made.
made_at : Timestamp
made_at = Timestamp.at_second(1_761_600_000)

## Key 1, its hash every byte 0x5a, made at `made_at` for every reach.
key_one : AgentKey
key_one = AgentKey.mint({
	id: key_id("1"),
	hash: hash_of(0x5a),
	now: made_at,
	scope: KeyScope.everywhere,
})

## Key 2, its hash every byte 0x6b, reading only.
key_two : AgentKey
key_two = AgentKey.mint({
	id: key_id("2"),
	hash: hash_of(0x6b),
	now: made_at,
	scope: KeyScope.of({ read: Everywhere, post: Off }),
})

## What `admit` makes of CC, holding `keys`, sending a secret whose hash is
## `hash` at `now`: the admitted agent's name and scope, or why not.
admitted_by : {
	keys : List(AgentKey),
	hash : SecretHash,
	now : Timestamp,
} -> Try((Str, KeyScope), _)
admitted_by = |{ keys, hash, now }|
	AgentKey.admit({
		user: Sample.user("CC"),
		keys,
		hash,
		now,
	})
		.map_ok(|admitted| (admitted.user().name().to_str(), admitted.scope()))

# A key admits its agent with its own scope, by its hash among several.
expect admitted_by({
	keys: [key_one, key_two],
	hash: hash_of(0x5a),
	now: made_at,
}) == Ok(("CC", KeyScope.everywhere))
expect admitted_by({
	keys: [key_one, key_two],
	hash: hash_of(0x6b),
	now: made_at,
}) == Ok(("CC", KeyScope.of({ read: Everywhere, post: Off })))
# No key has the hash: a wrong secret, or a key of no agent.
expect admitted_by({
	keys: [key_one, key_two],
	hash: hash_of(0x5b),
	now: made_at,
}) == Err(NoSuchKey)
expect admitted_by({
	keys: [],
	hash: hash_of(0x5a),
	now: made_at,
}) == Err(NoSuchKey)
# A revoked key admits no one; the other key still does.
expect {
	revoked = key_one.revoke() ?? crash "AgentKeySpec: an active key revokes"
	admitted_by({
		keys: [revoked, key_two],
		hash: hash_of(0x5a),
		now: made_at,
	}) == Err(Revoked)
		and admitted_by({
			keys: [revoked, key_two],
			hash: hash_of(0x6b),
			now: made_at,
		}).is_ok()
}
# A key's life: from its making, to a second before its expiry; refused at
# its expiry, past it, and before its making.
expect AgentKey.lifetime_seconds == Seconds.of(31_536_000)
expect key_one.expires() == made_at.plus(Seconds.of(31_536_000))
expect
	[made_at, made_at.plus(Seconds.of(31_535_999))].all(
		|now| admitted_by({
			keys: [key_one],
			hash: hash_of(0x5a),
			now,
		}).is_ok(),
	)
expect
	[
		made_at.plus(Seconds.of(31_536_000)),
		made_at.plus(Seconds.of(31_536_001)),
		made_at.plus(Seconds.of(-1)),
	].all(
		|now| admitted_by({
			keys: [key_one],
			hash: hash_of(0x5a),
			now,
		}) == Err(Expired),
	)
# A human holds no key, whatever keys are handed: only an agent is admitted.
expect AgentKey.admit({
	user: Sample.steve,
	keys: [key_one],
	hash: hash_of(0x5a),
	now: made_at,
}).map_ok(|_| {}) == Err(NotAnAgent)
# A key revokes once.
expect key_one.state() == Active
expect key_one.revoke().map_ok(AgentKey.state) == Ok(Revoked)
expect
	(key_one.revoke() ?? crash "AgentKeySpec: an active key revokes").revoke()
		== Err(AlreadyRevoked)

# A key admitted signs its agent in by key, with its scope, and never as a
# human in session; the door that stands in for sessions does.
expect {
	admitted = AgentKey.admit({
		user: Sample.user("CC"),
		keys: [key_two],
		hash: hash_of(0x6b),
		now: made_at,
	}) ?? crash "AgentKeySpec: key 2 admits CC"
	acting = SignedIn.by_api_key(admitted)
	acting.user() == Sample.user("CC")
		and acting.credential() == ApiKey(KeyScope.of({ read: Everywhere, post: Off }))
		and acting.human_in_session() == Err(ByApiKey)
}
expect
	SignedIn.dangerously_assume(Sample.steve).human_in_session().map_ok(Users.Human.id)
		== Ok(UserId.chat_owner)

# A key's files, exactly, and read back as the same key.
expect
	key_two.to_files()
		== {
			created: "1761600000".to_utf8(),
			expires: "1793136000".to_utf8(),
			state: "active".to_utf8(),
			read: "everywhere".to_utf8(),
			post: "off".to_utf8(),
			hash: "6b".repeat(32).to_utf8(),
		}
expect AgentKey.from_files(key_id("2"), key_two.to_files()) == Ok(key_two)
expect {
	revoked = key_one.revoke() ?? crash "AgentKeySpec: an active key revokes"
	revoked.to_files().state == "revoked".to_utf8() and AgentKey.from_files(
		key_id("1"),
		revoked.to_files(),
	) == Ok(revoked)
}
# Each fact that is no fact, refused by its file's name.
expect {
	files = key_one.to_files()
	[
		({ ..files, created: "-1".to_utf8() }, "created"),
		({ ..files, expires: "soon".to_utf8() }, "expires"),
		({ ..files, state: "Active".to_utf8() }, "state"),
		({ ..files, read: "on".to_utf8() }, "read"),
		({ ..files, post: "".to_utf8() }, "post"),
		({ ..files, hash: "5a".repeat(31).to_utf8() }, "hash"),
	].all(|(bad, name)| AgentKey.from_files(key_id("1"), bad) == Err(BadFact(name)))
}
# A key's number: one spelling, the next after the highest.
expect key_id("7").to_str() == "7"
expect AgentKey.Id.from_str("07") == Err(NotAKeyId)
expect AgentKey.Id.next_after([key_id("1"), key_id("3")]) == Ok(key_id("4"))
expect AgentKey.Id.next_after([]) == Ok(key_id("1"))

## Invite 1, its code's hash every byte 0x7c, made at `made_at`, posting
## nothing.
invite_one : AgentInvite
invite_one = AgentInvite.make({
	id: invite_id("1"),
	hash: hash_of(0x7c),
	now: made_at,
	scope: KeyScope.of({ read: Everywhere, post: Off }),
})

## Invite 2, its code's hash every byte 0x8d, for every reach.
invite_two : AgentInvite
invite_two = AgentInvite.make({
	id: invite_id("2"),
	hash: hash_of(0x8d),
	now: made_at,
	scope: KeyScope.everywhere,
})

## What redeeming the code whose hash is `hash` among `invites` at `now`
## makes: the spent invite's number, state and scope, or why not.
redeemed_by : {
	invites : List(AgentInvite),
	hash : SecretHash,
	now : Timestamp,
} -> Try((Str, AgentInvite.State, KeyScope), _)
redeemed_by = |{ invites, hash, now }|
	AgentInvite.redeem({ invites, hash, now }).map_ok(
		|spent| (spent.id().to_str(), spent.state(), spent.scope()),
	)

# A live invite redeems, by its hash among several, spent, with its scope.
expect redeemed_by({
	invites: [invite_one, invite_two],
	hash: hash_of(0x7c),
	now: made_at,
}) == Ok((
	"1",
	Spent,
	KeyScope.of({ read: Everywhere, post: Off }),
))
expect redeemed_by({
	invites: [invite_one, invite_two],
	hash: hash_of(0x8d),
	now: made_at,
}) == Ok(("2", Spent, KeyScope.everywhere))
# A wrong code redeems nothing.
expect redeemed_by({
	invites: [invite_one, invite_two],
	hash: hash_of(0x7d),
	now: made_at,
}) == Err(NoSuchInvite)
# An invite redeems once: spent, it is refused.
expect {
	spent = AgentInvite.redeem({
		invites: [invite_one],
		hash: hash_of(0x7c),
		now: made_at,
	}) ?? crash "AgentKeySpec: invite 1 redeems"
	AgentInvite.redeem({
		invites: [spent],
		hash: hash_of(0x7c),
		now: made_at,
	}).map_ok(|_| {}) == Err(Spent)
}
# Its life: ten minutes from its making, a second short of its expiry
# included; refused at its expiry, past it, and before its making.
expect AgentInvite.lifetime_seconds == Seconds.of(600)
expect invite_one.expires() == made_at.plus(Seconds.of(600))
expect [made_at, made_at.plus(Seconds.of(599))].all(
	|now| redeemed_by({
		invites: [invite_one],
		hash: hash_of(0x7c),
		now,
	}).is_ok(),
)
expect [
	made_at.plus(Seconds.of(600)),
	made_at.plus(Seconds.of(601)),
	made_at.plus(Seconds.of(-1)),
].all(
	|now| redeemed_by({
		invites: [invite_one],
		hash: hash_of(0x7c),
		now,
	}) == Err(Expired),
)
# A live invite revokes, and then redeems nothing; a spent one doesn't
# revoke, nor one already revoked.
expect {
	revoked = invite_one.revoke() ?? crash "AgentKeySpec: a live invite revokes"
	revoked.state() == Revoked
		and AgentInvite.redeem({
			invites: [revoked],
			hash: hash_of(0x7c),
			now: made_at,
		}).map_ok(|_| {}) == Err(Revoked)
		and revoked.revoke().map_ok(|_| {}) == Err(AlreadyRevoked)
}
expect {
	spent = AgentInvite.redeem({
		invites: [invite_one],
		hash: hash_of(0x7c),
		now: made_at,
	}) ?? crash "AgentKeySpec: invite 1 redeems"
	spent.revoke().map_ok(|_| {}) == Err(Spent)
}
# An invite's files, exactly, and read back; each state's word.
expect
	invite_one.to_files()
		== {
			created: "1761600000".to_utf8(),
			expires: "1761600600".to_utf8(),
			state: "live".to_utf8(),
			read: "everywhere".to_utf8(),
			post: "off".to_utf8(),
			hash: "7c".repeat(32).to_utf8(),
		}
expect AgentInvite.from_files(invite_id("1"), invite_one.to_files()) == Ok(invite_one)
expect {
	spent = AgentInvite.redeem({
		invites: [invite_one],
		hash: hash_of(0x7c),
		now: made_at,
	}) ?? crash "AgentKeySpec: invite 1 redeems"
	revoked = invite_two.revoke() ?? crash "AgentKeySpec: a live invite revokes"
	spent.to_files().state == "spent".to_utf8()
		and revoked.to_files().state == "revoked".to_utf8()
		and AgentInvite.from_files(invite_id("1"), spent.to_files()) == Ok(spent)
		and AgentInvite.from_files(invite_id("2"), revoked.to_files()) == Ok(revoked)
}
expect {
	files = invite_one.to_files()
	[
		({ ..files, created: "x".to_utf8() }, "created"),
		({ ..files, expires: "".to_utf8() }, "expires"),
		({ ..files, state: "used".to_utf8() }, "state"),
		({ ..files, read: "off off".to_utf8() }, "read"),
		({ ..files, post: "On".to_utf8() }, "post"),
		({ ..files, hash: "zz".repeat(32).to_utf8() }, "hash"),
	].all(|(bad, name)| AgentInvite.from_files(invite_id("1"), bad) == Err(BadFact(name)))
}
expect AgentInvite.Id.from_str("0") == Err(NotAnInviteId)
expect AgentInvite.Id.next_after([invite_id("2")]) == Ok(invite_id("3"))
