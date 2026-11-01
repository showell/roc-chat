## **HUMAN INVITES ON THE WIRE** (HumanInvite decides, HumanInviteCodec
## and Store keep them, AuditCodec records each):
##
##     POST /human-invites              invite someone: a form, `name=`, and
##                                      `topic=` and `welcome=` if not the defaults;
##                                      or `for=human:<n>` to invite them again
##     GET  /human-invites              your open invites, never a code
##     POST /human-invites/<id>/revoke  revoke one of them
##     GET  /join                       the redeem page (the code after `#`)
##     POST /join/name                  the name an open invite holds: `code=`
##     POST /join                       redeem: `code=`, and `name=` for another
##
## **ALL AT ONCE, OR NOTHING**: an invite's every decision is made before
## its first write (the account, the DM, its topic, the welcome, the
## code), so a refusal writes nothing. The writes then go account, DM,
## topic, welcome, invite: a failure part way leaves a reserved account
## whose inviter invites them again, never a code for a half-made one.
##
## **THE CODE NEVER REACHES A LOG**: the link is `/join#<code>`, whose
## part after `#` no browser sends; the page's script sends the code in a
## request's body. Only a session invites (a key, a 403); the redemption
## needs no credential (the code is one), and any refusal of it is one
## `401 invite refused`, audited when the code names a stored invite.
import pf.Chat
import pf.Host
import md.Md
import Access
import AccountCodec
import Accounts
import AuditCodec
import Channel
import ChannelName
import Conversations
import Credentials
import Html
import HumanInvite
import JsonOut
import MessageCodec
import Pages
import Principal
import Session
import SignIn
import SignInWeb
import Store
import Stored
import Topic
import Wire

HumanInvites := [].{

	## The routes.
	Route : [
		Invites,
		Revoke(HumanInvite.InviteId),
		Join,
		JoinName,
	]

	## The route a path names, if it names one.
	route : List(U8) -> Try(HumanInvites.Route, [NotHumanInvites])
	route = |path|
		match path.split_on('/') {
			[[], invites] if invites == "human-invites".to_utf8() => Ok(Invites)
			[[], join] if join == "join".to_utf8() => Ok(Join)
			[
				[],
				join,
				name,
			] if join == "join".to_utf8() and name == "name".to_utf8() => Ok(JoinName)
			[
				[],
				invites,
				id,
				revoke,
			] if invites == "human-invites".to_utf8() and revoke == "revoke".to_utf8() =>
				Stored.id(id, { name: "invite", make: HumanInvite.InviteId.from_u64 })
					.map_ok(|n| Revoke(n))
					.map_err(|_| NotHumanInvites)
			_ => Err(NotHumanInvites)
		}

	## **ANSWER IT**, by method.
	answer! : Chat.Request, HumanInvites.Route => Chat.Answer
	answer! = |req, asked|
		match asked {
			Invites =>
				match req.method {
					Post => answered!(invite_from!)
					Get => list!({})
					_ => Chat.not_allowed(Post)
				}
			Revoke(id) => if (req.method == Post) revoke!(id) else Chat.not_allowed(Post)
			Join =>
				match req.method {
					Get | Head => join_page
					Post => answered!(join!)
					_ => Chat.not_allowed(Get)
				}
			JoinName => if (req.method == Post) answered!(answer_name!) else Chat.not_allowed(Post)
		}
}

## The form read, and handed to `then!`; its answer, or the one that ended it.
answered! : (List(U8) => Try(Chat.Answer, Chat.Answer)) => Chat.Answer
answered! = |then!| {
	got = Host.read_body!(Wire.form_most)
	match got.status {
		Answered => Chat.answered
		Read =>
			match then!(got.bytes) {
				Ok(answer) => answer
				Err(answer) => answer
			}
	}
}

## **WHO INVITES**: a human's live session, with the accounts, the time,
## the viewer over topics (for the DM's topic), and their own invites.
Inviter : {
	human : Principal.HumanId,
	session : Principal.SessionId,
	viewer : Access.Viewer(Topic.At),
	accounts : List(Principal),
	now : I64,
	mine : List(HumanInvite.Record),
}

