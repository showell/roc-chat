## These are the tests of `GitHubTrip`: the URL that sends a browser to
## GitHub, and what GitHub answered in the way back's query.
import GitHubTrip

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
