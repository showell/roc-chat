## **ADMIN'S TESTS**: Steve, signed in, is an admin; every other user
## signed in, a human or an agent, is not.
import Admin
import Sample
import SignedIn

AdminSpec :: [].{}

## Whether the user `text`, signed in, is an admin.
as_admin : Str -> Try({}, [NotAdmin])
as_admin = |text| Admin.of(SignedIn.dangerously_assume(Sample.user(text))).map_ok(|_| {})

expect ["Steve", "Apoorva", "CC"].map(as_admin) == [
	Ok({}),
	Err(NotAdmin),
	Err(NotAdmin),
]
# The last id's user is no admin either.
expect {
	last = Sample.crowded(252).users().to_list().last() ?? crash "AdminSpec: the crowded sample has users"
	(
		last.id().to_str(),
		Admin.of(SignedIn.dangerously_assume(last)).map_ok(|_| {}),
	) == ("255", Err(NotAdmin))
}
expect Admin.of(SignedIn.dangerously_assume(Sample.steve)) == Ok(Sample.admin)
