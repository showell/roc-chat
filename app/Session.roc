## **A SIGN-IN SESSION, AND HOW LONG IT LIVES** (the Roc chat's auth design,
## section 2): a browser signed in as a human. The cookie carries a random
## secret; the store keeps the secret's hash (the host hashes, and looks a
## session up by it), the human, the generation of the account it was
## started for (Principal.Generation), when it was created and when it was last seen. A record on
## disk rather than a signed cookie, so a session can be listed and ended:
## "log out everywhere" is real.
##
## **ONLY TWO WAYS IN:** `start`, which takes the sign-in flow's Admission
## (GitHubSignIn: an opaque value only the flow makes, once every step
## held), and `load`, which takes a SessionCodec.Line (an opaque value only
## the decoder makes, from a stored line). There is no constructor from a
## record, so no handler mints a session, an admin's or anyone's, without
## the flow or a line in the store.
##
## **ITS LIFETIME, CONSERVATIVE BY DEFAULT:**
## - **idle:** a session not seen for 24 hours is over;
## - **absolute:** a session is over 7 days after it was created, however
##   often it is used, so a stolen cookie is good for a week at most;
## - a time from the future (a clock that went back) is trusted for
##   nothing: the session is over, as OAuthState's check treats a state;
## - **last seen** is written at most once in 5 minutes, so a busy browser
##   is not a write a request; idle expiry can therefore come up to 5
##   minutes early, never late;
## - **its account, not its GitHub id:** a session admits only the account
##   it was started for (the same generation), so an account retired and made
##   again with the same GitHub id never inherits the old one's sessions.
## Only humans sign in: an agent or a bot acts through API keys. Pure.
import Cast
import GitHubSignIn
import Principal
import SessionCodec
import Stored

Session :: SessionCodec.Fields.{

	## How long a session may go unseen, in seconds: 24 hours.
	idle_secs : I64
	idle_secs = 86400

	## How long a session may live at all, in seconds: 7 days.
	absolute_secs : I64
	absolute_secs = 604800

	## How stale `last seen` may be before a request writes it again, in
	## seconds: 5 minutes.
	touch_secs : I64
	touch_secs = 300

	## A session's stored fields, as SessionCodec writes and reads them.
	Fields : SessionCodec.Fields

	## What a session is at a time.
	Liveness : [
		Live,
		IdleExpired,
		AbsoluteExpired,
	]

	## **A NEW SESSION**, created and seen when the flow admitted it: the
	## sign-in flow's end, and the only way a session begins.
	start : GitHubSignIn.Admission -> Session
	start = |admission| {
		a = admission.facts()
		Session.(
			{
				id: a.session.id,
				human: a.human,
				generation: a.generation,
				token_hash: a.session.token_hash,
				created: a.now,
				last_seen: a.now,
			},
		)
	}

	## **A SESSION AS ITS STORED LINE HOLDS IT**: the only way back from
	## the store (SessionCodec checked the line whole).
	load : SessionCodec.Line -> Session
	load = |line| Session.(line.fields())

	## The session's fields, to store.
	fields : Session -> Session.Fields
	fields = |Session.(s)| s

	## The session's public number.
	id : Session -> Principal.SessionId
	id = |Session.(s)| s.id

	## The human signed in.
	human : Session -> Principal.GitHubId
	human = |Session.(s)| s.human

	## **IS THE SESSION LIVE AT `now`?** The absolute limit is said first:
	## a session past both is `AbsoluteExpired`. A creation or a last
	## sight after `now` is `AbsoluteExpired` too: nothing is trusted from
	## a time not yet reached, nor at a `now` outside Stored's range (no
	## touch ever writes a time the store cannot hold). Each limit is live
	## before it and over from
	## it on. Reckoned in I128, so no `now` a host hands in, and no stored
	## time, overflows a difference.
	liveness : Session, I64 -> Session.Liveness
	liveness = |Session.(s), now| {
		age = now.to_i128() - s.created.to_i128()
		unseen = now.to_i128() - s.last_seen.to_i128()
		if now < 0 or now > Stored.max_time or age < 0 or unseen < 0 or age >= Session.absolute_secs.to_i128() {
			AbsoluteExpired
		} else if unseen >= Session.idle_secs.to_i128() {
			IdleExpired
		} else {
			Live
		}
	}

	## **A REQUEST ON THIS SESSION, AT `now`**: admitted as its human, as
	## the accounts say now, when it is live and the account it was started
	## for is still there (exactly one account holds the human's id, made
	## when the session's account was: one retired takes their sessions
	## with them, and one made again does not bring them back); with the
	## session to write back when `last seen` is `touch_secs` stale or more.
	admit : Session,
	{
		accounts : List(Principal),
		now : I64,
	} -> [
		Admitted({ principal : Principal, write : [Unchanged, Touched(Session)] }),
		Refused(
			[
				IdleExpired,
				AbsoluteExpired,
				NoSuchAccount,
			],
		),
	]
	admit = |session, { accounts, now }| {
		Session.(s) = session
		match session.liveness(now) {
			IdleExpired => Refused(IdleExpired)
			AbsoluteExpired => Refused(AbsoluteExpired)
			Live =>
				match Principal.holds(accounts, { id: Principal.Id.Human(s.human), generation: s.generation, human: s.generation }) {
					Err(_) => Refused(NoSuchAccount)
					Ok(Agent(_)) | Ok(Bot(_)) => crash "Session.admit: a human's id holds a human"
					Ok(Human(h)) =>
						{
							write = if now - s.last_seen >= Session.touch_secs Touched(
								Session.(
									{
										..s,
										last_seen: now,
									},
								),
							) else Unchanged
							Admitted({ principal: Principal.Human(h), write })
						}
				}
		}
	}

	## **LOG OUT EVERYWHERE**: of `sessions`, every one of `human`'s, the
	## one asking included, live or not; nobody else's.
	log_out_everywhere : List(Session), Principal.GitHubId -> List(Principal.SessionId)
	log_out_everywhere = |sessions, whose|
		List.keep_if(sessions, |s| s.human() == whose).map(Session.id)

	## **THE SWEEP**: of `sessions`, every one over at `now`, for the host
	## to delete.
	sweep : List(Session), I64 -> List(Principal.SessionId)
	sweep = |sessions, now|
		List.keep_if(sessions, |s| s.liveness(now) != Live).map(Session.id)

	is_eq : _
}

