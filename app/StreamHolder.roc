## A `StreamHolder` is who holds an open stream, as the host counts and ends
## streams. A user's pages' streams (a conversation's, Recent's and the
## device code page's) are held by the user, under their id, so the host's
## cap on one holder's streams counts them together; an agent's own stream
## is held under a name no user's id is. This module is the one home of
## those names: `HttpAnswer.stream` takes a `StreamHolder`, so no stream is
## held under a name made anywhere else, and `UserStreams` ends a user's
## streams under each of them (tools/check_stream_endings.shale holds it to
## every one).
import UserId

StreamHolder :: List(U8).{

	## Who holds the streams of the pages `user` opens: the user, by id.
	user : UserId -> StreamHolder
	user = |id| StreamHolder.(id.to_str().to_utf8())

	## Who holds the agent `agent`'s own stream (`AgentStream`).
	agent : UserId -> StreamHolder
	agent = |id| StreamHolder.("agent-${id.to_str()}".to_utf8())

	## The holder's name, for the host.
	to_bytes : StreamHolder -> List(U8)
	to_bytes = |StreamHolder.(bytes)| bytes
}

# ── tests
expect StreamHolder.user(UserId.chat_owner).to_bytes() == "1".to_utf8()
expect StreamHolder.agent(UserId.chat_owner).to_bytes() == "agent-1".to_utf8()
# The edges: a user and the agent of the same number are two holders, and
# so are two users whose ids share digits, so ending one's streams ends no
# other's.
expect {
	ten = UserId.from_str("10") ?? crash "StreamHolder's tests: 10 is an id"
	one = UserId.chat_owner
	StreamHolder.user(one).to_bytes() != StreamHolder.agent(one).to_bytes()
		and StreamHolder.user(one).to_bytes() != StreamHolder.user(ten).to_bytes()
		and StreamHolder.agent(one).to_bytes() != StreamHolder.agent(ten).to_bytes()
}
