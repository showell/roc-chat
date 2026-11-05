## These are the tests of `ChannelMembers` and the channel routes: only the
## admin, by their own session, creates a channel and adds or removes its
## members, humans and agents alike; a member added may then read and post
## in its conversations, and one removed may not.
import Access
import AgentKey
import ChannelMembers
import ChannelName
import Directory
import KeyScope
import Place
import Route
import Sample
import SecretHash
import SignedIn
import UserId

ChannelMembersSpec :: [].{}

## The sample directory with the empty channel `team`.
with_team : Directory
with_team =
	(
		Sample.directory.create_channel({
			by: Sample.admin,
			name: team,
		}) ?? crash "ChannelMembersSpec: team is free"
	).directory

team : ChannelName
team = ChannelName.from_str("team") ?? crash "ChannelMembersSpec: a channel's name"

## Steve, by his session: the admin.
steve : SignedIn
steve = SignedIn.dangerously_assume(Sample.steve)

## Apoorva, by her session: a human who is not the admin.
apoorva : SignedIn
apoorva = SignedIn.dangerously_assume(Sample.user("Apoorva"))

## CC, Steve's agent, by a key that reads and posts everywhere.
cc_by_key : SignedIn
cc_by_key = {
	hash = SecretHash.of_digest(List.repeat(3, 32))
	key = AgentKey.mint({
		id: AgentKey.Id.from_str("1") ?? crash "ChannelMembersSpec: a key's number",
		hash,
		now: 0,
		scope: KeyScope.of({ read: Everywhere, post: Everywhere }),
	})
	admitted = AgentKey.admit({
		user: Sample.user("CC"),
		keys: [key],
		hash,
		now: 0,
	}) ?? crash "ChannelMembersSpec: CC's key admits"
	SignedIn.by_api_key(admitted)
}

## CC as though a session admitted it, which none does: an agent.
cc_by_session : SignedIn
cc_by_session = SignedIn.dangerously_assume(Sample.user("CC"))

## The id of the sample user named `text`.
id_of : Str -> UserId
id_of = |text| Sample.user(text).id()

## The ids of `team`'s members in `directory`.
team_members : Directory -> List(Str)
team_members = |directory|
	match directory.channels().channel(team) {
		Ok(channel) => channel.members().map(UserId.to_str)
		Err(NoSuchChannel) => crash "ChannelMembersSpec: team is a channel"
	}

## `with_team` with `name` added to `team` by `acting`: its members, or why
## not.
membership_after_add : SignedIn, Str -> Try(List(Str), _)
membership_after_add = |acting, name|
	ChannelMembers.add(
		with_team,
		{
			acting,
			channel: team,
			member: id_of(name),
		},
	).map_ok(|change| team_members(change.directory))

## `with_team` with CC and Apoorva in `team`.
with_cc_and_apoorva : Directory
with_cc_and_apoorva =
	["CC", "Apoorva"].fold(
		with_team,
		|so_far, name|
			(
				ChannelMembers.add(
					so_far,
					{
						acting: steve,
						channel: team,
						member: id_of(name),
					},
				) ?? crash "ChannelMembersSpec: Steve adds a member"
			).directory,
	)

## `with_cc_and_apoorva` with `name` removed from `team` by `acting`: its
## members, or why not.
membership_after_remove : SignedIn, Str -> Try(List(Str), _)
membership_after_remove = |acting, name|
	ChannelMembers.remove(
		with_cc_and_apoorva,
		{
			acting,
			channel: team,
			member: id_of(name),
		},
	).map_ok(|change| team_members(change.directory))

# Who is the admin: Steve by his session; no other human, no agent, and no
# key, whoever it names.
expect ChannelMembers.admin_of(steve).is_ok()
expect ChannelMembers.admin_of(apoorva).map_ok(|_| {}) == Err(NotAdmin)
expect ChannelMembers.admin_of(cc_by_key).map_ok(|_| {}) == Err(ByApiKey)
expect ChannelMembers.admin_of(cc_by_session).map_ok(|_| {}) == Err(Agent(id_of("CC")))

# Adding: the admin adds a human or an agent; the change's channel is the
# one written.
expect membership_after_add(steve, "CC") == Ok(["3"])
expect membership_after_add(steve, "Apoorva") == Ok(["2"])
expect membership_after_add(steve, "Steve") == Ok(["1"])
expect
	match ChannelMembers.add(
		with_team,
		{
			acting: steve,
			channel: team,
			member: id_of("CC"),
		},
	) {
		Ok(change) => change.channel.members_file() == "3\n".to_utf8()
		Err(_) => Bool.False
	}
# Adding refused: anyone but the admin, a member twice, no such channel or
# user.
expect membership_after_add(apoorva, "CC") == Err(NotAdmin)
expect membership_after_add(cc_by_key, "CC") == Err(ByApiKey)
expect membership_after_add(cc_by_session, "CC") == Err(Agent(id_of("CC")))
expect
	ChannelMembers.add(
		with_cc_and_apoorva,
		{
			acting: steve,
			channel: team,
			member: id_of("CC"),
		},
	).map_ok(|_| {})
		== Err(AlreadyMember)
expect
	ChannelMembers.add(
		with_team,
		{
			acting: steve,
			channel: ChannelName.from_str("other") ?? crash "ChannelMembersSpec: a name",
			member: id_of("CC"),
		},
	).map_ok(|_| {})
		== Err(NoSuchChannel)
expect
	ChannelMembers.add(
		with_team,
		{
			acting: steve,
			channel: team,
			member: UserId.from_str("9") ?? crash "ChannelMembersSpec: an id",
		},
	).map_ok(|_| {})
		== Err(NoSuchUser)

