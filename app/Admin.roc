## **AN ADMIN**: proof that the user acting may do what only an admin may,
## for now creating a channel and choosing its members (`Directory`).
## Steve is the only admin, and there are no levels: an admin may do all
## that an admin does. Opaque, so `of` is the rule's one home and the only
## way in, and a function only an admin may call asks for one in its type.
import UserId

Admin :: UserId.{

	## The acting user `id`, as the edge checked it, as an admin; unless
	## they are not one.
	of : UserId -> Try(Admin, [NotAdmin])
	of = |id| if (id == UserId.steve) Ok(Admin.(id)) else Err(NotAdmin)

	is_eq : _
}

# ── tests
## The id `count` after Steve's.
after_steve : U64 -> UserId
after_steve = |count| List.repeat({}, count).fold(
	UserId.steve,
	|at, {}| at.next() ?? crash "Admin's tests: a test's id fits",
)

# Steve is an admin; the id beside his, and the last, are not.
expect Admin.of(UserId.steve) == Ok(Admin.(UserId.steve))
expect [after_steve(1), after_steve(254)].map(Admin.of) == [Err(NotAdmin), Err(NotAdmin)]
