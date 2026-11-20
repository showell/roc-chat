## This module holds the plain decisions of a trip to GitHub and back that
## `GitHubRoute` acts on, so a spec can test them (`GitHubTripSpec`): the URL
## that sends a browser to GitHub, what GitHub's way back holds in its query,
## what a sign-up under a name makes, and the page that says why a sign-in or
## a name was refused. `GitHubSignIn` decides whose sign-in it is, and
## `GitHubRefusal` words each refusal.
import Ascii
import Channels
import Directory
import GitHubId
import GitHubRefusal
import GitHubSignIn
import GitHubState
import Hex
import HumanInvites
import Name
import SignInPage
import SignInRequest
import SignedIn
import Timestamp
import TrustedHtml
import UrlEncodedForm
import UserId
import Users
import Welcome

GitHubTrip :: [].{

	## GitHub's page that asks its human to authorize this server.
	authorize_url : {
		authorize_base : List(U8),
		client_id : List(U8),
		origin : Str,
		state_token : Str,
	} -> Str
	authorize_url = |{ authorize_base, client_id, origin, state_token }| {
		base = Str.from_utf8(authorize_base) ?? crash "GitHubTrip.authorize_url: the host's base URL is ASCII"
		id = percent_encoded(client_id)
		back = percent_encoded("${origin}/login/github".to_utf8())
		"${base}/login/oauth/authorize?client_id=${id}&redirect_uri=${back}&state=${state_token}"
	}

	## What GitHub answered in the way back's `query`: a code, none, or one it
	## wouldn't send.
	answer_in_query : List(U8) -> GitHubSignIn.Answer
	answer_in_query = |query|
		match UrlEncodedForm.field({ body: query, name: "code" }) {
			Err(MissingField) => NoCode
			Err(_) => BadCode
			Ok(text) =>
				match text.github_code() {
					Ok(code) => Code(code)
					Err(NotACode) => BadCode
				}
		}

	## The state the way back's `query` claims, for the host to check its
	## signature; or none, when it holds no state or none that is a claim's
	## spelling (`NoClaim`).
	state_claim_in_query : List(U8) -> Try(GitHubState.Claim, [NoClaim])
	state_claim_in_query = |query|
		match UrlEncodedForm.field({ body: query, name: "state" }) {
			Err(_) => Err(NoClaim)
			Ok(text) => text.github_state_claim().map_err(|NotAClaim| NoClaim)
		}

	## What the sign-up `resumed` makes under `name`, in `directory`: the
	## account (`SignUpResumed.create_account`, given `links`), and the new
	## human's welcome dated `now`; or why not, a sign-up that ends here
	## (`Refused`) or a name to try again (`NameRefused`).
	new_account : {
		resumed : GitHubSignIn.SignUpResumed,
		name : Name,
		links : List({ user : UserId, github : GitHubId }),
		directory : Directory,
		now : Timestamp,
	} -> Try(
		{
			made : {
				directory : Directory,
				human : Users.User,
				channel : Channels.Channel,
				github : GitHubId,
				admission : GitHubSignIn.Admission,
			},
			welcome : Welcome,
		},
		[
			Refused(GitHubSignIn.Refusal),
			NameRefused({ name : SignInPage.NameField, why : HumanInvites.Refusal }),
		],
	)
	new_account = |{ resumed, name, links, directory, now }| {
		made = resumed.create_account({
			name,
			links,
			directory,
		}) ? |why| account_refusal({ name, why })
		welcome = Welcome.make({
			directory: made.directory,
			human: made.admission.human(),
			now,
		}) ? |ClockOutOfRange| Refused(ClockOutOfRange)
		Ok({ made, welcome })
	}

	## The name to offer the human `resumed` signs up: their GitHub login,
	## when it is a name, free in `directory` and a new human's to take
	## (`Directory.check_new_human_name`); else why not.
	name_offer : GitHubSignIn.SignUpResumed,
	Directory -> [
		Suggested(Name),
		NotSuggested(SignInPage.NoOffer),
	]
	name_offer = |resumed, directory|
		match resumed.login() {
			NoLogin => NotSuggested(NoLogin)
			Login(login) =>
				match Name.from_str(login.to_str()) {
					Err(_) => NotSuggested(LoginNotAName)
					Ok(name) =>
						match (
							directory.add_human(name),
							directory.check_new_human_name({ name, leaving: NoOne }),
						) {
							(Err(Full), _) => NotSuggested(ChatFull)
							(Err(NameTaken), _) | (_, Err(NameTaken)) => NotSuggested(LoginTaken)
							(_, Err(NameReserved))
							| (_, Err(NameTooClose)) => NotSuggested(LoginTooClose)
							(Ok(_), Ok({})) => Suggested(name)
						}
				}
		}

	## The sign-in page for `viewer`, saying why GitHub's sign-in was refused,
	## under its status.
	refusal_page : { viewer : SignedIn.Actor, why : GitHubSignIn.Refusal } -> {
		status : U16,
		page : TrustedHtml,
	}
	refusal_page = |{ viewer, why }| {
		said = GitHubRefusal.refusal_said(why)
		{
			status: said.status,
			page: SignInPage.login({
				viewer,
				next: SignInRequest.default_next,
				problem: Problem(said.words),
				github: Offered,
			}),
		}
	}

	## The form that asks a name again, saying why the name `name` was
	## refused, under its status.
	name_refusal_page : { name : SignInPage.NameField, why : HumanInvites.Refusal } -> {
		status : U16,
		page : TrustedHtml,
	}
	name_refusal_page = |{ name, why }| {
		notice = HumanInvites.refusal_notice(why)
		{
			status: notice.status,
			page: SignInPage.github_sign_up({
				name,
				problem: Problem(notice.said),
				login_note: NoNote,
			}),
		}
	}
}

