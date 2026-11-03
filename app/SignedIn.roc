## A `SignedIn` is proof that the user doing something is that user, which
## a `Users.User` alone never proves. Whatever only the acting user may do
## asks for a `SignedIn` in its type, so an admin, for one, is always
## someone signed in (`Admin.of`).
##
## The program has no sessions yet, so nothing checks a sign-in. The one
## way in is `dangerously_assume`, which checks nothing; only main and tests
## call it, and its callers are what a security reader audits. When
## sessions exist, the session check becomes the way in.
##
## This module is one of the program's five trust boundaries, and says who
## is acting. The others are `UnvalidatedString`, the way text comes in;
## `TrustedHtml`, the way markup goes out to a page; `SecureImageTag`, which
## images a message may show; and `RequestOrigin`, which refuses a request
## from any origin but the server's own.
import Name
import Users

SignedIn :: Users.User.{

	## `user`, taken as signed in with nothing checked. This is dangerous:
	## a wrong call lets anyone act as anyone. It stands in for the session
	## check until sessions exist, and only main and tests call it.
	dangerously_assume : Users.User -> SignedIn
	dangerously_assume = |user| SignedIn.(user)

	## The user who is acting.
	user : SignedIn -> Users.User
	user = |SignedIn.(acting)| acting

	is_eq : _
}

# ── tests
expect {
	founded = Users.with_founder(Name.from_str("Steve") ?? crash "SignedIn's tests: Steve is a name")
	steve = founded.to_list().first() ?? crash "SignedIn's tests: Steve is the first user"
	SignedIn.dangerously_assume(steve).user() == steve
}
