## These are the tests of `HumanInvite` and `HumanInvites`: any human, by
## their own session, invites someone by a name, under a cap of open
## invites; the human who invited them, or the admin, invites them again;
## an invite redeems once, within its seven days, for the human it names;
## joining keeps the name the inviter chose or takes another free one, and
## a name chosen once stays; only someone signed in by no one joins; and
## an invite's facts go to their files and come back. The invites page says
## how each invite stands.
import AgentKey
import Directory
import HumanInvite
import HumanInvites
import KeyScope
import Page
import Password
import PeoplePages
import Route
import Sample
import Seconds
import Secret
import SecretHash
import SecretToken
import SignedIn
import Timestamp
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
		now: Timestamp.at_second(0),
		scope: KeyScope.of({ read: Everywhere, post: Everywhere }),
	})
	admitted = AgentKey.admit({
		user: Sample.user("CC"),
		keys: [key],
		hash,
		now: Timestamp.at_second(0),
	}) ?? crash "HumanInvitesSpec: CC's key admits"
	SignedIn.by_api_key(admitted)
}

## CC as though a session admitted it, which none does: an agent.
cc_by_session : SignedIn
cc_by_session = SignedIn.dangerously_assume(Sample.user("CC"))

## The id `text` spells, which a test's always does.
id : Str -> UserId
id = |text| UserId.from_str(text) ?? crash "HumanInvitesSpec: an id"

## The sample directory, with the default channel a new human starts in.
with_default_channel : Directory
with_default_channel = Sample.with_default_channel(Sample.directory)

## What inviting by the form `body`, by `acting` with `open` open invites,
## gives: the new human's name and id and their inviter's id, or why not.
invite_of : SignedIn, { body : Str, open : U64 } -> Try(Str, _)
invite_of = |acting, { body, open }|
	HumanInvites.invite(with_default_channel, { acting, body: body.to_utf8(), open })
		.map_ok(
			|made| {
				human = made.human
				"${human.name().to_str()} ${human.id().to_str()} by ${made.inviter.id().to_str()}"
			},
		)

# Any human invites, by their own session, a name a new account holds at
# once; never a key, never an agent.
expect invite_of(steve, { body: "name=Zoe", open: 0 }) == Ok("Zoe 4 by 1")
expect invite_of(apoorva, { body: "name=Zoe+Smith", open: 0 }) == Ok("Zoe Smith 4 by 2")
expect
	HumanInvites.invite(
		with_default_channel,
		{
			acting: steve,
			body: "name=Zoe".to_utf8(),
			open: 0,
		},
	).map_ok(
		|made|
			match made.directory.users().user(id("4")) {
				Ok(user) => user.role() == Human and made.channel.members_file() == "1\n4\n".to_utf8()
				Err(NoSuchUser) => Bool.False
			},
	)
		== Ok(Bool.True)
# A chat whose default channel is gone invites no one.
expect
	HumanInvites.invite(
		Sample.directory,
		{
			acting: steve,
			body: "name=Zoe".to_utf8(),
			open: 0,
		},
	).map_ok(|_| {})
		== Err(NoDefaultChannel)
expect HumanInvites.refusal_notice(NoDefaultChannel).status == 500
expect invite_of(cc_by_key, { body: "name=Zoe", open: 0 }) == Err(ByApiKey)
expect invite_of(cc_by_session, { body: "name=Zoe", open: 0 }) == Err(Agent(id("3")))
# The cap: nine open, a tenth made; ten or more open, none.
expect invite_of(steve, { body: "name=Zoe", open: 9 }) == Ok("Zoe 4 by 1")
expect [10, 11].all(|open| invite_of(steve, { body: "name=Zoe", open }) == Err(Capped))
# A form at fault, a name that is no name, one taken in any case, a full chat.
expect invite_of(steve, { body: "", open: 0 }) == Err(BadForm("The form has no field `name`."))
expect ["name=R2D2", "name=", "name=+Zoe"].all(
	|body| invite_of(steve, { body, open: 0 }) == Err(BadName),
)
expect ["name=cc", "name=STEVE", "name=apoorva"].all(
	|body| invite_of(steve, { body, open: 0 }) == Err(NameTaken),
)
expect
	HumanInvites.invite(
		Sample.directory_with_ids_left(0),
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
	with_zoe =
		(with_default_channel.add_human(Sample.name("Zoe")) ?? crash "HumanInvitesSpec: Zoe's name is free")
			.directory
	(with_zoe.add_human(Sample.name("Bob")) ?? crash "HumanInvitesSpec: Bob's name is free")
		.directory
}

