## These are the tests of sign-up hardening's names and invites: a new
## human's name refused when reserved or a lookalike
## (`Directory.check_new_human_name`), a lapsed invitee's name freed
## (`LapsedInvitee`, `Directory.release_humans`).
import Directory
import HumanInvite
import HumanInvites
import LapsedInvitee
import Sample
import SecretHash
import SignedIn
import Timestamp
import UserId

NamesSpec :: [].{}

## The sample directory, with the default channel a new human starts in.
chat : Directory
chat = Sample.with_default_channel(Sample.directory)

## Whether `text` may be a new human's name in `chat`.
new_name : Str -> Try({}, [NameTaken, NameReserved, NameTooClose])
new_name = |text| chat.check_new_human_name({ name: Sample.name(text), leaving: NoOne })

# Free names pass.
expect [
	"Zoe",
	"Bob",
	"Stephen",
	"Apoorva Smith",
	"Steven",
	"Admins",
].all(|text| new_name(text) == Ok({}))
# A name another user or a channel has, in any case, is taken.
expect ["steve", "APOORVA", "cc", "General"].all(|text| new_name(text) == Err(NameTaken))
# Reserved words, in any case, spaced or looking alike, are reserved; and a
# reserved word is said before a lookalike.
expect
	[
		"Admin",
		"Administrator",
		"ROOT",
		"System",
		"Support",
		"Help",
		"Owner",
		"Moderator",
		"Mod",
		"Staff",
		"Security",
		"Roc Chat",
		"LC",
		"C C",
		"Adrnin",
		"Rnod",
		"Lc",
	]
		.all(|text| new_name(text) == Err(NameReserved))
# A name that looks like a user's or a channel's is too close: accents,
# spaces, i for l, rn for m and vv for w.
expect [
	"Stéve",
	"Stève",
	"Ste ve",
	"Apoórva",
	"Apo orva",
	"Generai",
	"Genera I",
].all(|text| new_name(text) == Err(NameTooClose))
expect {
	with_one_more = (chat.add_new_human(Sample.name("Mia Wall")) ?? crash "NamesSpec: Mia's name is free").directory
	["Rnia Wall", "Mia Vvall", "Mla Wall", "Mia Waii"].all(
		|text| with_one_more.check_new_human_name({
			name: Sample.name(text),
			leaving: NoOne,
		}) == Err(NameTooClose),
	)
}
# The rules hold where a new human is made: an invite and a sign-up.
expect chat.add_new_human(Sample.name("Stéve")).map_ok(|_| {}) == Err(NameTooClose)
expect chat.add_new_human(Sample.name("Admin")).map_ok(|_| {}) == Err(NameReserved)
expect
	HumanInvites.invite(
		chat,
		{
			acting: SignedIn.dangerously_assume(Sample.steve),
			body: "name=St%C3%A9ve".to_utf8(),
			open: 0,
		},
	).map_ok(|_| {})
		== Err(NameTooClose)
expect
	HumanInvites.invite(
		chat,
		{
			acting: SignedIn.dangerously_assume(Sample.steve),
			body: "name=Support".to_utf8(),
			open: 0,
		},
	).map_ok(|_| {})
		== Err(NameReserved)
# A human renaming keeps clear of others, but their own name is theirs: a
# lookalike of it passes.
expect chat.rename_human({
	human: Sample.human("Apoorva"),
	name: Sample.name("Apo orva"),
}).map_ok(|_| {}) == Ok({})
expect chat.rename_human({
	human: Sample.human("Apoorva"),
	name: Sample.name("Stéve"),
}).map_ok(|_| {}) == Err(NameTooClose)
expect chat.rename_human({
	human: Sample.human("Apoorva"),
	name: Sample.name("Root"),
}).map_ok(|_| {}) == Err(NameReserved)
# Existing names are never judged: a stored directory holding lookalikes
# reads, and the admin's agents and channels keep their own rules.
expect {
	both = (Sample.directory.add_human(Sample.name("Stéve")) ?? crash "NamesSpec: a free key").directory
	Directory.from_stored({ users: both.users(), channels: both.channels() }).is_ok()
}
expect
	Sample.directory.add_agent({ name: Sample.name("Admin"), owner: Sample.human("Steve") }).is_ok()

# ── Lapsed invitees
## Invite `number`, made at 0 by Steve: it expires at 604800.
invite_made : U64 -> HumanInvite
invite_made = |number|
	HumanInvite.make({
		id: HumanInvite.Id.from_str(number.to_str()) ?? crash "NamesSpec: an invite's number",
		hash: SecretHash.of_digest(List.repeat(number.to_u8_wrap(), 32)),
		now: Timestamp.at_second(0),
		by: UserId.chat_owner,
	})

