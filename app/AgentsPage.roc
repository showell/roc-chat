## This module builds the agents page, which `AgentsRoute` serves at
## `/agents`: the admin's agents, each with its keys and its invites, and the
## forms that make, invite and revoke them, inviting with a choice of how
## far the agent's key reads and posts. Any other human sees a line
## saying agents are the admin's. A human with no GitHub account yet may be
## offered a button that links one (`GitHubLinkOffer`, which `GitHubRoute`
## decides).
import AgentInvite
import AgentKey
import DateTime
import Escape
import Html
import KeyScope
import PageKit
import SecretToken
import SignedIn
import Timestamp
import TrustedHtml
import Users

AgentsPage :: [].{

	## The line a viewer whose session a device code started sees in place
	## of the page's buttons.
	code_session_words : Str
	code_session_words = "This device signed in with a code, so it can't manage agents or link GitHub. Sign out here, then sign in with your password or GitHub for that."

	## One agent on the agents page, with its keys and its invites.
	AgentSummary : {
		agent : Users.User,
		keys : List(AgentKey),
		invites : List(AgentInvite),
	}

	## Whether the agents page offers to link GitHub: `LinkOffered` to a human
	## with no GitHub account yet, on a server with GitHub's settings.
	GitHubLinkOffer : [LinkOffered, LinkNotOffered]

	## The agents page, for `viewer`: when they keep agents (`Kept`, the
	## admin), a form that makes an agent, then each agent with a form that
	## invites it (`invite_form`), and its keys and invites, each with its
	## scope and each live one with a button that revokes it; else (`NotTheKeeper`) a line saying agents are the admin's.
	## When an invite was just made, its code comes first (`shown`), the one
	## time it is shown. Last, when `github_link` offers it, a button that
	## links GitHub. A viewer whose session a device code started sees no
	## button, as none would work for them (`FullSessionRoutes`), and a line
	## saying why.
	agents : {
		viewer : SignedIn,
		agents : [Kept(List(AgentsPage.AgentSummary)), NotTheKeeper],
		shown : [NoCode, Code({ agent : Users.User, code : SecretToken })],
		github_link : AgentsPage.GitHubLinkOffer,
	} -> TrustedHtml
	agents = |{ viewer, agents: kept, shown, github_link }| {
		buttons =
			match viewer.check_full_session() {
				Ok({}) => WithButtons
				Err(StartedByDeviceCode) => WithoutButtons
			}
		code =
			match shown {
				NoCode => TrustedHtml.join([])
				Code({ agent, code: invite_code }) =>
					TrustedHtml.join([
						PageKit.paragraph("The invite code for ${agent.name().to_str()}, shown this once. It lives ten minutes and redeems once: the agent posts it as `code` to /agents/redeem for its key."),
						PageKit.shown_code(invite_code.to_str()),
					])
			}
		make_form = Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path("/agents"))],
			inner: TrustedHtml.join([
				Html.element({
					name: Textarea,
					attributes: [FieldName(PageKit.token("name")), Required],
					inner: TrustedHtml.join([]),
				}),
				PageKit.newline,
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Make an agent"),
				}),
			]),
		})
		PageKit.document({
			title: "Agents",
			body: TrustedHtml.join([
				PageKit.top_bar({ title: "Agents", viewer }),
				PageKit.newline,
				code,
				match (kept, buttons) {
					(Kept(summaries), WithButtons) =>
						TrustedHtml.join([
							make_form,
							PageKit.newline,
							TrustedHtml.join(
								summaries.map(|summary| agent_section(summary, WithButtons)),
							),
						])
					(Kept(summaries), WithoutButtons) =>
						TrustedHtml.join([
							PageKit.paragraph(AgentsPage.code_session_words),
							TrustedHtml.join(
								summaries.map(|summary| agent_section(summary, WithoutButtons)),
							),
						])
					(
						NotTheKeeper,
						_,
					) => PageKit.paragraph("Only the admin makes and manages agents.")
				},
				match (github_link, buttons) {
					(LinkOffered, WithButtons) => PageKit.post_button({
						action: "/login/github/link",
						label: "Link GitHub",
					})
					_ => TrustedHtml.join([])
				},
			]),
		})
	}
}

