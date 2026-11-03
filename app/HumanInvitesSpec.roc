## These are the tests of `HumanInvite` and `HumanInvites`: any human, by
## their own session, invites someone by a name, under a cap of open
## invites; the human who invited them, or the admin, invites them again;
## an invite redeems once, within its seven days, for the human it names;
## and its facts go to their files and come back.
import AgentKey
import Directory
import HumanInvite
import HumanInvites
import KeyScope
import Password
import Route
import Sample
import Secret
import SecretHash
import SecretToken
import SignedIn
import UserId
import Users

HumanInvitesSpec :: [].{}

## Steve, by his session: the admin.
steve : SignedIn
steve = SignedIn.dangerously_assume(Sample.steve)

## Apoorva, by her session: a human who is not the admin.
apoorva : SignedIn
apoorva = SignedIn.dangerously_assume(Sample.user("Apoorva"))

## CC, Steve's agent, by a key.
cc_by_key : SignedIn
cc_by_key = {
	hash = SecretHash.of_digest(List.repeat(3, 32))
	key = AgentKey.mint({
		id: AgentKey.Id.from_str("1") ?? crash "HumanInvitesSpec: a key's number",
		hash,
		now: 0,
		scope: KeyScope.of({ read: Everywhere, post: Everywhere }),
	})
	admitted = AgentKey.admit({
		user: Sample.user("CC"),
		keys: [key],
		hash,
		now: 0,
	}) ?? crash "HumanInvitesSpec: CC's key admits"
	SignedIn.by_api_key(admitted)
}

## CC as though a session admitted it, which none does: an agent.
cc_by_session : SignedIn
cc_by_session = SignedIn.dangerously_assume(Sample.user("CC"))

## The id `text` spells, which a test's always does.
id : Str -> UserId
id = |text| UserId.from_str(text) ?? crash "HumanInvitesSpec: an id"

## What inviting by the form `body`, by `acting` with `open` open invites,
## gives: the new human's name and id and their inviter's id, or why not.
invite_of : SignedIn, { body : Str, open : U64 } -> Try(Str, _)
invite_of = |acting, { body, open }|
	HumanInvites.invite(
		Sample.directory,
		{
			acting,
			body: body.to_utf8(),
			open,
		},
	).map_ok(|made| "${made.human.name().to_str()} ${made.human.id().to_str()} by ${made.inviter.id().to_str()}")

# Any human invites, by their own session, a name a new account holds at
# once; never a key, never an agent.
expect invite_of(
	steve,
	{
		body: "name=Zoe",
		open: 0,
	},
) == Ok("Zoe 4 by 1")
expect invite_of(
	apoorva,
	{
		body: "name=Zoe+Smith",
		open: 0,
	},
) == Ok("Zoe Smith 4 by 2")
expect
	HumanInvites.invite(
		Sample.directory,
		{
			acting: steve,
			body: "name=Zoe".to_utf8(),
			open: 0,
		},
	).map_ok(
		|made|
			match made.directory.users().user(id("4")) {
				Ok(user) => user.role() == Human
				Err(NoSuchUser) => Bool.False
			},
	)
		== Ok(Bool.True)
expect invite_of(
	cc_by_key,
	{
		body: "name=Zoe",
		open: 0,
	},
) == Err(ByApiKey)
expect invite_of(
	cc_by_session,
	{
		body: "name=Zoe",
		open: 0,
	},
) == Err(Agent(id("3")))
# The cap: nine open, a tenth made; ten or more open, none.
expect invite_of(
	steve,
	{
		body: "name=Zoe",
		open: 9,
	},
) == Ok("Zoe 4 by 1")
expect [10, 11].all(|open| invite_of(steve, { body: "name=Zoe", open }) == Err(Capped))
# A form at fault, a name that is no name, one taken in any case, a full chat.
expect invite_of(
	steve,
	{
		body: "",
		open: 0,
	},
) == Err(BadForm("The form has no field `name`."))
expect [
	"name=R2D2",
	"name=",
	"name=+Zoe",
].all(
	|body| invite_of(
		steve,
		{
			body,
			open: 0,
		},
	) == Err(BadName),
)
expect [
	"name=cc",
	"name=STEVE",
	"name=apoorva",
].all(
	|body| invite_of(
		steve,
		{
			body,
			open: 0,
		},
	) == Err(NameTaken),
)
expect
	HumanInvites.invite(
		Sample.crowded_directory(252),
		{
			acting: steve,
			body: "name=Zoe".to_utf8(),
			open: 0,
		},
	).map_ok(|_| {})
		== Err(Full)

