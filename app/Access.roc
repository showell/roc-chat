## This module decides who may read and who may post in a conversation,
## from its place. A channel's members may read and post in each of its
## conversations, humans and agents alike; a DM's one or two humans may
## read and post in its. Nobody else may, the admin included: an admin
## changes a channel's members to take part. A user signed in by an API key
## may besides do only what the key's scope reaches (`KeyScope`).
##
## main asks this of every conversation's route before it answers, so no
## route answers a reader or a writer the place doesn't admit.
import ChannelName
import Directory
import KeyScope
import Place
import SignedIn
import UserId

Access :: [].{

	## What a request does in a conversation.
	Act : [Read, Post]

	## Whether `acting` may `act` in a conversation at `place`, as
	## `directory` holds it: `Ok`, or why not: not one of the place's
	## members (`NotAMember`), or a key whose scope is off for the act
	## (`ScopeOff`). Membership is asked first.
	check : {
		acting : SignedIn,
		place : Place,
		directory : Directory,
		act : Access.Act,
	} -> Try({}, [NotAMember, ScopeOff])
	check = |
		{
			acting,
			place,
			directory,
			act,
		},
	|
		if !Access.members({ place, directory }).contains(acting.user().id()) {
			Err(NotAMember)
		} else {
			match (acting.credential(), act) {
				(Session, Read) => Ok({})
				(Session, Post) => Ok({})
				(ApiKey(scope), Read) => reach_answer(scope.read())
				(ApiKey(scope), Post) => reach_answer(scope.post())
			}
		}

	## The ids of everyone who may read and post at `place`: a channel's
	## members, or a DM's humans.
	members : { place : Place, directory : Directory } -> List(UserId)
	members = |{ place, directory }|
		match place.which() {
			Channel(name) => channel_members(directory, name)
			Dm(pair) => pair.members()
		}

	## The agents among `place`'s members, who hear its messages on their
	## own streams (`AgentStream`).
	agent_members : { place : Place, directory : Directory } -> List(UserId)
	agent_members = |{ place, directory }|
		Access.members({ place, directory }).keep_if(
			|id|
				match directory.users().user(id) {
					Ok(user) =>
						match user.role() {
							Agent(_) => Bool.True
							Human => Bool.False
						}
					Err(NoSuchUser) => Bool.False
				},
		)
}

## A channel's members, by its name. A place is built only from a channel
## its directory holds, so the channel is always there.
channel_members : Directory, ChannelName -> List(UserId)
channel_members = |directory, name|
	match directory.channels().channel(name) {
		Ok(channel) => channel.members()
		Err(NoSuchChannel) =>
			crash "Access.channel_members: a place names only a channel its directory holds"
	}

## A key's reach, as an answer.
reach_answer : KeyScope.Reach -> Try({}, [ScopeOff])
reach_answer = |reach|
	match reach {
		Everywhere => Ok({})
		Off => Err(ScopeOff)
	}