## `invite` spent.
spend : HumanInvite -> HumanInvite
spend = |invite| HumanInvite.from_facts(invite.id(), { ..invite.to_facts(), state: Spent })

## A human Steve invited, never joined, with invite 1, at `now`.
lapsed_at : I64 -> LapsedInvitee.Facts
lapsed_at = |second| {
	inviter: InvitedBy(UserId.chat_owner),
	invites: [invite_made(1)],
	password: NoPassword,
	github: NotLinked,
	now: Timestamp.at_second(second),
}

# Lapsed from the second the invite expires, and not a second before.
expect LapsedInvitee.is_lapsed(lapsed_at(604800))
expect LapsedInvitee.is_lapsed(lapsed_at(999999))
expect !LapsedInvitee.is_lapsed(lapsed_at(604799))
expect !LapsedInvitee.is_lapsed(lapsed_at(0))
# Never one who wasn't invited, has a password or GitHub, has no invite yet,
# or joined once.
expect !LapsedInvitee.is_lapsed({ ..lapsed_at(604800), inviter: NoInviter })
expect !LapsedInvitee.is_lapsed({ ..lapsed_at(604800), password: HasPassword })
expect !LapsedInvitee.is_lapsed({ ..lapsed_at(604800), github: Linked })
expect !LapsedInvitee.is_lapsed({ ..lapsed_at(604800), invites: [] })
expect !LapsedInvitee.is_lapsed({ ..lapsed_at(604800), invites: [spend(invite_made(1))] })
expect !LapsedInvitee.is_lapsed({
	..lapsed_at(604800),
	invites: [invite_made(1), spend(invite_made(2))],
})
# An invite made again, still open, keeps them; once it expires too, lapsed.
expect {
	again =
		HumanInvite.make({
			id: HumanInvite.Id.from_str("2") ?? crash "NamesSpec: a number",
			hash: SecretHash.of_digest(List.repeat(9, 32)),
			now: Timestamp.at_second(604800),
			by: UserId.chat_owner,
		})
	facts = { ..lapsed_at(604800), invites: [invite_made(1), again] }
	!LapsedInvitee.is_lapsed(facts) and LapsedInvitee.is_lapsed({
		..facts,
		now: Timestamp.at_second(1209600),
	})
}

# Releasing Zoe frees her name, takes her out of the default channel, and
# leaves the counter of ids where it was.
expect {
	with_zoe = chat.add_new_human(Sample.name("Zoe")) ?? crash "NamesSpec: Zoe's name is free"
	zoe = with_zoe.user.as_human() ?? crash "NamesSpec: Zoe is a human"
	before = with_zoe.directory.check_new_human_name({ name: Sample.name("Zoë"), leaving: NoOne })
	released = with_zoe.directory.release_humans([zoe])
	before
		== Err(NameTooClose)
		and with_zoe.directory.humans_alike_list(Sample.name("ZOË")) == [zoe]
		and released.directory.users().user(zoe.id()) == Err(NoSuchUser)
		and released.changed.map(|channel| channel.members_bytes()) == ["1\n".to_utf8()]
		and released.directory.check_new_human_name({
			name: Sample.name("Zoe"),
			leaving: NoOne,
		}) == Ok({})
		and released.directory.users().next_id() == with_zoe.directory.users().next_id()
		and released.directory.add_new_human(Sample.name("Zoe")).is_ok()
}

# An invite is expired from its expiry's second on, never a second before,
# and a spent one never.
expect !invite_made(1).is_expired(Timestamp.at_second(604799))
expect invite_made(1).is_expired(Timestamp.at_second(604800))
expect !spend(invite_made(1)).is_expired(Timestamp.at_second(999999))
# A lapsed invitee beside a lookalike who is not lapsed frees nothing: with
# the lapsed one released, the name is still too close to the other's, so
# no release is planned (`NameRelease.plan_release!` keeps the directory as
# it was, and writes nothing).
expect {
	with_zoe = chat.add_new_human(Sample.name("Zoe")) ?? crash "NamesSpec: Zoe's name is free"
	lapsed = with_zoe.user.as_human() ?? crash "NamesSpec: Zoe is a human"
	both = (with_zoe.directory.add_human(Sample.name("Zoé")) ?? crash "NamesSpec: a free key").directory
	released = both.release_humans([lapsed])
	both.humans_alike_list(Sample.name("Zoe")).len() == 2
		and released.directory.check_new_human_name({
			name: Sample.name("Zoe"),
			leaving: NoOne,
		}) == Err(NameTooClose)
}

# The refusals' statuses and words.
expect {
	reserved = HumanInvites.refusal_notice(NameReserved)
	too_close = HumanInvites.refusal_notice(NameTooClose)
	reserved.status == 409
		and reserved.said.contains("reserved")
		and too_close.status == 409
		and too_close.said.contains("too close")
}
