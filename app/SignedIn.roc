## **WHO IS ACTING, AS THE EDGE CHECKED THEM**: proof that the user doing
## something is that user, the one thing a `Users.User` alone never
## proves. What only the acting user may do asks for one in its type, so
## an admin is only ever someone signed in (`Admin.of`).
##
## **THE DOOR IS DANGEROUS UNTIL SESSIONS EXIST**: its one door belongs to
## the session check, which the edge will make. Until then the door is
## `dangerously_assume`, which checks nothing, and only the edge, the demo
## and tests may call it. Its callers are the audit.
##
## **ONE OF THE TRUST BOUNDARIES**: this is who is acting;
## `UnvalidatedString` is the way text from outside comes in, `TrustedHtml`
## the way out to a page, and `SecureImageTag` rules which images a message
## may show. A security reader starts at any of the four.
import Name
import Users

SignedIn :: Users.User.{

	## **THE DOOR, AND IT IS DANGEROUS**: `user`, taken as signed in with
	## nothing checked. It stands in for the session check until sessions
	## exist; only the edge, the demo and tests may call it. A wrong
	## promise lets anyone act as anyone.
	dangerously_assume : Users.User -> SignedIn
	dangerously_assume = |user| SignedIn.(user)

	## The user who is acting.
	user : SignedIn -> Users.User
	user = |SignedIn.(acting)| acting

	is_eq : _
}

# ── tests
expect {
	steve = Users.founded_by(Name.from_str("Steve") ?? crash "SignedIn's tests: a name").to_list()
	when_found = steve.first() ?? crash "SignedIn's tests: Steve is the first user"
	SignedIn.dangerously_assume(when_found).user() == when_found
}
