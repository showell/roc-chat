## This module decides what the human invites' routes may do, with no
## effects, so its tests reach every rule; `HumanInvitesRoute` reads and
## writes the files and answers. The rules:
##
## - Any human, signed in by their own session, invites someone by a name,
##   and a new account holds that name at once. A request with an API key
##   never invites, whoever the key names.
## - The invite's code is single-use, lives seven days, and is shown once;
##   only its hash is kept (`HumanInvite`).
## - Inviting someone again, by the human who invited them or by the admin,
##   is a new invite for the same account, never a new account or a new
##   id. Only a human someone invited is invited again: the founder, who
##   was never invited, is not. And only while they have claimed nothing
##   (`HumanClaim`): for a human who joined, it is refused (`Joined`), as
##   their password changes only with their own proof.
## - A human has at most `open_most` open invites at once, counting every
##   invite they made that is live and unexpired for a human who has claimed
##   nothing. A joined human's live invites redeem nothing, so they don't
##   count.
## - In a person's first day they make at most a few new invites
##   (`NewcomerInvites`), a 403 past it.
## - A new human's name, the inviter's choice or the invitee's, is held to
##   `Directory.check_new_human_name`: free in any case, not reserved, and
##   not one that looks like a name the chat holds.
## - The new account starts in the default channel, so the invited human has
##   somewhere to land when they join.
##
## The invited human joins from a link that holds the code. Joining
## redeems it: they keep the name their inviter chose or take any other free
## name, and choose a password, as they sign in with one. Their name is
## theirs from then on. An invite redeems only for a human who has claimed
## nothing, so no invite, a later one or one made before they joined, sets
## the password of a human who joined. Joining needs no other credential; a
## request with an API key, or from a browser signed in already, may not
## join. A name refused spends nothing, so the human tries another.
import Admin
import Agents
import Channels
import Directory
import HumanClaim
import HumanInvite
import Name
import NewcomerInvites
import Password
import SecretHash
import SecretToken
import SignUpLimits
import SignedIn
import Timestamp
import UrlEncodedForm
import UserId
import Users

