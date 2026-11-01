## **/stream, ONE STREAM PER AGENT** (AgentStream decides, pure): for an
## agent's or a bot's key that may read everywhere, every conversation it
## is in and every topic of every channel it is a member of, live, on its own bus key
## (Conversations.agent_key, where a post in any of them is published), each
## event its message with where it is first (`"conversation":N`, or
## `"channel"` and `"topic"`, and the topic's `"ref"`). After
## `Last-Event-ID`, the backlog of each one's newest page that
## AgentStream.is_after sends, in order, a `gap` naming any further
## behind. A key read-scoped to listed conversations streams them one by
## one (its scope stays the host's to check per conversation): a 403. So
## is a session, or a human's key: the one stream is an agent's. Signed
## out, a 401. **ITS HOLDER IS THE AGENT**, so it counts as one of the
## agent's streams under the host's cap.
import pf.Chat
import pf.Host
import Access
import AgentStream
import Conversations
import Credentials
import Topics
import Wire

OneStream := [].{

	## **/stream, GET**: the one stream, or why not.
	serve! : {} => Chat.Answer
	serve! = |{}|
		match Credentials.load_viewer!(ListConversations) {
			Err(answer) => answer
			Ok(asked) =>
				match (asked.viewer.who(), asked.key) {
					(SignedOut, _) => Wire.refused(401, "not signed in")
					(Session(_), _) | (_, NoKey) => Wire.refused(
						403,
						"the one stream is an agent's, by its key; a browser streams a conversation",
					)
					(Key(b), Key(k)) =>
						match b.id {
							Human(_) => Wire.refused(
								403,
								"the one stream is an agent's or a bot's; a human's key streams a conversation",
							)
							Agent(_) | Bot(_) =>
								if k.record().scope.read != On(Everywhere) {
									Wire.refused(
										403,
										"a key that reads only some conversations streams them one by one",
									)
								} else {
									match load_sources!({ agent: b, asked }) {
										Err(Failed) => Chat.failed
										Ok(sources) => {
											cursor = AgentStream.cursor(Host.read_header!(Str.to_utf8("last-event-id")))
											match Conversations.backlog!(sources, cursor) {
												Err(Failed) => Chat.failed
												Ok(backlog) =>
													Chat.stream({
														key: Conversations.agent_key(b.id),
														backlog,
														holder: Conversations.holder(asked.viewer),
													})
											}
										}
									}
								}
						}
				}
		}
}

## The agent's conversations, and the topics of the channels it is in.
load_sources! : { agent : _, asked : _ } => Try(List(Conversations.Source), [Failed])
load_sources! = |{ agent, asked }| {
	mine = Conversations.load_mine!(asked.viewer, asked.accounts)?
	theirs = mine.keep_if(|c| c.participants().any(|p| p.id == agent.id))
	topics = Topics.sources_of!({ viewer: Access.Viewer.over(asked.viewer), accounts: asked.accounts })?
	Ok(Conversations.sources_of(theirs, asked.accounts).concat(topics))
}
