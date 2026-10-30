## **WHO MAY SEE A CONVERSATION, AND WHO ELECTS** (the Roc chat's auth
## design, section 4, with Steve's answers in 8, 9 and 11): the chat's layer
## on Access.roc. A conversation is the resource; what makes it public is
## the chat's own rule, kept here:
## - a conversation of humans alone is always private;
## - one with an agent or a bot in it is public only while every human
##   involved (its human participants, and the owners of its agents and
##   bots) still has an account and has elected public; any one of them can
##   withdraw, and retiring one withdraws their election.
## A conversation holds its participants bound to their accounts
## (Principal.Bound, made when it starts): who owns an agent is the
## accounts' answer at each decision, never a copy the caller hands in, and
## a participant counts only while its binding holds (Principal.holds), so
## an account made again with a retired participant's id, a human's or an
## agent's, never sees, posts in or answers for the old conversations. An
## election is held by the voter's account (its generation), so an account
## made again never inherits a public vote either. Who sees and who posts
## is then Access's, on the resource made here, for an Access.Viewer: an
## opaque value minted only from a live session or a standing key, so no
## handler claims an identity, and checked again here against the accounts
## of the decision. Elections take a session's viewer alone.
## Pure; the table of every viewer against every conversation is below,
## a cell a line, which is why the module runs past a thousand lines: the
## code ends at `# ── the cast`.
import Access
import ApiKey
import Cast
import ConvCodec
import Principal
import Session
import SessionCodec

ConvAccess := [].{

	## A conversation's id, from the chat's own counter. Opaque: made only
	## by `from_u64`, which refuses 0.
	ConvId :: U64.{
		from_u64 : U64 -> Try(ConvAccess.ConvId, [NotAnId])
		from_u64 = |n| if n == 0 Err(NotAnId) else Ok(ConvAccess.ConvId.(n))

		to_u64 : ConvAccess.ConvId -> U64
		to_u64 = |ConvAccess.ConvId.(n)| n

		is_eq : _
	}

	## One human's election: who is voting (a viewer from their own live
	## session: an agent or a bot never votes, not even for its owner, and a
	## key, even a human's, never elects), the visibility they want, and the
	## accounts now.
	Election : {
		by : Access.Viewer(ConvAccess.ConvId),
		visibility : [Private, Public],
		accounts : List(Principal),
	}

	## Why an election is refused. **ONE ALIAS ON PURPOSE**: `elect` and the
	## `refused` check behind it share it, and the tags' reasons are said once.
	ElectionRefusal : [
		## Nobody signed in asked.
		SignedOut,

		## A key asked: only a human's own session elects, so a key, an
		## agent's or a human's own, never makes a conversation public.
		NeedsSession,

		## A conversation of humans alone has no election.
		AlwaysPrivate,

		## The voter's session is not of an account now (retired, or made again).
		NoSuchPrincipal,

		## The voter is neither in it nor owns an agent or a bot in it.
		NotInvolved,
	]

	## **A CONVERSATION AND ITS ELECTIONS, AS A STATE MACHINE**: opaque, so
	## `start` is the one way in (every human's election private), and
	## `elect` and `withdraw_votes` the transitions. `public_by` holds the
	## accounts whose election is public now, each by its human's GitHub id
	## and the account's generation; a human not in it has elected private,
	## or never elected, which is the same.
	Conv :: {
		id : ConvAccess.ConvId,
		participants : List(Principal.Bound),
		public_by : List({ human : Principal.GitHubId, generation : Principal.Generation }),
	}.{

		## **A CONVERSATION STARTED BY `starter`, WITH `others`**: the one way
		## in, from the routes and the tests alike. Each agent or bot named must answer to
		## the starter's human (its owner, or the owner's own agent asking):
		## a stranger never pulls someone's agent into a conversation
		## (`NotTheOwner`). A human may name any other human.
		start : {
			id : ConvAccess.ConvId,
			starter : Principal.Id,
			others : List(Principal.Id),
			accounts : List(Principal),
		} -> Try(
			ConvAccess.Conv,
			[NoParticipants, NoSuchParticipant(Principal.Id), NotTheOwner(Principal.Id)],
		)
		start = |{ id, starter, others, accounts }| {
			human =
				match Principal.find(accounts, starter) {
					Ok(p) => Ok(Principal.answers_to(p))
					Err(_) => Err(NoSuchParticipant(starter))
				}?
			List.fold_try(
				others,
				{},
				|{}, other|
					match other {
						Human(_) => Ok({})
						Agent(_) | Bot(_) =>
							match Principal.find(accounts, other) {
								Err(_) => Err(NoSuchParticipant(other))
								Ok(p) => if Principal.answers_to(p) == human Ok({}) else Err(NotTheOwner(other))
							}
					},
			)?
			among_bound({ id, participants: List.prepend(others, starter), accounts }).map_err(
				|e|
					match e {
						NoParticipants => NoParticipants
						NoSuchParticipant(p) => NoSuchParticipant(p)
					},
			)
		}

		## The conversation's id.
		id : ConvAccess.Conv -> ConvAccess.ConvId
		id = |ConvAccess.Conv.(c)| c.id

		## **A CONVERSATION AS ITS STORED LINE HOLDS IT**: the only way back
		## from the store (ConvCodec checked the line whole), its bindings
		## and elections as they were written, never bound again.
		load : ConvCodec.Line -> ConvAccess.Conv
		load = |line| {
			f = line.fields()
			match ConvAccess.ConvId.from_u64(f.id) {
				Ok(conv_id) => ConvAccess.Conv.(
					{
						id: conv_id,
						participants: f.participants,
						public_by: f.public_by,
					},
				)
				Err(NotAnId) => crash "ConvAccess.Conv.load: ConvCodec refuses an id of 0"
			}
		}

		## The conversation's fields, to store, made when it started at
		## `created`.
		fields : ConvAccess.Conv, I64 -> ConvCodec.Fields
		fields = |ConvAccess.Conv.(c), created| {
			id: c.id.to_u64(),
			created,
			participants: c.participants,
			public_by: c.public_by,
		}

		## The participants, each bound as they were when it started.
		participants : ConvAccess.Conv -> List(Principal.Bound)
		participants = |ConvAccess.Conv.(c)| c.participants

		## Humans alone, or an agent or a bot among them: the ids say.
		kind : ConvAccess.Conv -> [HumansOnly, WithAgents]
		kind = |ConvAccess.Conv.(c)|
			if List.all(
				c.participants,
				|p| match p.id {
					Human(_) => Bool.True
					Agent(_) | Bot(_) => Bool.False
				},
			) {
				HumansOnly
			} else {
				WithAgents
			}

		## **THE HUMANS INVOLVED, WHO ELECT, AS THE ACCOUNTS SAY NOW**: the
		## human participants, and the owner of each agent and bot, each
		## once, for each participant whose binding still holds.
		involved : ConvAccess.Conv, List(Principal) -> List(Principal.GitHubId)
		involved = |ConvAccess.Conv.(c), accounts|
			List.fold(
				c.participants,
				[],
				|kept, p|
					match answerer(accounts, p) {
						Answers(human) =>
							if List.contains(kept, human) {
								kept
							} else {
								List.append(kept, human)
							}
						Unresolved => kept
					},
			)

		## **AN ELECTION**: the human signed in as `by` elects a visibility
		## for themselves. Electing private withdraws a public election, and
		## makes the conversation private at once.
		elect : ConvAccess.Conv,
		ConvAccess.Election -> Try(
			ConvAccess.Conv,
			ConvAccess.ElectionRefusal,
		)
		elect = |
			conv,
			{
				by,
				visibility,
				accounts,
			},
		| {
			ConvAccess.Conv.(c) = conv
			match (by.who(), conv.kind()) {
				(SignedOut, _) => Err(SignedOut)
				(Key(_), _) => Err(NeedsSession)
				(Session(_), HumansOnly) => Err(AlwaysPrivate)
				(Session(b), WithAgents) =>
					match Principal.holds(accounts, b) {
						Err(_) => Err(NoSuchPrincipal)
						Ok(Agent(_)) | Ok(Bot(_)) => crash "ConvAccess.elect: a session's viewer is a human"
						Ok(Human(h)) =>
							if !List.contains(conv.involved(accounts), h.id) {
								Err(NotInvolved)
							} else {
								others = List.keep_if(c.public_by, |vote| vote.human != h.id)
								match visibility {
									Public => Ok(
										ConvAccess.Conv.(
											{
												..c,
												public_by: others.append({
													human: h.id,
													generation: h.generation,
												}),
											},
										),
									)
									Private => Ok(ConvAccess.Conv.({ ..c, public_by: others }))
								}
							}
					}
			}
		}

		## **A RETIRED HUMAN'S ELECTION, WITHDRAWN**, for the retirement's
		## plan (Admin.roc) to write back: their public election is gone for
		## good. (Until it is written, `visibility` counts no election of a
		## human without an account, nor one an earlier generation of their
		## GitHub id cast.)
		withdraw_votes : ConvAccess.Conv, Principal.GitHubId -> ConvAccess.Conv
		withdraw_votes = |ConvAccess.Conv.(c), human|
			ConvAccess.Conv.(
				{
					..c,
					public_by: List.keep_if(c.public_by, |vote| vote.human != human),
				},
			)

		## **ITS VISIBILITY NOW**: private for humans alone; otherwise
		## public only while every participant's binding holds, and every
		## human involved has exactly one account, which has elected public
		## itself.
		visibility : ConvAccess.Conv, List(Principal) -> [Private, Public]
		visibility = |conv, accounts| {
			ConvAccess.Conv.(c) = conv
			match conv.kind() {
				HumansOnly => Private
				WithAgents => {
					is_resolved = List.all(c.participants, |p| answerer(accounts, p) != Unresolved)
					is_elected = List.all(
						conv.involved(accounts),
						|h|
							match Principal.human_account(accounts, h) {
								Ok(account) => c.public_by.contains({
									human: h,
									generation: account.generation,
								})
								Err(_) => Bool.False
							},
					)
					if is_resolved and is_elected Public else Private
				}
			}
		}

		## The conversation as Access decides on it, with the accounts now:
		## its participants those whose binding holds, and the humans
		## involved bound to their accounts now.
		resource : ConvAccess.Conv, List(Principal) -> Access.Resource(ConvAccess.ConvId)
		resource = |conv, accounts| {
			ConvAccess.Conv.(c) = conv
			{
				id: c.id,
				participants: List.keep_if(
					c.participants,
					|b| Principal.holds(accounts, b).is_ok(),
				),
				involved: List.keep_oks(
					conv.involved(accounts),
					|h| Principal.bind(accounts, Principal.Id.Human(h)),
				),
				visibility: conv.visibility(accounts),
			}
		}
	}

	## **CAN THIS VIEWER SEE THIS CONVERSATION?** Access's rule on the
	## conversation's resource: a participant, or the human it answers to,
	## always; any human or agent signed in while it is public, never a bot
	## not in it; nobody signed out, and no viewer whose account is not the
	## one it was minted for (a retired participant sees nothing); a key,
	## where its read reaches. An admin is no exception.
	can_see : Access.Viewer(ConvAccess.ConvId),
	{
		conv : ConvAccess.Conv,
		accounts : List(Principal),
	} -> Bool
	can_see = |viewer, { conv, accounts }|
		is_held(viewer, accounts) and Access.can_see(viewer, conv.resource(accounts))

	## **CAN THIS VIEWER POST TO THIS CONVERSATION?** A participant, or the
	## human it answers to, public or not, of the accounts it was minted
	## for; a key, where its post reaches.
	can_post : Access.Viewer(ConvAccess.ConvId),
	{
		conv : ConvAccess.Conv,
		accounts : List(Principal),
	} -> Bool
	can_post = |viewer, { conv, accounts }|
		is_held(viewer, accounts) and Access.can_post(viewer, conv.resource(accounts))
}