bob_user : Users.User
bob_user = with_zoe_and_bob.users().user(id("5")) ?? crash "HumanInvitesSpec: Bob is 5"

## Bob, by his session.
bob : SignedIn
bob = SignedIn.dangerously_assume(bob_user)

## Zoe invited again by `acting` with `open` open invites, her inviter
## `inviter`: the human the invite is for and who makes it, or why not.
reinvite_of : SignedIn,
{
	human : Str,
	inviter : HumanInvites.Inviter,
	open : U64,
} -> Try(Str, _)
reinvite_of = |acting, { human, inviter, open }|
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
		"65536",
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
		now: Timestamp.at_second(1000),
		by: id(by),
	})

zoe : Users.Human
zoe =
	(with_zoe_and_bob.users().user(id("4")) ?? crash "HumanInvitesSpec: Zoe is 4").as_human()
		?? crash "HumanInvitesSpec: Zoe is a human"

## Zoe's invite 1 found by the hash `hash(code)` at `now`, and spent for
## her: its state after, and whom it admits; or why not.
zoes_redemption : {
	invites : List(HumanInvite),
	code : U8,
	now : Timestamp,
} -> Try(Str, _)
zoes_redemption = |{ invites, code, now }|
	HumanInvite.find_redeemable(invites, { hash: hash(code), now }).map_ok(
		|redeemable| {
			redeemed = HumanInvite.redeem(redeemable, zoe)
			"${state_word(redeemed.spent)}, admits ${redeemed.admission.human().id().to_str()}"
		},
	)

## An invite's state, as a test reads it.
state_word : HumanInvite -> Str
state_word = |invite|
	match invite.state() {
		Live => "live"
		Spent => "spent"
	}

## When an invite made at 1000 expires.
invite_expiry : Timestamp
invite_expiry = Timestamp.at_second(1000).plus(HumanInvite.lifetime_seconds)

## The last second an invite made at 1000 is open.
last_open_second : Timestamp
last_open_second = invite_expiry.plus(Seconds.of(-1))

## Zoe's invite 1, made at 1000, found and spent at `now` by its own code.
redemption_at : Timestamp -> Try(Str, _)
redemption_at = |now| zoes_redemption({
	invites: [invite_made({ n: 1, by: "2" })],
	code: 1,
	now,
})

## Zoe's invite 1, spent.
spent_invite : HumanInvite
spent_invite =
	match HumanInvite.find_redeemable(
		[invite_made({ n: 1, by: "2" })],
		{ hash: hash(1), now: Timestamp.at_second(1000) },
	) {
		Ok(redeemable) => HumanInvite.redeem(redeemable, zoe).spent
		Err(_) => crash "HumanInvitesSpec: Zoe's invite 1 is redeemable at 1000"
	}

## The invites page for Steve at `now`, of `invited`, on a server that doesn't
## offer GitHub, with `shown` and `problem`, as a test reads it.
invites_page : {
	invited : List(PeoplePages.InvitedHuman),
	shown : [NoLink, Link({ human : Users.User, link : Str })],
	problem : [NoProblem, Problem(Str)],
	now : Timestamp,
} -> Str
invites_page = |{ invited, shown, problem, now }|
	Str.from_utf8_lossy(
		PeoplePages.invites({
			viewer: steve,
			users: with_zoe_and_bob.users(),
			invited,
			github: NotOffered,
			shown,
			problem,
			now,
		}).to_utf8(),
	)

