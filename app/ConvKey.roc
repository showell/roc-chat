## **THE CHAT'S API KEYS** (the Roc chat's auth design, sections 3 and 10):
## ApiKey's generic core, at the chat's resource. A chat key is
## `ApiKey.Key(ConvAccess.Conv, ConvAccess.ConvId)`, so it decides only on a
## ConvAccess.Conv, an opaque conversation only ConvAccess makes, whose
## visibility and owners come from its elections and the accounts: a
## handler cannot hand a chat key a resource it made public itself, or any
## other type with a `resource` method (it does not compile). The chat
## issues, loads, stores and decides its keys here, and nowhere else. Pure.
import Access
import ApiKey
import Cast
import ConvAccess
import ConvCodec
import KeyCodec
import Principal
import Session
import SessionCodec
import Stored

ConvKey := [].{

	## A chat key: over conversations, by their ids.
	Key : ApiKey.Key(ConvAccess.Conv, ConvAccess.ConvId)

	## **WHAT THE STORE KEEPS OF A CHAT KEY**, the key store's entry: the key (when it was made is
	## its record's), and the hash the host looks it up by.
	Entry : {
		key : ConvKey.Key,
		hash : Stored.SecretHash,
	}

	## A new chat key, from a grant (ApiKey.may_grant: a live session's,
	## for its own principals).
	issue : ApiKey.Grant(ConvAccess.Conv, ConvAccess.ConvId),
	{ key : Principal.KeyId, expires : I64 } -> Try(
		ConvKey.Key,
		[Refused(ApiKey.GrantRefusal)],
	)
	issue = |grant, made| ApiKey.Key.issue(grant, made)

	## The entry's line (KeyCodec), a conversation by its number.
	encode : ConvKey.Entry -> List(U8)
	encode = |{ key, hash }|
		KeyCodec.encode({ record: key.record(), hash }, ConvAccess.ConvId.to_u64)

	## The chat key a stored line holds: the one way back from the store.
	decode : List(U8) -> Try(ConvKey.Entry, _)
	decode = |raw| {
		line = KeyCodec.decode(raw, ConvAccess.ConvId.from_u64)?
		entry = line.entry()
		Ok({ key: ApiKey.Key.load(line), hash: entry.hash })
	}

	## **MAY THIS CHAT KEY READ OR POST IN THIS CONVERSATION, NOW?**
	## Access's decision, on the conversation as ConvAccess makes it from
	## the accounts.
	decide : ConvKey.Key,
	{
		accounts : List(Principal),
		action : [Read(ConvAccess.Conv), Post(ConvAccess.Conv)],
		now : I64,
	} -> ApiKey.Verdict
	decide = |key, request| Access.decide(key, request)
}

# ── tests
cid : U64 -> ConvAccess.ConvId
cid = |n|
	match ConvAccess.ConvId.from_u64(n) {
		Ok(id) => id
		Err(NotAnId) => crash "cid: a test's conversation id is not 0"
	}

## A test's human, its account of generation 1.
human : U64, { name : Str, role : Principal.Role } -> Principal
human = |n, { name, role }|
	Principal.Human({
		id: Cast.gid(n),
		login: "h${n.to_str()}",
		name,
		role,
		generation: Cast.gen(1),
	})

# The cast: Ann and Bea, members; Boss, an admin; Bea owns BeaAgent,
# DeeAgent and BeaBot.
ann : Principal
ann = human(1, { name: "Ann", role: Member })

bea : Principal
bea = human(2, { name: "Bea", role: Member })

boss : Principal
boss = human(3, { name: "Boss", role: Admin })

bea_agent : Principal
bea_agent = Principal.Agent({
	id: Cast.aid(2),
	name: "BeaAgent",
	owner: Cast.gid(2),
	generation: Cast.gen(1),
})

dee_agent : Principal
dee_agent = Principal.Agent({
	id: Cast.aid(4),
	name: "DeeAgent",
	owner: Cast.gid(2),
	generation: Cast.gen(1),
})

bea_bot : Principal
bea_bot = Principal.Bot({
	id: Cast.aid(5),
	name: "BeaBot",
	owner: Cast.gid(2),
	generation: Cast.gen(1),
})

accounts : List(Principal)
accounts = [
	ann,
	bea,
	boss,
	bea_agent,
	dee_agent,
	bea_bot,
]

## A copy of BeaAgent claiming Ann as owner, FIRST in the accounts.
forged : List(Principal)
forged = List.prepend(
	accounts,
	Principal.Agent({
		id: Cast.aid(2),
		name: "BeaAgent",
		owner: Cast.gid(1),
		generation: Cast.gen(1),
	}),
)