## A viewer whose binding holds among `accounts`; nobody signed out.
is_held : Access.Viewer(ConvAccess.ConvId), List(Principal) -> Bool
is_held = |viewer, accounts|
	match viewer.who() {
		SignedOut => Bool.True
		Session(b) | Key(b) => Principal.holds(accounts, b).is_ok()
	}

## **THE HUMAN A PARTICIPANT ANSWERS TO, AS THE ACCOUNTS SAY**: a human,
## itself; an agent or a bot, its owner; while its binding holds. One
## retired, made again since, or held twice (a forged copy beside the real
## one) names nobody: `Unresolved`.
answerer : List(Principal), Principal.Bound -> [Answers(Principal.GitHubId), Unresolved]
answerer = |accounts, bound|
	match Principal.holds(accounts, bound) {
		Ok(only) => Answers(Principal.answers_to(only))
		Err(_) => Unresolved
	}

# ── the cast
# Four humans, and six agents and bots:
#   Ann     a member, owns AnnAgent
#   Bea     a member, owns BeaAgent and BeaBot
#   Cal     an ADMIN, owns CalAgent; in `adm` and, by CalAgent, in `ca`
#   Dee     a member, owns DeeAgent and DeeBot; by DeeAgent, in `three`
# and `Out`, nobody signed in.
Who : [
	Out,
	Ann,
	Bea,
	Cal,
	Dee,
	AnnAgent,
	BeaAgent,
	BeaBot,
	CalAgent,
	DeeAgent,
	DeeBot,
]

principal : Who -> Principal
principal = |who|
	match who {
		Out => crash "principal: nobody signed in is no principal"
		Ann => Cast.person(1, Member)
		Bea => Cast.person(2, Member)
		Cal => Cast.person(3, Admin)
		Dee => Cast.person(4, Member)
		AnnAgent => Cast.owned(Agent, { id: 1, owner: 1 })
		BeaAgent => Cast.owned(Agent, { id: 2, owner: 2 })
		BeaBot => Cast.owned(Bot, { id: 3, owner: 2 })
		CalAgent => Cast.owned(Agent, { id: 6, owner: 3 })
		DeeAgent => Cast.owned(Agent, { id: 4, owner: 4 })
		DeeBot => Cast.owned(Bot, { id: 5, owner: 4 })
	}

## Every account in the cast.
accounts : List(Principal)
accounts = List.map(
	[
		Ann,
		Bea,
		Cal,
		Dee,
		AnnAgent,
		BeaAgent,
		BeaBot,
		CalAgent,
		DeeAgent,
		DeeBot,
	],
	principal,
)

## The cast's accounts, `gone` retired.
without : Who -> List(Principal)
without = |gone| List.keep_if(accounts, |p| Principal.id(p) != Principal.id(principal(gone)))

## Human `who`'s session to their account of generation `g`, from its
## stored line, signed in at 0.
session_of : U64, U64 -> Session
session_of = |who, g|
	match SessionCodec.decode(Str.to_utf8("session v1 id=${who.to_str()} human=${who.to_str()} generation=${g.to_str()} token=${Str.repeat("01", 32)} created=0 seen=0\n")) {
		Ok(line) => Session.load(line)
		Err(_) => crash "session_of: a test's session line decodes"
	}

## **A VIEWER, AS A HANDLER GETS ONE**, minted among `among` at 10: `Out`
## signed out; a human by a session to their account in `among`; an agent
## or a bot by a key reaching everywhere, granted by its owner among the
## whole cast. `NoViewer` when no credential mints one (its account, or its
## owner's, gone or made again).
viewer_among : Who, List(Principal) -> [Viewer(Access.Viewer(ConvAccess.ConvId)), NoViewer]
viewer_among = |who, among|
	match (who, principal_or_out(who)) {
		(_, Nobody) => Viewer(Access.Viewer.signed_out({}))
		(_, Someone(Human(h))) => {
			g =
				match Principal.human_account(among, h.id) {
					Ok(now) => now.generation.to_u64()
					Err(_) => 1
				}
			match Access.Viewer.from_session(
				session_of(h.id.to_u64(), g),
				{ accounts: among, now: 10 },
			) {
				Ok({ viewer: v, write: _ }) => Viewer(v)
				Err(_) => NoViewer
			}
		}
		(_, Someone(p)) => {
			owner = Principal.answers_to(p)
			key = ApiKey.Key.issue(
				{
					granter: Session(session_of(owner.to_u64(), 1)),
					acts_as: Principal.id(p),
					scope: {
						read: On(Everywhere),
						post: On(Everywhere),
						admin: Off,
					},
					accounts,
					now: 10,
				},
				{ key: Cast.kid(1), expires: 1000 },
			)
			match key {
				Err(_) => NoViewer
				Ok(k) =>
					match Access.Viewer.from_key(k, { accounts: among, now: 10 }) {
						Ok(v) => Viewer(v)
						Err(_) => NoViewer
					}
			}
		}
	}

## The cast member, or nobody for `Out`.
principal_or_out : Who -> [Someone(Principal), Nobody]
principal_or_out = |who|
	match who {
		Out => Nobody
		_ => Someone(principal(who))
	}

## The viewer `who` mints among the whole cast.
viewer : Who -> Access.Viewer(ConvAccess.ConvId)
viewer = |who| viewer_in(who, accounts)

## The viewer `who` mints among `among`, in a test where one is minted.
viewer_in : Who, List(Principal) -> Access.Viewer(ConvAccess.ConvId)
viewer_in = |who, among|
	match viewer_among(who, among) {
		Viewer(v) => v
		NoViewer => crash "viewer_in: a test's viewer is minted"
	}

## **THE RAW CONSTRUCTION, NEVER EXPOSED**: a conversation among
## `participants` (each once), each bound to its accounts now, private to
## every human involved, with no rule on who started it. Only
## `Conv.start` (the owner rule first) and this module's tests reach it.
## `NoParticipants` for none; `NoSuchParticipant` for an id that
## exactly one account, and its human, do not hold.
among_bound : {
	id : ConvAccess.ConvId,
	participants : List(Principal.Id),
	accounts : List(Principal),
} -> Try(
	ConvAccess.Conv,
	[NoParticipants, NoSuchParticipant(Principal.Id)],
)
among_bound = |
	{
		id,
		participants,
		accounts: holders,
	},