## The invites page at `now` of `invited` alone, as a test reads it.
page_of_humans : List(PeoplePages.InvitedHuman), Timestamp -> Str
page_of_humans = |invited, now|
	invites_page({
		invited,
		shown: NoLink,
		problem: NoProblem,
		now,
	})

## The invites page at `now` of Zoe and `invite` alone, as a test reads it.
page_of_invite : HumanInvite, Timestamp -> Str
page_of_invite = |invite, now| page_of_humans([{ human: zoe.user(), invites: [invite] }], now)

## The part of `page` after `heading`, empty when the page has no such heading.
after_heading : Str, Str -> Str
after_heading = |page, heading|
	match page.split_on("<h1>${heading}</h1>") {
		[_, after] => after
		_ => ""
	}

## The list of open invites on `page`, up to the past invites if there are any.
open_part : Str -> Str
open_part = |page| {
	open_and_past = after_heading(page, "Open invites")
	match open_and_past.split_on("<h1>Past invites</h1>") {
		[open_alone, _] => open_alone
		_ => open_and_past
	}
}

## The list of past invites on `page`.
past_part : Str -> Str
past_part = |page| after_heading(page, "Past invites")

## Zoe's button that invites her again, as the page writes it.
zoe_again_button : Str
zoe_again_button = "<form method=\"post\" action=\"/invites/4/again\"><button>Invite Zoe again</button></form>"

# An invite on the page: open to its last second, expired from the next, used
# once spent, each naming who made it.
expect
	open_part(page_of_invite(invite_made({ n: 1, by: "2" }), last_open_second))
		.contains("<p>Zoe: open until 1970-01-08, made by Apoorva.</p>")
expect
	past_part(page_of_invite(invite_made({ n: 1, by: "2" }), invite_expiry))
		.contains("<p>Zoe: expired on 1970-01-08, made by Apoorva.</p>")
expect
	past_part(page_of_invite(spent_invite, Timestamp.at_second(1000)))
		.contains("<p>Zoe: used, made by Apoorva.</p>")
# A maker the chat doesn't hold is named by their id.
expect
	page_of_invite(invite_made({ n: 1, by: "9" }), Timestamp.at_second(1000))
		.contains("<p>Zoe: open until 1970-01-08, made by user 9.</p>")
# No one invited: the page says nothing is open, and has no past invites.
expect {
	page = page_of_humans([], Timestamp.at_second(1000))
	open_part(page).contains("<p>No open invites.</p>")
		and !page.contains("Past invites")
		and !page.contains("A link is shown only once")
}
# An invite open: no word that nothing is open, what a lost link needs, and
# no past invites.
expect {
	page = page_of_invite(invite_made({ n: 1, by: "2" }), Timestamp.at_second(1000))
	open_part(page).contains("<p>A link is shown only once.")
		and open_part(page).contains(zoe_again_button)
		and !page.contains("No open invites.")
		and !page.contains("Past invites")
}
# Only past invites: nothing is open, and the button and what it does are
# under the past invites.
expect {
	page = page_of_invite(spent_invite, Timestamp.at_second(1000))
	open_part(page).contains("<p>No open invites.</p>")
		and !open_part(page).contains(zoe_again_button)
		and past_part(page).contains("the link sets a new password.</p>")
		and past_part(page).contains(zoe_again_button)
}
# Several humans, with one button each, first with invites open and then once
# they expire. Zoe's two open invites are a line each, and her spent one isn't
# shown while she has an open one.
expect {
	made_at = Timestamp.at_second(1000)
	bobs_invite = invite_made({ n: 1, by: "1" })
	zoes = [spent_invite, invite_made({ n: 2, by: "2" }), invite_made({ n: 3, by: "1" })]
	page = page_of_humans(
		[{ human: zoe.user(), invites: zoes }, { human: bob_user, invites: [bobs_invite] }],
		made_at.plus(Seconds.of(1)),
	)
	later = page_of_humans(
		[{ human: zoe.user(), invites: zoes }, { human: bob_user, invites: [bobs_invite] }],
		invite_expiry,
	)
	open_part(page).contains("<p>Zoe: open until 1970-01-08, made by Apoorva.</p>\n<p>Zoe: open until 1970-01-08, made by Steve.</p>\n${zoe_again_button}")
		and !page.contains("Zoe: used")
		and open_part(page).contains("<p>Bob: open until 1970-01-08, made by Steve.</p>")
		and !page.contains("Past invites")
		and open_part(later).contains("<p>No open invites.</p>")
		and past_part(later).contains("<p>Zoe: used, made by Apoorva.</p>\n<p>Zoe: expired on 1970-01-08, made by Apoorva.</p>\n<p>Zoe: expired on 1970-01-08, made by Steve.</p>\n${zoe_again_button}")
		and past_part(later).contains("<p>Bob: expired on 1970-01-08, made by Steve.</p>")
}
# One human open and another past: each in their own list.
expect {
	page = page_of_humans(
		[
			{ human: zoe.user(), invites: [spent_invite] },
			{ human: bob_user, invites: [invite_made({ n: 1, by: "1" })] },
		],
		Timestamp.at_second(1000),
	)
	open_part(page).contains("Bob: open")
		and !open_part(page).contains("Zoe:")
		and past_part(page).contains("Zoe: used")
		and !past_part(page).contains("Bob:")
}
# A human whose invite was never written is past, and says so.
expect
	past_part(page_of_humans([{ human: zoe.user(), invites: [] }], Timestamp.at_second(1000)))
		.contains("<p>Zoe: no invite yet.</p>\n${zoe_again_button}")