# ── tests

## The session a stored line holds, through the codec, the store's way in.
stored : Str -> Session
stored = |text|
	match SessionCodec.decode(Str.to_utf8(text)) {
		Ok(line) => Session.load(line)
		Err(_) => crash "stored: a test's session line decodes"
	}

## Session `n` of human `who` (whose account is generation 1), created at
## `at` and last seen at `seen`.
seen_line : { n : U64, who : U64, at : I64, seen : I64 } -> Session
seen_line = |{ n, who, at, seen }|
	stored("session v1 id=${n.to_str()} human=${who.to_str()} generation=1 token=${Str.repeat("01", 32)} created=${at.to_str()} seen=${seen.to_str()}\n")

## Session `n` of human `who`, created and seen at `at`.
opened : {
	n : U64,
	who : U64,
	at : I64,
} -> Session
opened = |
	{
		n,
		who,
		at,
	},
|
	seen_line({ n, who, at, seen: at })

# Created at 100000.
s1 : Session
s1 = opened({
	n: 1,
	who: 1,
	at: 100000,
})

day : I64
day = Session.idle_secs

week : I64
week = Session.absolute_secs

# ── THE LIVENESS TABLE
# Fresh, at each limit's edge, past both, and from the future.
expect s1.liveness(100000) == Live
expect s1.liveness(100000 + day - 1) == Live
expect s1.liveness(100000 + day) == IdleExpired
expect s1.liveness(100000 + week) == AbsoluteExpired
expect s1.liveness(99999) == AbsoluteExpired

## `s1`, last seen at `at`.
seen_at : I64 -> Session
seen_at = |at| seen_line({ n: 1, who: 1, at: 100000, seen: at })

# Used every day, it lives a week and not a second more.
expect seen_at(100000 + week - 10).liveness(100000 + week - 1) == Live
expect seen_at(100000 + week - 10).liveness(100000 + week) == AbsoluteExpired

# Idle a day from its last sight, not from its creation.
expect seen_at(105000).liveness(105000 + day - 1) == Live
expect seen_at(105000).liveness(105000 + day) == IdleExpired

# Seen in the future: over.
expect seen_at(105000).liveness(104999) == AbsoluteExpired

