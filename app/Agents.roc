## This module decides what the `/agents` routes may do, with no effects,
## so its tests reach every rule; `AgentsRoute` reads and writes the files
## and answers. The rules are roc-chat's:
##
## - A human signed in by their own session makes an agent, which they
##   then own, and invites it. A request with an API key may do neither,
##   whoever the key names: a key never makes an agent, invites, or lists
##   or revokes keys (`SignedIn.human_in_session`).
## - An agent's key comes only from redeeming an invite, so humans never
##   pass a durable secret around (`AgentInvite`, `AgentKey`). A redemption
##   needs no other credential, and a request with an API key may not
##   redeem: a key never mints a key.
## - A human manages only the agents they own: their keys and invites are
##   listed, and revoked, by their owner alone.
import AgentInvite
import AgentKey
import Directory
import KeyScope
import SecretToken
import SignedIn
import UnvalidatedString
import UrlEncodedForm
import UserId
import Users

Agents :: [].{

	## Every reason an `/agents` route refuses, as `refusal_notice` takes it.
	Refusal : [
		ByApiKey,
		Agent(UserId),
		NoSuchAgent,
		NotTheOwner,
		BadForm(Str),
		BadName,
		NameTaken,
		Full,
		NoSuchKey,
		NoSuchInvite,
		AlreadyRevoked,
		Spent,
		CodeRefused,
	]

	## A refusal in words, with its status: a request with a key, or a
	## human who doesn't own the agent, a 403; no such agent, key or
	## invite, a 404; a form at fault, a 400; a name taken, the chat full,
	## or a key or invite already ended, a 409; and any refusal of an
	## invite's code one 401 that says no more.
	refusal_notice : Agents.Refusal -> { status : U16, said : Str }
	refusal_notice = |why|
		match why {
			ByApiKey => {
				status: 403,
				said: "An API key can't do this: only a human, signed in, makes, invites and manages agents, and a key never mints a key.",
			}
			Agent(_) => { status: 403, said: "An agent can't make, invite or manage agents." }
			NoSuchAgent => { status: 404, said: "No such agent." }
			NotTheOwner => { status: 403, said: "Only the agent's owner manages it." }
			BadForm(said) => { status: 400, said }
			BadName => {
				status: 400,
				said: "The name is not a name: letters and single spaces, at most 60.",
			}
			NameTaken => { status: 409, said: "The name is taken." }
			Full => { status: 409, said: "The chat holds as many as it can." }
			NoSuchKey => { status: 404, said: "No such key." }
			NoSuchInvite => { status: 404, said: "No such invite." }
			AlreadyRevoked => { status: 409, said: "It is already revoked." }
			Spent => { status: 409, said: "The invite is already redeemed." }
			CodeRefused => { status: 401, said: "The invite code is not live." }
		}

	## The agents `owner` owns, in id order.
	agents_of : Directory, Users.Human -> List(Users.User)
	agents_of = |directory, owner|
		directory.users().to_list().keep_if(
			|user|
				match user.role() {
					Agent(role) => role.owner == owner.id()
					Human => Bool.False
				},
		)

	## The agent `agent`, which `owner` owns; unless no agent has the id
	## (`NoSuchAgent`) or another human owns it (`NotTheOwner`).
	owned_agent : Directory,
	{ owner : Users.Human, agent : UserId } -> Try(
		Users.User,
		[NoSuchAgent, NotTheOwner],
	)
	owned_agent = |directory, { owner, agent }|
		match directory.users().user(agent) {
			Err(NoSuchUser) => Err(NoSuchAgent)
			Ok(user) =>
				match user.role() {
					Human => Err(NoSuchAgent)
					Agent(role) if role.owner == owner.id() => Ok(user)
					Agent(_) => Err(NotTheOwner)
				}
		}

	## `directory` with an agent named by the form `body`'s field `name`,
	## owned by `owner`, and that agent; or why not.
	make : Directory,
	{ owner : Users.Human, body : List(U8) } -> Try(
		Directory.Addition,
		[
			BadForm(Str),
			BadName,
			NameTaken,
			Full,
		],
	)
	make = |directory, { owner, body }| {
		unchecked = UrlEncodedForm.field({ body, name: "name" }) ? |fault| BadForm(
			form_words({
				fault,
				name: "name",
			}),
		)
		name = unchecked.name() ? |_| BadName
		match directory.add_agent({ name, owner }) {
			Ok(addition) => Ok(addition)
			Err(NameTaken) => Err(NameTaken)
			Err(Full) => Err(Full)
			Err(NoSuchOwner) => crash "Agents.make: the owner is a human of the directory, signed in"
		}
	}

	## The scope an invite's form `body` asks for: its `read` and `post`
	## fields, each `everywhere` or `off`, and `everywhere` when the field
	## is not sent; or why not.
	scope_from_form : List(U8) -> Try(KeyScope, [BadForm(Str)])
	scope_from_form = |body| {
		read = reach_field({ body, name: "read" })?
		post = reach_field({ body, name: "post" })?
		Ok(KeyScope.of({ read, post }))
	}

	## The invite's code a redemption's form `body` holds in its field
	## `code`; or why not.
	code_from_form : List(U8) -> Try(SecretToken, [BadForm(Str), CodeRefused])
	code_from_form = |body| {
		unchecked = UrlEncodedForm.field({ body, name: "code" }) ? |fault| BadForm(
			form_words({
				fault,
				name: "code",
			}),
		)
		unchecked.secret_token().map_err(|NotAToken| CodeRefused)
	}

	## The key `key` of an agent's `keys`, revoked; or why not.
	revoked_key : List(AgentKey), AgentKey.Id -> Try(AgentKey, [NoSuchKey, AlreadyRevoked])
	revoked_key = |keys, key|
		match keys.find_first(|held| held.id() == key) {
			Err(NotFound) => Err(NoSuchKey)
			Ok(held) => held.revoke()
		}

	## The invite `invite` of an agent's `invites`, revoked; or why not.
	revoked_invite : List(AgentInvite),
	AgentInvite.Id -> Try(
		AgentInvite,
		[
			NoSuchInvite,
			Spent,
			AlreadyRevoked,
		],
	)
	revoked_invite = |invites, invite|
		match invites.find_first(|held| held.id() == invite) {
			Err(NotFound) => Err(NoSuchInvite)
			Ok(held) => held.revoke()
		}
}

## The reach a form's field `name` asks for, `everywhere` when it is not
## sent.
reach_field : { body : List(U8), name : Str } -> Try(KeyScope.Reach, [BadForm(Str)])
reach_field = |{ body, name }|
	match UrlEncodedForm.field({ body, name }) {
		Err(MissingField) => Ok(Everywhere)
		Err(fault) => Err(BadForm(form_words({ fault, name })))
		Ok(unchecked) => unchecked.reach().map_err(|NotAReach| BadForm("The form's `${name}` is `everywhere` or `off`."))
	}

## A form's fault with its field `name`, in words.
form_words : { fault : [MissingField, RepeatedField, BadEscape, NotUtf8], name : Str } -> Str
form_words = |{ fault, name }|
	match fault {
		MissingField => "The form has no field `${name}`."
		RepeatedField => "The form has the field `${name}` more than once."
		BadEscape => "The form's `${name}` holds a % that starts no two hex digits."
		NotUtf8 => "The form's `${name}` is not UTF-8."
	}