## The sample directory with Zoe (4), invited by Apoorva, and Bob (5).
with_zoe_and_bob : Directory
with_zoe_and_bob = {
	with_zoe = (Sample.directory.add_human(Sample.name("Zoe")) ?? crash "HumanInvitesSpec: Zoe's name is free").directory
	(with_zoe.add_human(Sample.name("Bob")) ?? crash "HumanInvitesSpec: Bob's name is free").directory
}

## Bob, by his session.
bob : SignedIn
bob = SignedIn.dangerously_assume(with_zoe_and_bob.users().user(id("5")) ?? crash "HumanInvitesSpec: Bob is 5")

## Zoe invited again by `acting` with `open` open invites, her inviter
## `inviter`: the human the invite is for and who makes it, or why not.
reinvite_of : SignedIn,
{
	human : Str,
	inviter : HumanInvites.Inviter,
	open : U64,
} -> Try(Str, _)
reinvite_of = |
	acting,
	{
		human,
		inviter,
		open,
	},
|
	HumanInvites.reinvite(
		with_zoe_and_bob,
		{
			acting,
			human: id(human),
			inviter,
			open,
		},
	).map_ok(|again| "${again.human.id().to_str()} by ${again.by.id().to_str()}")

# Invited again by the human who invited them, or by the admin; nobody else.
expect reinvite_of(
	apoorva,
	{
		human: "4",
		inviter: InvitedBy(id("2")),
		open: 0,
	},
) == Ok("4 by 2")
expect reinvite_of(
	steve,
	{
		human: "4",
		inviter: InvitedBy(id("2")),
		open: 0,
	},
) == Ok("4 by 1")
expect reinvite_of(
	bob,
	{
		human: "4",
		inviter: InvitedBy(id("2")),
		open: 0,
	},
) == Err(NotYours)
expect reinvite_of(
	cc_by_key,
	{
		human: "4",
		inviter: InvitedBy(id("2")),
		open: 0,
	},
) == Err(ByApiKey)
# Only a human someone invited, and one there is: not the founder, not an
# agent, not an id no one has.
expect reinvite_of(
	steve,
	{
		human: "1",
		inviter: NoInviter,
		open: 0,
	},
) == Err(NotInvited)
expect reinvite_of(
	steve,
	{
		human: "3",
		inviter: NoInviter,
		open: 0,
	},
) == Err(NoSuchHuman)
expect reinvite_of(
	steve,
	{
		human: "9",
		inviter: NoInviter,
		open: 0,
	},
) == Err(NoSuchHuman)
# The cap holds for an invite again too.
expect reinvite_of(
	apoorva,
	{
		human: "4",
		inviter: InvitedBy(id("2")),
		open: 9,
	},
) == Ok("4 by 2")
expect reinvite_of(
	apoorva,
	{
		human: "4",
		inviter: InvitedBy(id("2")),
		open: 10,
	},
) == Err(Capped)
# Whose a human is to invite again, asked alone, as the page asks it.
expect HumanInvites.is_theirs_to_invite_again(apoorva, InvitedBy(id("2")))
expect !HumanInvites.is_theirs_to_invite_again(bob, InvitedBy(id("2")))
expect HumanInvites.is_theirs_to_invite_again(steve, InvitedBy(id("2")))
expect !HumanInvites.is_theirs_to_invite_again(steve, NoInviter)
expect !HumanInvites.is_theirs_to_invite_again(apoorva, NoInviter)

# An `inviter` file: none is no inviter; an id's digits, that id; anything
# else refused.
expect HumanInvites.inviter_from_file(NoFile) == Ok(NoInviter)
expect HumanInvites.inviter_from_file(File("2\n".to_utf8())) == Ok(InvitedBy(id("2")))
expect HumanInvites.inviter_from_file(File(" 12 ".to_utf8())) == Ok(InvitedBy(id("12")))
expect
	[
		"0",
		"x",
		"",
		"02",
		"256",
	].all(|text| HumanInvites.inviter_from_file(File(text.to_utf8())) == Err(NotAnInviter))