## The inviter asking, or the answer that refuses them.
load_inviter! : {} => Try(Inviter, Chat.Answer)
load_inviter! = |{}| {
	asked = Credentials.load_viewer!(ListConversations)?
	match asked.viewer.who() {
		SignedOut => Err(Wire.refused(401, "not signed in"))
		Key(_) => Err(Wire.refused(403, "a human invites from their own session, never by a key"))
		Session(b) =>
			match (b.id, Credentials.load_credential!({})?) {
				(Human(human), Session(s)) => {
					mine = Store.load_human_invites_of!(human).map_err(|_| Chat.failed)?
					Ok({
						human,
						session: s.id(),
						viewer: Access.Viewer.over(asked.viewer),
						accounts: asked.accounts,
						now: asked.now,
						mine,
					})
				}
				_ => Err(Wire.refused(403, "a human invites from their own session"))
			}
	}
}

## **/human-invites, POST**: a new human's invite, or `for=` one again.
invite_from! : List(U8) => Try(Chat.Answer, Chat.Answer)
invite_from! = |form| {
	inviter = load_inviter!({})?
	match SignInWeb.form_field(form, "for") {
		Ok(text) => invite_again!(inviter, text)
		Err(Missing) => invite_new!(inviter, form)
		Err(Malformed) => Err(Wire.refused(400, "for= is the invited human's id"))
	}
}

## The text of a form's field, or `default` when the form has none.
text_or : List(U8), { name : Str, default : Str } -> Try(Str, Chat.Answer)
text_or = |form, { name, default }|
	match SignInWeb.form_field(form, name) {
		Err(Missing) => Ok(default)
		Ok(bytes) => Str.from_utf8(bytes).map_err(|_| Wire.refused(400, "${name}= is UTF-8 text"))
		Err(Malformed) => Err(Wire.refused(400, "${name}= does not read"))
	}

## **A NEW HUMAN'S INVITE**: every decision first (HumanInvite.invite,
## Channel.dm, Topic.make, the welcome's rule), then each write in order.
invite_new! : Inviter, List(U8) => Try(Chat.Answer, Chat.Answer)
invite_new! = |inviter, form| {
	settings = SignIn.load_settings!({}).map_err(|_| Chat.failed)?
	channels = Store.load_channel_names!({}).map_err(|_| Chat.failed)?
	name = SignInWeb.form_field(form, "name") ?? []
	made =
		HumanInvite.invite({
			by: inviter.human,
			name,
			open: open_count(inviter),
			made: List.len(inviter.mine),
			accounts: inviter.accounts,
			channels,
			settings,
			now: inviter.now,
		}).map_err(invite_refused)?
	after = Accounts.applied(made.steps, { accounts: inviter.accounts, settings })
	dm =
		Channel.dm({
			by: inviter.viewer,
			other: made.human.id(),
			accounts: after.accounts,
		}).map_err(|_| Chat.failed)?
	topic_name = text_or(form, { name: "topic", default: HumanInvite.default_topic })?
	topic =
		Topic.make({
			by: inviter.viewer,
			channel: dm,
			name: topic_name,
			topics: [],
			accounts: after.accounts,
		}).map_err(
			|_| Wire.refused(
				400,
				"a topic's name is letters and digits joined by single hyphens, at most 80",
			),
		)?
	welcome = text_or(
		form,
		{ name: "welcome", default: HumanInvite.default_welcome(inviter_name(inviter)) },
	)?
	body = welcome.to_utf8()
	if body == [] {
		Err(Wire.refused(400, "a welcome says something"))
	} else if Md.hostility(body, Conversations.markdown) == TooMuchFormatting {
		Err(Wire.refused(400, Md.too_much_formatting))
	} else {
		bound = Principal.bind(after.accounts, made.human.id()).map_err(|_| Chat.failed)?
		issued = issue!(inviter, bound)?
		written =
			Store.save_accounts!(after)
				|> and_then!(|_| taken_as_written(Store.save_new_channel!(dm)))
				|> and_then!(|_| taken_as_written(Store.save_new_topic!(topic)))
				|> and_then!(
					|_| {
						files = Store.topic_files(topic.at())
						match Store.load_tally!(files) {
							Err(Failed) => Failed
							Ok(tally) =>
								match Store.append_message!({
									files,
									tally,
									message: {
										id: MessageCodec.next_id(tally.messages),
										at: inviter.now,
										by: Principal.Id.Human(inviter.human),
										body,
									},
								}) {
									Failed => Failed
									Appended => Written
								}
						}
					},
				)
				|> and_then!(|_| Store.save_new_human_invite!(issued.record))
		match written {
			Failed => Ok(Chat.failed)
			Written => {
				audit!({
					record: issued.record,
					verdict: Created(inviter.human),
					now: inviter.now,
				})
				Ok(
					Wire.json(
						201,
						invite_json(
							issued.record,
							{
								name: inviter_name_of(after.accounts, made.human.id()),
								code: Shown(issued.code),
								dm: Made({ dm: dm.name(), topic: topic_name }),
							},
						),
					),
				)
			}
		}
	}
}

