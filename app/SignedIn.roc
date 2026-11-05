## A `SignedIn` is proof that the user doing something is that user, which
## a `Users.User` alone never proves, and says how they proved it: by a
## session, or by an agent's API key with that key's scope. Whatever only
## the acting user may do asks for a `SignedIn` in its type, so an admin,
## for one, is always someone signed in (`Admin.of`); and whatever only a
## human may do by their own session, such as making an agent or inviting
## one, asks `human_in_session`, so a key never does it.
##
## There are three ways in. `by_session` takes a `Session.Admitted`, which
## only `Session.admit` makes, after the host said the session cookie's
## signature matches and its second is in date (`SignInRoute` checks the
## password, or `GitHubSignIn` the GitHub account, that signs one). `by_api_key` takes an `AgentKey.Admitted`,
## which only `AgentKey.admit` makes, after the hash of the secret an agent
## sent matched a live key of its own (`AgentInvite` is how a key is got).
## The third, `dangerously_assume`, checks nothing. Only main's first start,
## which makes the founder before anyone can sign in, and tests call it,
## and its callers are what a security reader audits.
##
## A request that proves nothing is `Anonymous` (`Actor`), never someone
## signed in: only the routes that take an `Actor` answer it.
##
## This module is one of the program's five trust boundaries, and says who
## is acting, with `AgentKey` and `AgentInvite` behind its key door, and
## `HumanInvite` behind the door a redeemed invite opens
## (`SignInRoute.start_session_by_invite!`), and `GitHubSignIn` behind the
## door a GitHub sign-in opens (`SignInRoute.start_session_by_github!`). The
## others are `UnvalidatedString`, the way text comes in; `TrustedHtml`, the
## way markup goes out to a page; `SecureImageTag`, which images a message
## may show; and `RequestOrigin`, which refuses a request from any origin
## but the server's own.
import AgentKey
import KeyScope
import Name
import Session
import UserId
import Users

SignedIn :: { user : Users.User, credential : SignedIn.Credential }.{

	## How the acting user proved who they are: by a session, or by an API
	## key, with its scope.
	Credential : [Session, ApiKey(KeyScope)]

	## Who is acting: someone signed in, or a request that proves no one
	## (`Anonymous`).
	Actor : [SignedIn(SignedIn), Anonymous]

	## `user`, taken as signed in by a session with nothing checked. This is
	## dangerous: a wrong call lets anyone act as anyone. Only main's first
	## start, which makes the founder, and tests call it.
	dangerously_assume : Users.User -> SignedIn
	dangerously_assume = |user| SignedIn.({ user, credential: Session })

	## The human a session admitted, signed in by that session.
	by_session : Session.Admitted -> SignedIn
	by_session = |admitted| SignedIn.({ user: admitted.human().user(), credential: Session })

	## The agent a key admitted, signed in by that key, with its scope.
	by_api_key : AgentKey.Admitted -> SignedIn
	by_api_key = |admitted| SignedIn.(
		{
			user: admitted.user(),
			credential: ApiKey(admitted.scope()),
		},
	)

	## The user who is acting.
	user : SignedIn -> Users.User
	user = |SignedIn.(acting)| acting.user

	## How they proved it.
	credential : SignedIn -> SignedIn.Credential
	credential = |SignedIn.(acting)| acting.credential

	## The acting human, signed in by their own session; refused when the
	## request came with an API key (`ByApiKey`), whoever it names, or when
	## the user is an agent (`Agent`, its id).
	human_in_session : SignedIn -> Try(Users.Human, [ByApiKey, Agent(UserId)])
	human_in_session = |SignedIn.(acting)|
		match acting.credential {
			ApiKey(_) => Err(ByApiKey)
			Session => acting.user.as_human()
		}

	is_eq : _
}

# ── tests
## The tests' users: Steve, and his agent CC.
tests_users : Users
tests_users = {
	founded =
		Users.with_founder(Name.from_str("Steve") ?? crash "SignedIn's tests: Steve is a name")
	owner =
		(founded.user(UserId.steve) ?? crash "SignedIn's tests: Steve is id 1").as_human()
			?? crash "SignedIn's tests: Steve is a human"
	(
		founded.add_agent({
			name: Name.from_str("CC") ?? crash "SignedIn's tests: CC is a name",
			owner,
		}) ?? crash "SignedIn's tests: CC joins"
	).users
}

steve : Users.User
steve = tests_users.to_list().first() ?? crash "SignedIn's tests: Steve is the first user"

cc : Users.User
cc = tests_users.to_list().last() ?? crash "SignedIn's tests: CC is the last user"

expect SignedIn.dangerously_assume(steve).user() == steve
expect SignedIn.dangerously_assume(steve).credential() == Session
# A human by session is one; an agent by session is not, and nobody by key.
expect SignedIn.dangerously_assume(steve).human_in_session().map_ok(Users.Human.user) == Ok(steve)
expect SignedIn.dangerously_assume(cc).human_in_session() == Err(Agent(cc.id()))