## The invites page at 1000 of no one, on a server whose offer is `github`.
page_offering : Page.GitHubOffer -> Str
page_offering = |github|
	Str.from_utf8_lossy(
		PeoplePages.invites({
			viewer: steve,
			users: with_zoe_and_bob.users(),
			invited: [],
			github,
			shown: NoLink,
			problem: NoProblem,
			now: Timestamp.at_second(1000),
		}).to_utf8(),
	)

# What an invite is for mentions GitHub only where GitHub signs people up.
expect page_offering(Offered).contains("<p>An invite brings in someone who doesn&#39;t use GitHub.")
expect page_offering(Offered).contains("Anyone with GitHub can sign up on their own, with no invite.</p>")
expect !page_offering(NotOffered).contains("GitHub")
# A link is shown and a problem said only when there is one, each before the form.
expect {
	page = invites_page({
		invited: [],
		shown: Link({ human: zoe.user(), link: "http://x/join#4-a" }),
		problem: Problem("The <name> is taken."),
		now: Timestamp.at_second(1000),
	})
	page.contains("<p>The &lt;name&gt; is taken.</p>\n<p>Send this link to Zoe.")
		and page.contains("<p class=\"invite-code\">http://x/join#4-a</p>\n<p>An invite brings someone")
}
expect {
	page = page_of_invite(spent_invite, Timestamp.at_second(1000))
	!page.contains("invite-code") and !page.contains("Send this link")
}

# A redemption: spent, admitting its human; at its making, and just before
# its expiry; refused at its expiry, before its making, and by any other
# hash.
expect redemption_at(Timestamp.at_second(1000)) == Ok("spent, admits 4")
expect redemption_at(last_open_second) == Ok("spent, admits 4")
expect redemption_at(invite_expiry) == Err(Expired)
expect redemption_at(Timestamp.at_second(999)) == Err(Expired)
expect HumanInvite.lifetime_seconds == Seconds.of(604800)
expect zoes_redemption({
	invites: [invite_made({ n: 1, by: "2" })],
	code: 2,
	now: Timestamp.at_second(1000),
}) == Err(NoSuchInvite)
# Redeemed once: the spent invite redeems no more, and another of hers still
# does.
expect state_word(spent_invite) == "spent"
expect zoes_redemption({
	invites: [spent_invite],
	code: 1,
	now: Timestamp.at_second(1000),
}) == Err(Spent)
expect
	zoes_redemption({
		invites: [spent_invite, invite_made({ n: 2, by: "2" })],
		code: 2,
		now: Timestamp.at_second(1000),
	})
		== Ok("spent, admits 4")