## One agent's part of the agents page: its name and id, the form that
## invites it, then its keys and its invites, each with its scope and each
## live one with a button that revokes it; the buttons left out `WithoutButtons`.
agent_section : AgentsPage.AgentSummary, [WithButtons, WithoutButtons] -> TrustedHtml
agent_section = |{ agent, keys, invites }, buttons| {
	folder = "/agents/${agent.id().to_str()}"
	button = |made|
		match buttons {
			WithButtons => made
			WithoutButtons => TrustedHtml.join([])
		}
	TrustedHtml.join([
		Html.element({
			name: H1,
			attributes: [],
			inner: Escape.text("${agent.name().to_str()} (id ${agent.id().to_str()})"),
		}),
		PageKit.newline,
		button(invite_form({ folder, name: agent.name().to_str() })),
		TrustedHtml.join(
			keys.map(
				|key| {
					state_word =
						match key.state() {
							Active => "active"
							Revoked => "revoked"
						}
					expiry = time_text(key.expires())
					said =
						"Key ${key.id().to_str()}: ${state_word}, expires ${expiry}. ${scope_text(key.scope())}"
					revoke =
						match key.state() {
							Active => PageKit.post_button({
								action: "${folder}/keys/${key.id().to_str()}/revoke",
								label: "Revoke key ${key.id().to_str()}",
							})
							Revoked => TrustedHtml.join([])
						}
					TrustedHtml.join([PageKit.paragraph(said), button(revoke)])
				},
			),
		),
		TrustedHtml.join(
			invites.map(
				|invite| {
					state_word = invite_state_word(invite.state())
					expiry = time_text(invite.expires())
					said =
						"Invite ${invite.id().to_str()}: ${state_word}, expires ${expiry}. ${scope_text(invite.scope())}"
					revoke =
						match invite.state() {
							Live => PageKit.post_button({
								action: "${folder}/invites/${invite.id().to_str()}/revoke",
								label: "Revoke invite ${invite.id().to_str()}",
							})
							Spent => TrustedHtml.join([])
							Revoked => TrustedHtml.join([])
						}
					TrustedHtml.join([PageKit.paragraph(said), button(revoke)])
				},
			),
		),
	])
}

## The form that invites the agent named `name`, whose folder is `folder`:
## a choice of how far its key will read and how far it will post, each
## starting at every channel the agent is a member of, then the button.
invite_form : { folder : Str, name : Str } -> TrustedHtml
invite_form = |{ folder, name }|
	TrustedHtml.join([
		Html.element({
			name: Form,
			attributes: [MethodPost, Action(PageKit.site_path("${folder}/invites"))],
			inner: TrustedHtml.join([
				reach_choices(Read),
				reach_choices(Post),
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Invite ${name}"),
				}),
			]),
		}),
		PageKit.newline,
	])

## One power's choices in the invite form: its name, then a radio button
## for each reach, posting its word as the field `read` or `post`, the
## first (every channel the agent is a member of) chosen.
reach_choices : [Read, Post] -> TrustedHtml
reach_choices = |power| {
	choice = |reach|
		Html.element({
			name: Label,
			attributes: [],
			inner: TrustedHtml.join([
				Html.input(
					List.concat(
						[
							InputType(Radio),
							FieldName(PageKit.token(power_field(power))),
							TokenValue(PageKit.token(KeyScope.reach_word(reach))),
						],
						match reach {
							Everywhere => [Checked]
							Off => []
						},
					),
				),
				Escape.text(" ${reach_words(power, reach)}"),
			]),
		})
	Html.element({
		name: Fieldset,
		attributes: [],
		inner: TrustedHtml.join([
			Html.element({
				name: Legend,
				attributes: [],
				inner: Escape.text(power_name(power)),
			}),
			choice(Everywhere),
			PageKit.space,
			choice(Off),
		]),
	})
}

## A key's or an invite's scope in the words the invite form chooses it by.
scope_text : KeyScope -> Str
scope_text = |scope|
	"${power_name(Read)}: ${reach_words(Read, scope.read())}. ${power_name(Post)}: ${reach_words(Post, scope.post())}."

power_name : [Read, Post] -> Str
power_name = |power|
	match power {
		Read => "Read"
		Post => "Post"
	}

## The form field that carries `power`'s reach (`Agents.scope_from_form`).
power_field : [Read, Post] -> Str
power_field = |power|
	match power {
		Read => "read"
		Post => "post"
	}

## How far `power` reaches, said for a reader. A key reaches no DM, as
## agents take part only in channels (`Access`).
reach_words : [Read, Post], KeyScope.Reach -> Str
reach_words = |power, reach|
	match (power, reach) {
		(_, Everywhere) => "every channel it's a member of"
		(Read, Off) => "nothing"
		(Post, Off) => "nowhere"
	}

invite_state_word : AgentInvite.State -> Str
invite_state_word = |state|
	match state {
		Live => "live"
		Spent => "redeemed"
		Revoked => "revoked"
	}

## `moment` as a transcript writes one, or its seconds when it is out of a
## date's range.
time_text : Timestamp -> Str
time_text = |moment|
	match DateTime.from_timestamp(moment) {
		Ok(time) => time.to_str()
		Err(OutOfRange) => "at ${moment.to_str()} seconds"
	}
