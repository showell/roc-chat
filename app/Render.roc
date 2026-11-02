## **WHAT EVERY RENDERER OF A MESSAGE DRAWS ALIKE**: the name its poster
## goes by, the login beside it, the header those make, and the message's
## HTML, roc-markdown's. The JSON routes, the pages and their live
## fragments (Bubble.roc) all ask here, so none of them disagree; a
## topic's routes publish a page's bubbles too, which is why this is a
## module of its own, below both. Pure.
import md.Md
import AccountCodec
import Cast
import MessageCodec
import Principal
import Uploads

Render := [].{

	## A message's HTML: roc-markdown's render of its markdown, the one
	## the transcript, the stream and the pages all give.
	html_of : MessageCodec.Fields -> List(U8)
	html_of = |m| Md.render(m.body, Render.markdown)

	## **WHAT THE CHAT TELLS THE RENDERER**: its uploads are the paths under
	## `/chat/uploads/` (Uploads.prefix, UploadPage.roc), the only places a
	## member's image may load from; none of the chat's other routes is one.
	markdown : Md.Options
	markdown = { uploads: Md.uploads_under(Str.to_utf8(Uploads.prefix)) }

	## The name a principal goes by, as the accounts say now; its id where
	## no account holds it.
	name_of : List(Principal), Principal.Id -> Str
	name_of = |accounts, id|
		match Principal.find(accounts, id) {
			Ok(Human(h)) => h.name
			Ok(Agent(a)) => a.name
			Ok(Bot(b)) => b.name
			Err(_) => AccountCodec.id_text(id)
		}

	## **THE GITHUB LOGIN BESIDE A POSTER'S NAME** (DisplayName's promise:
	## a name is self-chosen, a login is not): a human's own; an agent's or
	## a bot's owner's, as the accounts say now. None for a login cleared
	## (GitHub gave it to another account since), nor for a poster, or an
	## owner, no account holds now.
	login_of : List(Principal), Principal.Id -> [Login(Str), NoLogin]
	login_of = |accounts, id|
		match Principal.find(accounts, id) {
			Err(_) => NoLogin
			Ok(p) =>
				match Principal.human_account(accounts, p.answers_to()) {
					Ok(h) if h.login != "" => Login(h.login)
					_ => NoLogin
				}
		}

	## **A MESSAGE'S HEADER, BEFORE ITS TIME**: the poster's name, then, for
	## an agent or a bot, its kind and its owner's login ("CC · agent of
	## @showell"), and for a human, their login when it is not their name.
	## The one rule every bubble's meta line draws. A poster no account
	## holds is its id, which says its kind.
	header_of : List(Principal), Principal.Id -> Str
	header_of = |accounts, id|
		match Principal.find(accounts, id) {
			Err(_) => AccountCodec.id_text(id)
			Ok(p) => {
				name = Render.name_of(accounts, id)
				match (p, Render.login_of(accounts, id)) {
					(Human(_), Login(l)) => if (l == name) name else "${name} · @${l}"
					(Human(_), NoLogin) => name
					(Agent(_), Login(l)) => "${name} · agent of @${l}"
					(Bot(_), Login(l)) => "${name} · bot of @${l}"
					(Agent(_), NoLogin) => "${name} · agent"
					(Bot(_), NoLogin) => "${name} · bot"
				}
			}
		}
}

# ── tests
# The login beside a name: a human's own, an agent's or a bot's owner's;
# none once cleared, nor for an owner, or a poster, no account holds.
## Ann made again with her login cleared.
cleared : Principal
cleared = Principal.Human({
	id: Cast.hid(2),
	sign_in: Cast.github(2),
	login: "",
	name: "H2",
	role: Member,
	generation: Cast.gen(1),
})

## Steve, login `Steve`, his name.
steve : Principal
steve = Principal.Human({
	id: Cast.hid(7),
	sign_in: Cast.github(7),
	login: "Steve",
	name: "Steve",
	role: Member,
	generation: Cast.gen(1),
})

## Ann's agent, named as she is.
posing : Principal
posing = Principal.Agent({
	id: Cast.aid(8),
	name: "H2",
	owner: Cast.hid(2),
	generation: Cast.gen(1),
})

## A bot of Steve's.
steve_bot : Principal
steve_bot = Principal.Bot({
	id: Cast.aid(9),
	name: "commits",
	owner: Cast.hid(7),
	generation: Cast.gen(1),
})

expect Render.login_of(Cast.accounts, Cast.ann.id()) == Login("h2")
expect Render.login_of(Cast.accounts, Cast.ann_agent.id()) == Login("h2")
expect Render.login_of([cleared, Cast.ann_agent], Cast.ann_agent.id()) == NoLogin
expect Render.login_of([Cast.ann_agent], Cast.ann_agent.id()) == NoLogin
expect Render.login_of(Cast.accounts, Principal.Id.Agent(Cast.aid(99))) == NoLogin
# The header: an agent named like a human says whose it is.
expect Render.header_of([Cast.ann, posing], posing.id()) == "H2 · agent of @h2"
expect Render.header_of([Cast.ann, posing], Cast.ann.id()) == "H2 · @h2"
expect Render.header_of([steve, steve_bot], steve_bot.id()) == "commits · bot of @Steve"
expect Render.header_of([steve], steve.id()) == "Steve"
expect Render.header_of([cleared, posing], posing.id()) == "H2 · agent"
expect Render.header_of([cleared], cleared.id()) == "H2"
expect Render.header_of([steve_bot], steve_bot.id()) == "commits · bot"
expect Render.header_of([], posing.id()) == "agent:8"
# A name, or the id no account holds.
expect Render.name_of(Cast.accounts, Cast.ann.id()) == "H2"
expect Render.name_of([], Cast.ann.id()) == "human:2"