# Open: live, from its making to just before its expiry.
expect invite_made({ n: 1, by: "2" }).is_open(Timestamp.at_second(1000))
expect invite_made({ n: 1, by: "2" }).is_open(last_open_second)
expect !invite_made({ n: 1, by: "2" }).is_open(invite_expiry)
expect !invite_made({ n: 1, by: "2" }).is_open(Timestamp.at_second(999))
expect !spent_invite.is_open(Timestamp.at_second(1000))

# The open invites a human made: theirs, live and unexpired, among every
# human's.
expect HumanInvites.open_count(
	[
		invite_made({ n: 1, by: "2" }),
		invite_made({ n: 2, by: "2" }),
		invite_made({ n: 3, by: "1" }),
	],
	{ by: id("2"), now: Timestamp.at_second(1000) },
) == 2
expect HumanInvites.open_count(
	[invite_made({ n: 1, by: "2" })],
	{ by: id("2"), now: invite_expiry },
) == 0
expect HumanInvites.open_count(
	[spent_invite, invite_made({ n: 2, by: "2" })],
	{ by: id("2"), now: Timestamp.at_second(1000) },
) == 1

## A code for the user `user`, carrying the secret of every byte 1, among
## `invites`, its hash `hash(code)`, at 1000.
join_code : {
	user : Str,
	invites : List(HumanInvite),
	code : U8,
} -> HumanInvites.JoinCode
join_code = |{ user, invites, code }| {
	token: SecretToken.of({ user: id(user), secret: secret(1) }),
	invites,
	hash: hash(code),
	now: Timestamp.at_second(1000),
}

## The invitee a code for the user `user` finds among Zoe's one invite, by
## its own hash: their id and name.
invitee_of : Str -> Try(Str, _)
invitee_of = |user|
	HumanInvites.find_invitee(
		with_zoe_and_bob,
		join_code({
			user,
			invites: [invite_made({ n: 1, by: "2" })],
			code: 1,
		}),
	).map_ok(|found| "${found.human.id().to_str()} ${found.human.user().name().to_str()}")

# A code finds the human it names and the name they hold; one naming an
# agent or no one, or whose secret matches no invite or a spent one, is the
# one refusal.
expect invitee_of("4") == Ok("4 Zoe")
expect invitee_of("3") == Err(CodeRefused)
expect invitee_of("9") == Err(CodeRefused)
expect
	HumanInvites.find_invitee(
		with_zoe_and_bob,
		join_code({
			user: "4",
			invites: [invite_made({ n: 1, by: "2" })],
			code: 2,
		}),
	).map_ok(|_| {})
		== Err(CodeRefused)
expect
	HumanInvites.find_invitee(
		with_zoe_and_bob,
		join_code({
			user: "4",
			invites: [spent_invite],
			code: 1,
		}),
	).map_ok(|_| {})
		== Err(CodeRefused)

## Zoe, by the code for `user` among `invites` with the hash `hash(code)`,
## joining as `name`: the invite's state after, whom it admits and under
## what name, and whether the name changed; or why not.
join_as : {
	user : Str,
	invites : List(HumanInvite),
	code : U8,
	name : Str,
} -> Try(Str, _)
join_as = |{ user, invites, code, name }|
	HumanInvites.join(
		with_zoe_and_bob,
		{ code: join_code({ user, invites, code }), name: Sample.name(name) },
	).map_ok(
		|joined| {
			changed =
				match joined.name {
					Kept => "kept"
					Changed => "changed"
				}
			human = joined.admission.human()
			human_name = human.user().name().to_str()
			"${state_word(joined.spent)}, admits ${human.id().to_str()} as ${human_name}, ${changed}"
		},
	)

## Zoe's first invite, which she has never redeemed.
first_invite : List(HumanInvite)
first_invite = [invite_made({ n: 1, by: "2" })]