## The secret whose every byte is `b`.
secret : U8 -> Secret
secret = |b| Secret.from_random_bytes(List.repeat(b, 32))

## The hash of the secret whose every byte is `b`, as a test stands in for
## the host's.
hash : U8 -> SecretHash
hash = |b| SecretHash.of_digest(List.repeat(b, 32))

## Zoe's invite numbered `n`, made by `by` at 1000, its code's hash `hash(n)`.
invite_made : { n : U32, by : Str } -> HumanInvite
invite_made = |{ n, by }|
	HumanInvite.make({
		id: HumanInvite.Id.from_str(n.to_str()) ?? crash "HumanInvitesSpec: an invite's number",
		hash: hash(n.to_u8_wrap()),
		now: 1000,
		by: id(by),
	})

zoe : Users.Human
zoe = (with_zoe_and_bob.users().user(id("4")) ?? crash "HumanInvitesSpec: Zoe is 4").as_human() ?? crash "HumanInvitesSpec: Zoe is a human"

## Zoe's invite 1 redeemed at `now` by its own code: its state after, and
## whom it admits; or why not.
redemption_at : I64 -> Try(Str, _)
redemption_at = |now|
	HumanInvite.redeem({
		human: zoe,
		invites: [invite_made({ n: 1, by: "2" })],
		hash: hash(1),
		now,
	}).map_ok(
		|r| {
			state =
				match r.spent.state() {
					Live => "live"
					Spent => "spent"
				}
			"${state}, admits ${r.admission.human().id().to_str()}"
		},
	)

# A redemption: spent, admitting its human; at its making, and just before
# its expiry; refused at its expiry, before its making, and by any other
# hash.
expect redemption_at(1000) == Ok("spent, admits 4")
expect redemption_at(1000 + HumanInvite.lifetime_seconds - 1) == Ok("spent, admits 4")
expect redemption_at(1000 + HumanInvite.lifetime_seconds) == Err(Expired)
expect redemption_at(999) == Err(Expired)
expect HumanInvite.lifetime_seconds == 604800
expect
	HumanInvite.redeem({
		human: zoe,
		invites: [invite_made({ n: 1, by: "2" })],
		hash: hash(2),
		now: 1000,
	}).map_ok(|_| {})
		== Err(NoSuchInvite)
# Redeemed once: the spent invite redeems no more.
expect
	match HumanInvite.redeem({
		human: zoe,
		invites: [invite_made({ n: 1, by: "2" })],
		hash: hash(1),
		now: 1000,
	}) {
		Ok(r) =>
			HumanInvite.redeem({
				human: zoe,
				invites: [r.spent],
				hash: hash(1),
				now: 1000,
			}).map_ok(|_| {})
				== Err(Spent)
		Err(_) => Bool.False
	}
# Open: live, from its making to just before its expiry.
expect invite_made({ n: 1, by: "2" }).is_open(1000)
expect invite_made({ n: 1, by: "2" }).is_open(1000 + HumanInvite.lifetime_seconds - 1)
expect !invite_made({ n: 1, by: "2" }).is_open(1000 + HumanInvite.lifetime_seconds)
expect !invite_made({ n: 1, by: "2" }).is_open(999)

# The open invites a human made: theirs, live and unexpired, among every
# human's.
expect HumanInvites.open_count(
	[
		invite_made({ n: 1, by: "2" }),
		invite_made({ n: 2, by: "2" }),
		invite_made({ n: 3, by: "1" }),
	],
	{ by: id("2"), now: 1000 },
) == 2
expect HumanInvites.open_count([invite_made({ n: 1, by: "2" })], { by: id("2"), now: 1000 + HumanInvite.lifetime_seconds }) == 0
expect
	match HumanInvite.redeem({
		human: zoe,
		invites: [invite_made({ n: 1, by: "2" })],
		hash: hash(1),
		now: 1000,
	}) {
		Ok(r) => HumanInvites.open_count(
			[
				r.spent,
				invite_made({ n: 2, by: "2" }),
			],
			{ by: id("2"), now: 1000 },
		) == 1
		Err(_) => Bool.False
	}

