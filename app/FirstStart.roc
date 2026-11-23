## This module says what a new chat holds when the server first starts on an
## empty data folder: Steve, the founder, a human of id 1, and the default
## channel, which he creates as the chat's first admin and is the one member
## of. It is a product decision, not storage: `DirectoryStore` writes this
## directory to disk, and the demo's page shows it.
import Admin
import Channels
import Directory
import Name
import SignedIn

FirstStart :: [].{

	## The directory at the first start: Steve (id 1), a human, and one
	## channel, the default one, which he creates as the chat's first admin and
	## is the one member of. Steve acts here with nothing checked (`SignedIn`),
	## as no one has signed in before the chat exists.
	first_directory : Directory
	first_directory = {
		founded = Directory.with_founder(FirstStart.founder_name)
		founder = founded.chat_owner().as_user()
		admin =
			Admin.of(SignedIn.dangerously_assume(founder))
				?? crash "FirstStart.first_directory: Steve, id 1, is an admin"
		created = (
			founded.create_channel({
				by: admin,
				name: Channels.default_name,
			}) ?? crash "FirstStart.first_directory: the default channel's name is free"
		).directory
		created.add_member({
			by: admin,
			channel: Channels.default_name,
			member: founder,
		}) ?? crash "FirstStart.first_directory: Steve joins the default channel"
	}

	## The founder's name, Steve.
	founder_name : Name
	founder_name = Name.from_str("Steve") ?? crash "FirstStart.founder_name: Steve is a name"
}