## `bytes` as a URL's query value: letters, digits and `-_.~` as they are,
## any other byte `%` and its hex digits.
percent_encoded : List(U8) -> Str
percent_encoded = |bytes| {
	spelled = bytes.map(
		|byte|
			if is_unreserved(byte) {
				Str.from_utf8([byte]) ?? crash "GitHubTrip.percent_encoded: ASCII is UTF-8"
			} else {
				"%${Hex.to_hex([byte])}"
			},
	)
	Str.join_with(spelled, "")
}

is_unreserved : U8 -> Bool
is_unreserved = |byte|
	Ascii.is_letter(byte) or Ascii.is_digit(byte) or "-_.~".to_utf8().contains(byte)

## Why `name` made no account: a sign-up that ends here, or a name to try
## again.
account_refusal : {
	name : Name,
	why : [
		AccountExists,
		DuplicateAccount,
		SignUpsPaused,
		NameTaken,
		NameReserved,
		NameTooClose,
		Full,
		NoDefaultChannel,
	],
} -> [
	Refused(GitHubSignIn.Refusal),
	NameRefused({ name : SignInPage.NameField, why : HumanInvites.Refusal }),
]
account_refusal = |{ name, why }|
	match why {
		AccountExists => Refused(AccountExists)
		DuplicateAccount => Refused(DuplicateAccount)
		SignUpsPaused => Refused(SignUpsPaused)
		NameTaken => NameRefused({ name: Named(name), why: NameTaken })
		NameReserved => NameRefused({ name: Named(name), why: NameReserved })
		NameTooClose => NameRefused({ name: Named(name), why: NameTooClose })
		Full => NameRefused({ name: Named(name), why: Full })
		NoDefaultChannel => Refused(NoDefaultChannel)
	}

# ── tests
expect percent_encoded("aZ09-_.~".to_utf8()) == "aZ09-_.~"
expect percent_encoded("a b&c=/".to_utf8()) == "a%20b%26c%3d%2f"
