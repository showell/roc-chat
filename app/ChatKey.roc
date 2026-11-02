## **THE CHAT'S API KEYS** (the Roc chat's auth design, sections 3 and 10):
## ApiKey's core, as the chat issues, stores and loads its keys, here and
## nowhere else. **A KEY SAYS WHO YOU ARE** (Steve, 2026-11-01): what its
## holder reaches is the chat's other rules', on the viewer it mints
## (Access.Viewer.from_key). Pure.
import ApiKey
import Cast
import KeyCodec
import Principal
import Session
import Stored

ChatKey := [].{

	## A chat key.
	Key : ApiKey.Key

	## **WHAT THE STORE KEEPS OF A CHAT KEY**, the key store's entry: the key (when it was made is
	## its record's), and the hash the host looks it up by.
	Entry : {
		key : ChatKey.Key,
		hash : Stored.SecretHash,
	}

	## A new chat key, from a grant (ApiKey.may_grant: a live session's,
	## for its own principals).
	issue : ApiKey.Grant,
	{ key : Principal.KeyId, expires : I64 } -> Try(
		ChatKey.Key,
		[Refused(ApiKey.GrantRefusal)],
	)
	issue = |grant, made| ApiKey.Key.issue(grant, made)

	## The entry's line (KeyCodec).
	encode : ChatKey.Entry -> List(U8)
	encode = |{ key, hash }| KeyCodec.encode({ record: key.record(), hash })

	## The chat key a stored line holds: the one way back from the store.
	decode : List(U8) -> Try(ChatKey.Entry, _)
	decode = |raw| {
		line = KeyCodec.decode(raw)?
		entry = line.entry()
		Ok({ key: ApiKey.Key.load(line), hash: entry.hash })
	}
}

# ── tests
## Bea, a member, and her agent.
bea : Principal
bea = Principal.Human({
	id: Cast.hid(2),
	sign_in: Cast.github(2),
	login: "h2",
	name: "Bea",
	role: Member,
	generation: Cast.gen(1),
})

bea_agent : Principal
bea_agent = Principal.Agent({
	id: Cast.aid(2),
	name: "BeaAgent",
	owner: Cast.hid(2),
	generation: Cast.gen(1),
})

accounts : List(Principal)
accounts = [bea, bea_agent]

## Bea's session, signed in at 0, as a granter.
bea_session : ApiKey.Granter
bea_session =
	match Session.decode(Str.to_utf8("session v1 id=2 human=2 generation=1 token=${Str.repeat("01", 32)} created=0 seen=0\n")) {
		Ok(session) => Session(session)
		Err(_) => crash "bea_session: a test's session line decodes"
	}

## Bea's agent's key, reading and posting.
agent_key : ChatKey.Key
agent_key =
	match ChatKey.issue(
		{
			granter: bea_session,
			acts_as: bea_agent.id(),
			scope: {
				read: On,
				post: On,
			},
			accounts,
			now: 10,
		},
		{ key: Cast.kid(3), expires: 1000 },
	) {
		Ok(k) => k
		Err(_) => crash "agent_key: Bea grants her own agent's key"
	}

# **THE STORE**: a chat key's line round-trips, its record and its hash.
expect
	match ChatKey.decode(ChatKey.encode({ key: agent_key, hash: Cast.token(9) })) {
		Ok({ key, hash }) => key.record() == agent_key.record() and hash == Cast.token(9)
		Err(_) => Bool.False
	}
# A line that is no key's is no entry.
expect ChatKey.decode("key v1 id=3\n".to_utf8()).is_err()
# The key stands as its agent, and as no one once the agent is retired.
expect agent_key.principal({ accounts, now: 50 }).map_ok(|p| p.id()) == Ok(bea_agent.id())
expect agent_key.principal({ accounts: [bea], now: 50 }).is_err()