| {
	once = List.fold(
		participants,
		[],
		|kept, p| if List.contains(kept, p) kept else List.append(kept, p),
	)
	bound = List.map_try(
		once,
		|p|
			match Principal.bind(holders, p) {
				Ok(b) => Ok(b)
				Err(_) => Err(NoSuchParticipant(p))
			},
	)?
	if List.is_empty(bound) {
		Err(NoParticipants)
	} else {
		Ok(
			ConvAccess.Conv.(
				{
					id,
					participants: bound,
					public_by: [],
				},
			),
		)
	}
}

## The one conversation id the tests use.
first_conv_id : ConvAccess.ConvId
first_conv_id = ConvAccess.ConvId.from_u64(1) ?? crash "first_conv_id: not 0"

## A conversation among the cast.
among : List(Who) -> ConvAccess.Conv
among = |people|
	match among_bound({
		id: first_conv_id,
		participants: List.map(people, id_of),
		accounts,
	}) {
		Ok(conv) => conv
		Err(_) => crash "among: a test's conversation has participants with accounts"
	}

## A cast member's id.
id_of : Who -> Principal.Id
id_of = |who| Principal.id(principal(who))

## `human` elects `visibility`, in a test where that is allowed.
elected : ConvAccess.Conv, { human : Who, visibility : [Private, Public] } -> ConvAccess.Conv
elected = |conv, { human, visibility }|
	match conv.elect({
		by: viewer(human),
		visibility,
		accounts,
	}) {
		Ok(next) => next
		Err(_) => crash "elected: a test's election is allowed"
	}

## The conversation's visibility among the whole cast.
shown : ConvAccess.Conv -> [Private, Public]
shown = |conv| conv.visibility(accounts)

## The answers said as words, so each cell reads plainly.
sees : Who, ConvAccess.Conv -> [Visible, Hidden]
sees = |who, conv| sees_among(who, { conv, among: accounts })

posts : Who, ConvAccess.Conv -> [Writable, ReadOnly]
posts = |who, conv| posts_among(who, { conv, among: accounts })

## `sees`, among other accounts: `who`'s viewer minted among them too.
sees_among : Who, { conv : ConvAccess.Conv, among : List(Principal) } -> [Visible, Hidden]
sees_among = |who, { conv, among: others }|
	match viewer_among(who, others) {
		Viewer(v) => if ConvAccess.can_see(v, { conv, accounts: others }) Visible else Hidden
		NoViewer => Hidden
	}

## `posts`, among other accounts.
posts_among : Who, { conv : ConvAccess.Conv, among : List(Principal) } -> [Writable, ReadOnly]
posts_among = |who, { conv, among: others }|
	match viewer_among(who, others) {
		Viewer(v) => if ConvAccess.can_post(v, { conv, accounts: others }) Writable else ReadOnly
		NoViewer => ReadOnly
	}

# ── the conversations, in each election state
# hh        Ann and Bea: humans alone, always private, no election.
# ha_own    Ann and AnnAgent: Ann alone elects.
# ha_cross  Ann and BeaAgent: Ann and Bea elect.
# aa        AnnAgent and BeaAgent: their owners, Ann and Bea, elect.
# hb        Ann and BeaBot: Ann and Bea elect.
# adm       Cal, an admin, and AnnAgent: Cal and Ann elect.
# ca        Ann and CalAgent, an admin's agent: Ann and Cal elect.
# own_bot   Bea and BeaBot, her own bot: Bea alone elects.
# three     Ann, Bea and DeeAgent: Ann, Bea and Dee elect.
# A state's suffix says who has elected public now: `none`, `ann`, `bea`,
# `both`, `all`, or a withdrawal: `withdrawn` (all elected, then Ann
# elected private again), `bea_withdrawn` (both, then Bea, an owner not in
# it), `dee_withdrawn` (all three, then Dee).
hh : ConvAccess.Conv
hh = among([Ann, Bea])

ha_own_none : ConvAccess.Conv
ha_own_none = among([Ann, AnnAgent])

ha_own_ann : ConvAccess.Conv
ha_own_ann = elected(ha_own_none, { human: Ann, visibility: Public })

ha_own_withdrawn : ConvAccess.Conv
ha_own_withdrawn = elected(ha_own_ann, { human: Ann, visibility: Private })

ha_cross_none : ConvAccess.Conv
ha_cross_none = among([Ann, BeaAgent])

ha_cross_ann : ConvAccess.Conv
ha_cross_ann = elected(ha_cross_none, { human: Ann, visibility: Public })

ha_cross_bea : ConvAccess.Conv
ha_cross_bea = elected(ha_cross_none, { human: Bea, visibility: Public })

ha_cross_both : ConvAccess.Conv
ha_cross_both = elected(ha_cross_ann, { human: Bea, visibility: Public })

ha_cross_withdrawn : ConvAccess.Conv
ha_cross_withdrawn = elected(ha_cross_both, { human: Ann, visibility: Private })

ha_cross_bea_withdrawn : ConvAccess.Conv
ha_cross_bea_withdrawn = elected(ha_cross_both, { human: Bea, visibility: Private })

aa_none : ConvAccess.Conv
aa_none = among([AnnAgent, BeaAgent])

aa_ann : ConvAccess.Conv
aa_ann = elected(aa_none, { human: Ann, visibility: Public })

aa_bea : ConvAccess.Conv
aa_bea = elected(aa_none, { human: Bea, visibility: Public })

aa_both : ConvAccess.Conv
aa_both = elected(aa_ann, { human: Bea, visibility: Public })

aa_withdrawn : ConvAccess.Conv
aa_withdrawn = elected(aa_both, { human: Ann, visibility: Private })

hb_none : ConvAccess.Conv
hb_none = among([Ann, BeaBot])

hb_ann : ConvAccess.Conv
hb_ann = elected(hb_none, { human: Ann, visibility: Public })

hb_bea : ConvAccess.Conv
hb_bea = elected(hb_none, { human: Bea, visibility: Public })

hb_both : ConvAccess.Conv
hb_both = elected(hb_ann, { human: Bea, visibility: Public })

hb_withdrawn : ConvAccess.Conv
hb_withdrawn = elected(hb_both, { human: Ann, visibility: Private })

adm_none : ConvAccess.Conv
adm_none = among([Cal, AnnAgent])

adm_cal : ConvAccess.Conv
adm_cal = elected(adm_none, { human: Cal, visibility: Public })

adm_both : ConvAccess.Conv
adm_both = elected(adm_cal, { human: Ann, visibility: Public })

ca_none : ConvAccess.Conv
ca_none = among([Ann, CalAgent])

ca_ann : ConvAccess.Conv
ca_ann = elected(ca_none, { human: Ann, visibility: Public })

ca_both : ConvAccess.Conv
ca_both = elected(ca_ann, { human: Cal, visibility: Public })

own_bot_none : ConvAccess.Conv
own_bot_none = among([Bea, BeaBot])

own_bot_bea : ConvAccess.Conv
own_bot_bea = elected(own_bot_none, { human: Bea, visibility: Public })

three_none : ConvAccess.Conv
three_none = among([
	Ann,
	Bea,
	DeeAgent,
])

three_ann : ConvAccess.Conv
three_ann = elected(three_none, { human: Ann, visibility: Public })

three_both : ConvAccess.Conv
three_both = elected(three_ann, { human: Bea, visibility: Public })

three_all : ConvAccess.Conv
three_all = elected(three_both, { human: Dee, visibility: Public })

three_dee_withdrawn : ConvAccess.Conv
three_dee_withdrawn = elected(three_all, { human: Dee, visibility: Private })

# ── the elections
## `who` tries to elect public, where that may be refused.
refused : ConvAccess.Conv, Who -> Try(ConvAccess.ConvId, ConvAccess.ElectionRefusal)
refused = |conv, who|
	conv.elect({
		by: viewer(who),
		visibility: Public,
		accounts,
	})
		.map_ok(ConvAccess.Conv.id)

nobody : Try(ConvAccess.ConvId, [NoParticipants, NoSuchParticipant(Principal.Id)])
nobody = among_bound({
	id: first_conv_id,
	participants: [],
	accounts,
}).map_ok(ConvAccess.Conv.id)

# Humans alone have no election; a human uninvolved has none either.
expect refused(hh, Ann) == Err(AlwaysPrivate)
expect refused(hh, Cal) == Err(AlwaysPrivate)
expect refused(ha_own_none, Bea) == Err(NotInvolved)
expect refused(aa_none, Cal) == Err(NotInvolved)
expect refused(hb_none, Dee) == Err(NotInvolved)
expect nobody == Err(NoParticipants)
# A participant no account holds, or whose owner none does, starts nothing.
expect among_bound({
	id: first_conv_id,
	participants: [id_of(Ann), Principal.Id.Agent(Cast.aid(99))],
	accounts,
}).map_ok(ConvAccess.Conv.id) == Err(NoSuchParticipant(Principal.Id.Agent(Cast.aid(99))))
expect among_bound({
	id: first_conv_id,
	participants: [id_of(AnnAgent)],
	accounts: without(Ann),
}).map_ok(ConvAccess.Conv.id) == Err(NoSuchParticipant(id_of(AnnAgent)))
# **ONLY ITS OWNER NAMES AN AGENT OR A BOT** (Conv.start): Ann names her
# own agent and Bea; Cal names Ann's agent and is refused; Ann's agent,
# starting, names Ann's own; Bea names Bea's bot and not Ann's agent.
started_by : Who, List(Who) -> Try(ConvAccess.ConvId, [NoParticipants, NoSuchParticipant(Principal.Id), NotTheOwner(Principal.Id)])
started_by = |starter, others| ConvAccess.Conv.start({
	id: first_conv_id,
	starter: id_of(starter),
	others: List.map(others, id_of),
	accounts,
}).map_ok(ConvAccess.Conv.id)