# Removing: the admin removes a member; refused to anyone else, and for
# one who is not in.
expect team_members(with_cc_and_apoorva) == ["2", "3"]
expect membership_after_remove(steve, "CC") == Ok(["2"])
expect membership_after_remove(steve, "Apoorva") == Ok(["3"])
expect membership_after_remove(steve, "Steve") == Err(NotMember)
expect membership_after_remove(apoorva, "CC") == Err(NotAdmin)
expect membership_after_remove(cc_by_key, "CC") == Err(ByApiKey)
expect
	ChannelMembers.remove(
		with_team,
		{
			acting: steve,
			channel: team,
			member: UserId.from_str("9") ?? crash "ChannelMembersSpec: an id",
		},
	).map_ok(|_| {})
		== Err(NoSuchUser)

# A member added may read and post in the channel's conversations; removed,
# they may not.
## Whether CC's key may post in `team` in `directory`.
cc_posts_in : Directory -> Try({}, _)
cc_posts_in = |directory| {
	place = directory.place(Channel(team)) ?? crash "ChannelMembersSpec: team is a place"
	Access.check({
		acting: cc_by_key,
		place,
		directory,
		act: Post,
	})
}

expect cc_posts_in(with_team) == Err(NotAMember)
expect cc_posts_in(with_cc_and_apoorva) == Ok({})
expect
	ChannelMembers.remove(
		with_cc_and_apoorva,
		{
			acting: steve,
			channel: team,
			member: id_of("CC"),
		},
	).map_ok(|change| cc_posts_in(change.directory))
		== Ok(Err(NotAMember))
expect
	Place.channel(
		with_cc_and_apoorva.channels().channel(team) ?? crash "ChannelMembersSpec: team",
	).which()
		== Channel(team)

## A channel created from the form `body` by `acting`: its name, or why not.
channel_by_form : SignedIn, Str -> Try(Str, _)
channel_by_form = |acting, body|
	ChannelMembers.create(
		with_team,
		{ acting, body: body.to_utf8() },
	).map_ok(|c| c.channel.name().to_str())

# Creating: the admin's, a channel's name free in the one namespace.
expect channel_by_form(steve, "name=crew") == Ok("crew")
expect channel_by_form(steve, "name=Crew-2") == Ok("Crew-2")
expect channel_by_form(apoorva, "name=crew") == Err(NotAdmin)
expect channel_by_form(cc_by_key, "name=crew") == Err(ByApiKey)
expect channel_by_form(steve, "") == Err(BadForm("The form has no field `name`."))
expect ["name=1st", "name=a_b", "name="].all(|body| channel_by_form(steve, body) == Err(BadName))
expect [
	"name=team",
	"name=TEAM",
	"name=cc",
].all(|body| channel_by_form(steve, body) == Err(NameTaken))

# A channel's page: the admin's alone, of a channel there is.
expect
	ChannelMembers.members_page_of(
		with_cc_and_apoorva,
		{ acting: steve, channel: team },
	).map_ok(|found| found.users.len())
		== Ok(3)
expect ChannelMembers.members_page_of(
	with_team,
	{ acting: apoorva, channel: team },
).map_ok(|_| {}) == Err(NotAdmin)
expect
	ChannelMembers.members_page_of(
		with_team,
		{
			acting: steve,
			channel: ChannelName.from_str("other") ?? crash "ChannelMembersSpec: a name",
		},
	).map_ok(|_| {})
		== Err(NoSuchChannel)

# Each refusal's status.
expect
	[
		(ByApiKey, 403),
		(Agent(id_of("CC")), 403),
		(NotAdmin, 403),
		(NoSuchChannel, 404),
		(NoSuchUser, 404),
		(AlreadyMember, 409),
		(NotMember, 409),
		(BadForm("x"), 400),
		(BadName, 400),
		(NameTaken, 409),
	].all(|(why, status)| ChannelMembers.refusal_notice(why).status == status)

## The route `method` and `path` choose, in `with_team`.
route_of : Str, Str -> Route.Choice
route_of = |method, path|
	Route.choose({
		method: method.to_utf8(),
		path: path.to_utf8(),
		directory: with_team,
	})

# The routes: every resource with every method, and paths that are none.
expect route_of("GET", "/channels") == SignedInOnly(ShowChannels)
expect route_of("POST", "/channels") == SignedInOnly(CreateChannel)
expect route_of("PUT", "/channels") == MethodNotAllowed(GetAndPost)
expect route_of("GET", "/channels/team") == SignedInOnly(ShowChannelMembers(team))
expect route_of("POST", "/channels/team") == MethodNotAllowed(GetOnly)
expect route_of("PUT", "/channels/team") == MethodNotAllowed(GetOnly)
expect route_of(
	"POST",
	"/channels/team/members/3/add",
) == SignedInOnly(AddChannelMember({ channel: team, member: id_of("CC") }))
expect route_of("GET", "/channels/team/members/3/add") == MethodNotAllowed(PostOnly)
expect route_of("PUT", "/channels/team/members/3/add") == MethodNotAllowed(PostOnly)
expect route_of(
	"POST",
	"/channels/team/members/3/remove",
) == SignedInOnly(RemoveChannelMember({ channel: team, member: id_of("CC") }))
expect route_of("GET", "/channels/team/members/3/remove") == MethodNotAllowed(PostOnly)
expect route_of("PUT", "/channels/team/members/3/remove") == MethodNotAllowed(PostOnly)
expect
	[
		"/channels/1st",
		"/channels/team/members/x/add",
		"/channels/team/members/3/kick",
		"/channels/team/people/3/add",
		"/channels/team/members/3",
		"/channels/",
	].all(|path| route_of("POST", path) == NotFound)
