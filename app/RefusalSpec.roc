## These are the tests of the refusals, held to one contract: each has its
## status; its words name the reason and leak nothing (no user's id, no path
## of the data folder, no hash), and fit one line of plain text, since an
## API's refusal sends them as they are (`HttpAnswer.text`); and a refusal
## page offers nothing the refused person can't use (no form, no button,
## none of the working parts a signed-in page has). Pages are read through
## `PageContract`'s classes and `Html`'s own element names, not their raw
## HTML. Each refusal's exact words are its own module's tests; these hold
## the whole set to the contract.
##
## Not here: the answers themselves (`Http.Response`: a 401's plain line, a
## 405's `allow`, a page's type and policy), since the specs' platform has no
## `pf.Http`, so no module that builds one reaches a spec. `HttpAnswer`'s,
## `Actor`'s, `AnonymousRefusal`'s and `SignInRoute`'s own tests hold those.
## For the same reason, three sets of refusals are pinned by their own
## modules' tests, each one's status and words: a conversation's
## (`ConversationRefusal`, which reaches `pf.Http` through
## `ConversationStream`), no one's at a signed-in route (`AnonymousRefusal`:
## a page's 303 to sign in, else the 401), and a place's to a reader or a
## writer it doesn't admit (`Dispatch.access_refusal`). Nor the upload, post
## and disk limits' 413 and 507 (`UploadRoute`) and `Admission`, which
## another lane is changing; nor the invites' refusals (`HumanInvites`),
## likewise.
import Agents
import ChannelMembers
import FullSessionRoutes
import GitHubRefusal
import Html
import PageContract
import PageKit
import SignUpLimits
import TrustedHtml
import UserId

RefusalSpec :: [].{}

## How the element `name` opens, as `Html` spells it: `<form`.
opening_of : Html.ElementName -> Str
opening_of = |name| {
	whole = Html.element({ name, attributes: [], inner: TrustedHtml.join([]) }).to_utf8()
	Str.from_utf8_lossy(whole.take_first(whole.find_first_index(|b| b == '>') ?? 0))
}

## The class attribute `chosen` is, as `PageContract` spells it on an
## element: `class="panel"`.
class_attribute : PageContract.Class -> Str
class_attribute = |chosen|
	Str.from_utf8_lossy(PageContract.empty_paragraph([PageContract.class(chosen)]).drop_first(3).drop_last(5))

## The classes of a page's working parts, which a refusal never shows.
working_classes : List(PageContract.Class)
working_classes = [Layout, Panel, Compose, Messages, InviteCode, SignInCode, Sidebar, TopBar]

## Whether the page `html` offers nothing to use: no form and no button,
## and none of the working parts of a signed-in page.
offers_nothing : TrustedHtml -> Bool
offers_nothing = |html| {
	text = Str.from_utf8_lossy(html.to_utf8())
	[Form, Button].all(|name| !text.contains(opening_of(name)))
		and working_classes.all(|chosen| !text.contains(class_attribute(chosen)))
}

## The refusal page a route makes of `said`, as the routes do
## (`PageKit.notice` under the title "Refused").
refusal_page : Str -> TrustedHtml
refusal_page = |said| PageKit.notice({ title: "Refused", text: said })

## A user id no sample holds, so words that name it are found out.
stranger_id : UserId
stranger_id = UserId.from_str("4711") ?? crash "RefusalSpec: an id"

## Whether `words` say something and leak nothing: no stranger's id, no
## path of the data folder or the host, no hash; and fit one plain line.
leaks_nothing : Str -> Bool
leaks_nothing = |words|
	!words.is_empty()
		and !words.contains("\n")
		and !words.contains("<")
		and ["4711", "auth/", "users/", "/home", "/tmp", "/var", "data/", ".json", "$2b$"].all(
			|said| !words.contains(said),
		)

# The helpers find what they look for: a form, a button and a panel are
# each seen, so a refusal that showed one would fail.
expect opening_of(Form) == "<form" and class_attribute(Panel) == "class=\"panel\""
expect
	!offers_nothing(Html.element({ name: Form, attributes: [], inner: TrustedHtml.join([]) }))
		and !offers_nothing(Html.element({ name: Button, attributes: [], inner: TrustedHtml.join([]) }))
		and !offers_nothing(Html.element({ name: Div, attributes: [PageContract.class(Panel)], inner: TrustedHtml.join([]) }))
expect !leaks_nothing("user 4711") and !leaks_nothing("") and !leaks_nothing("a\nb")

# Nothing at a path: the 404 page says so and offers nothing.
expect offers_nothing(PageKit.not_found)
# A session a device code started, at a route that hands out a credential:
# the words name the reason and the way out, and the 403 page offers
# nothing, not even a sign-out button (the way out is the top bar's, on
# the pages it may use).
expect {
	words = FullSessionRoutes.refusal_words
	words.contains("signed in with a code from another device")
		and words.contains("sign in with your password or GitHub")
		and leaks_nothing(words)
		and offers_nothing(refusal_page(words))
}

# The agents' refusals: a key, an agent or a human not allowed, a 403; none
# such, a 404; a form at fault, a 400; a name taken, the chat full or a
# thing already ended, a 409; an invite's code refused, one 401. No words
# name the agent's id, and a page of any offers nothing.
expect
	[
		(ByApiKey, 403),
		(Agent(stranger_id), 403),
		(NotAdmin, 403),
		(NotTheOwner, 403),
		(NoSuchAgent, 404),
		(NoSuchKey, 404),
		(NoSuchInvite, 404),
		(BadForm("The form has no field `name`."), 400),
		(BadName, 400),
		(NameTaken, 409),
		(Full, 409),
		(AlreadyRevoked, 409),
		(Spent, 409),
		(CodeRefused, 401),
	].all(
		|(why, status)| {
			notice = Agents.refusal_notice(why)
			notice.status == status and leaks_nothing(notice.said) and offers_nothing(refusal_page(notice.said))
		},
	)
# The channels' refusals, the same way.
expect
	[
		(ByApiKey, 403),
		(Agent(stranger_id), 403),
		(NotAdmin, 403),
		(NoSuchChannel, 404),
		(NoSuchUser, 404),
		(BadForm("The form has no field `name`."), 400),
		(BadName, 400),
		(AlreadyMember, 409),
		(NotMember, 409),
		(NameTaken, 409),
	].all(
		|(why, status)| {
			notice = ChannelMembers.refusal_notice(why)
			notice.status == status and leaks_nothing(notice.said) and offers_nothing(refusal_page(notice.said))
		},
	)
# GitHub's refusals: too many at once a 429; sign-ups paused by
# `SignUpLimits` a 503 in its words; the rest a 403, a 409, a 500 or a 502,
# each saying what went wrong and leaking nothing.
expect GitHubRefusal.refusal_said(GitHubBusy).status == 429
expect
	GitHubRefusal.refusal_said(SignUpsPaused)
		== { status: 503, words: SignUpLimits.paused_words }
expect
	[
		StateForged,
		StateMismatched,
		StateExpired,
		GitHubDenied,
		NotACode,
		CodeRefused,
		GitHubUnreachable,
		GitHubBusy,
		BadIdentity,
		DuplicateAccount,
		SignUpForged,
		SignUpExpired,
		AccountExists,
		NoDefaultChannel,
		LinkNotYours,
		AlreadyLinked,
		GitHubIdTaken,
		SignedInAlready,
		ClockOutOfRange,
		SignUpsPaused,
	].all(
		|why| {
			said = GitHubRefusal.refusal_said(why)
			[403, 409, 429, 500, 502, 503].contains(said.status) and leaks_nothing(said.words)
		},
	)