expect started_by(Ann, [AnnAgent, Bea]) == Ok(first_conv_id)
expect started_by(Cal, [AnnAgent]) == Err(NotTheOwner(id_of(AnnAgent)))
expect started_by(Cal, [Ann, Bea]) == Ok(first_conv_id)
expect started_by(AnnAgent, [Ann]) == Ok(first_conv_id)
expect started_by(Bea, [BeaBot]) == Ok(first_conv_id)
expect started_by(Bea, [BeaBot, AnnAgent]) == Err(NotTheOwner(id_of(AnnAgent)))
expect ConvAccess.Conv.start({
	id: first_conv_id,
	starter: id_of(Ann),
	others: [Principal.Id.Agent(Cast.aid(99))],
	accounts,
}).map_ok(ConvAccess.Conv.id) == Err(NoSuchParticipant(Principal.Id.Agent(Cast.aid(99))))

# Only a human elects, for themselves: an agent or a bot never, even one
# whose owner may.
expect refused(ha_own_none, AnnAgent) == Err(NeedsSession)
expect refused(own_bot_none, BeaBot) == Err(NeedsSession)
expect refused(hh, AnnAgent) == Err(NeedsSession)
# Nobody signed in elects nothing; nor does a human's own key: elections
# take the human's session.
expect refused(ha_own_none, Out) == Err(SignedOut)
ann_key_viewer : Access.Viewer(ConvAccess.ConvId)
ann_key_viewer = own_key_viewer(Ann)

expect ha_own_none.elect({
	by: ann_key_viewer,
	visibility: Public,
	accounts,
}).map_ok(ConvAccess.Conv.id) == Err(NeedsSession)
# A human without an account elects nothing.
expect
	ha_own_none.elect({
		by: viewer(Ann),
		visibility: Public,
		accounts: without(Ann),
	}).is_err()
# Who is involved: participants that are humans, and owners, each once.
expect ha_cross_none.involved(accounts) == [Cast.gid(1), Cast.gid(2)]
expect aa_none.involved(accounts) == [Cast.gid(1), Cast.gid(2)]
expect among([BeaAgent, BeaBot]).involved(accounts) == [Cast.gid(2)]
expect three_none.involved(accounts) == [
	Cast.gid(1),
	Cast.gid(2),
	Cast.gid(4),
]
expect among([
	Ann,
	Ann,
]).resource(accounts).participants.map(|b| b.id) == [Principal.Id.Human(Cast.gid(1))]
# Electing public twice is one election; one withdrawal undoes it.
expect shown(elected(ha_own_ann, { human: Ann, visibility: Public })) == Public
ha_own_twice : ConvAccess.Conv
ha_own_twice = elected(ha_own_ann, { human: Ann, visibility: Public })

expect shown(elected(ha_own_twice, { human: Ann, visibility: Private })) == Private
# Electing private when already private changes nothing.
expect shown(elected(aa_none, { human: Ann, visibility: Private })) == Private

# Each state's visibility, stated.
expect shown(hh) == Private
expect shown(ha_own_none) == Private
expect shown(ha_own_ann) == Public
expect shown(ha_own_withdrawn) == Private
expect shown(ha_cross_none) == Private
expect shown(ha_cross_ann) == Private
expect shown(ha_cross_bea) == Private
expect shown(ha_cross_both) == Public
expect shown(ha_cross_withdrawn) == Private
expect shown(ha_cross_bea_withdrawn) == Private
expect shown(aa_none) == Private
expect shown(aa_ann) == Private
expect shown(aa_bea) == Private
expect shown(aa_both) == Public
expect shown(aa_withdrawn) == Private
expect shown(hb_none) == Private
expect shown(hb_ann) == Private
expect shown(hb_bea) == Private
expect shown(hb_both) == Public
expect shown(hb_withdrawn) == Private
expect shown(adm_none) == Private
expect shown(adm_cal) == Private
expect shown(adm_both) == Public
expect shown(ca_none) == Private
expect shown(ca_ann) == Private
expect shown(ca_both) == Public
expect shown(own_bot_none) == Private
expect shown(own_bot_bea) == Public
expect shown(three_none) == Private
expect shown(three_ann) == Private
expect shown(three_both) == Private
expect shown(three_all) == Public
expect shown(three_dee_withdrawn) == Private

# ── RETIRING A HUMAN WITHDRAWS THEIR ELECTION (decision 4)
# A public conversation goes private when a human it relied on retires: a
# participant (Ann), or an owner not in it (Bea, Dee).
expect ha_own_ann.visibility(without(Ann)) == Private
expect ha_cross_both.visibility(without(Bea)) == Private
expect aa_both.visibility(without(Bea)) == Private
expect three_all.visibility(without(Dee)) == Private
expect sees_among(Dee, { conv: ha_cross_both, among: without(Bea) }) == Hidden
# Retiring someone it never relied on changes nothing.
expect ha_own_ann.visibility(without(Dee)) == Public
# The retirement's write: an account made again starts private.
expect shown(ha_own_ann.withdraw_votes(Cast.gid(1))) == Private
expect shown(ha_cross_both.withdraw_votes(Cast.gid(4))) == Public

# ── A CONVERSATION HOLDS IDS, AND THE ACCOUNTS NAME THE OWNERS (bug 4)
# A copy of BeaAgent claiming Ann as its owner, in the accounts beside the
# real one: neither copy names an owner, so the conversation stays private
# and nobody gains an owner's sight of it.
forged_bea_agent : Principal
forged_bea_agent = Cast.owned(Agent, { id: 2, owner: 1 })

forged_first : List(Principal)
forged_first = List.prepend(accounts, forged_bea_agent)

forged_last : List(Principal)
forged_last = List.append(accounts, forged_bea_agent)

expect ha_cross_both.visibility(forged_first) == Private
expect ha_cross_both.visibility(forged_last) == Private
expect sees_among(Ann, { conv: among([BeaAgent, DeeAgent]), among: forged_first }) == Hidden
expect sees_among(Bea, { conv: among([BeaAgent, DeeAgent]), among: forged_last }) == Hidden
# Ann alone cannot make Bea's agent's conversation public, whatever list
# of participants started it.
repeated : ConvAccess.Conv
repeated = among([
	BeaAgent,
	Ann,
	BeaAgent,
])

expect shown(elected(repeated, { human: Ann, visibility: Public })) == Private
# An agent that has no account names no owner: private, whatever was
# elected.
expect ha_cross_both.visibility(without(BeaAgent)) == Private

# ── THE can_see TABLE
# Every viewer against every conversation in every election state, one
# cell a line, its answer written out. A private conversation is seen by
# its participants and the humans they answer to (Bea in ha_cross, aa and
# hb; Ann in aa and adm; Cal in ca; Dee in three); not Cal the admin
# elsewhere, never `Out`. A public one is seen by every human and agent
# signed in, by a bot only when it is in it, and still never by `Out`.

# hh: Ann and Bea; always private.
expect sees(Out, hh) == Hidden
expect sees(Ann, hh) == Visible
expect sees(Bea, hh) == Visible
expect sees(Cal, hh) == Hidden
expect sees(Dee, hh) == Hidden
expect sees(AnnAgent, hh) == Hidden
expect sees(BeaAgent, hh) == Hidden
expect sees(BeaBot, hh) == Hidden
expect sees(CalAgent, hh) == Hidden
expect sees(DeeAgent, hh) == Hidden
expect sees(DeeBot, hh) == Hidden

# ha_own, nobody elected public: private to Ann and AnnAgent.
expect sees(Out, ha_own_none) == Hidden
expect sees(Ann, ha_own_none) == Visible
expect sees(Bea, ha_own_none) == Hidden
expect sees(Cal, ha_own_none) == Hidden
expect sees(Dee, ha_own_none) == Hidden
expect sees(AnnAgent, ha_own_none) == Visible
expect sees(BeaAgent, ha_own_none) == Hidden
expect sees(BeaBot, ha_own_none) == Hidden
expect sees(CalAgent, ha_own_none) == Hidden
expect sees(DeeAgent, ha_own_none) == Hidden
expect sees(DeeBot, ha_own_none) == Hidden

# ha_own, Ann elected public: public, Ann being the only human involved.
expect sees(Out, ha_own_ann) == Hidden
expect sees(Ann, ha_own_ann) == Visible
expect sees(Bea, ha_own_ann) == Visible
expect sees(Cal, ha_own_ann) == Visible
expect sees(Dee, ha_own_ann) == Visible
expect sees(AnnAgent, ha_own_ann) == Visible
expect sees(BeaAgent, ha_own_ann) == Visible
expect sees(BeaBot, ha_own_ann) == Hidden
expect sees(CalAgent, ha_own_ann) == Visible
expect sees(DeeAgent, ha_own_ann) == Visible
expect sees(DeeBot, ha_own_ann) == Hidden

