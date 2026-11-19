## These are the tests of `GitHubTrip`: the URL that sends a browser to
## GitHub, what GitHub answered in the way back's query, and the name a
## sign-up's form offers.
import Directory
import GitHubId
import GitHubSignIn
import GitHubSignUp
import GitHubTrip
import Html
import Name
import Sample
import Timestamp

GitHubTripSpec :: [].{}

expect
	GitHubTrip.authorize_url({
		authorize_base: "https://github.com".to_utf8(),
		client_id: "Iv1 x".to_utf8(),
		origin: "https://chat.example.com",
		state_token: "a.1.b.c",
	})
		== "https://github.com/login/oauth/authorize?client_id=Iv1%20x&redirect_uri=https%3a%2f%2fchat.example.com%2flogin%2fgithub&state=a.1.b.c"
# The query's answer: a code, none, or one GitHub wouldn't send.
expect GitHubTrip.answer_in_query("state=x".to_utf8()) == NoCode
expect
	["code=a%20b", "code=a&code=b", "code="].all(
		|query| GitHubTrip.answer_in_query(query.to_utf8()) == BadCode,
	)
expect
	match GitHubTrip.answer_in_query("code=abc&state=x".to_utf8()) {
		Code(code) => code.bytes_to_exchange() == "abc".to_utf8()
		_ => Bool.False
	}

## The name a sign-up's form offers in `directory`, GitHub having called the
## account `login`, the sign-up back from its browser in time.
offer_for : Str, Directory -> _
offer_for = |login, directory| {
	sign_up = GitHubSignUp.issue({
		github: GitHubId.from_u64(300) ?? crash "GitHubTripSpec: an id",
		login: GitHubSignIn.login_heard(login.to_utf8()),
		now: Timestamp.at_second(1000),
		next: Html.SitePath.from_str("/chat") ?? crash "GitHubTripSpec: a site path",
	})
	resumed =
		GitHubSignIn.SignUpResumed.resume({ sign_up: Signed(sign_up), viewer: Anonymous, now: Timestamp.at_second(1300) })
			?? crash "GitHubTripSpec: a sign-up in time"
	GitHubTrip.name_offer(resumed, directory)
}

# The login is offered when it is a name and free, as GitHub spells it.
expect offer_for("Zoe", Sample.directory) == Suggested(Name.from_str("Zoe") ?? crash "GitHubTripSpec: a name")
# A login that is no name, one taken in any case, none this chat shows, and a
# chat that is full, offer nothing, each saying why.
expect ["person9", "mona-lisa"].all(|login| offer_for(login, Sample.directory) == NotSuggested(LoginNotAName))
expect ["Steve", "sTeVe", "apoorva"].all(|login| offer_for(login, Sample.directory) == NotSuggested(LoginTaken))
expect ["octo_cat", ""].all(|login| offer_for(login, Sample.directory) == NotSuggested(NoLogin))
expect offer_for("Zoe", Sample.directory_with_ids_left(0)) == NotSuggested(ChatFull)
