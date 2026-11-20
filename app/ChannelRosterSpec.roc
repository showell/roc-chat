## These are the tests of `ChannelRoster`: a channel card's members, by
## participation, and the words that say when each last posted.
import Author
import ChannelRoster
import ConversationKey
import DateTime
import Sample
import Seconds
import Timestamp
import Transcript
import Users

ChannelRosterSpec :: [].{}

## When the tests draw the card: 2026-11-02T19:11:32Z, the sample's time.
now : Timestamp
now = Timestamp.at_second(1793646692)

## The sample directory with three more humans, whose names sort apart in
## and out of case: Ann, bea and Zed.
users : Users
users = {
	one_more = (Sample.directory.add_human(Sample.name("Ann")) ?? crash "ChannelRosterSpec: Ann is free").directory
	two_more = (one_more.add_human(Sample.name("bea")) ?? crash "ChannelRosterSpec: bea is free").directory
	(two_more.add_human(Sample.name("Zed")) ?? crash "ChannelRosterSpec: Zed is free").directory.users()
}

## The user named `text`.
member : Str -> Users.User
member = |text|
	users.to_list().find_first(|user| user.name().to_str() == text)
		?? crash "ChannelRosterSpec: the users hold ${text}"

## A post by `author`, `ago` seconds before `now`.
post : Str, I64 -> Transcript.Byline
post = |author, ago| {
	author: Author.from_str(author) ?? crash "ChannelRosterSpec: an author's name",
	time: DateTime.from_timestamp(Timestamp.at_second(1793646692 - ago))
		?? crash "ChannelRosterSpec: a time",
}

## The rows of `names`' members for Steve, ordered by `posts`, as a test reads
## them: each name and its words, or "-" for none.
rows_of : List(Str), List(Transcript.Byline) -> List((Str, Str))
rows_of = |names, posts|
	ChannelRoster.rows({
		members: names.map(member),
		viewer: Sample.human("Steve"),
		posts,
		now,
	}).map(
		|row| (
			row.name,
			match row.posted {
				Posted(words) => words
				NotLately => "-"
			},
		),
	)

## Every member, given in no particular order.
member_names : List(Str)
member_names = ["Zed", "CC", "Apoorva", "bea", "Steve", "Ann"]

# Those who posted lately first, the latest first, each with when; then the
# rest by name in any case (Ann, bea, Zed, never ASCII's Ann, Zed, bea).
expect
	rows_of(
		member_names,
		[
			post("Steve", 3 * 86_400),
			post("Apoorva", 2 * 3600),
			post("CC", 600),
		],
	)
		== [
			("CC", "posted 10 minutes ago"),
			("Apoorva", "posted 2 hours ago"),
			("Steve", "posted 3 days ago"),
			("Ann", "-"),
			("bea", "-"),
			("Zed", "-"),
		]
# No posts: member_names by name.
expect
	rows_of(member_names, [])
		== [
			("Ann", "-"),
			("Apoorva", "-"),
			("bea", "-"),
			("CC", "-"),
			("Steve", "-"),
			("Zed", "-"),
		]
# A member's latest post decides, however the posts come (each topic's are
# read in turn, so they are in no one order).
expect
	rows_of(
		["Steve", "Apoorva"],
		[
			post("Steve", 7200),
			post("Apoorva", 3600),
			post("Steve", 60),
			post("Steve", 86_400),
		],
	)
		== [("Steve", "posted 1 minute ago"), ("Apoorva", "posted 1 hour ago")]
# Two who posted in one second, by name.
expect rows_of(["Zed", "Ann"], [post("Zed", 300), post("Ann", 300)]) == [
	("Ann", "posted 5 minutes ago"),
	("Zed", "posted 5 minutes ago"),
]
# The window: 14 days ago exactly still counts, a second before it doesn't.
expect
	rows_of(["Steve", "Apoorva"], [post("Steve", 14 * 86_400), post("Apoorva", 14 * 86_400 + 1)])
		== [("Steve", "posted 14 days ago"), ("Apoorva", "-")]
# A post by someone not in the channel (who has left it) names no one.
expect rows_of(["Steve"], [post("Apoorva", 60)]) == [("Steve", "-")]
# Names are case-sensitive: `steve` posting is not Steve.
expect rows_of(["Steve"], [post("steve", 60)]) == [("Steve", "-")]
# A human's row is the viewer's DM with them, the viewer's own DM for the
# viewer; an agent's is an agent's.
expect {
	kinds = ChannelRoster.rows({
		members: ["Steve", "Apoorva", "CC"].map(member),
		viewer: Sample.human("Steve"),
		posts: [],
		now,
	}).map(
		|row|
			match row.kind {
				Human(dm) => ConversationKey.place_url_path(dm)
				Agent => "agent"
			},
	)
	kinds == ["/chat/dm/1_2", "agent", "/chat/dm/1_1"]
}
# The words: under a minute, or ahead of the clock, is just now; else the
# largest whole unit.
expect
	[
		(0, "posted just now"),
		(59, "posted just now"),
		(-30, "posted just now"),
		(60, "posted 1 minute ago"),
		(3599, "posted 59 minutes ago"),
		(3600, "posted 1 hour ago"),
		(86_399, "posted 23 hours ago"),
		(86_400, "posted 1 day ago"),
		(10 * 86_400, "posted 10 days ago"),
	].all(|(seconds, words)| ChannelRoster.words(Seconds.of(seconds)) == words)
# Where `Transcript.latest_posts` stops: 14 days before the clock, or the
# epoch for a clock nearer it than that.
expect ChannelRoster.since(now).to_str() == "2026-10-19T19:11:32Z"
expect ChannelRoster.since(Timestamp.at_second(86_400)).to_str() == "1970-01-01T00:00:00Z"
