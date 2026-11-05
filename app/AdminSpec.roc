## These are the tests of `Admin`: Steve, signed in, is an admin, and every
## other user signed in, human or agent, is not.
import Admin
import Sample
import SignedIn

AdminSpec :: [].{}

## Whether the user `text`, signed in, is an admin.
as_admin : Str -> Try({}, [NotAdmin])
as_admin = |text| Admin.of(SignedIn.dangerously_assume(Sample.user(text))).map_ok(|_| {})

expect as_admin("Steve") == Ok({})
expect as_admin("Apoorva") == Err(NotAdmin)
expect as_admin("CC") == Err(NotAdmin)
# The last id's user is no admin either.
expect {
	last =
		(Sample.directory_with_ids_left(1).add_human(Sample.name("Last")) ?? crash "AdminSpec: one id is left")
			.user
	last.id().to_str() == "65535"
		and Admin.of(SignedIn.dangerously_assume(last)).map_ok(|_| {}) == Err(NotAdmin)
}
expect Admin.of(SignedIn.dangerously_assume(Sample.steve)) == Ok(Sample.admin)