HumanInvites :: [].{

	## Every reason a human invites' route refuses, as `refusal_notice`
	## takes it.
	Refusal : [
		ByApiKey,
		Agent(UserId),
		Capped,
		FirstDayFull(Timestamp),
		BadForm(Str),
		BadName,
		NameTaken,
		NameReserved,
		NameTooClose,
		Full,
		SignUpsPaused,
		NoDefaultChannel,
		NoSuchHuman,
		NotInvited,
		NotYours,
		Joined,
		BadPassword,
		CodeRefused,
		SignedInAlready,
	]

	## A refusal in words, with its status: a request with a key, an agent,
	## a human at the cap, one past their first day's invites, or one who may
	## not invite this human again, or one who has joined, a 403; no such
	## human, a 404; a form at
	## fault, a name that is no name or a password that is none, a 400; a
	## name taken, reserved, too close to another or chosen already, the
	## chat full, or a browser signed in already, a 409; no default channel,
	## a 500; sign-ups paused (`SignUpLimits`), a 503; and any refusal of an
	## invite's code one 401 that says no more.
	refusal_notice : HumanInvites.Refusal -> { status : U16, said : Str }
	refusal_notice = |why|
		match why {
			ByApiKey => {
				status: 403,
				said: "An API key can't invite or join: only a human, signed in, invites.",
			}
			Agent(_) => { status: 403, said: "An agent can't invite anyone." }
			Capped => {
				status: 403,
				said: "You have as many open invites as one person may (${HumanInvites.open_most.to_str()}).",
			}
			FirstDayFull(until) => { status: 403, said: NewcomerInvites.full_words(until) }
			BadForm(said) => { status: 400, said }
			BadName => {
				status: 400,
				said: "The name is not a name: letters and single spaces, at most 60.",
			}
			NameTaken => { status: 409, said: "The name is taken." }
			NameReserved => {
				status: 409,
				said: "The name is reserved: it is, or looks like, a role's or the chat's own. Choose another.",
			}
			NameTooClose => {
				status: 409,
				said: "The name is too close to one the chat already has: it could be mistaken for it. Choose another.",
			}
			Full => { status: 409, said: "The chat holds as many as it can." }
			SignUpsPaused => { status: 503, said: SignUpLimits.paused_words }
			NoDefaultChannel => {
				status: 500,
				said: "This chat has no ${Channels.default_name.to_str()} channel for a new human to start in.",
			}
			NoSuchHuman => { status: 404, said: "No such human." }
			NotInvited => { status: 403, said: "Only a human someone invited is invited again." }
			NotYours => {
				status: 403,
				said: "Only the human who invited them, or the admin, invites them again.",
			}
			Joined => {
				status: 403,
				said: "They have joined, so a new link would change nothing: they sign in with their own password or GitHub.",
			}
			BadPassword => { status: 400, said: "A password is 1 to 72 bytes." }
			CodeRefused => { status: 401, said: "The invite code is not live." }
			SignedInAlready => {
				status: 409,
				said: "You are signed in already. Sign out first, or open the link in a private window.",
			}
		}

	## The most open invites one human may have at once.
	open_most : U64
	open_most = 10

	## How many of `invites`, one invited human's, the human `by` made that
	## are open at `now`; none once that human has claimed their account
	## (`claim`), since an invite then redeems nothing
	## (`InviteRights.load_unclaimed_invitee!`).
	open_count : List(HumanInvite),
	{
		by : UserId,
		now : Timestamp,
		claim : [Unclaimed(HumanClaim.Unclaimed), Claimed],
	} -> U64
	open_count = |invites, { by, now, claim }| {
		open = invites.count_if(|invite| invite.invite_maker() == by and invite.is_open(now))
		match claim {
			Unclaimed(_) => open
			Claimed => 0
		}
	}

	## Who invited a human: the human `InvitedBy` names, or no one
	## (`NoInviter`: the founder, or a human the server's owner made by hand).
	Inviter : [InvitedBy(UserId), NoInviter]

	## The inviter a human's `inviter` file names: none, `NoInviter`; or an
	## id's digits.
	inviter_from_file : [NoFile, File(List(U8))] -> Try(HumanInvites.Inviter, [NotAnInviter])
	inviter_from_file = |file|
		match file {
			NoFile => Ok(NoInviter)
			File(bytes) =>
				UserId.from_file(bytes)
					.map_ok(|id| InvitedBy(id))
					.map_err(|NotAUserId| NotAnInviter)
		}

	## `directory` with a human named by the form `body`'s field `name`,
	## invited by `acting`, who has `open` invites open now; the new human,
	## the human who invited them, and the default channel, which holds the
	## new human; or why not.
	invite : Directory,
	{
		acting : SignedIn,
		body : List(U8),
		open : U64,
	} -> Try(
		{
			directory : Directory,
			human : Users.User,
			inviter : Users.Human,
			channel : Channels.Channel,
		},
		[
			ByApiKey,
			Agent(UserId),
			Capped,
			BadForm(Str),
			BadName,
			NameTaken,
			NameReserved,
			NameTooClose,
			Full,
			SignUpsPaused,
			NoDefaultChannel,
		],
	)
	invite = |directory, { acting, body, open }| {
		inviter = acting.human_in_session()?
		if open >= HumanInvites.open_most {
			Err(Capped)
		} else {
			name = HumanInvites.name_from_form(body)?
			addition = directory.add_new_human(name)?
			Ok({
				directory: addition.directory,
				human: addition.user,
				inviter,
				channel: addition.channel,
			})
		}
	}

	## May `acting` invite again a human whose inviter is `inviter`? Yes when
	## they invited them, or are the admin; never a human no one invited.
	is_theirs_to_invite_again : SignedIn, HumanInvites.Inviter -> Bool
	is_theirs_to_invite_again = |acting, inviter|
		match (inviter, Admin.of(acting)) {
			(NoInviter, Ok(_)) => Bool.False
			(NoInviter, Err(NotAdmin)) => Bool.False
			(InvitedBy(_), Ok(_)) => Bool.True
			(InvitedBy(who), Err(NotAdmin)) => who == acting.user().id()
		}

	## The human `human`, whose inviter is `inviter`, invited again by
	## `acting`, who has `open` invites open now; and `acting`, as the human
	## who makes the invite; or why not.
	reinvite : Directory,
	{
		acting : SignedIn,
		human : UserId,
		inviter : HumanInvites.Inviter,
		open : U64,
	} -> Try(
		{ human : Users.Human, by : Users.Human },
		[
			ByApiKey,
			Agent(UserId),
			NoSuchHuman,
			NotInvited,
			NotYours,
			Capped,
		],
	)
	reinvite = |directory, { acting, human, inviter, open }| {
		by = acting.human_in_session()?
		invited =
			match directory.users().user(human) {
				Ok(user) => user.as_human().map_err(|_| NoSuchHuman)
				Err(NoSuchUser) => Err(NoSuchHuman)
			}?
		match inviter {
			NoInviter => Err(NotInvited)
			InvitedBy(_) =>
				if !HumanInvites.is_theirs_to_invite_again(acting, inviter) {
					Err(NotYours)
				} else if open >= HumanInvites.open_most {
					Err(Capped)
				} else {
					Ok({ human: invited, by })
				}
		}
	}

	## The name a form `body` holds in its field `name`; or why not.
	name_from_form : List(U8) -> Try(Name, [BadForm(Str), BadName])
	name_from_form = |body| {
		unchecked = UrlEncodedForm.field({ body, name: "name" }) ? |fault| BadForm(
			UrlEncodedForm.fault_words({ fault, name: "name" }),
		)
		unchecked.name().map_err(|_| BadName)
	}

	## The password a redemption's form `body` holds in its field
	## `password`; or why not.
	password_from_form : List(U8) -> Try(Password, [BadForm(Str), BadPassword])
	password_from_form = |body| {
		unchecked = UrlEncodedForm.field({ body, name: "password" }) ? |fault| BadForm(
			UrlEncodedForm.fault_words({ fault, name: "password" }),
		)
		unchecked.password().map_err(|NotAPassword| BadPassword)
	}

	## The invite's code a redemption's form `body` holds in its field
	## `code`, read as an agent's invite's code is (`Agents.code_from_form`):
	## both are a `SecretToken`.
	code_from_form : List(U8) -> Try(SecretToken, [BadForm(Str), CodeRefused])
	code_from_form = |body| Agents.code_from_form(body)

	## Whether `actor` may join: anyone signed in by no one. A request with
	## an API key is refused (`ByApiKey`), and so is a browser signed in
	## already (`SignedInAlready`), as joining would sign it in as someone
	## else.
	admit_joiner : SignedIn.Actor -> Try({}, [ByApiKey, SignedInAlready])
	admit_joiner = |actor|
		match actor {
			Anonymous => Ok({})
			SignedIn(acting) =>
				match acting.credential() {
					ApiKey(_) => Err(ByApiKey)
					Session => Err(SignedInAlready)
				}
		}

	## A code, the invite it names, and that invite's human, as joining
	## reads them.
	JoinCode : {
		token : SecretToken,
		invites : List(HumanInvite),
		hash : SecretHash,
		now : Timestamp,
	}

	## The human the code `token` names, whose secret's hash is `hash`, and
	## the invite among theirs, `invites`, it opens at `now`; or
	## `CodeRefused`, whatever was wrong, a token naming no human included.
	find_invitee : Directory,
	HumanInvites.JoinCode -> Try(
		{ human : Users.Human, redeemable : HumanInvite.Redeemable },
		[CodeRefused],
	)
	find_invitee = |directory, { token, invites, hash, now }| {
		user = directory.users().user(token.user()) ? |NoSuchUser| CodeRefused
		human = user.as_human() ? |Agent(_)| CodeRefused
		redeemable = HumanInvite.find_redeemable(invites, { hash, now }) ? |_| CodeRefused
		Ok({ human, redeemable })
	}

	## The human the code names joining under `name`: the invite spent, the
	## human admitted as named, and whether the name `Changed` or was
	## `Kept`. The code is judged first (`CodeRefused`), so a name is judged
	## only for its invitee, who must be `unclaimed`, the human the code
	## names having claimed nothing (`HumanClaim`): any other is the same
	## `CodeRefused`. A new name another user or a channel has, in any case,
	## is refused (`NameTaken`), as is one reserved or too close to another
	## (`Directory.rename_human`).
	join : Directory,
	{
		code : HumanInvites.JoinCode,
		name : Name,
		unclaimed : HumanClaim.Unclaimed,
	} -> Try(
		{
			spent : HumanInvite,
			admission : HumanInvite.Admission,
			name : [Kept, Changed],
		},
		[CodeRefused, NameTaken, NameReserved, NameTooClose],
	)
	join = |directory, { code, name, unclaimed }| {
		found = HumanInvites.find_invitee(directory, code)?
		if unclaimed.human().id() != found.human.id() {
			Err(CodeRefused)
		} else if found.human.user().name() == name {
			redeemed = HumanInvite.redeem(found.redeemable, { unclaimed, human: found.human })
			Ok({
				spent: redeemed.spent,
				admission: redeemed.admission,
				name: Kept,
			})
		} else {
			renamed =
				match directory.rename_human({ human: found.human, name }) {
					Ok(done) => Ok(done.human)
					Err(NameTaken) => Err(NameTaken)
					Err(NameReserved) => Err(NameReserved)
					Err(NameTooClose) => Err(NameTooClose)
					Err(NoSuchHuman) =>
						crash "HumanInvites.join: the invitee is a human of the directory, found in it by id"
				}?
			redeemed = HumanInvite.redeem(found.redeemable, { unclaimed, human: renamed })
			Ok({
				spent: redeemed.spent,
				admission: redeemed.admission,
				name: Changed,
			})
		}
	}
}
