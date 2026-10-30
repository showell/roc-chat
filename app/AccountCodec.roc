## **AN ACCOUNT, STORED** (the Roc chat's auth design, section 1): a human,
## an agent or a bot, one line in Stored's format:
##
##     account v1 kind=human github=583231 login=octocat generation=3 role=admin name=Steve H.
##     account v1 kind=agent id=7 owner=583231 generation=4 name=CC
##     account v1 kind=bot id=9 owner=583231 generation=5 name=commits
##
## A human is keyed by its GitHub id; an agent and a bot by the chat's own
## id, with the GitHub id of the human who owns it. Every account's
## `generation` (Principal.Generation) is what its sessions, keys, votes
## and participations are bound to. The
## name is last, as Stored's free text is, and held to DisplayName's rule
## both ways; a login to GitHubLogin's, or empty once cleared (another
## account signed in with it since). `decode` gives a Principal or a named
## Stored.Problem, never a guess; `load` gives a whole store of them, or the
## first line it refuses, or the first id two lines hold. Pure.
import Cast
import DisplayName
import GitHubLogin
import Principal
import Stored

AccountCodec := [].{

	## Why an account will not encode: a name or a login its rule refuses
	## (an account built by hand; the sign-in flow makes only good ones).
	## Stored as it is, it would not decode. **ONE ALIAS ON PURPOSE**:
	## `encode` and its two field checks share it, and `round_trip` wraps it.
	EncodeProblem : [
		NameRefused(DisplayName.Problem),
		NameUntrimmed,
		LoginRefused,
	]

	## The account's line.
	encode : Principal -> Try(List(U8), AccountCodec.EncodeProblem)
	encode = |principal|
		match principal {
			Human(h) => {
				name = name_text(h.name)?
				login = login_text(h.login)?
				Ok(
					Stored.line(
						"account",
						[
							("kind", spell_kind(Human)),
							("github", h.id.to_u64().to_str()),
							("login", login),
							("generation", h.generation.to_u64().to_str()),
							("role", AccountCodec.role_text(h.role)),
							("name", name),
						],
					),
				)
			}

			Agent(a) => owned_line(
				Agent,
				{
					id: a.id,
					owner: a.owner,
					generation: a.generation,
					name: a.name,
				},
			)
			Bot(b) => owned_line(
				Bot,
				{
					id: b.id,
					owner: b.owner,
					generation: b.generation,
					name: b.name,
				},
			)
		}

	## The account a line holds.
	decode : List(U8) -> Try(Principal, Stored.Problem)
	decode = |raw| {
		fields = Stored.Reader.open(raw, "account")?
		kind = fields.field("kind")?
		match Stored.word(
			kind.value,
			{
				name: "kind",
				all: all_kinds,
				spell: spell_kind,
			},
		)? {
			Human => decode_human(kind.rest)
			Agent => decode_owned(kind.rest).map_ok(|a| Principal.Agent(a))
			Bot => decode_owned(kind.rest).map_ok(|b| Principal.Bot(b))
		}
	}

	## Why a store of accounts will not load. **ONE ALIAS ON PURPOSE**: the
	## tags' reasons are said once here, not at `load` and its test helper.
	LoadProblem : [
		## Line `line` (from 1) is refused, as `decode` says.
		BadLine({ line : U64, problem : Stored.Problem }),

		## Two lines hold one id (Principal.unique): a forged copy beside
		## the real account, which no decision may pick between.
		DuplicateId(Principal.Id),
	]

	## **THE ACCOUNTS LOADER**: a store of account lines, each ending in its
	## newline (an empty store is no accounts), as the accounts every
	## decision is made against; refused whole at its first bad line, or
	## when two lines hold one id. A torn last line is the first's problem
	## (`Torn`).
	load : List(U8) -> Try(List(Principal), AccountCodec.LoadProblem)
	load = |raw| {
		pieces = raw.split_on('\n')
		lines = pieces.drop_last(1)
		torn =
			match pieces.last() {
				Ok(last) if last != [] => [last]
				_ => []
			}
		decoded = lines.map(|l| l.append('\n')).concat(torn).map_with_index(|bytes, i|
			AccountCodec.decode(bytes).map_err(|problem| BadLine({ line: i + 1, problem })))
		accounts = decoded.map_try(|d| d)?
		Principal.unique(accounts).map_err(|DuplicateId(id)| DuplicateId(id))
	}

	## **A PRINCIPAL'S ID AS EVERY STORED RECORD SPELLS IT**: its kind, a
	## colon, its number (`human:583231`, `agent:7`, `bot:9`); what a key's
	## `acts` and an audit entry's `who` hold.
	id_text : Principal.Id -> Str
	id_text = |id|
		match id {
			Human(g) => "${spell_kind(Human)}:${g.to_u64().to_str()}"
			Agent(a) => "${spell_kind(Agent)}:${a.to_u64().to_str()}"
			Bot(b) => "${spell_kind(Bot)}:${b.to_u64().to_str()}"
		}

	## **A HUMAN'S ROLE AS EVERY STORED RECORD SPELLS IT**: `admin` or
	## `member`; what an account's `role` and an audit entry's `set-role`
	## hold.
	role_text : Principal.Role -> Str
	role_text = |role|
		match role {
			Admin => "admin"
			Member => "member"
		}

	## The role the value `role_text` spelled, in the field `name`.
	role_from : List(U8), Str -> Try(Principal.Role, Stored.Problem)
	role_from = |value, name|
		Stored.word(
			value,
			{
				name,
				all: all_roles,
				spell: AccountCodec.role_text,
			},
		)

	## The principal's id the value `id_text` spelled, in the field `name`.
	id_from : List(U8), Str -> Try(Principal.Id, Stored.Problem)
	id_from = |value, name|
		match value.split_first(':') {
			Err(NotFound) => Err(BadValue(name))
			Ok({ before, after }) =>
				match Stored.word(
					before,
					{
						name,
						all: all_kinds,
						spell: spell_kind,
					},
				)? {
					Human => Stored.id(
						after,
						{ name, make: Principal.GitHubId.from_u64 },
					).map_ok(|g| Principal.Id.Human(g))
					Agent => Stored.id(
						after,
						{ name, make: Principal.AgentId.from_u64 },
					).map_ok(|a| Principal.Id.Agent(a))
					Bot => Stored.id(
						after,
						{ name, make: Principal.AgentId.from_u64 },
					).map_ok(|b| Principal.Id.Bot(b))
				}
		}
}