# ha_own, Ann elected public then withdrew: private to Ann and AnnAgent.
expect sees(Out, ha_own_withdrawn) == Hidden
expect sees(Ann, ha_own_withdrawn) == Visible
expect sees(Bea, ha_own_withdrawn) == Hidden
expect sees(Cal, ha_own_withdrawn) == Hidden
expect sees(Dee, ha_own_withdrawn) == Hidden
expect sees(AnnAgent, ha_own_withdrawn) == Visible
expect sees(BeaAgent, ha_own_withdrawn) == Hidden
expect sees(BeaBot, ha_own_withdrawn) == Hidden
expect sees(CalAgent, ha_own_withdrawn) == Hidden
expect sees(DeeAgent, ha_own_withdrawn) == Hidden
expect sees(DeeBot, ha_own_withdrawn) == Hidden

# ha_cross, nobody elected public: private to Ann, BeaAgent and Bea, its
# owner.
expect sees(Out, ha_cross_none) == Hidden
expect sees(Ann, ha_cross_none) == Visible
expect sees(Bea, ha_cross_none) == Visible
expect sees(Cal, ha_cross_none) == Hidden
expect sees(Dee, ha_cross_none) == Hidden
expect sees(AnnAgent, ha_cross_none) == Hidden
expect sees(BeaAgent, ha_cross_none) == Visible
expect sees(BeaBot, ha_cross_none) == Hidden
expect sees(CalAgent, ha_cross_none) == Hidden
expect sees(DeeAgent, ha_cross_none) == Hidden
expect sees(DeeBot, ha_cross_none) == Hidden

# ha_cross, Ann alone elected public: still private.
expect sees(Out, ha_cross_ann) == Hidden
expect sees(Ann, ha_cross_ann) == Visible
expect sees(Bea, ha_cross_ann) == Visible
expect sees(Cal, ha_cross_ann) == Hidden
expect sees(Dee, ha_cross_ann) == Hidden
expect sees(AnnAgent, ha_cross_ann) == Hidden
expect sees(BeaAgent, ha_cross_ann) == Visible
expect sees(BeaBot, ha_cross_ann) == Hidden
expect sees(CalAgent, ha_cross_ann) == Hidden
expect sees(DeeAgent, ha_cross_ann) == Hidden
expect sees(DeeBot, ha_cross_ann) == Hidden

# ha_cross, Bea alone elected public: still private.
expect sees(Out, ha_cross_bea) == Hidden
expect sees(Ann, ha_cross_bea) == Visible
expect sees(Bea, ha_cross_bea) == Visible
expect sees(Cal, ha_cross_bea) == Hidden
expect sees(Dee, ha_cross_bea) == Hidden
expect sees(AnnAgent, ha_cross_bea) == Hidden
expect sees(BeaAgent, ha_cross_bea) == Visible
expect sees(BeaBot, ha_cross_bea) == Hidden
expect sees(CalAgent, ha_cross_bea) == Hidden
expect sees(DeeAgent, ha_cross_bea) == Hidden
expect sees(DeeBot, ha_cross_bea) == Hidden

# ha_cross, both elected public: public.
expect sees(Out, ha_cross_both) == Hidden
expect sees(Ann, ha_cross_both) == Visible
expect sees(Bea, ha_cross_both) == Visible
expect sees(Cal, ha_cross_both) == Visible
expect sees(Dee, ha_cross_both) == Visible
expect sees(AnnAgent, ha_cross_both) == Visible
expect sees(BeaAgent, ha_cross_both) == Visible
expect sees(BeaBot, ha_cross_both) == Hidden
expect sees(CalAgent, ha_cross_both) == Visible
expect sees(DeeAgent, ha_cross_both) == Visible
expect sees(DeeBot, ha_cross_both) == Hidden

# ha_cross, both elected, then Ann withdrew: private again.
expect sees(Out, ha_cross_withdrawn) == Hidden
expect sees(Ann, ha_cross_withdrawn) == Visible
expect sees(Bea, ha_cross_withdrawn) == Visible
expect sees(Cal, ha_cross_withdrawn) == Hidden
expect sees(Dee, ha_cross_withdrawn) == Hidden
expect sees(AnnAgent, ha_cross_withdrawn) == Hidden
expect sees(BeaAgent, ha_cross_withdrawn) == Visible
expect sees(BeaBot, ha_cross_withdrawn) == Hidden
expect sees(CalAgent, ha_cross_withdrawn) == Hidden
expect sees(DeeAgent, ha_cross_withdrawn) == Hidden
expect sees(DeeBot, ha_cross_withdrawn) == Hidden

# ha_cross, both elected, then Bea, the owner not in it, withdrew: private
# again.
expect sees(Out, ha_cross_bea_withdrawn) == Hidden
expect sees(Ann, ha_cross_bea_withdrawn) == Visible
expect sees(Bea, ha_cross_bea_withdrawn) == Visible
expect sees(Cal, ha_cross_bea_withdrawn) == Hidden
expect sees(Dee, ha_cross_bea_withdrawn) == Hidden
expect sees(AnnAgent, ha_cross_bea_withdrawn) == Hidden
expect sees(BeaAgent, ha_cross_bea_withdrawn) == Visible
expect sees(BeaBot, ha_cross_bea_withdrawn) == Hidden
expect sees(CalAgent, ha_cross_bea_withdrawn) == Hidden
expect sees(DeeAgent, ha_cross_bea_withdrawn) == Hidden
expect sees(DeeBot, ha_cross_bea_withdrawn) == Hidden

# aa, nobody elected public: private to the two agents and their owners.
expect sees(Out, aa_none) == Hidden
expect sees(Ann, aa_none) == Visible
expect sees(Bea, aa_none) == Visible
expect sees(Cal, aa_none) == Hidden
expect sees(Dee, aa_none) == Hidden
expect sees(AnnAgent, aa_none) == Visible
expect sees(BeaAgent, aa_none) == Visible
expect sees(BeaBot, aa_none) == Hidden
expect sees(CalAgent, aa_none) == Hidden
expect sees(DeeAgent, aa_none) == Hidden
expect sees(DeeBot, aa_none) == Hidden

# aa, Ann alone elected public: still private.
expect sees(Out, aa_ann) == Hidden
expect sees(Ann, aa_ann) == Visible
expect sees(Bea, aa_ann) == Visible
expect sees(Cal, aa_ann) == Hidden
expect sees(Dee, aa_ann) == Hidden
expect sees(AnnAgent, aa_ann) == Visible
expect sees(BeaAgent, aa_ann) == Visible
expect sees(BeaBot, aa_ann) == Hidden
expect sees(CalAgent, aa_ann) == Hidden
expect sees(DeeAgent, aa_ann) == Hidden
expect sees(DeeBot, aa_ann) == Hidden

# aa, Bea alone elected public: still private.
expect sees(Out, aa_bea) == Hidden
expect sees(Ann, aa_bea) == Visible
expect sees(Bea, aa_bea) == Visible
expect sees(Cal, aa_bea) == Hidden
expect sees(Dee, aa_bea) == Hidden
expect sees(AnnAgent, aa_bea) == Visible
expect sees(BeaAgent, aa_bea) == Visible
expect sees(BeaBot, aa_bea) == Hidden
expect sees(CalAgent, aa_bea) == Hidden
expect sees(DeeAgent, aa_bea) == Hidden
expect sees(DeeBot, aa_bea) == Hidden

# aa, both owners elected public: public.
expect sees(Out, aa_both) == Hidden
expect sees(Ann, aa_both) == Visible
expect sees(Bea, aa_both) == Visible
expect sees(Cal, aa_both) == Visible
expect sees(Dee, aa_both) == Visible
expect sees(AnnAgent, aa_both) == Visible
expect sees(BeaAgent, aa_both) == Visible
expect sees(BeaBot, aa_both) == Hidden
expect sees(CalAgent, aa_both) == Visible
expect sees(DeeAgent, aa_both) == Visible
expect sees(DeeBot, aa_both) == Hidden

# aa, both elected, then Ann withdrew: private again.
expect sees(Out, aa_withdrawn) == Hidden
expect sees(Ann, aa_withdrawn) == Visible
expect sees(Bea, aa_withdrawn) == Visible
expect sees(Cal, aa_withdrawn) == Hidden
expect sees(Dee, aa_withdrawn) == Hidden
expect sees(AnnAgent, aa_withdrawn) == Visible
expect sees(BeaAgent, aa_withdrawn) == Visible
expect sees(BeaBot, aa_withdrawn) == Hidden
expect sees(CalAgent, aa_withdrawn) == Hidden
expect sees(DeeAgent, aa_withdrawn) == Hidden
expect sees(DeeBot, aa_withdrawn) == Hidden

# hb, nobody elected public: private to Ann, BeaBot and Bea, its owner.
expect sees(Out, hb_none) == Hidden
expect sees(Ann, hb_none) == Visible
expect sees(Bea, hb_none) == Visible
expect sees(Cal, hb_none) == Hidden
expect sees(Dee, hb_none) == Hidden
expect sees(AnnAgent, hb_none) == Hidden
expect sees(BeaAgent, hb_none) == Hidden
expect sees(BeaBot, hb_none) == Visible
expect sees(CalAgent, hb_none) == Hidden
expect sees(DeeAgent, hb_none) == Hidden
expect sees(DeeBot, hb_none) == Hidden

