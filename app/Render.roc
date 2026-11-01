## **WHAT EVERY RENDERER OF A MESSAGE DRAWS ALIKE**: the name its poster
## goes by, the login beside it, the header those make, and the message's
## HTML, roc-markdown's. The JSON routes, the pages and their live
## fragments (Bubble.roc) all ask here, so none of them disagree; the
## conversations' routes publish a page's bubbles too, which is why this
## is a module of its own, below both (Conversations.roc keeps its names
## for these, each asking here). Pure.
import md.Md
import AccountCodec
import MessageCodec
import Principal

Render := [].{

	## A message's HTML: roc-markdown's render of its markdown, the one
	## the transcript, the stream and the pages all give.
	html_of : MessageCodec.Fields -> List(U8)
	html_of = |m| Md.render(m.body, Render.markdown)

	## **WHAT THE CHAT TELLS THE RENDERER**: its uploads are the paths under
	## `/user_uploads/`, the only places a member's image or video may load
	## from; none of the chat's own routes is one. The chat serves no
	## uploads yet: this is the folder they will be served from.
	markdown : Md.Options
	markdown = { uploads: Md.uploads_under(Str.to_utf8("/user_uploads/")) }

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