## The next write, once the one before it is written.
and_then! : [Failed, Written], ({} => [Failed, Written]) => [Failed, Written]
and_then! = |before, next!|
	match before {
		Failed => Failed
		Written => next!({})
	}

## A new record's write, one already there taken as written (its making
## decided it is new: a DM's channel, a topic in it).
taken_as_written : [
	Failed,
	Taken,
	Written,
] -> [Failed, Written]
taken_as_written = |result|
	match result {
		Failed => Failed
		Taken | Written => Written
	}

## **INVITED AGAIN**: `for=` an invited human (HumanInvite.reinvite).
invite_again! : Inviter, List(U8) => Try(Chat.Answer, Chat.Answer)
invite_again! = |inviter, text| {
	human =
		match AccountCodec.id_from(text, "for") {
			Ok(Human(h)) => Ok(h)
			_ => Err(Wire.refused(400, "for= is the invited human's id"))
		}?
	bound =
		HumanInvite.reinvite({
			asker: inviter.human,
			human,
			open: open_count(inviter),
			made: List.len(inviter.mine),
			accounts: inviter.accounts,
		}).map_err(
			|why|
				match why {
					NoSuchInviter => Wire.refused(401, "not signed in")
					NoSuchHuman => Wire.refused(404, "no human holds that id")
					SignsInByGitHub => Wire.refused(
						400,
						"they sign in with GitHub; an invite is for someone who has no GitHub",
					)
					NotYours => Wire.refused(
						403,
						"only the human who invited them, or an admin, invites them again",
					)
					Capped(OpenInvites) => Wire.refused(
						403,
						"you have as many open invites as one person may (10)",
					)
					Capped(Made) => Wire.refused(
						403,
						"you have made as many invites as one person may",
					)
				},
		)?
	issued = issue!(inviter, bound)?
	match Store.save_new_human_invite!(issued.record) {
		Failed => Ok(Chat.failed)
		Written => {
			audit!({
				record: issued.record,
				verdict: Reinvited(inviter.human),
				now: inviter.now,
			})
			Ok(
				Wire.json(
					201,
					invite_json(
						issued.record,
						{
							name: inviter_name_of(inviter.accounts, bound.id),
							code: Shown(issued.code),
							dm: Again,
						},
					),
				),
			)
		}
	}
}

## **A NEW CODE, AND THE RECORD ITS HASH IS KEPT IN**, for the human
## bound: live for HumanInvite.lifetime_secs, made by the inviter. It
## writes nothing.
issue! : Inviter,
Principal.Bound => Try(
	{ code : List(U8), record : HumanInvite.Record },
	Chat.Answer,
)
issue! = |inviter, human| {
	code = Host.random_bytes!(Wire.secret_bytes)
	hash = Stored.SecretHash.from_bytes(Host.hash!(code)).map_err(|_| Chat.failed)?
	id = Store.load_next_human_invite_id!({}).map_err(|_| Chat.failed)?
	Ok({
		code,
		record: {
			id,
			human,
			by: inviter.human,
			hash,
			created: inviter.now,
			expires: inviter.now + HumanInvite.lifetime_secs,
			state: Live,
		},
	})
}

## The open invites the inviter has now.
open_count : Inviter -> U64
open_count = |inviter| List.count_if(inviter.mine, |r| HumanInvite.is_open(r, inviter.now))

## The inviter's own name, as the accounts hold it.
inviter_name : Inviter -> Str
inviter_name = |inviter| inviter_name_of(inviter.accounts, Principal.Id.Human(inviter.human))

## An account's name, or nothing when no account holds the id.
inviter_name_of : List(Principal), Principal.Id -> Str
inviter_name_of = |accounts, id|
	match Principal.find(accounts, id) {
		Ok(Human(h)) => h.name
		Ok(Agent(a)) => a.name
		Ok(Bot(b)) => b.name
		Err(_) => ""
	}

