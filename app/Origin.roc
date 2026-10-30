## **A WRITE COMES FROM THE CHAT'S OWN PAGES**: the CSRF check every
## request that is not a GET or a HEAD passes before its route. SameSite=Lax
## trusts every `*.lynrummy.com`, so a page on another subdomain could post
## with the victim's cookie; this check refuses it.
##
## A write passes when its `Origin` is the configured origin, or, with no
## `Origin`, its `Sec-Fetch-Site` is `same-origin`. A request with no
## cookie is exempt: a forgery borrows the browser's ambient cookie, and
## without one it acts as nobody, or as the Bearer key it names (agents send
## keys from scripts, with no Origin). So is the invite's redemption (it
## carries no credential at all; its code is one).
Origin := [].{

	## What a request says of where it came from.
	Sent : {
		method : [Get, Head, Post, Other],
		path : List(U8),
		origin : List(List(U8)),
		fetch_site : List(List(U8)),
		has_cookie : Bool,
		has_key : Bool,
	}

	## **MAY THIS REQUEST GO ON TO ITS ROUTE?** `configured` is the
	## config's `.origin`.
	check : Origin.Sent, List(U8) -> [Allowed, CrossOrigin]
	check = |sent, configured|
		match sent.method {
			Get | Head => Allowed
			Post | Other =>
				if sent.path == Str.to_utf8("/invites/redeem") {
					Allowed
				} else if !sent.has_cookie {
					Allowed
				} else {
					match sent.origin {
						[one] => if one == configured Allowed else CrossOrigin
						[] =>
							if sent.fetch_site == [Str.to_utf8("same-origin")] {
								Allowed
							} else {
								CrossOrigin
							}
						_ => CrossOrigin
					}
				}
		}
}

ours : List(U8)
ours = Str.to_utf8("https://chat.lynrummy.com")

post : Origin.Sent
post = {
	method: Post,
	path: Str.to_utf8("/conversations"),
	origin: [ours],
	fetch_site: [],
	has_cookie: True,
	has_key: False,
}

expect Origin.check(post, ours) == Allowed
expect Origin.check({ ..post, origin: [Str.to_utf8("https://evil.lynrummy.com")] }, ours) == CrossOrigin
expect Origin.check({ ..post, origin: [Str.to_utf8("http://chat.lynrummy.com")] }, ours) == CrossOrigin
expect Origin.check({ ..post, origin: [ours, ours] }, ours) == CrossOrigin
# No Origin: Sec-Fetch-Site decides; neither sent is refused.
expect Origin.check({ ..post, origin: [], fetch_site: [Str.to_utf8("same-origin")] }, ours) == Allowed
expect Origin.check({ ..post, origin: [], fetch_site: [Str.to_utf8("same-site")] }, ours) == CrossOrigin
expect Origin.check({ ..post, origin: [] }, ours) == CrossOrigin
# A GET is never refused here; a key without a cookie, and the redemption,
# are exempt; a key beside a cookie is not.
expect Origin.check({ ..post, method: Get, origin: [] }, ours) == Allowed
expect Origin.check({ ..post, origin: [], has_cookie: False, has_key: True }, ours) == Allowed
expect Origin.check({ ..post, origin: [], has_key: True }, ours) == CrossOrigin
expect Origin.check({ ..post, origin: [], has_cookie: False }, ours) == Allowed
expect Origin.check({ ..post, path: Str.to_utf8("/invites/redeem"), origin: [] }, ours) == Allowed
expect Origin.check({ ..post, method: Other, origin: [] }, ours) == CrossOrigin
