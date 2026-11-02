## **AN ADMIN**: proof that the user acting may do what only an admin may,
## for now creating a channel and choosing its members (`Channels`).
## Steve is the only admin, and there are no levels: an admin may do all
## that an admin does. Opaque, so `of` is the rule's one home and the only
## way in, and a function only an admin may call asks for one in its type.
## `of` takes only a `SignedIn`, so an admin is always the user acting.
import SignedIn
import UserId

Admin :: SignedIn.{

	## The acting user, as the edge checked them, as an admin; unless they
	## are not one.
	of : SignedIn -> Try(Admin, [NotAdmin])
	of = |acting| if (acting.user().id() == UserId.steve) Ok(Admin.(acting)) else Err(NotAdmin)

	is_eq : _
}
