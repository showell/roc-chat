## The rules of who holds a GitHub id and who may link one, read from the
## `github-id` files: `links` is every user's GitHub account as those files
## were read. `GitHubSignIn` holds a sign-in's states and alone makes them;
## these are the facts its steps ask of the links and of the viewer.
import GitHubId
import SignedIn
import UserId
import Users

GitHubLinks :: [].{

	## The human `viewer` starts linking GitHub for: a human, by their own
	## session; unless no one is signed in (`NotSignedIn`), or the request came
	## with an API key (`ByApiKey`), or from an agent (`Agent`).
	human_to_link : SignedIn.Actor -> Try(Users.Human, [NotSignedIn, ByApiKey, Agent(UserId)])
	human_to_link = |viewer|
		match viewer {
			Anonymous => Err(NotSignedIn)
			SignedIn(acting) => acting.human_in_session()
		}

	## The human who links `github` to the human `id`: `viewer` must be that
	## human, by their own session (`LinkNotYours`), with no GitHub account of
	## their own (`AlreadyLinked`), and no user may be linked to the id
	## (`GitHubIdTaken`), an agent included, as nothing about a stray file says
	## who it is for.
	human_for_link : {
		id : UserId,
		github : GitHubId,
		links : List({ user : UserId, github : GitHubId }),
		viewer : SignedIn.Actor,
	} -> Try(Users.Human, [LinkNotYours, AlreadyLinked, GitHubIdTaken])
	human_for_link = |{ id, github, links, viewer }|
		match GitHubLinks.human_to_link(viewer) {
			Ok(human) if human.id() == id =>
				if links.any(|link| link.user == id) {
					Err(AlreadyLinked)
				} else if links.any(|link| link.github == github) {
					Err(GitHubIdTaken)
				} else {
					Ok(human)
				}
			_ => Err(LinkNotYours)
		}

	## The humans among `users` whom `links` links to the id `github`.
	humans_holding : {
		github : GitHubId,
		links : List({ user : UserId, github : GitHubId }),
		users : Users,
	} -> List(Users.Human)
	humans_holding = |{ github, links, users }|
		links
			.keep_if(|link| link.github == github)
			.keep_oks(|link| users.user(link.user))
			.keep_oks(|user| user.as_human())
}
