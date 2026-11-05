## A GitHub id is the number GitHub gives an account, which stays with it
## through every rename of its login. It is what ties a human here to a
## GitHub account: their sign-up writes it, digits, in the human's
## `auth/<id>/github-id` (docs/design.md, "Storage"), or the server's owner
## does, for a human who has an account already. GitHub's ids start at 1.
import FactFile

GitHubId :: U64.{

	## The id GitHub's `/user` answered; unless it is 0 (`NotAGitHubId`).
	from_u64 : U64 -> Try(GitHubId, [NotAGitHubId])
	from_u64 = |number| if number == 0 {
		Err(NotAGitHubId)
	} else {
		Ok(GitHubId.(number))
	}

	## The id a `github-id` file holds; unless it holds anything but an id's
	## digits (`NotAGitHubId`).
	from_file : List(U8) -> Try(GitHubId, [NotAGitHubId])
	from_file = |bytes|
		match FactFile.number_from_file(bytes) {
			Ok(number) => GitHubId.from_u64(number)
			Err(NotANumber) => Err(NotAGitHubId)
		}

	## The id's digits, as a `github-id` file and a sign-up's token hold them.
	to_str : GitHubId -> Str
	to_str = |GitHubId.(number)| number.to_str()

	is_eq : _
}

# ── tests
expect GitHubId.from_u64(0) == Err(NotAGitHubId)
expect GitHubId.from_u64(1) == GitHubId.from_file("1\n".to_utf8())
expect GitHubId.from_u64(583231) == GitHubId.from_file(" 583231".to_utf8())
expect GitHubId.from_u64(1) != GitHubId.from_u64(2)
expect GitHubId.from_u64(583231).map_ok(GitHubId.to_str) == Ok("583231")
expect
	[
		"",
		"0",
		"x",
		"-1",
		"583231x",
		"18446744073709551616",
	].all(|text| GitHubId.from_file(text.to_utf8()) == Err(NotAGitHubId))