Kind : [
	Human,
	Agent,
	Bot,
]

all_kinds : List(Kind)
all_kinds = [
	Human,
	Agent,
	Bot,
]

spell_kind : Kind -> Str
spell_kind = |kind|
	match kind {
		Human => "human"
		Agent => "agent"
		Bot => "bot"
	}

all_roles : List(Principal.Role)
all_roles = [Admin, Member]

## The login as stored: GitHubLogin's rule, or empty (cleared).
login_text : Str -> Try(Str, AccountCodec.EncodeProblem)
login_text = |login|
	if login == "" {
		Ok("")
	} else {
		match GitHubLogin.from_str(login) {
			Ok(known) => Ok(known.to_str())
			Err(NotALogin) => Err(LoginRefused)
		}
	}

## The name as stored: it passes the rule and is already trimmed.
name_text : Str -> Try(Str, AccountCodec.EncodeProblem)
name_text = |name|
	match DisplayName.from_str(name) {
		Err(why) => Err(NameRefused(why))
		Ok(taken) => if (taken.to_str() == name) Ok(name) else Err(NameUntrimmed)
	}

## An agent's or a bot's line.
owned_line : [Agent, Bot],
{
	id : Principal.AgentId,
	owner : Principal.GitHubId,
	generation : Principal.Generation,
	name : Str,
} -> Try(List(U8), AccountCodec.EncodeProblem)
owned_line = |
	kind,
	{
		id,
		owner,
		generation,
		name,
	},
