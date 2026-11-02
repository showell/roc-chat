## **THE USERS PAGE, AN ADMIN'S** (Steve, 2026-11-02): every human, by id,
## each with a **Remove** button where they may be erased (Erase.plan: in
## no channel, nor any agent of theirs; never the admin themselves, nor an
## admin), or why not; the button's are-you-sure is the page's script's
## (js/users_page.js). Removing erases them and everything of theirs
## (Store.erase!), and the browser lands back on the page.
##
##     GET  /chat/users               the page
##     POST /chat/users/<n>/remove    human `n` erased; a 303 back
##
## For an admin by their own session; signed out, the page to `/login` (the
## form, a 401); a key, a 403; anyone else, a 403 that says why. A human
## who may not be erased, a 409 saying why; no such human, a 404.
import pf.Chat
import Channel
import Chrome
import Erase
import Html
import Pages
import Principal
import Render
import Store
import Stored
import Topics
import Wire

UsersPage := [].{

	## What a path asks of the users page.
	Route : [Page, Remove(Principal.HumanId)]

	## The route a path names, if it names one.
	route : List(U8) -> Try(UsersPage.Route, [NotUsers])
	route = |path|
		match path.split_on('/') {
			[
				[],
				chat,
				users,
			] if chat == "chat".to_utf8() and users == "users".to_utf8() => Ok(Page)
			[
				[],
				chat,
				users,
				n,
				remove,
			] if chat == "chat".to_utf8() and users == "users".to_utf8() and remove == "remove".to_utf8() =>
				Stored.id(n, { name: "human", make: Principal.HumanId.from_u64 }).map_ok(|h| Remove(h)).map_err(|_| NotUsers)
			_ => Err(NotUsers)
		}

	## **ANSWER IT**: the page to a GET or a HEAD; a removal to a POST.
	answer! : Chat.Request, UsersPage.Route => Chat.Answer
	answer! = |req, r| {
		got =
			match r {
				Page => if (req.method == Get or req.method == Head) page!(req.path) else Ok(Chat.not_allowed(Get))
				Remove(h) => if (req.method == Post) remove!(h) else Ok(Chat.not_allowed(Post))
			}
		match got {
			Ok(answer) => answer
			Err(answer) => answer
		}
	}
}

## **THE ASKING ADMIN**: their id, the accounts and every channel and DM;
## signed out, `signed_out` the answer; a key, the 403 every page gives one;
## anyone else, a 403 that says why.
Asked : {
	me : Principal.Id,
	accounts : List(Principal),
	channels : List(Channel),
}

load_admin! : Chat.Answer => Try(Asked, Chat.Answer)
load_admin! = |signed_out| {
	v = Topics.load_viewer!({})?
	me =
		match v.viewer.who() {
			SignedOut => Err(signed_out)
			Key(_) => Err(Pages.key_refused)
			Session(b) => Ok(b)
		}?
	match Channel.administers(v.viewer, v.accounts) {
		Err(SignedOut) | Err(NoSuchPrincipal) => Err(signed_out)
		Err(NeedsSession) => Err(Pages.key_refused)
		Err(NotAdmin) => Err(Wire.refused(403, "the users page is an admin's"))
		Ok({}) => {
			listed = Store.load_channels!({}).map_err(|_| Chat.failed)?
			Ok({
				me: me.id,
				accounts: v.accounts,
				channels: listed.channels,
			})
		}
	}
}

## **THE PAGE**: each human by id, their name and id, and the Remove button
## or why not. Everything written here is escaped.
page! : List(U8) => Try(Chat.Answer, Chat.Answer)
page! = |here| {
	a = load_admin!(Pages.to_login(here))?
	by_id = |x, y| {
		(i, j) = (x.answers_to().to_u64(), y.answers_to().to_u64())
		if (i < j) Before else if (i > j) After else Same
	}
	humans = a.accounts.keep_if(|p| p.id() == Principal.Id.Human(p.answers_to())).sort_with(by_id)
	row = |p| {
		h = p.answers_to()
		name = Html.text(Render.name_of(a.accounts, p.id()))
		Html.join([
			Html.markup("<li data-human="),
			Html.number(h.to_u64()),
			Html.markup(">"),
			name,
			Html.markup(" (<code>human:"),
			Html.number(h.to_u64()),
			Html.markup("</code>) "),
			match plan_of(a, h) {
				Ok(_) => Html.join([
					Html.markup("<form class=erase method=post action=\"/chat/users/"),
					Html.number(h.to_u64()),
					Html.markup("/remove\" data-name=\""),
					name,
					Html.markup("\"><button>Remove</button></form>"),
				])
				Err(why) => Html.join([
					Html.markup("<span class=muted>"),
					Html.text(Erase.why(why)),
					Html.markup("</span>"),
				])
			},
			Html.markup("</li>\n"),
		])
	}
	Ok(
		Chrome.page({
			title: Html.markup("Users"),
			viewer: Html.text(Render.name_of(a.accounts, a.me)),
			here: Elsewhere,
			kind: Plain,
			body_attrs: Html.join([]),
			body: Html.join([
				Html.markup("<h2>Users</h2>\n<p class=muted>Remove erases a human and everything of theirs: their DMs (both sides), their agents and sessions. Only a human in no channel can be removed.</p>\n<ul id=users>\n"),
				Html.join(humans.map(row)),
				Html.markup("</ul>\n<script src=\"/users_page.js\"></script>\n"),
			]),
		}),
	)
}

## The asking admin's plan for erasing `target` (Erase.plan).
plan_of : Asked, Principal.HumanId -> Try(Erase.Plan, _)
plan_of = |a, target|
	Erase.plan({
		asker: a.me,
		target,
		accounts: a.accounts,
		channels: a.channels,
	})

## **HUMAN `target` ERASED** (Erase.plan decides, Store.erase! does it), and
## a 303 back to the page; a refusal, its words.
remove! : Principal.HumanId => Try(Chat.Answer, Chat.Answer)
remove! = |target| {
	a = load_admin!(Wire.refused(401, "not signed in"))?
	plan =
		plan_of(a, target).map_err(
			|why|
				match why {
					NoSuchHuman => Wire.refused(404, Erase.why(why))
					Yourself | AnAdmin | InChannels(_) => Wire.refused(409, Erase.why(why))
				},
		)?
	match Store.erase!(plan) {
		Failed => Err(Chat.failed)
		Erased => Ok(Chat.respond(303, { content_type: Chat.text, body: [] }) |> Chat.with_header("location", "/chat/users".to_utf8()))
	}
}

# ── tests
expect UsersPage.route("/chat/users".to_utf8()) == Ok(Page)
expect
	match UsersPage.route("/chat/users/7/remove".to_utf8()) {
		Ok(Remove(h)) => h.to_u64() == 7
		_ => Bool.False
	}
expect
	[
		"/chat/users/07/remove",
		"/chat/users/0/remove",
		"/chat/users/x/remove",
		"/chat/users/7",
		"/chat/users/7/erase",
		"/chat/user",
	].all(|path| UsersPage.route(path.to_utf8()).is_err())
