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
##   was never invited, is not.
## - A human has at most `open_most` open invites at once, counting every
##   invite they made that is live and unexpired.
## - The new account starts in the default channel, so the invited human has
##   somewhere to land when they join.
##
## The invited human joins from a link that holds the code. Joining
## redeems it: they keep the name their inviter chose or take any other free
## name, and choose a password, as they sign in with one. Their name is
## theirs from then on: redeeming a later invite for the same account keeps
## it, and sets a new password. Joining needs no other credential; a
## request with an API key, or from a browser signed in already, may not
## join. A name refused spends nothing, so the human tries another.
import Admin
import Agents
import Channels
import Directory
import FactFile
import HumanInvite
import Name
import Password
import SecretHash
import SecretToken
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
		BadForm(Str),
		BadName,
		NameTaken,
		Full,
		NoDefaultChannel,
		NoSuchHuman,
		NotInvited,
		NotYours,
		BadPassword,
		CodeRefused,
		SignedInAlready,
		NameChosen,
	]

	## A refusal in words, with its status: a request with a key, an agent,
	## a human at the cap, or one who may not invite this human again, a
	## 403; no such human, a 404; a form at fault, a name that is no name or
	## a password that is none, a 400; a name taken or chosen already, the
	## chat full, or a browser signed in already, a 409; no default channel,
	## a 500; and any refusal of an invite's code one 401 that says no more.
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
			BadForm(said) => { status: 400, said }
			BadName => {
				status: 400,
				said: "The name is not a name: letters and single spaces, at most 60.",
			}
			NameTaken => { status: 409, said: "The name is taken." }
			Full => { status: 409, said: "The chat holds as many as it can." }
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
			BadPassword => { status: 400, said: "A password is 1 to 72 bytes." }
			CodeRefused => { status: 401, said: "The invite code is not live." }
			SignedInAlready => {
				status: 409,
				said: "You are signed in already. Sign out first, or open the link in a private window.",
			}
			NameChosen => {
				status: 409,
				said: "Your name is chosen already, and stays as it is: join under it.",
			}
		}

	## The most open invites one human may have at once.
	open_most : U64
	open_most = 10

	## How many of `invites` the human `by` made that are open at `now`.
	open_count : List(HumanInvite), { by : UserId, now : Timestamp } -> U64
	open_count = |
		invites,
		{ by, now },
	| invites.count_if(|invite| invite.by() == by and invite.is_open(now))

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
				match Str.from_utf8(FactFile.word_from_file(bytes)) {
					Ok(digits) =>
						UserId.from_str(digits)
							.map_ok(|id| InvitedBy(id))
							.map_err(|NotAUserId| NotAnInviter)
					Err(_) => Err(NotAnInviter)
				}
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
			Full,
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
	## only for its invitee. A human who redeemed an invite before chose
	## their name then, and keeps it (`NameChosen`); a new name another
	## user or a channel has, in any case, is refused (`NameTaken`).
	join : Directory,
	{ code : HumanInvites.JoinCode, name : Name } -> Try(
		{
			spent : HumanInvite,
			admission : HumanInvite.Admission,
			name : [Kept, Changed],
		},
		[CodeRefused, NameChosen, NameTaken],
	)
	join = |directory, { code, name }| {
		found = HumanInvites.find_invitee(directory, code)?
		if found.human.user().name() == name {
			redeemed = HumanInvite.redeem(found.redeemable, found.human)
			Ok({
				spent: redeemed.spent,
				admission: redeemed.admission,
				name: Kept,
			})
		} else if code.invites.any(|made| made.state() == Spent) {
			Err(NameChosen)
		} else {
			renamed =
				match directory.rename_human({ human: found.human, name }) {
					Ok(done) => Ok(done.human)
					Err(NameTaken) => Err(NameTaken)
					Err(NoSuchHuman) =>
						crash "HumanInvites.join: the invitee is a human of the directory, found in it by id"
				}?
			redeemed = HumanInvite.redeem(found.redeemable, renamed)
			Ok({
				spent: redeemed.spent,
				admission: redeemed.admission,
				name: Changed,
			})
		}
	}
}