| {
	text = name_text(name)?
	Ok(
		Stored.line(
			"account",
			[
				(
					"kind",
					match kind {
						Agent => spell_kind(Agent)
						Bot => spell_kind(Bot)
					},
				),
				("id", id.to_u64().to_str()),
				("owner", owner.to_u64().to_str()),
				("generation", generation.to_u64().to_str()),
				("name", text),
			],
		),
	)
}

## A human's fields, after its kind.
decode_human : Stored.Reader -> Try(Principal, Stored.Problem)
decode_human = |after_kind| {
	github = after_kind.field("github")?
	id = Stored.id(github.value, { name: "github", make: Principal.GitHubId.from_u64 })?
	login = github.rest.field("login")?
	login_word =
		if login.value == [] {
			""
		} else {
			GitHubLogin.from_utf8(login.value).map_err(|_| BadValue("login"))?.to_str()
		}
	generation = generation_after(login.rest)?
	role = generation.rest.field("role")?
	role_word = AccountCodec.role_from(role.value, "role")?
	name = stored_name(role.rest)?
	Ok(
		Principal.Human({
			id,
			login: login_word,
			name,
			role: role_word,
			generation: generation.value,
		}),
	)
}

## An agent's or a bot's fields, after its kind.
decode_owned : Stored.Reader -> Try(
	{
		id : Principal.AgentId,
		name : Str,
		owner : Principal.GitHubId,
		generation : Principal.Generation,
	},
	Stored.Problem,
)
decode_owned = |after_kind| {
	id_field = after_kind.field("id")?
	id = Stored.id(id_field.value, { name: "id", make: Principal.AgentId.from_u64 })?
	owner_field = id_field.rest.field("owner")?
	owner = Stored.id(owner_field.value, { name: "owner", make: Principal.GitHubId.from_u64 })?
	generation = generation_after(owner_field.rest)?
	name = stored_name(generation.rest)?
	Ok({
		id,
		name,
		owner,
		generation: generation.value,
	})
}

## The `generation` field, which must come next, and the fields after it.
generation_after : Stored.Reader -> Try(
	{ value : Principal.Generation, rest : Stored.Reader },
	Stored.Problem,
)
generation_after = |fields| {
	field = fields.field("generation")?
	value = Stored.id(field.value, { name: "generation", make: Principal.Generation.from_u64 })?
	Ok({ value, rest: field.rest })
}

## The last field, the name: as the rule takes it, already trimmed.
stored_name : Stored.Reader -> Try(Str, Stored.Problem)
stored_name = |fields| {
	text = fields.text("name")?
	match name_text(text) {
		Ok(name) => Ok(name)
		Err(_) => Err(BadValue("name"))
	}
}

# ── tests

## A test's human, its name and role.
human : { name : Str, role : Principal.Role } -> Principal
human = |{ name, role }|
	Principal.Human({
		id: Cast.gid(583231),
		login: "octocat",
		name,
		role,
		generation: Cast.gen(3),
	})

steve : Principal
steve = human({ name: "Steve H.", role: Admin })

cc : Principal
cc = Principal.Agent({
	id: Cast.aid(7),
	owner: Cast.gid(583231),
	generation: Cast.gen(4),
	name: "CC",
})

commits : Principal
commits = Principal.Bot({
	id: Cast.aid(9),
	owner: Cast.gid(583231),
	generation: Cast.gen(5),
	name: "commits",
})

## **A PRINCIPAL, EVERY FIELD OF IT, FOR A TEST TO COMPARE**: Principal has
## no `==` on purpose (two principals are the same one when their ids are),
## and a round trip must keep every field, not only the id.
Every : [
	Human(
		{
			id : Principal.GitHubId,
			login : Str,
			name : Str,
			role : Principal.Role,
			generation : Principal.Generation,
		},
	),
	Agent(
		{
			id : Principal.AgentId,
			name : Str,
			owner : Principal.GitHubId,
			generation : Principal.Generation,
		},
	),
	Bot(
		{
			id : Principal.AgentId,
			name : Str,
			owner : Principal.GitHubId,
			generation : Principal.Generation,
		},
	),
]

