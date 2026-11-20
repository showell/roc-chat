## This module decides where a link to a message goes (`MessageLink`), as
## Gopher Chat's `/chat/msg/<id>` decided (angry-gopher's
## zig-server/src/chat.zig, `redirectToMsg` and `onlyPlace`):
## the places a topic's link may mean for a reader (`meant`), and, of the
## conversations found with its topic, the one it goes to, or why none
## (`destination`). `MessageLinkRoute` reads the topics and answers.
import Access
import ConversationKey
import Directory
import Dm
import Place
import SignedIn

MessageLinkPlaces :: [].{

	## The places a topic's link may mean for `acting`, as Gopher's looked:
	## their DMs with each other human, then the channels, each one they may
	## read; never their own DM, which Gopher's left out, as Recent and
	## search do.
	meant : { acting : SignedIn, directory : Directory } -> List(Place)
	meant = |{ acting, directory }| {
		dms =
			match acting.user().as_human() {
				Ok(reader) =>
					directory.users().to_list()
						.keep_oks(|user| user.as_human())
						.drop_if(|other| other.id() == reader.id())
						.map(|other| Place.dm(Dm.between({ one: reader, other })))
				Err(Agent(_)) => []
			}
		channels = directory.channels().to_list().map(Place.channel)
		List.concat(dms, channels).keep_if(
			|place| Access.check({ acting, place, directory, act: Read }).is_ok(),
		)
	}

	## Where a link goes, of the conversations `found` with its topic: the
	## one, or nowhere when there is none, or no guess when there are more
	## (`Ambiguous`).
	destination : List(ConversationKey) -> [GoesTo(ConversationKey), Nowhere, Ambiguous]
	destination = |found|
		match found {
			[] => Nowhere
			[key] => GoesTo(key)
			_ => Ambiguous
		}
}