# hb, Ann alone elected public: still private.
expect sees(Out, hb_ann) == Hidden
expect sees(Ann, hb_ann) == Visible
expect sees(Bea, hb_ann) == Visible
expect sees(Cal, hb_ann) == Hidden
expect sees(Dee, hb_ann) == Hidden
expect sees(AnnAgent, hb_ann) == Hidden
expect sees(BeaAgent, hb_ann) == Hidden
expect sees(BeaBot, hb_ann) == Visible
expect sees(CalAgent, hb_ann) == Hidden
expect sees(DeeAgent, hb_ann) == Hidden
expect sees(DeeBot, hb_ann) == Hidden

# hb, Bea alone elected public: still private.
expect sees(Out, hb_bea) == Hidden
expect sees(Ann, hb_bea) == Visible
expect sees(Bea, hb_bea) == Visible
expect sees(Cal, hb_bea) == Hidden
expect sees(Dee, hb_bea) == Hidden
expect sees(AnnAgent, hb_bea) == Hidden
expect sees(BeaAgent, hb_bea) == Hidden
expect sees(BeaBot, hb_bea) == Visible
expect sees(CalAgent, hb_bea) == Hidden
expect sees(DeeAgent, hb_bea) == Hidden
expect sees(DeeBot, hb_bea) == Hidden

# hb, both elected public: public; DeeBot, a bot not in it, still not.
expect sees(Out, hb_both) == Hidden
expect sees(Ann, hb_both) == Visible
expect sees(Bea, hb_both) == Visible
expect sees(Cal, hb_both) == Visible
expect sees(Dee, hb_both) == Visible
expect sees(AnnAgent, hb_both) == Visible
expect sees(BeaAgent, hb_both) == Visible
expect sees(BeaBot, hb_both) == Visible
expect sees(CalAgent, hb_both) == Visible
expect sees(DeeAgent, hb_both) == Visible
expect sees(DeeBot, hb_both) == Hidden

# hb, both elected, then Ann withdrew: private again.
expect sees(Out, hb_withdrawn) == Hidden
expect sees(Ann, hb_withdrawn) == Visible
expect sees(Bea, hb_withdrawn) == Visible
expect sees(Cal, hb_withdrawn) == Hidden
expect sees(Dee, hb_withdrawn) == Hidden
expect sees(AnnAgent, hb_withdrawn) == Hidden
expect sees(BeaAgent, hb_withdrawn) == Hidden
expect sees(BeaBot, hb_withdrawn) == Visible
expect sees(CalAgent, hb_withdrawn) == Hidden
expect sees(DeeAgent, hb_withdrawn) == Hidden
expect sees(DeeBot, hb_withdrawn) == Hidden

# adm, nobody elected public: private to Cal, AnnAgent and Ann, its owner.
expect sees(Out, adm_none) == Hidden
expect sees(Ann, adm_none) == Visible
expect sees(Bea, adm_none) == Hidden
expect sees(Cal, adm_none) == Visible
expect sees(Dee, adm_none) == Hidden
expect sees(AnnAgent, adm_none) == Visible
expect sees(BeaAgent, adm_none) == Hidden
expect sees(BeaBot, adm_none) == Hidden
expect sees(CalAgent, adm_none) == Hidden
expect sees(DeeAgent, adm_none) == Hidden
expect sees(DeeBot, adm_none) == Hidden

# adm, Cal alone elected public: an admin's election is one of two.
expect sees(Out, adm_cal) == Hidden
expect sees(Ann, adm_cal) == Visible
expect sees(Bea, adm_cal) == Hidden
expect sees(Cal, adm_cal) == Visible
expect sees(Dee, adm_cal) == Hidden
expect sees(AnnAgent, adm_cal) == Visible
expect sees(BeaAgent, adm_cal) == Hidden
expect sees(BeaBot, adm_cal) == Hidden
expect sees(CalAgent, adm_cal) == Hidden
expect sees(DeeAgent, adm_cal) == Hidden
expect sees(DeeBot, adm_cal) == Hidden

# adm, both elected public: public.
expect sees(Out, adm_both) == Hidden
expect sees(Ann, adm_both) == Visible
expect sees(Bea, adm_both) == Visible
expect sees(Cal, adm_both) == Visible
expect sees(Dee, adm_both) == Visible
expect sees(AnnAgent, adm_both) == Visible
expect sees(BeaAgent, adm_both) == Visible
expect sees(BeaBot, adm_both) == Hidden
expect sees(CalAgent, adm_both) == Visible
expect sees(DeeAgent, adm_both) == Visible
expect sees(DeeBot, adm_both) == Hidden

# ca, nobody elected public: private to Ann, CalAgent and Cal, its owner.
expect sees(Out, ca_none) == Hidden
expect sees(Ann, ca_none) == Visible
expect sees(Bea, ca_none) == Hidden
expect sees(Cal, ca_none) == Visible
expect sees(Dee, ca_none) == Hidden
expect sees(AnnAgent, ca_none) == Hidden
expect sees(BeaAgent, ca_none) == Hidden
expect sees(BeaBot, ca_none) == Hidden
expect sees(CalAgent, ca_none) == Visible
expect sees(DeeAgent, ca_none) == Hidden
expect sees(DeeBot, ca_none) == Hidden

# ca, Ann alone elected public: still private.
expect sees(Out, ca_ann) == Hidden
expect sees(Ann, ca_ann) == Visible
expect sees(Bea, ca_ann) == Hidden
expect sees(Cal, ca_ann) == Visible
expect sees(Dee, ca_ann) == Hidden
expect sees(AnnAgent, ca_ann) == Hidden
expect sees(BeaAgent, ca_ann) == Hidden
expect sees(BeaBot, ca_ann) == Hidden
expect sees(CalAgent, ca_ann) == Visible
expect sees(DeeAgent, ca_ann) == Hidden
expect sees(DeeBot, ca_ann) == Hidden

# ca, both elected public: public.
expect sees(Out, ca_both) == Hidden
expect sees(Ann, ca_both) == Visible
expect sees(Bea, ca_both) == Visible
expect sees(Cal, ca_both) == Visible
expect sees(Dee, ca_both) == Visible
expect sees(AnnAgent, ca_both) == Visible
expect sees(BeaAgent, ca_both) == Visible
expect sees(BeaBot, ca_both) == Hidden
expect sees(CalAgent, ca_both) == Visible
expect sees(DeeAgent, ca_both) == Visible
expect sees(DeeBot, ca_both) == Hidden

# own_bot, nobody elected public: private to Bea and BeaBot.
expect sees(Out, own_bot_none) == Hidden
expect sees(Ann, own_bot_none) == Hidden
expect sees(Bea, own_bot_none) == Visible
expect sees(Cal, own_bot_none) == Hidden
expect sees(Dee, own_bot_none) == Hidden
expect sees(AnnAgent, own_bot_none) == Hidden
expect sees(BeaAgent, own_bot_none) == Hidden
expect sees(BeaBot, own_bot_none) == Visible
expect sees(CalAgent, own_bot_none) == Hidden
expect sees(DeeAgent, own_bot_none) == Hidden
expect sees(DeeBot, own_bot_none) == Hidden

# own_bot, Bea elected public: public, Bea being the only human involved.
expect sees(Out, own_bot_bea) == Hidden
expect sees(Ann, own_bot_bea) == Visible
expect sees(Bea, own_bot_bea) == Visible
expect sees(Cal, own_bot_bea) == Visible
expect sees(Dee, own_bot_bea) == Visible
expect sees(AnnAgent, own_bot_bea) == Visible
expect sees(BeaAgent, own_bot_bea) == Visible
expect sees(BeaBot, own_bot_bea) == Visible
expect sees(CalAgent, own_bot_bea) == Visible
expect sees(DeeAgent, own_bot_bea) == Visible
expect sees(DeeBot, own_bot_bea) == Hidden

# three, nobody elected public: private to Ann, Bea, DeeAgent and Dee.
expect sees(Out, three_none) == Hidden
expect sees(Ann, three_none) == Visible
expect sees(Bea, three_none) == Visible
expect sees(Cal, three_none) == Hidden
expect sees(Dee, three_none) == Visible
expect sees(AnnAgent, three_none) == Hidden
expect sees(BeaAgent, three_none) == Hidden
expect sees(BeaBot, three_none) == Hidden
expect sees(CalAgent, three_none) == Hidden
expect sees(DeeAgent, three_none) == Visible
expect sees(DeeBot, three_none) == Hidden

# three, Ann and Bea elected public: Dee has not, so still private.
expect sees(Out, three_both) == Hidden
expect sees(Ann, three_both) == Visible
expect sees(Bea, three_both) == Visible
expect sees(Cal, three_both) == Hidden
expect sees(Dee, three_both) == Visible
expect sees(AnnAgent, three_both) == Hidden
expect sees(BeaAgent, three_both) == Hidden
expect sees(BeaBot, three_both) == Hidden
expect sees(CalAgent, three_both) == Hidden
expect sees(DeeAgent, three_both) == Visible
expect sees(DeeBot, three_both) == Hidden