# Zoe joins under the name her inviter chose, or under any other free name,
# her own in another case included; a name another user or a channel has,
# in any case, is refused, and nothing is spent.
expect join_as({
	user: "4",
	invites: first_invite,
	code: 1,
	name: "Zoe",
}) == Ok("spent, admits 4 as Zoe, kept")
expect join_as({
	user: "4",
	invites: first_invite,
	code: 1,
	name: "Zoey",
}) == Ok("spent, admits 4 as Zoey, changed")
expect join_as({
	user: "4",
	invites: first_invite,
	code: 1,
	name: "ZOE",
}) == Ok("spent, admits 4 as ZOE, changed")
expect ["Bob", "bob", "Steve", "CC"].all(
	|name| join_as({
		user: "4",
		invites: first_invite,
		code: 1,
		name,
	}) == Err(NameTaken),
)
# The code is judged before the name: a bad code is the one refusal, whatever
# the name.
expect ["Zoe", "Zoey", "Bob"].all(
	|name| join_as({
		user: "4",
		invites: first_invite,
		code: 2,
		name,
	}) == Err(CodeRefused),
)
expect join_as({
	user: "4",
	invites: [spent_invite],
	code: 1,
	name: "Zoe",
}) == Err(CodeRefused)
# A human who redeemed an invite before chose her name then: redeeming a
# later one keeps it exactly, and any other name, her own in another case
# included, is refused.
expect
	join_as({
		user: "4",
		invites: [spent_invite, invite_made({ n: 2, by: "1" })],
		code: 2,
		name: "Zoe",
	})
		== Ok("spent, admits 4 as Zoe, kept")
expect
	["Zoey", "ZOE", "Bob"].all(
		|name| join_as({
			user: "4",
			invites: [spent_invite, invite_made({ n: 2, by: "1" })],
			code: 2,
			name,
		}) == Err(NameChosen),
	)

# Who may join: no one signed in; never a key, never a browser signed in.
expect HumanInvites.admit_joiner(Anonymous) == Ok({})
expect HumanInvites.admit_joiner(SignedIn(cc_by_key)) == Err(ByApiKey)
expect [
	steve,
	apoorva,
	cc_by_session,
].all(|acting| HumanInvites.admit_joiner(SignedIn(acting)) == Err(SignedInAlready))

# A join's name: a name; none, or one that is no name, refused; a form at
# fault said.
expect
	HumanInvites.name_from_form("code=x&name=Zoey&password=y".to_utf8())
		.map_ok(|name| name.to_str())
		== Ok("Zoey")
expect HumanInvites.name_from_form("name=".to_utf8()).map_ok(|_| {}) == Err(BadName)
expect HumanInvites.name_from_form("name=Zoe%21".to_utf8()).map_ok(|_| {}) == Err(BadName)
expect
	HumanInvites.name_from_form("code=x".to_utf8()).map_ok(|_| {})
		== Err(BadForm("The form has no field `name`."))

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
expect
	HumanInvites.password_from_form("code=x&password=hunter2".to_utf8())
		.map_ok(Password.bytes_to_check)
		== Ok("hunter2".to_utf8())
expect HumanInvites.password_from_form("password=".to_utf8()).map_ok(|_| {}) == Err(BadPassword)
expect
	HumanInvites.password_from_form("password=${"x".repeat(73)}".to_utf8()).map_ok(|_| {})
		== Err(BadPassword)
expect
	HumanInvites.password_from_form("code=x".to_utf8()).map_ok(|_| {})
		== Err(BadForm("The form has no field `password`."))

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
		(SignedInAlready, 409),
		(NameChosen, 409),
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
expect route_of("GET", "/join") == Open(ShowJoin)
expect route_of("POST", "/join") == Open(Join)
expect route_of("POST", "/join/name") == Open(LookUpJoinName)
expect
	[
		"/invites/x/again",
		"/invites/4",
		"/invites/4/redeem",
		"/invites/",
		"/invites/redeem/x",
	].all(|path| route_of("POST", path) == NotFound)