## A refused invite, said.
invite_refused : _ -> Chat.Answer
invite_refused = |why|
	match why {
		ClockOutOfRange => Chat.failed
		NoSuchInviter => Wire.refused(401, "not signed in")
		Capped(OpenInvites) => Wire.refused(
			403,
			"you have as many open invites as one person may (10)",
		)
		Capped(Made) => Wire.refused(
			403,
			"you have made as many invites as one person may, or the chat holds as many accounts as it may",
		)
		NameRefused(_) => Wire.refused(
			400,
			"a name is 1 to 40 characters of letters, digits, spaces and . - _ '",
		)
		NameTaken => Wire.refused(409, "someone already goes by that name, in some spelling")
		Stuck(_) => Chat.failed
	}

## An invite as the wire spells it: the code only in the answer that made
## it, and the DM a new human's invite made.
invite_json : HumanInvite.Record,
{
	name : Str,
	code : [Shown(List(U8)), Hidden],
	dm : [
		Made({ dm : ChannelName, topic : Str }),
		Again,
		Listed,
	],
} -> JsonOut
invite_json = |
	r,
	{
		name,
		code,
		dm,
	},
| {
	shown =
		match code {
			Shown(bytes) => {
				hex = SignInWeb.hex(bytes)
				[
					("code", JsonOut.text(hex)),
					("link", JsonOut.text("/join#".to_utf8().concat(hex))),
				]
			}
			Hidden => []
		}
	made =
		match dm {
			Made(d) => [
				("dm", JsonOut.string(d.dm.to_str())),
				("topic", JsonOut.string(d.topic)),
			]
			Again | Listed => []
		}
	JsonOut.object(
		[
			("id", JsonOut.number(r.id.to_u64())),
			("for", JsonOut.string(AccountCodec.id_text(r.human.id))),
			("name", JsonOut.string(name)),
			("expires", JsonOut.signed(r.expires)),
		]
			.concat(made)
			.concat(shown),
	)
}

## **/human-invites, GET**: the asker's open invites, by id.
list! : {} => Chat.Answer
list! = |{}|
	match load_inviter!({}) {
		Err(answer) => answer
		Ok(inviter) => {
			open = inviter.mine.keep_if(|r| HumanInvite.is_open(r, inviter.now)).sort_with(by_id)
			Wire.json(
				200,
				JsonOut.object([
					(
						"invites",
						JsonOut.array(
							open.map(
								|r| invite_json(
									r,
									{
										name: inviter_name_of(inviter.accounts, r.human.id),
										code: Hidden,
										dm: Listed,
									},
								),
							),
						),
					),
				]),
			)
		}
	}

## Two invites in their ids' order.
by_id : HumanInvite.Record,
HumanInvite.Record -> [
	Before,
	Same,
	After,
]
by_id = |a, b| {
	(x, y) = (a.id.to_u64(), b.id.to_u64())
	if (x < y) Before else if (x > y) After else Same
}

## **/human-invites/<id>/revoke**: one of the asker's live invites
## revoked; another's, or none live, a 404.
revoke! : HumanInvite.InviteId => Chat.Answer
revoke! = |id|
	match load_inviter!({}) {
		Err(answer) => answer
		Ok(inviter) =>
			match inviter.mine.keep_if(|r| r.id == id).first() {
				Err(_) => Wire.refused(404, "no live invite of yours has that id")
				Ok(r) =>
					match HumanInvite.revoke(r) {
						Err(NotLive) => Wire.refused(404, "no live invite of yours has that id")
						Ok(revoked) =>
							match Store.save_human_invite!(revoked) {
								Failed => Chat.failed
								Written => {
									audit!({
										record: revoked,
										verdict: Revoked(inviter.human),
										now: inviter.now,
									})
									Wire.json(
										200,
										invite_json(
											revoked,
											{
												name: inviter_name_of(inviter.accounts, r.human.id),
												code: Hidden,
												dm: Listed,
											},
										),
									)
								}
							}
					}
			}
	}