every : Principal -> Every
every = |principal|
	match principal {
		Human(h) => Human(h)
		Agent(a) => Agent(a)
		Bot(b) => Bot(b)
	}

## The account, stored and read back.
round_trip : Principal -> Try(Every, [Encode(AccountCodec.EncodeProblem), Decode(Stored.Problem)])
round_trip = |account| {
	line = AccountCodec.encode(account).map_err(|why| Encode(why))?
	AccountCodec.decode(line).map_err(|why| Decode(why)).map_ok(every)
}

## The account survives a round trip whole.
is_kept : Principal -> Bool
is_kept = |account| round_trip(account) == Ok(every(account))

## The account's line, as text.
line_of : Principal -> Str
line_of = |account|
	match AccountCodec.encode(account) {
		Ok(bytes) =>
			match Str.from_utf8(bytes) {
				Ok(text) => text
				Err(_) => crash "line_of: a stored line is UTF-8"
			}
		Err(_) => crash "line_of: a test's account encodes"
	}

# The exact lines.
expect line_of(steve) == "account v1 kind=human github=583231 login=octocat generation=3 role=admin name=Steve H.\n"
expect line_of(cc) == "account v1 kind=agent id=7 owner=583231 generation=4 name=CC\n"
expect line_of(commits) == "account v1 kind=bot id=9 owner=583231 generation=5 name=commits\n"

# Round trips: every kind, every role, names that look like fields, a
# non-ASCII name, the longest id.
expect is_kept(steve)
expect is_kept(human({ name: "Ann", role: Member }))
expect is_kept(cc)
expect is_kept(commits)
expect
	[
		"x role=admin",
		"name=root",
		"Zoë 🦊",
		"a  b",
		"=",
	].all(|name| is_kept(human({ name, role: Member })))
biggest : Principal
biggest = Principal.Bot({
	id: Cast.aid(18446744073709551615),
	owner: Cast.gid(18446744073709551615),
	generation: Cast.gen(18446744073709551615),
	name: "max",
})

expect is_kept(biggest)
expect round_trip(steve) != round_trip(human({ name: "Steve H.", role: Member }))
# A cleared login (another account signed in with it since) is stored
# empty, and reads back empty.
expect is_kept(
	Principal.Human({
		id: Cast.gid(5),
		login: "",
		name: "Old",
		role: Member,
		generation: Cast.gen(1),
	}),
)
expect line_of(
	Principal.Human({
		id: Cast.gid(5),
		login: "",
		name: "Old",
		role: Member,
		generation: Cast.gen(1),
	}),
) == "account v1 kind=human github=5 login= generation=1 role=member name=Old\n"

# Bytes round trip too: a decoded line encodes to the same bytes.
expect
	[
		"account v1 kind=human github=1 login=a generation=7 role=member name=b\n",
		"account v1 kind=agent id=7 owner=583231 generation=8 name=CC\n",
		"account v1 kind=bot id=9 owner=2 generation=9 name=commits bot\n",
	].all(
		|text| {
			raw = text.to_utf8()
			match AccountCodec.decode(raw) {
				Ok(account) => AccountCodec.encode(account) == Ok(raw)
				Err(_) => Bool.False
			}
		},
	)

# ── THE MALFORMED TABLE: each line, its named problem.
decoded : Str -> Try({}, Stored.Problem)
decoded = |text| AccountCodec.decode(text.to_utf8()).map_ok(|_| {})

human_line : Str
human_line = "account v1 kind=human github=1 login=a generation=7 role=member name=b\n"

agent_line : Str
agent_line = "account v1 kind=agent id=7 owner=5 generation=2 name=CC\n"

## The human's line with `from` replaced by `to`, decoded.
human_but : { from : Str, to : Str } -> Try({}, Stored.Problem)
human_but = |{ from, to }| decoded(human_line.replace_first(from, to))

## The agent's line with `from` replaced by `to`, decoded.
agent_but : { from : Str, to : Str } -> Try({}, Stored.Problem)
agent_but = |{ from, to }| decoded(agent_line.replace_first(from, to))