## The redemption of a token for the user `user`, carrying the secret of
## every byte 1, among Zoe's one invite.
token_redemption : Str -> Try(Str, _)
token_redemption = |user|
	HumanInvites.redeem(
		with_zoe_and_bob,
		{
			token: SecretToken.of({ user: id(user), secret: secret(1) }),
			invites: [invite_made({ n: 1, by: "2" })],
			hash: hash(1),
			now: 1000,
		},
	).map_ok(|r| r.admission.human().id().to_str())

# A code redeems for the human it names; one naming an agent or no one, or
# whose secret matches no invite, is the one refusal.
expect token_redemption("4") == Ok("4")
expect token_redemption("3") == Err(CodeRefused)
expect token_redemption("9") == Err(CodeRefused)
expect
	HumanInvites.redeem(
		with_zoe_and_bob,
		{
			token: SecretToken.of({ user: id("4"), secret: secret(1) }),
			invites: [invite_made({ n: 1, by: "2" })],
			hash: hash(2),
			now: 1000,
		},
	).map_ok(|_| {})
		== Err(CodeRefused)

# Its facts to their files and back; each fact that holds no such fact
# refused, naming its file.
expect {
	made = invite_made({ n: 3, by: "2" })
	files = made.to_files()
	files.by == "2".to_utf8()
		and files.state == "live".to_utf8()
		and files.created == "1000".to_utf8()
		and HumanInvite.from_files(made.id(), files) == Ok(made)
}
expect {
	made = invite_made({ n: 3, by: "2" })
	files = made.to_files()
	[
		({ ..files, created: "x".to_utf8() }, "created"),
		({ ..files, expires: "".to_utf8() }, "expires"),
		({ ..files, state: "revoked".to_utf8() }, "state"),
		({ ..files, by: "0".to_utf8() }, "by"),
		({ ..files, hash: "00".to_utf8() }, "hash"),
	].all(|(bad, fact)| HumanInvite.from_files(made.id(), bad).map_ok(|_| {}) == Err(BadFact(fact)))
}

# A redemption's password: 1 to 72 bytes; none, or more, refused; a form at
# fault said.
expect HumanInvites.password_from_form("code=x&password=hunter2".to_utf8()).map_ok(Password.bytes_to_check) == Ok("hunter2".to_utf8())
expect HumanInvites.password_from_form("password=".to_utf8()).map_ok(|_| {}) == Err(BadPassword)
expect HumanInvites.password_from_form("password=${"x".repeat(73)}".to_utf8()).map_ok(|_| {}) == Err(BadPassword)
expect HumanInvites.password_from_form("code=x".to_utf8()).map_ok(|_| {}) == Err(BadForm("The form has no field `password`."))

# Each refusal's status.
expect
	[
		(ByApiKey, 403),
		(Agent(id("3")), 403),
		(Capped, 403),
		(BadForm("x"), 400),
		(BadName, 400),
		(NameTaken, 409),
		(Full, 409),
		(NoSuchHuman, 404),
		(NotInvited, 403),
		(NotYours, 403),
		(BadPassword, 400),
		(CodeRefused, 401),
	].all(|(why, status)| HumanInvites.refusal_notice(why).status == status)

## The route `method` and `path` choose, in the sample directory.
route_of : Str, Str -> Route.Choice
route_of = |method, path|
	Route.choose({
		method: method.to_utf8(),
		path: path.to_utf8(),
		directory: Sample.directory,
	})

# The routes: every resource with every method, and paths that are none.
expect route_of("GET", "/invites") == SignedInOnly(ShowInvites)
expect route_of("POST", "/invites") == SignedInOnly(InviteHuman)
expect route_of("PUT", "/invites") == MethodNotAllowed(GetAndPost)
expect route_of("POST", "/invites/4/again") == SignedInOnly(InviteHumanAgain(id("4")))
expect route_of("GET", "/invites/4/again") == MethodNotAllowed(PostOnly)
expect route_of("PUT", "/invites/4/again") == MethodNotAllowed(PostOnly)
expect route_of("POST", "/invites/redeem") == Open(RedeemHumanInvite)
expect route_of("GET", "/invites/redeem") == MethodNotAllowed(PostOnly)
expect route_of("PUT", "/invites/redeem") == MethodNotAllowed(PostOnly)
expect
	[
		"/invites/x/again",
		"/invites/4",
		"/invites/4/redeem",
		"/invites/",
		"/invites/redeem/x",
	].all(|path| route_of("POST", path) == NotFound)
