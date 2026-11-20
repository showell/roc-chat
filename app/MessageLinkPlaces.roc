## This module decides where a link to a message goes (`MessageLink`), as
## Gopher Chat's `/chat/msg/<id>` decided (angry-gopher's
## zig-server/src/chat.zig, `redirectToMsg` and `onlyPlace`):
## the places a topic's link may mean for a reader (`readable_places`), and, of the
## conversations found with its topic, the one it goes to, or why none
## (`destination`). `MessageLinkRoute` reads the topics and answers.
import Access
import ConversationKey
import Directory
import Dm
import Place
import SignedIn

MessageLinkPlaces :: [].{

	## The places a topic's link may mean for `acting`: their DMs, their own
	## among them, by the other human's id, then the channels, each one they
	## may read. Gopher's never looked in a human's own DM; this one does, as
	## Recent and search do, since a message to yourself is like any other.
	readable_places : { acting : SignedIn, directory : Directory } -> List(Place)
	readable_places = |{ acting, directory }| {
		dms =
			match acting.user().as_human() {
				Ok(reader) =>
					directory.users().to_list()
						.keep_oks(|user| user.as_human())

						.map(|other| Place.dm(Dm.between({ one: reader, other })))
				Err(Agent(_)) => []
			}
		channels = directory.channels().to_list().map(Place.channel)
		List.concat(dms, channels).keep_if(
			|place| Access.check({ acting, place, directory, act: Read }).is_ok(),
		)
	}

	## Where a link goes, of the conversations `found_keys` with its topic: the
	## one, or nowhere when there is none, or no guess when there are more
	## (`Ambiguous`).
	destination : List(ConversationKey) -> [GoesTo(ConversationKey), Nowhere, Ambiguous]
	destination = |found_keys|
		match found_keys {
			[] => Nowhere
			[key] => GoesTo(key)
			_ => Ambiguous
		}
}