## Human `who`'s session to their account of generation `g`, signed in at
## 0, from its stored line.
session_of : U64, U64 -> ApiKey.Granter(ConvAccess.Conv, ConvAccess.ConvId)
session_of = |who, g| Session(session_line(who, g))

## Human `who`'s session to their account of generation `g`.
session_line : U64, U64 -> Session
session_line = |who, g|
	match SessionCodec.decode(Str.to_utf8("session v1 id=${who.to_str()} human=${who.to_str()} generation=${g.to_str()} token=${Str.repeat("01", 32)} created=0 seen=0\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_line: a test's session line decodes"
	}

## A conversation among `who`, numbered `n`, as the store holds it: some
## of the table's (two humans' agents together) no start allows, so they
## come through the store's door, as a stored one would.
conv : U64, List(Principal) -> ConvAccess.Conv
conv = |n, who| {
	bound = List.map(
		who,
		|p|
			match Principal.bind(accounts, Principal.id(p)) {
				Ok(b) => b
				Err(_) => crash "conv: a test's participant has an account"
			},
	)
	line = ConvCodec.encode({
		id: n,
		created: 0,
		participants: bound,
		public_by: [],
	})
	match ConvCodec.decode(line) {
		Ok(decoded) => ConvAccess.Conv.load(decoded)
		Err(_) => crash "conv: a test's conversation round-trips its line"
	}
}

## `by` elects public, where that is allowed.
public_by : ConvAccess.Conv, Principal -> ConvAccess.Conv
public_by = |c, by|
	match Access.Viewer.from_session(
		session_line(by.answers_to().to_u64(), 1),
		{ accounts, now: 10 },
	) {
		Err(_) => crash "public_by: a test's session is admitted"
		Ok({ viewer, write: _ }) =>
			match c.elect({
				by: viewer,
				visibility: Public,
				accounts,
			}) {
				Ok(next) => next
				Err(_) => crash "public_by: a test's election is allowed"
			}
	}

## BeaAgent's private conversation with DeeAgent.
private_conv : ConvAccess.Conv
private_conv = conv(5, [bea_agent, dee_agent])

## Bea and BeaBot, made public by Bea, the one human involved.
bot_public : ConvAccess.Conv
bot_public = public_by(conv(6, [bea, bea_bot]), bea)

## Ann and BeaAgent, made public by both; BeaBot is not in it.
cross_public : ConvAccess.Conv
cross_public = public_by(public_by(conv(7, [ann, bea_agent]), ann), bea)

everything : ApiKey.Scope(ConvAccess.ConvId)
everything = {
	read: On(Everywhere),
	post: On(Everywhere),
	admin: Off,
}

## A key acting as `acts_as`, granted by `who`'s session among `among`.
key_by : U64,
{
	acts_as : Principal,
	among : List(Principal),
} -> Try(ConvKey.Key, [Refused(ApiKey.GrantRefusal)])
key_by = |who, { acts_as, among }|
	ConvKey.issue(
		{
			granter: session_of(who, 1),
			acts_as: acts_as.id(),
			scope: everything,
			accounts: among,
			now: 10,
		},
		{ key: Cast.kid(who), expires: 1000 },
	)

## The key, which the test's grant allows.
granted : Try(ConvKey.Key, [Refused(ApiKey.GrantRefusal)]) -> ConvKey.Key
granted = |t|
	match t {
		Ok(k) => k
		Err(_) => crash "granted: a test's grant is allowed"
	}

verdict : ConvKey.Key,
{
	accounts : List(Principal),
	action : [Read(ConvAccess.Conv), Post(ConvAccess.Conv)],
} -> ApiKey.Verdict
verdict = |key, { accounts: among, action }| ConvKey.decide(
	key,
	{
		accounts: among,
		action,
		now: 10,
	},
)

# ── THE ROUND-TWO ATTACKER'S FIRST: a forged copy of BeaAgent, first in the
# accounts, claiming Ann as owner. Ann's session is granted no key acting
# as BeaAgent, and a key of BeaAgent's own (granted by Bea) reads nothing
# while the copy is there.
expect key_by(
	1,
	{ acts_as: bea_agent, among: forged },
).map_ok(|_| {}) == Err(Refused(NoSuchPrincipal))
expect
	match Access.Viewer.from_session(session_line(1, 1), { accounts: forged, now: 10 }) {
		Ok({ viewer, write: _ }) => !ConvAccess.can_see(
			viewer,
			{ conv: private_conv, accounts: forged },
		)
		Err(_) => Bool.False
	}

bea_agent_key : ConvKey.Key
bea_agent_key = granted(key_by(2, { acts_as: bea_agent, among: accounts }))

expect verdict(bea_agent_key, { accounts, action: Read(private_conv) }) == Permitted
expect verdict(
	bea_agent_key,
	{ accounts: forged, action: Read(private_conv) },
) == Refused(NoSuchPrincipal)
expect verdict(
	bea_agent_key,
	{ accounts: forged, action: Post(private_conv) },
) == Refused(NoSuchPrincipal)

# ── THE ROUND-TWO ATTACKER'S SECOND: a chat key decides on a Conv and
# nothing else. Ann's key reads her own public conversation, and not
# BeaAgent's private one; a `Fake` with a `resource` method saying public
# is no Conv, so `ann_key.decide({ action: Read(Fake.({})), .. })` does not
# compile (ApiKey's tests' Held is a `Key(Held, U64)`'s, never a chat
# key's).
ann_key : ConvKey.Key
ann_key = granted(key_by(1, { acts_as: ann, among: accounts }))

expect verdict(ann_key, { accounts, action: Read(private_conv) }) == Refused(BeyondPrincipal)
expect verdict(ann_key, { accounts, action: Read(cross_public) }) == Permitted
expect verdict(ann_key, { accounts, action: Post(cross_public) }) == Permitted

# ── A BOT READING, BY KEY: BeaBot reads and
# posts in the public conversation it is in; a public one it is not in,
# it neither reads nor posts (decision 3).
bot_key : ConvKey.Key
bot_key = granted(key_by(2, { acts_as: bea_bot, among: accounts }))

expect verdict(bot_key, { accounts, action: Read(bot_public) }) == Permitted
expect verdict(bot_key, { accounts, action: Post(bot_public) }) == Permitted
expect verdict(bot_key, { accounts, action: Read(cross_public) }) == Refused(BeyondPrincipal)
expect verdict(bot_key, { accounts, action: Post(cross_public) }) == Refused(BeyondPrincipal)
# And while it is private, Bea not yet having elected: still its own.
expect verdict(bot_key, { accounts, action: Read(conv(6, [bea, bea_bot])) }) == Permitted

# ── THE STORE: a chat key's line round-trips, and decides the same.
stored : ConvKey.Key -> ConvKey.Key
stored = |key|
	match ConvKey.decode(ConvKey.encode({ key, hash: Cast.token(7) })) {
		Ok(entry) => entry.key
		Err(_) => crash "stored: a chat key's line decodes"
	}

expect stored(bot_key).record() == bot_key.record()
expect verdict(stored(bot_key), { accounts, action: Read(bot_public) }) == Permitted
expect
	ConvKey.decode("key v1 id=4 acts=agent:2 generation=1 human-generation=1 hash=${"5a".repeat(32)} created=1 expires=2 state=active read=only:9,3,3 post=off admin=off\n".to_utf8()).map_ok(|_| {})
		== Err(BadValue("read"))

# ── ATTACK, BY KEY: Ann retired and made again
# (generation 2); a key from her new account's session reads and posts
# nothing of the old account's private conversations, the human-only DM
# with Bea included.
ann_again : Principal
ann_again = Principal.Human({
	id: Cast.gid(1),
	login: "ann",
	name: "Ann",
	role: Member,
	generation: Cast.gen(2),
})

again : List(Principal)
again = [
	ann_again,
	bea,
	boss,
	bea_agent,
	dee_agent,
	bea_bot,
]

old_dm : ConvAccess.Conv
old_dm = conv(8, [ann, bea])

new_ann_key : ConvKey.Key
new_ann_key =
	granted(
		ConvKey.issue(
			{
				granter: session_of(1, 2),
				acts_as: ann_again.id(),
				scope: everything,
				accounts: again,
				now: 10,
			},
			{ key: Cast.kid(9), expires: 1000 },
		),
	)

expect verdict(new_ann_key, { accounts: again, action: Read(old_dm) }) == Refused(BeyondPrincipal)
expect verdict(new_ann_key, { accounts: again, action: Post(old_dm) }) == Refused(BeyondPrincipal)
expect verdict(
	new_ann_key,
	{ accounts: again, action: Read(cross_public) },
) == Refused(BeyondPrincipal)
# Bea, still in it, still reads it.
expect verdict(
	granted(key_by(2, { acts_as: bea, among: again })),
	{ accounts: again, action: Read(old_dm) },
) == Permitted