# three, all three elected public: public.
expect sees(Out, three_all) == Hidden
expect sees(Ann, three_all) == Visible
expect sees(Bea, three_all) == Visible
expect sees(Cal, three_all) == Visible
expect sees(Dee, three_all) == Visible
expect sees(AnnAgent, three_all) == Visible
expect sees(BeaAgent, three_all) == Visible
expect sees(BeaBot, three_all) == Hidden
expect sees(CalAgent, three_all) == Visible
expect sees(DeeAgent, three_all) == Visible
expect sees(DeeBot, three_all) == Hidden

# three, all elected, then Dee withdrew: private again.
expect sees(Out, three_dee_withdrawn) == Hidden
expect sees(Ann, three_dee_withdrawn) == Visible
expect sees(Bea, three_dee_withdrawn) == Visible
expect sees(Cal, three_dee_withdrawn) == Hidden
expect sees(Dee, three_dee_withdrawn) == Visible
expect sees(AnnAgent, three_dee_withdrawn) == Hidden
expect sees(BeaAgent, three_dee_withdrawn) == Hidden
expect sees(BeaBot, three_dee_withdrawn) == Hidden
expect sees(CalAgent, three_dee_withdrawn) == Hidden
expect sees(DeeAgent, three_dee_withdrawn) == Visible
expect sees(DeeBot, three_dee_withdrawn) == Hidden

# ── THE can_post TABLE
# Seeing is not posting: each conversation private and public, and only
# its participants and the humans they answer to may post in either.

# hh: Ann and Bea.
expect posts(Out, hh) == ReadOnly
expect posts(Ann, hh) == Writable
expect posts(Bea, hh) == Writable
expect posts(Cal, hh) == ReadOnly
expect posts(Dee, hh) == ReadOnly
expect posts(AnnAgent, hh) == ReadOnly
expect posts(BeaAgent, hh) == ReadOnly
expect posts(BeaBot, hh) == ReadOnly
expect posts(CalAgent, hh) == ReadOnly
expect posts(DeeAgent, hh) == ReadOnly
expect posts(DeeBot, hh) == ReadOnly

# ha_own, private: Ann and AnnAgent.
expect posts(Out, ha_own_none) == ReadOnly
expect posts(Ann, ha_own_none) == Writable
expect posts(Bea, ha_own_none) == ReadOnly
expect posts(Cal, ha_own_none) == ReadOnly
expect posts(Dee, ha_own_none) == ReadOnly
expect posts(AnnAgent, ha_own_none) == Writable
expect posts(BeaAgent, ha_own_none) == ReadOnly
expect posts(BeaBot, ha_own_none) == ReadOnly
expect posts(CalAgent, ha_own_none) == ReadOnly
expect posts(DeeAgent, ha_own_none) == ReadOnly
expect posts(DeeBot, ha_own_none) == ReadOnly

# ha_own, public: still Ann and AnnAgent.
expect posts(Out, ha_own_ann) == ReadOnly
expect posts(Ann, ha_own_ann) == Writable
expect posts(Bea, ha_own_ann) == ReadOnly
expect posts(Cal, ha_own_ann) == ReadOnly
expect posts(Dee, ha_own_ann) == ReadOnly
expect posts(AnnAgent, ha_own_ann) == Writable
expect posts(BeaAgent, ha_own_ann) == ReadOnly
expect posts(BeaBot, ha_own_ann) == ReadOnly
expect posts(CalAgent, ha_own_ann) == ReadOnly
expect posts(DeeAgent, ha_own_ann) == ReadOnly
expect posts(DeeBot, ha_own_ann) == ReadOnly

# ha_cross, private: Ann, BeaAgent, and Bea, its owner.
expect posts(Out, ha_cross_none) == ReadOnly
expect posts(Ann, ha_cross_none) == Writable
expect posts(Bea, ha_cross_none) == Writable
expect posts(Cal, ha_cross_none) == ReadOnly
expect posts(Dee, ha_cross_none) == ReadOnly
expect posts(AnnAgent, ha_cross_none) == ReadOnly
expect posts(BeaAgent, ha_cross_none) == Writable
expect posts(BeaBot, ha_cross_none) == ReadOnly
expect posts(CalAgent, ha_cross_none) == ReadOnly
expect posts(DeeAgent, ha_cross_none) == ReadOnly
expect posts(DeeBot, ha_cross_none) == ReadOnly

# ha_cross, public: the same three.
expect posts(Out, ha_cross_both) == ReadOnly
expect posts(Ann, ha_cross_both) == Writable
expect posts(Bea, ha_cross_both) == Writable
expect posts(Cal, ha_cross_both) == ReadOnly
expect posts(Dee, ha_cross_both) == ReadOnly
expect posts(AnnAgent, ha_cross_both) == ReadOnly
expect posts(BeaAgent, ha_cross_both) == Writable
expect posts(BeaBot, ha_cross_both) == ReadOnly
expect posts(CalAgent, ha_cross_both) == ReadOnly
expect posts(DeeAgent, ha_cross_both) == ReadOnly
expect posts(DeeBot, ha_cross_both) == ReadOnly

# aa, private: the two agents and their owners.
expect posts(Out, aa_none) == ReadOnly
expect posts(Ann, aa_none) == Writable
expect posts(Bea, aa_none) == Writable
expect posts(Cal, aa_none) == ReadOnly
expect posts(Dee, aa_none) == ReadOnly
expect posts(AnnAgent, aa_none) == Writable
expect posts(BeaAgent, aa_none) == Writable
expect posts(BeaBot, aa_none) == ReadOnly
expect posts(CalAgent, aa_none) == ReadOnly
expect posts(DeeAgent, aa_none) == ReadOnly
expect posts(DeeBot, aa_none) == ReadOnly

# aa, public: the same four.
expect posts(Out, aa_both) == ReadOnly
expect posts(Ann, aa_both) == Writable
expect posts(Bea, aa_both) == Writable
expect posts(Cal, aa_both) == ReadOnly
expect posts(Dee, aa_both) == ReadOnly
expect posts(AnnAgent, aa_both) == Writable
expect posts(BeaAgent, aa_both) == Writable
expect posts(BeaBot, aa_both) == ReadOnly
expect posts(CalAgent, aa_both) == ReadOnly
expect posts(DeeAgent, aa_both) == ReadOnly
expect posts(DeeBot, aa_both) == ReadOnly

# hb, private: Ann, BeaBot, and Bea, its owner.
expect posts(Out, hb_none) == ReadOnly
expect posts(Ann, hb_none) == Writable
expect posts(Bea, hb_none) == Writable
expect posts(Cal, hb_none) == ReadOnly
expect posts(Dee, hb_none) == ReadOnly
expect posts(AnnAgent, hb_none) == ReadOnly
expect posts(BeaAgent, hb_none) == ReadOnly
expect posts(BeaBot, hb_none) == Writable
expect posts(CalAgent, hb_none) == ReadOnly
expect posts(DeeAgent, hb_none) == ReadOnly
expect posts(DeeBot, hb_none) == ReadOnly

# hb, public: the same three.
expect posts(Out, hb_both) == ReadOnly
expect posts(Ann, hb_both) == Writable
expect posts(Bea, hb_both) == Writable
expect posts(Cal, hb_both) == ReadOnly
expect posts(Dee, hb_both) == ReadOnly
expect posts(AnnAgent, hb_both) == ReadOnly
expect posts(BeaAgent, hb_both) == ReadOnly
expect posts(BeaBot, hb_both) == Writable
expect posts(CalAgent, hb_both) == ReadOnly
expect posts(DeeAgent, hb_both) == ReadOnly
expect posts(DeeBot, hb_both) == ReadOnly

# adm, private: Cal, AnnAgent, and Ann, its owner.
expect posts(Out, adm_none) == ReadOnly
expect posts(Ann, adm_none) == Writable
expect posts(Bea, adm_none) == ReadOnly
expect posts(Cal, adm_none) == Writable
expect posts(Dee, adm_none) == ReadOnly
expect posts(AnnAgent, adm_none) == Writable
expect posts(BeaAgent, adm_none) == ReadOnly
expect posts(BeaBot, adm_none) == ReadOnly
expect posts(CalAgent, adm_none) == ReadOnly
expect posts(DeeAgent, adm_none) == ReadOnly
expect posts(DeeBot, adm_none) == ReadOnly

# adm, public: the same three.
expect posts(Out, adm_both) == ReadOnly
expect posts(Ann, adm_both) == Writable
expect posts(Bea, adm_both) == ReadOnly
expect posts(Cal, adm_both) == Writable
expect posts(Dee, adm_both) == ReadOnly
expect posts(AnnAgent, adm_both) == Writable
expect posts(BeaAgent, adm_both) == ReadOnly
expect posts(BeaBot, adm_both) == ReadOnly
expect posts(CalAgent, adm_both) == ReadOnly
expect posts(DeeAgent, adm_both) == ReadOnly
expect posts(DeeBot, adm_both) == ReadOnly

