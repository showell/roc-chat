## This module is the one home of the Home link, the first link on the right
## of every signed-in page's top bar (`PageKit.top_bar`): where it goes and
## the words it shows. roc-chat's goes back to lynrummy.com, the site the chat
## sits beside, which reaches Lyn Rummy and its other games.
##
## A fork changes `home` to its own home page: `url` to its address and
## `label` to the link's words. The address is `https://`, a host, then
## nothing, `/` or a path (`Html.HttpsUrl`); the test below holds it to that.
## A fork that wants no Home link sets `home` to `NoHomeLink`.
import Html

HomeLink :: [].{

	## The Home link, or none.
	home : [Link({ url : Str, label : Str }), NoHomeLink]
	home = Link({ url: "https://lynrummy.com/", label: "Home" })
}

# ── tests
# The Home link's address is one an `OffSiteLink` can write.
expect
	match HomeLink.home {
		Link(link) => Html.HttpsUrl.from_str(link.url).is_ok()
		NoHomeLink => Bool.True
	}