## **THE OPEN INVITE A FORM'S `code=` NAMES**, or the refusal (audited by
## the caller).
load_named! : List(U8) => Try(HumanInvite.Record, [Refused(HumanInvite.Refusal), Failed])
load_named! = |form|
	match SignInWeb.form_field(form, "code") {
		Err(_) => Err(Refused(Unknown))
		Ok(hex) =>
			match SignInWeb.unhex(hex) {
				Err(NotHex) => Err(Refused(Unknown))
				Ok(code) =>
					match Stored.SecretHash.from_bytes(Host.hash!(code)) {
						Err(NotAHash) => Err(Failed)
						Ok(hash) =>
							match Store.load_human_invite!(hash) {
								Ok(r) => Ok(r)
								Err(Missing) | Err(Malformed) => Err(Refused(Unknown))
								Err(Failed) => Err(Failed)
							}
					}
			}
	}

## **/join/name**: the name an open invite's account holds, for the redeem
## page to fill in; any other code, the one 401.
answer_name! : List(U8) => Try(Chat.Answer, Chat.Answer)
answer_name! = |form|
	match load_named!(form) {
		Err(Failed) => Ok(Chat.failed)
		Err(Refused(_)) => Ok(join_refused)
		Ok(r) => {
			accounts = Store.load_accounts!({}).map_err(|_| Chat.failed)?
			now = Host.read_time!({})
			if HumanInvite.is_open(r, now) and Principal.holds(accounts, r.human).is_ok() {
				Ok(
					Wire.json(
						200,
						JsonOut.object([
							(
								"name",
								JsonOut.string(inviter_name_of(accounts, r.human.id)),
							),
						]),
					),
				)
			} else {
				Ok(join_refused)
			}
		}
	}

## **/join, POST**: the code redeemed (HumanInvite.redeem), the invite
## spent first so it never signs in twice, the name changed if asked, and
## a session started on this device, its cookie set.
join! : List(U8) => Try(Chat.Answer, Chat.Answer)
join! = |form| {
	now = Host.read_time!({})
	match load_named!(form) {
		Err(Failed) => Ok(Chat.failed)
		# A code naming no stored invite is anyone's to send, and never
		# audited, as an agent invite's is not.
		Err(Refused(_)) => Ok(join_refused)
		Ok(record) => {
			accounts = Store.load_accounts!({}).map_err(|_| Chat.failed)?
			settings = SignIn.load_settings!({}).map_err(|_| Chat.failed)?
			channels = Store.load_channel_names!({}).map_err(|_| Chat.failed)?
			name =
				match SignInWeb.form_field(form, "name") {
					Ok(bytes) => Chosen(bytes)
					Err(_) => Kept
				}
			secret = Host.random_bytes!(Wire.secret_bytes)
			sid = Principal.SessionId.from_u64(SignInWeb.u64_of(Host.random_bytes!(8))).map_err(|_| Chat.failed)?
			token_hash = Stored.SecretHash.from_bytes(Host.hash!(secret)).map_err(|_| Chat.failed)?
			match HumanInvite.redeem({
				record,
				name,
				accounts,
				channels,
				session: { id: sid, token_hash },
				now,
			}) {
				Err(Refused(why)) => {
					audit!({
						record,
						verdict: Refused(why),
						now,
					})
					Ok(join_refused)
				}
				Err(NameRefused(_)) => Ok(
					Wire.refused(
						400,
						"a name is 1 to 40 characters of letters, digits, spaces and . - _ '",
					),
				)
				Err(NameTaken) => Ok(
					Wire.refused(
						409,
						"someone already goes by that name, in some spelling",
					),
				)
				Ok(redeemed) => {
					session = Session.start_invited(redeemed.admission)
					after = Accounts.applied(redeemed.steps, { accounts, settings })
					written =
						Store.save_human_invite!(redeemed.spent)
							|> and_then!(|_| if (redeemed.steps.is_empty()) Written else Store.save_accounts!(after))
							|> and_then!(|_| Store.save_session!(session.fields()))
					match written {
						Failed => Ok(Chat.failed)
						Written => {
							audit!({
								record: redeemed.spent,
								verdict: Redeemed(sid),
								now,
							})
							Ok(
								Wire.json(
									200,
									JsonOut.object([
										(
											"human",
											JsonOut.string(AccountCodec.id_text(record.human.id)),
										),
										(
											"name",
											JsonOut.string(
												inviter_name_of(
													after.accounts,
													record.human.id,
												),
											),
										),
									]),
								)
									|> Chat.with_header(
										"set-cookie",
										SignInWeb.set_cookie({
											name: "session",
											contents: SignInWeb.hex(secret),
											max_age: Session.absolute_secs,
										}),
									),
							)
						}
					}
				}
			}
		}
	}
}

