## These are the tests of `Html.HttpsUrl`, the one address a page may link
## off the site by: what it takes, and both sides of each refusal.
import Html

HtmlSpec :: [].{}

# An address on another site: `https://`, a host, then nothing, `/` or a
# site path; both sides of each refusal.
expect
	[
		"https://lynrummy.com/",
		"https://lynrummy.com",
		"https://example.org/games/lyn-rummy",
		"https://a-b.c1.example",
	].all(|text| Html.HttpsUrl.from_str(text).map_ok(Html.HttpsUrl.to_str) == Ok(text))
expect
	[
		"http://lynrummy.com/",
		"javascript:alert(1)",
		"//lynrummy.com/",
		"/chat",
		"",
	].all(|text| Html.HttpsUrl.from_str(text) == Err(NotHttps))
expect
	[
		"https://",
		"https:///chat",
		"https://.lynrummy.com/",
		"https://lynrummy..com/",
		"https://lynrummy.com:8080/",
		"https://user@lynrummy.com/",
		"https://lynrummy.com?x",
		"https://lynrummy.com\"/",
	].all(|text| Html.HttpsUrl.from_str(text) == Err(BadHost))
expect
	[
		"https://lynrummy.com//x",
		"https://lynrummy.com/x/",
		"https://lynrummy.com/x?y",
		"https://lynrummy.com/x#y",
		"https://lynrummy.com/../x",
		"https://lynrummy.com/x\"",
	].all(|text| Html.HttpsUrl.from_str(text) == Err(BadPath))
