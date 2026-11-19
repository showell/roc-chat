## These are the tests of `SignInRequest`: where a sign-in page's query and
## its form send the browser once signed in.
import Html
import SignInRequest

SignInRequestSpec :: [].{}

## The `next` a query or a form names, as a test reads it.
next_text : Try(Html.SitePath, [BadNext]) -> Try(Str, [BadNext])
next_text = |next| next.map_ok(Html.SitePath.to_str)

# A query's `next`: none is /chat; a path on this site is itself; any
# other path, another field, or bytes that are no text, refused.
expect next_text(SignInRequest.next_from_query([])) == Ok("/chat")
expect
	next_text(SignInRequest.next_from_query("next=/chat/dm/1_1/plans".to_utf8()))
		== Ok("/chat/dm/1_1/plans")
expect
	[
		"next=",
		"next=//evil.example",
		"next=https://evil.example",
		"next=/a?b",
		"next=/a/../b",
		"to=/agents",
		"next=/agents&x=1",
	].all(|query| SignInRequest.next_from_query(query.to_utf8()) == Err(BadNext))
expect SignInRequest.next_from_query(List.concat("next=/".to_utf8(), [0xff])) == Err(BadNext)
# A form's `next`: none is /chat; a path on this site, decoded, is itself;
# any other, or two, refused.
expect next_text(SignInRequest.next_from_form("name=Steve".to_utf8())) == Ok("/chat")
expect
	next_text(SignInRequest.next_from_form("next=%2Fchat%2Fdm%2F1_1%2Fplans&name=Steve".to_utf8()))
		== Ok("/chat/dm/1_1/plans")
expect
	[
		"next=%2F%2Fevil.example",
		"next=",
		"next=/a&next=/b",
		"next=%G0",
	].all(|body| SignInRequest.next_from_form(body.to_utf8()) == Err(BadNext))