## The one answer to any refused redemption.
join_refused : Chat.Answer
join_refused = Wire.refused(401, "invite refused")

## An invite's event, audited: never its code.
audit! : {
	record : HumanInvite.Record,
	verdict : [
		Created(Principal.HumanId),
		Reinvited(Principal.HumanId),
		Redeemed(Principal.SessionId),
		Revoked(Principal.HumanId),
		Refused(HumanInvite.Refusal),
	],
	now : I64,
} => {}
audit! = |
	{
		record,
		verdict,
		now,
	},
|
	write_audit!({
		at: now,
		invite: Known({ id: record.id, human: human_of(record) }),
		verdict,
	})

## The audit's line written; a time outside its range writes none.
write_audit! : AuditCodec.HumanInviteEvent => {}
write_audit! = |event|
	match AuditCodec.Entry.of_human_invite(event) {
		Ok(entry) => Store.append_audit!(entry)
		Err(ClockOutOfRange) => {}
	}

## The human an invite is for.
human_of : HumanInvite.Record -> Principal.HumanId
human_of = |r|
	match r.human.id {
		Human(h) => h
		Agent(_) | Bot(_) => crash "HumanInvites.human_of: a human invite is for a human (HumanInviteCodec refuses others)"
	}

## **THE REDEEM PAGE**, the same for every code (the code after `#` is the
## script's alone): the name filled in, which the invitee may change; the
## plain first paragraph; the mechanism as fine print.
join_page : Chat.Answer
join_page =
	Pages.standalone({
		title: Html.markup("Join"),
		body: Html.join([
			Html.markup(join_html),
			Html.markup("<script>\n"),
			Html.markup(join_js),
			Html.markup("</script>\n"),
		]),
	})

join_html : Str
join_html =
	\\<h1>Join the chat</h1>
	\\<p id=plain>Someone you know invited you. There is no password: this device stays signed in, and you are signed out after 30 days without a visit. To join on another device, or if you lose this one, ask them for a new invite.</p>
	\\<form id=join><label>Your name <input name=name required maxlength=40></label> <button>Join</button></form>
	\\<p id=said></p>
	\\<p class=quiet><small>The fine print: the link's code is after its <code>#</code>, which a browser never sends, so it reaches no server's log; this page sends it in a request's body. A code works once, for 7 days. Joining starts a session on this device: a cookie that lasts 90 days at most, and ends after 30 days unused. The name is yours to change now to any name no one else goes by.</small></p>
	\\

## The redeem page's script: the code from the link's `#`, the name its
## invite holds filled in, and the join posted with both.
join_js : Str
join_js =
	\\const said = document.getElementById("said"), form = document.getElementById("join");
	\\const code = location.hash.slice(1);
	\\const post = (path, body) => fetch(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body });
	\\const gone = "This invite has been used, revoked, or has expired. Ask the person who invited you for a new one.";
	\\if (!code) { said.textContent = "This link has no invite code in it."; form.hidden = true; }
	\\else post("/join/name", "code=" + encodeURIComponent(code)).then(async (r) => {
	\\  if (r.ok) form.elements.name.value = (await r.json()).name; else { said.textContent = gone; form.hidden = true; }
	\\});
	\\form.addEventListener("submit", async (e) => {
	\\  e.preventDefault();
	\\  const r = await post("/join", "code=" + encodeURIComponent(code) + "&name=" + encodeURIComponent(form.elements.name.value.trim()));
	\\  if (r.ok) location = "/chat"; else said.textContent = r.status == 401 ? gone : await r.text();
	\\});
	\\

# ── tests
expect HumanInvites.route("/human-invites".to_utf8()) == Ok(Invites)
expect HumanInvites.route("/join".to_utf8()) == Ok(Join)
expect HumanInvites.route("/join/name".to_utf8()) == Ok(JoinName)
expect HumanInvites.route("/human-invites/3/revoke".to_utf8()).map_ok(|r| r == Revoke(HumanInvite.InviteId.from_u64(3) ?? crash "3 is an id")) == Ok(Bool.True)
expect HumanInvites.route("/human-invites/0/revoke".to_utf8()) == Err(NotHumanInvites)
expect HumanInvites.route("/human-invites/3".to_utf8()) == Err(NotHumanInvites)
expect HumanInvites.route("/join/x".to_utf8()) == Err(NotHumanInvites)
expect HumanInvites.route("/invites".to_utf8()) == Err(NotHumanInvites)
