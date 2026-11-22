## This module ends a user's open streams, the one place the app does. A
## stream is judged once, when it opens, and the host holds it for up to an
## hour (`Limits.stream_most_ms`) without asking again, so every action in
## the app that ends a session, revokes a credential or removes someone's
## access calls `end_every_stream!` after its write: each stream reconnects
## and is judged again, admitted only by what still admits it.
## tools/check_stream_endings.shale holds the app to that, and to every
## holder `StreamHolder` names being one this module ends.
import pf.Host
import StreamHolder
import UserId

UserStreams :: [].{

	## Every stream the user `id` holds ended now, under each holder
	## `StreamHolder` names: their pages' streams (a conversation's, Recent's
	## and the device code page's) and an agent's own stream.
	end_every_stream! : UserId => {}
	end_every_stream! = |id| {
		Host.end_every_stream_of_holder!(StreamHolder.user(id).to_bytes())
		Host.end_every_stream_of_holder!(StreamHolder.agent(id).to_bytes())
	}
}