# **NO `now` OVERFLOWS** (round two's seventh): I64's ends against the
# earliest and latest stored times.
expect opened({ n: 1, who: 1, at: 0 }).liveness(9223372036854775807) == AbsoluteExpired
expect opened({ n: 1, who: 1, at: 253402300799 }).liveness(-9223372036854775808) == AbsoluteExpired
expect opened({ n: 1, who: 1, at: 0 }).liveness(-9223372036854775808) == AbsoluteExpired

# Loading: a line round-trips through the codec.
expect Session.load(
	match SessionCodec.decode(SessionCodec.encode(s1.fields())) {
		Ok(line) => line
		Err(_) => crash "a stored session decodes"
	},
)
	== s1

# ── ADMITTING A REQUEST
ann : Principal
ann = Principal.Human({
	id: Cast.gid(1),
	login: "ann",
	name: "Ann",
	role: Member,
	generation: Cast.gen(1),
})

bea : Principal
bea = Principal.Human({
	id: Cast.gid(2),
	login: "bea",
	name: "Bea",
	role: Member,
	generation: Cast.gen(1),
})

Admission : [
	Admitted({ principal : Principal.Id, write : [Unchanged, Touched(I64)] }),
	Refused(
		[
			IdleExpired,
			AbsoluteExpired,
			NoSuchAccount,
		],
	),
]

## The admission of `session` at `now` among `among`, the principal by id
## and a write by the last sight it writes.
admitted : Session, { among : List(Principal), now : I64 } -> Admission
admitted = |session, { among, now }|
	match session.admit({ accounts: among, now }) {
		Refused(why) => Refused(why)
		Admitted({ principal, write }) =>
			Admitted({
				principal: Principal.id(principal),
				write: match write {
					Unchanged => Unchanged
					Touched(s) => Touched(s.fields().last_seen)
				},
			})
	}

expect admitted(s1, { among: [ann, bea], now: 100000 }) == Admitted({
	principal: Principal.id(ann),
	write: Unchanged,
})
expect admitted(s1, { among: [ann, bea], now: 100299 }) == Admitted({
	principal: Principal.id(ann),
	write: Unchanged,
})
expect admitted(s1, { among: [ann, bea], now: 100300 }) == Admitted({
	principal: Principal.id(ann),
	write: Touched(100300),
})
expect admitted(s1, { among: [ann, bea], now: 100000 + day }) == Refused(IdleExpired)
expect admitted(
	seen_at(100000 + week - 1),
	{ among: [ann], now: 100000 + week },
) == Refused(AbsoluteExpired)
expect admitted(s1, { among: [ann], now: 99999 }) == Refused(AbsoluteExpired)

# Ann retired: her live session admits nobody.
expect admitted(s1, { among: [bea], now: 100000 }) == Refused(NoSuchAccount)

# The role is the accounts' now, not the one at sign-in.
expect
	match s1.admit({
		accounts: [
			Principal.Human({
				id: Cast.gid(1),
				login: "ann",
				name: "Ann",
				role: Admin,
				generation: Cast.gen(1),
			}),
		],
		now: 100000,
	}) {
		Admitted({ principal: Human(h), write: _ }) => h.role == Admin
		_ => Bool.False
	}

# **A DUPLICATE OR FORGED ACCOUNT FIRST** (round two's first): a copy of
# Ann claiming admin, before her or after: the session admits nobody, so
# no copy's role is ever taken.
ann_admin_copy : Principal
ann_admin_copy = Principal.Human({
	id: Cast.gid(1),
	login: "ann",
	name: "Ann",
	role: Admin,
	generation: Cast.gen(1),
})

expect admitted(s1, { among: [ann_admin_copy, ann, bea], now: 100000 }) == Refused(NoSuchAccount)
expect admitted(s1, { among: [ann, ann_admin_copy], now: 100000 }) == Refused(NoSuchAccount)

# **RE-CREATION AFTER RETIREMENT** (round two's fifth): Ann retired, then
# made again with her GitHub id at 200: her old session admits nobody.
ann_again : Principal
ann_again = Principal.Human({
	id: Cast.gid(1),
	login: "ann",
	name: "Ann",
	role: Member,
	generation: Cast.gen(2),
})

