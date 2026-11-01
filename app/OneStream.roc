## **/stream, ONE STREAM PER AGENT** (AgentStream decides, pure): for an
## agent's or a bot's key that reads, every topic of every channel it is a
## member of, live, on its own bus key (Messages.agent_key, where a post in
## any of them is published), each event its message with where it is
## first (`"channel"` and `"topic"`, and the topic's `"ref"`). After
## `Last-Event-ID`, the backlog of each one's newest page that
## AgentStream.is_after sends, in order, a `gap` naming any further behind.
## A key whose read is off is a 403, and so is a session, or a human's key:
## the one stream is an agent's. Signed out, a 401. **ITS HOLDER IS THE
## AGENT**, so it counts as one of the agent's streams under the host's
## cap.
import pf.Chat
import pf.Host
import AgentStream
import Messages
import Credentials
import Topics
import Wire

OneStream := [].{

	## **/stream, GET**: the one stream, or why not.
	serve! : {} => Chat.Answer
	serve! = |{}|
		match Credentials.load_viewer!({}) {
			Err(answer) => answer
			Ok(asked) =>
				match (asked.viewer.who(), asked.key) {
					(SignedOut, _) => Wire.refused(401, "not signed in")
					(Session(_), _) | (_, NoKey) => Wire.refused(
						403,
						"the one stream is an agent's, by its key; a browser streams a topic",
					)
					(Key(b), Key(k)) =>
						match b.id {
							Human(_) => Wire.refused(
								403,
								"the one stream is an agent's or a bot's; a human's key streams a topic",
							)
							Agent(_) | Bot(_) =>
								if k.record().scope.read != On {
									Wire.refused(403, "a key whose read is off streams nothing")
								} else {
									match Topics.sources_of!({ viewer: asked.viewer, accounts: asked.accounts }) {
										Err(Failed) => Chat.failed
										Ok(sources) => {
											cursor = AgentStream.cursor(Host.read_header!(Str.to_utf8("last-event-id")))
											match Messages.backlog!(sources, cursor) {
												Err(Failed) => Chat.failed
												Ok(backlog) =>
													Chat.stream({
														key: Messages.agent_key(b.id),
														backlog,
														holder: Messages.holder(asked.viewer),
													})
											}
										}
									}
								}
						}
				}
		}
}
