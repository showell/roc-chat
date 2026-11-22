## This module ends a user's open streams, the one place the app does, and
## makes the one value that lets a write revoke anything a stream was
## admitted by. A stream is judged once, when it opens, and the host holds
## it for up to an hour (`Limits.stream_most_ms`) without asking again, so
## a write that ends a session, revokes a credential or removes someone's
## access must be followed by ending that user's streams: each reconnects
## and is judged again, admitted only by what still admits it.
##
## Every such write takes a `Revoker`, and only `with_streams_ended!` makes
## one: it hands the revoking writes their `Revoker`, then ends the user's
## streams, however those writes went. A revoking write outside it has no
## `Revoker` to pass, so it doesn't compile. A `*Files` writer takes the
## `Revoker` and writes for its user; ending streams is left to this
## module. tools/check_stream_endings.shale holds every revoking writer to
## taking one, and every holder `StreamHolder` names to being one this
## module ends.
import pf.Host
import FileFacts
import StreamHolder
import UserId

UserStreams :: [].{

	## The right to make the revoking writes of one user, whose streams
	## `with_streams_ended!` ends after them. Only `with_streams_ended!`
	## makes one, and its body's answer holds none, so none outlives it.
	Revoker :: UserId.{

		## The user whose sessions, credentials or access the writes revoke.
		user : UserStreams.Revoker -> UserId
		user = |UserStreams.Revoker.(id)| id
	}

	## `revoke!` run with the right to revoke the user `id`'s sessions,
	## credentials or access, then every stream `id` holds ended: when
	## `revoke!` succeeds, and when it fails or returns early too, since a
	## write may have landed before the failure.
	with_streams_ended! : UserId, (UserStreams.Revoker => Try({}, [FileSystem(FileFacts.Fault)])) => Try({}, [FileSystem(FileFacts.Fault)])
	with_streams_ended! = |id, revoke!| {
		revoked = revoke!(UserStreams.Revoker.(id))
		end_every_stream!(id)
		revoked
	}
}

## Every stream the user `id` holds ended now, under each holder
## `StreamHolder` names: their pages' streams (a conversation's, Recent's
## and the device code page's) and an agent's own stream.
end_every_stream! : UserId => {}
end_every_stream! = |id| {
	Host.end_every_stream_of_holder!(StreamHolder.user(id).to_bytes())
	Host.end_every_stream_of_holder!(StreamHolder.agent(id).to_bytes())
}