expect human_but({ from: "", to: "" }) == Ok({})
expect agent_but({ from: "", to: "" }) == Ok({})
expect decoded("") == Err(Torn)
expect agent_but({ from: "\n", to: "" }) == Err(Torn)
expect decoded(agent_line.concat(agent_line)) == Err(ExtraLine)
expect decoded("session v1 id=1\n") == Err(WrongRecord)
expect agent_but({ from: "v1", to: "v2" }) == Err(UnknownVersion)
expect agent_but({ from: "kind=agent", to: "kind=robot" }) == Err(UnknownWord("kind"))
expect human_but({ from: "kind=human", to: "kind=Human" }) == Err(UnknownWord("kind"))
expect human_but({ from: " kind=human", to: "" }) == Err(MissingField("kind"))
expect human_but({
	from: "github=1 login=a",
	to: "login=a github=1",
}) == Err(MissingField("github"))
expect human_but({ from: " login=a", to: "" }) == Err(MissingField("login"))
expect human_but({ from: "github=1", to: "github=1 github=1" }) == Err(MissingField("login"))
expect human_but({ from: " role=member", to: "" }) == Err(MissingField("role"))
expect human_but({ from: " name=b", to: "" }) == Err(MissingField("name"))
expect human_but({ from: "login=a ", to: "login=a  " }) == Err(MissingField("generation"))
expect human_but({ from: "login=a ", to: "login=a extra=1 " }) == Err(MissingField("generation"))
expect human_but({ from: "github=1", to: "github=0" }) == Err(BadValue("github"))
expect human_but({ from: "github=1", to: "github=01" }) == Err(BadNumber("github"))
expect human_but({ from: "github=1", to: "github=-1" }) == Err(BadNumber("github"))
expect human_but({ from: "github=1", to: "github=" }) == Err(BadNumber("github"))
expect human_but({ from: "login=a", to: "login=a_b" }) == Err(BadValue("login"))
expect human_but({ from: "login=a", to: "login=" }) == Ok({})
expect human_but({ from: " generation=7", to: "" }) == Err(MissingField("generation"))
expect human_but({ from: "generation=7", to: "created=7" }) == Err(MissingField("generation"))
expect human_but({ from: "generation=7", to: "generation=-7" }) == Err(BadNumber("generation"))
expect human_but({ from: "generation=7", to: "generation=07" }) == Err(BadNumber("generation"))
expect human_but({ from: "generation=7", to: "generation=0" }) == Err(BadValue("generation"))
expect human_but({
	from: "login=a generation=7",
	to: "generation=7 login=a",
}) == Err(MissingField("login"))
expect agent_but({ from: " generation=2", to: "" }) == Err(MissingField("generation"))
expect agent_but({ from: "generation=2", to: "generation=0" }) == Err(BadValue("generation"))
expect human_but({ from: "role=member", to: "role=owner" }) == Err(UnknownWord("role"))
expect human_but({ from: "role=member", to: "role=Admin" }) == Err(UnknownWord("role"))
expect human_but({ from: "name=b", to: "name=" }) == Err(BadValue("name"))
expect human_but({ from: "name=b", to: "name= b" }) == Err(BadValue("name"))
expect human_but({ from: "name=b", to: "name=b " }) == Err(BadValue("name"))
expect human_but({ from: "name=b", to: "name=b\r" }) == Err(BadValue("name"))
expect human_but({ from: "name=b", to: "name=a\tb" }) == Err(BadValue("name"))
expect human_but({ from: "name=b", to: "name=${"n".repeat(65)}" }) == Err(BadValue("name"))
expect agent_but({ from: "id=7", to: "id=0" }) == Err(BadValue("id"))
expect agent_but({ from: "owner=5", to: "owner=0" }) == Err(BadValue("owner"))
expect agent_but({ from: " owner=5", to: "" }) == Err(MissingField("owner"))
expect agent_but({
	from: "id=7 owner=5",
	to: "github=1 login=a role=member",
}) == Err(MissingField("id"))
expect agent_but({
	from: "kind=agent id=7",
	to: "kind=bot id=18446744073709551616",
}) == Err(BadNumber("id"))
expect AccountCodec.decode([
	0x61,
	0xff,
	'\n',
]).map_ok(|_| {}) == Err(NotUtf8)

