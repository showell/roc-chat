## An `Admin` is proof that the user who is acting is an admin. Creating a
## channel and changing its members ask for one in their types, so only an
## admin can do them.
##
## Steve is the only admin, and there are no levels of admin. `of` is the
## only way to get an `Admin`, and it takes a `SignedIn`, so an admin is
## always the user who is acting.
import SignedIn
import UserId

Admin :: SignedIn.{

	## The acting user as an admin, unless they are not one.
	of : SignedIn -> Try(Admin, [NotAdmin])
	of = |acting|
		if acting.user().id() == UserId.chat_owner {
			Ok(Admin.(acting))
		} else {
			Err(NotAdmin)
		}

	is_eq : _
}