expect admitted(s1, { among: [ann_again, bea], now: 100000 }) == Refused(NoSuchAccount)

# ATTACK (round three's fifth): Ann made again in the same second her old
# account was (or under a clock that went back) is a new generation all the
# same, and her old session does not admit it.
ann_same_second : Principal
ann_same_second = Principal.Human({ id: Cast.gid(1), login: "ann", name: "Ann", role: Admin, generation: Cast.gen(3) })

expect admitted(s1, { among: [ann_same_second, bea], now: 100000 }) == Refused(NoSuchAccount)

# ATTACK (round three's second, its class): a session live near the end of
# the store's range, asked at a time past it, is never touched with a time
# the store cannot write.
late : Session
late = seen_line({ n: 1, who: 1, at: Stored.max_time - 10, seen: Stored.max_time - 10 })

expect admitted(late, { among: [ann], now: Stored.max_time + 100 }) == Refused(AbsoluteExpired)
expect admitted(late, { among: [ann], now: Stored.max_time }) == Admitted({ principal: Principal.id(ann), write: Unchanged })

# ── STARTING: only from the flow's admission
## GitHub id `who`, known at `now` through the flow's steps.
known_by : U64, I64 -> Try(GitHubSignIn.IdentityKnown, GitHubSignIn.Refusal)
known_by = |who, now| {
	nonce = Str.to_utf8("q7Zr2Lx9q7Zr2Lx9")
	started =
		match GitHubSignIn.Started.start({ nonce, now }) {
			Ok(s) => s
			Err(_) => crash "known_by: a 16-byte nonce starts"
		}
	back = GitHubSignIn.CameBack.came_back({ state: Signed(started.state()), answer: Code(Str.to_utf8("c0de")) })?
	checked = back.check({ cookie: Sent(nonce), now, nonce_use: FirstUse })?
	checked.identify(Identified({ id: who, login: Str.to_utf8("ann") }))
}

## A sign-in by GitHub id `who` at `now`, through every step of the flow,
## to its admission's session.
signed_in : { who : U64, among : List(Principal), now : I64 } -> Session
signed_in = |{ who, among, now }|
	match known_by(who, now) {
		Ok(k) =>
			match k.resolve({
				accounts: among,
				settings: { first_admin: Unnamed, barred: [], next_generation: Cast.gen(9) },
				session: {
					id: Cast.sid(9),
					token_hash: Cast.token(1),
				},
				now,
			}) {
				SignedIn(s) => Session.start(s.admission)
				_ => crash "signed_in: the human has an account"
			}
		Err(_) => crash "signed_in: the flow holds"
	}

# A flow's session: its human, the account it was made for, created and
# seen at the sign-in; it admits that account and no other made since.
flowed : Session
flowed = signed_in({ who: 1, among: [ann, bea], now: 100000 })

expect flowed.fields() == { ..s1.fields(), id: Cast.sid(9) }
expect admitted(flowed, { among: [ann], now: 100000 }) == Admitted({ principal: Principal.id(ann), write: Unchanged })
expect admitted(flowed, { among: [ann_again], now: 100000 }) == Refused(NoSuchAccount)

# ── LOG OUT EVERYWHERE, AND THE SWEEP
# Ann's sessions 1 and 2 (2 a day older, idle by 100000), Bea's 3.
sessions : List(Session)
sessions = [
	s1,
	opened({
		n: 2,
		who: 1,
		at: 100000 - day,
	}),
	opened({
		n: 3,
		who: 2,
		at: 100000,
	}),
]

expect Session.log_out_everywhere(sessions, Cast.gid(1)) == [Cast.sid(1), Cast.sid(2)]
expect Session.log_out_everywhere(sessions, Cast.gid(2)) == [Cast.sid(3)]
expect Session.log_out_everywhere(sessions, Cast.gid(9)) == []
expect Session.log_out_everywhere([], Cast.gid(1)) == []
expect Session.sweep(sessions, 100000) == [Cast.sid(2)]
expect Session.sweep(sessions, 100000 + day - 1) == [Cast.sid(2)]
expect Session.sweep(sessions, 100000 + day) == [
	Cast.sid(1),
	Cast.sid(2),
	Cast.sid(3),
]
expect Session.sweep(sessions, 99999) == [Cast.sid(1), Cast.sid(3)]
expect Session.sweep([], 100000) == []