# A principal's id: each kind round-trips; each malformed spelling, its
# problem.
expect
	List.all(
		[
			Principal.Id.Human(Cast.gid(583231)),
			Principal.Id.Agent(Cast.aid(7)),
			Principal.Id.Bot(Cast.aid(7)),
		],
		|id| AccountCodec.id_from(AccountCodec.id_text(id).to_utf8(), "who") == Ok(id),
	)
expect AccountCodec.id_text(Principal.Id.Bot(Cast.aid(9))) == "bot:9"
id_read : Str -> Try(Principal.Id, Stored.Problem)
id_read = |text| AccountCodec.id_from(text.to_utf8(), "who")

expect id_read("human:0") == Err(BadValue("who"))
expect id_read("human") == Err(BadValue("who"))
expect id_read("") == Err(BadValue("who"))
expect id_read("robot:1") == Err(UnknownWord("who"))
expect id_read(":1") == Err(UnknownWord("who"))
expect id_read("agent:") == Err(BadNumber("who"))
expect id_read("agent:07") == Err(BadNumber("who"))
expect id_read("agent:7:8") == Err(BadNumber("who"))

# What will not encode: a name the rule refuses, one untrimmed, a login
# GitHub would not give.
expect AccountCodec.encode(human({ name: "", role: Member })) == Err(NameRefused(Empty))
expect AccountCodec.encode(
	human({
		name: "a\nrole=admin",
		role: Member,
	}),
) == Err(NameRefused(ControlCharacter))
expect AccountCodec.encode(human({ name: " Ann", role: Member })) == Err(NameUntrimmed)
expect AccountCodec.encode(
	Principal.Agent({
		id: Cast.aid(1),
		owner: Cast.gid(1),
		generation: Cast.gen(1),
		name: "",
	}),
) == Err(NameRefused(Empty))
expect
	AccountCodec.encode(
		Principal.Human({
			id: Cast.gid(1),
			login: "bad login",
			name: "b",
			role: Member,
			generation: Cast.gen(1),
		}),
	)
		== Err(LoginRefused)

# ── THE ACCOUNTS LOADER
loaded : Str -> Try(List(Principal.Id), AccountCodec.LoadProblem)
loaded = |text| AccountCodec.load(text.to_utf8()).map_ok(|list| list.map(Principal.id))

agent_7 : Str
agent_7 = "account v1 kind=agent id=7 owner=1 generation=2 name=CC\n"

expect loaded("") == Ok([])
expect loaded(human_line) == Ok([Principal.Id.Human(Cast.gid(1))])
expect loaded("${human_line}${agent_7}") == Ok([
	Principal.Id.Human(Cast.gid(1)),
	Principal.Id.Agent(Cast.aid(7)),
])
# A torn last line, a bad line (its number from 1), a blank line.
expect loaded("${human_line}${agent_7}".replace_last("\n", "")) == Err(
	BadLine({
		line: 2,
		problem: Torn,
	}),
)
expect loaded("${human_line}account v1 kind=robot\n") == Err(
	BadLine({
		line: 2,
		problem: UnknownWord("kind"),
	}),
)
expect loaded("${human_line}\n${agent_7}") == Err(BadLine({ line: 2, problem: WrongRecord }))
# **A FORGED COPY FIRST**: an agent line
# claiming another owner, or a human line claiming admin, before the real
# one; or an agent and a bot from the one counter.
expect loaded("account v1 kind=agent id=7 owner=9 generation=3 name=CC\n${human_line}${agent_7}") == Err(DuplicateId(Principal.Id.Agent(Cast.aid(7))))
expect loaded("${human_line.replace_first("role=member", "role=admin")}${human_line}") == Err(DuplicateId(Principal.Id.Human(Cast.gid(1))))
expect loaded("${agent_7}${agent_7.replace_first("kind=agent", "kind=bot")}") == Err(DuplicateId(Principal.Id.Bot(Cast.aid(7))))