# ca, private: Ann, CalAgent, and Cal, its owner.
expect posts(Out, ca_none) == ReadOnly
expect posts(Ann, ca_none) == Writable
expect posts(Bea, ca_none) == ReadOnly
expect posts(Cal, ca_none) == Writable
expect posts(Dee, ca_none) == ReadOnly
expect posts(AnnAgent, ca_none) == ReadOnly
expect posts(BeaAgent, ca_none) == ReadOnly
expect posts(BeaBot, ca_none) == ReadOnly
expect posts(CalAgent, ca_none) == Writable
expect posts(DeeAgent, ca_none) == ReadOnly
expect posts(DeeBot, ca_none) == ReadOnly

# ca, public: the same three.
expect posts(Out, ca_both) == ReadOnly
expect posts(Ann, ca_both) == Writable
expect posts(Bea, ca_both) == ReadOnly
expect posts(Cal, ca_both) == Writable
expect posts(Dee, ca_both) == ReadOnly
expect posts(AnnAgent, ca_both) == ReadOnly
expect posts(BeaAgent, ca_both) == ReadOnly
expect posts(BeaBot, ca_both) == ReadOnly
expect posts(CalAgent, ca_both) == Writable
expect posts(DeeAgent, ca_both) == ReadOnly
expect posts(DeeBot, ca_both) == ReadOnly

# own_bot, private: Bea and BeaBot.
expect posts(Out, own_bot_none) == ReadOnly
expect posts(Ann, own_bot_none) == ReadOnly
expect posts(Bea, own_bot_none) == Writable
expect posts(Cal, own_bot_none) == ReadOnly
expect posts(Dee, own_bot_none) == ReadOnly
expect posts(AnnAgent, own_bot_none) == ReadOnly
expect posts(BeaAgent, own_bot_none) == ReadOnly
expect posts(BeaBot, own_bot_none) == Writable
expect posts(CalAgent, own_bot_none) == ReadOnly
expect posts(DeeAgent, own_bot_none) == ReadOnly
expect posts(DeeBot, own_bot_none) == ReadOnly

# own_bot, public: still Bea and BeaBot.
expect posts(Out, own_bot_bea) == ReadOnly
expect posts(Ann, own_bot_bea) == ReadOnly
expect posts(Bea, own_bot_bea) == Writable
expect posts(Cal, own_bot_bea) == ReadOnly
expect posts(Dee, own_bot_bea) == ReadOnly
expect posts(AnnAgent, own_bot_bea) == ReadOnly
expect posts(BeaAgent, own_bot_bea) == ReadOnly
expect posts(BeaBot, own_bot_bea) == Writable
expect posts(CalAgent, own_bot_bea) == ReadOnly
expect posts(DeeAgent, own_bot_bea) == ReadOnly
expect posts(DeeBot, own_bot_bea) == ReadOnly

# three, private: Ann, Bea, DeeAgent, and Dee, its owner.
expect posts(Out, three_none) == ReadOnly
expect posts(Ann, three_none) == Writable
expect posts(Bea, three_none) == Writable
expect posts(Cal, three_none) == ReadOnly
expect posts(Dee, three_none) == Writable
expect posts(AnnAgent, three_none) == ReadOnly
expect posts(BeaAgent, three_none) == ReadOnly
expect posts(BeaBot, three_none) == ReadOnly
expect posts(CalAgent, three_none) == ReadOnly
expect posts(DeeAgent, three_none) == Writable
expect posts(DeeBot, three_none) == ReadOnly

# three, public: the same four.
expect posts(Out, three_all) == ReadOnly
expect posts(Ann, three_all) == Writable
expect posts(Bea, three_all) == Writable
expect posts(Cal, three_all) == ReadOnly
expect posts(Dee, three_all) == Writable
expect posts(AnnAgent, three_all) == ReadOnly
expect posts(BeaAgent, three_all) == ReadOnly
expect posts(BeaBot, three_all) == ReadOnly
expect posts(CalAgent, three_all) == ReadOnly
expect posts(DeeAgent, three_all) == Writable
expect posts(DeeBot, three_all) == ReadOnly

# ── RE-CREATION AFTER RETIREMENT
# Ann elected ha_own public, then retired; an account made again with her
# GitHub id (a later generation) does not inherit her vote, even before the
# retirement's withdrawal is written: private.
ann_again : Principal
ann_again = Principal.Human({
	id: Cast.gid(1),
	login: "ann",
	name: "Ann",
	role: Member,
	generation: Cast.gen(2),
})

again : List(Principal)
again = List.prepend(without(Ann), ann_again)

expect ha_own_ann.visibility(again) == Private
expect ha_cross_both.visibility(again) == Private
expect sees_among(Dee, { conv: ha_own_ann, among: again }) == Hidden
# Her own account, back as it was (the same generation), is the same vote.
expect ha_own_ann.visibility(List.append(without(Ann), principal(Ann))) == Public
# The new account is in none of the old one's conversations: it has no
# election there, and its agent (bound to the old account) answers to it
# no more.
expect ha_own_ann.elect({
	by: viewer_in(Ann, again),
	visibility: Public,
	accounts: again,
}).map_ok(ConvAccess.Conv.id) == Err(NotInvolved)
expect ha_own_ann.involved(again) == []
# ATTACK: the re-created Ann sees and posts nothing of
# the old account's private conversations, the human-only DM with Bea
# included.
expect sees_among(Ann, { conv: hh, among: again }) == Hidden
expect sees_among(Ann, { conv: ha_cross_none, among: again }) == Hidden
expect posts_among(Ann, { conv: hh, among: again }) == ReadOnly
# A copy of Ann's account beside it: her vote names nobody.
expect ha_own_ann.visibility(List.append(accounts, principal(Ann))) == Private

# ── VIEWERS AFTER AN AGENT PARTICIPANT RETIRES
# ha_cross, both elected public, then BeaAgent retired: private; Ann still
# sees and posts; Bea, BeaAgent's owner, no longer answers for it; the
# retired agent itself sees nothing.
gone_agent : List(Principal)
gone_agent = without(BeaAgent)

sees_gone : Who -> [Visible, Hidden]
sees_gone = |who| sees_among(who, { conv: ha_cross_both, among: gone_agent })

posts_gone : Who -> [Writable, ReadOnly]
posts_gone = |who|
	posts_among(who, { conv: ha_cross_both, among: gone_agent })

expect ha_cross_both.visibility(gone_agent) == Private
expect sees_gone(Out) == Hidden
expect sees_gone(Ann) == Visible
expect sees_gone(Bea) == Hidden
expect sees_gone(Cal) == Hidden
expect sees_gone(Dee) == Hidden
expect sees_gone(AnnAgent) == Hidden
expect sees_gone(BeaAgent) == Hidden
expect sees_gone(BeaBot) == Hidden
expect sees_gone(CalAgent) == Hidden
expect sees_gone(DeeAgent) == Hidden
expect sees_gone(DeeBot) == Hidden
expect posts_gone(Out) == ReadOnly
expect posts_gone(Ann) == Writable
expect posts_gone(Bea) == ReadOnly
expect posts_gone(BeaAgent) == ReadOnly
expect posts_gone(Cal) == ReadOnly
# aa, both elected public, then BeaAgent retired: private to AnnAgent and
# Ann alone.
expect sees_among(Ann, { conv: aa_both, among: gone_agent }) == Visible
expect sees_among(AnnAgent, { conv: aa_both, among: gone_agent }) == Visible
expect sees_among(Bea, { conv: aa_both, among: gone_agent }) == Hidden
expect sees_among(Dee, { conv: aa_both, among: gone_agent }) == Hidden
expect sees_among(BeaAgent, { conv: aa_both, among: gone_agent }) == Hidden

# A viewer two accounts hold sees nothing, even a public conversation.
expect sees_among(Dee, { conv: ha_own_ann, among: List.append(accounts, principal(Dee)) }) == Hidden

## A key acting as human `who` themselves, reaching everywhere, as a viewer.
own_key_viewer : Who -> Access.Viewer(ConvAccess.ConvId)
own_key_viewer = |who| {
	p = principal(who)
	key = ApiKey.Key.issue(
		{
			granter: Session(session_of(Principal.answers_to(p).to_u64(), 1)),
			acts_as: Principal.id(p),
			scope: {
				read: On(Everywhere),
				post: On(Everywhere),
				admin: Off,
			},
			accounts,
			now: 10,
		},
		{ key: Cast.kid(2), expires: 1000 },
	)
	match key {
		Ok(k) =>
			match Access.Viewer.from_key(k, { accounts, now: 10 }) {
				Ok(v) => v
				Err(_) => crash "own_key_viewer: a test's key stands"
			}
		Err(_) => crash "own_key_viewer: a test's key is grantable"
	}
}

# A human's own key sees and posts as the human does, where it reaches.
expect ConvAccess.can_see(own_key_viewer(Ann), { conv: hh, accounts })
expect ConvAccess.can_post(own_key_viewer(Ann), { conv: hh, accounts })
expect !ConvAccess.can_see(own_key_viewer(Cal), { conv: hh, accounts })

# A conversation stored and loaded is the one that started: its bindings
# and elections whole, never bound again.
stored_and_loaded : ConvAccess.Conv -> Try(ConvCodec.Fields, _)
stored_and_loaded = |conv|
	ConvCodec.decode(ConvCodec.encode(conv.fields(1761600000))).map_ok(|line| ConvAccess.Conv.load(line).fields(1761600000))

expect stored_and_loaded(hh) == Ok(hh.fields(1761600000))
