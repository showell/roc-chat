## This module builds the agents page, which `AgentsRoute` serves at
## `/agents`: the admin's agents, each with its keys and its invites, and the
## buttons that make, invite and revoke them. Any other human sees a line
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
	## admin), a form that makes an agent, then each agent with a button that
	## invites it, and its keys and invites, each live one with a button that
	## revokes it; else (`NotTheKeeper`) a line saying agents are the admin's.
	## When an invite was just made, its code comes first (`shown`), the one
	## time it is shown. Last, when `github_link` offers it, a button that
	## links GitHub.
	agents : {
		viewer : SignedIn,
		agents : [Kept(List(AgentsPage.AgentSummary)), NotTheKeeper],
		shown : [NoCode, Code({ agent : Users.User, code : SecretToken })],
		github_link : AgentsPage.GitHubLinkOffer,
	} -> TrustedHtml
	agents = |{ viewer, agents: kept, shown, github_link }| {
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
				match kept {
					Kept(summaries) =>
						TrustedHtml.join([
							make_form,
							PageKit.newline,
							TrustedHtml.join(summaries.map(agent_section)),
						])
					NotTheKeeper => PageKit.paragraph("Only the admin makes and manages agents.")
				},
				match github_link {
					LinkOffered => PageKit.post_button({
						action: "/login/github/link",
						label: "Link GitHub",
					})
					LinkNotOffered => TrustedHtml.join([])
				},
			]),
		})
	}
}

## One agent's part of the agents page: its name and id, the button that
## invites it, then its keys and its invites.
agent_section : AgentsPage.AgentSummary -> TrustedHtml
agent_section = |{ agent, keys, invites }| {
	folder = "/agents/${agent.id().to_str()}"
	TrustedHtml.join([
		Html.element({
			name: H1,
			attributes: [],
			inner: Escape.text("${agent.name().to_str()} (id ${agent.id().to_str()})"),
		}),
		PageKit.newline,
		PageKit.post_button({
			action: "${folder}/invites",
			label: "Invite ${agent.name().to_str()}",
		}),
		TrustedHtml.join(
			keys.map(
				|key| {
					state_word =
						match key.state() {
							Active => "active"
							Revoked => "revoked"
						}
					expiry = time_text(key.expires())
					read_word = KeyScope.reach_word(key.scope().read())
					post_word = KeyScope.reach_word(key.scope().post())
					said =
						"Key ${key.id().to_str()}: ${state_word}, expires ${expiry}, read ${read_word}, post ${post_word}."
					revoke =
						match key.state() {
							Active => PageKit.post_button({
								action: "${folder}/keys/${key.id().to_str()}/revoke",
								label: "Revoke key ${key.id().to_str()}",
							})
							Revoked => TrustedHtml.join([])
						}
					TrustedHtml.join([PageKit.paragraph(said), revoke])
				},
			),
		),
		TrustedHtml.join(
			invites.map(
				|invite| {
					state_word = invite_state_word(invite.state())
					expiry = time_text(invite.expires())
					said = "Invite ${invite.id().to_str()}: ${state_word}, expires ${expiry}."
					revoke =
						match invite.state() {
							Live => PageKit.post_button({
								action: "${folder}/invites/${invite.id().to_str()}/revoke",
								label: "Revoke invite ${invite.id().to_str()}",
							})
							Spent => TrustedHtml.join([])
							Revoked => TrustedHtml.join([])
						}
					TrustedHtml.join([PageKit.paragraph(said), revoke])
				},
			),
		),
	])
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
