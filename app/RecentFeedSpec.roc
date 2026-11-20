## These are the tests of `RecentFeed`: which places Recent lists, each
## conversation's tile, and their order. `PageSpec` holds its page.
import Author
import ChannelName
import ConversationKey
import DateTime
import Directory
import RecentFeed
import Sample
import UnvalidatedString

RecentFeedSpec :: [].{}

## The sample directory, with the channel `crew` created by Steve.
with_crew : Directory
with_crew = {
	name = ChannelName.from_str("crew") ?? crash "RecentFeedSpec: a channel's name"
	(
		Sample.directory.create_channel({
			by: Sample.admin,
			name,
		}) ?? crash "RecentFeedSpec: the name is free"
	).directory
}

## The conversation at `path` in `with_crew`.
key_at : Str -> ConversationKey
key_at = |path| ConversationKey.from_url_path({
	path: UnvalidatedString.from_utf8(path.to_utf8()) ?? crash "RecentFeedSpec: a path is UTF-8",
	directory: with_crew,
}).map_ok(|found| found.key) ?? crash "RecentFeedSpec: a conversation's path"

## The time `text` spells.
time_of : Str -> DateTime
time_of = |text| DateTime.from_str(text) ?? crash "RecentFeedSpec: a time"

## The tile of `path`, listed as `label`, whose last message `author` sent
## at `time`, saying `markdown`, as Steve sees it, Apoorva online.
steves_tile : {
	path : Str,
	label : Str,
	author : Str,
	time : Str,
	markdown : Str,
} -> RecentFeed.Tile
steves_tile = |{ path, label, author, time, markdown }|
	RecentFeed.tile({
		key: key_at(path),
		label,
		latest: {
			author: Author.from_str(author) ?? crash "RecentFeedSpec: an author",
			time: time_of(time),
			markdown,
		},
		reader: Sample.steve.id(),
		viewer: Sample.name("Steve"),
		online_humans: [Sample.user("Apoorva").id()],
	})

# Steve's own DM is a tile like any other (Steve, 2026-11-20: "For some
# reason DMs to myself don't show up in Recent"): it names him, by his own
# name, always online, and its place is "DM with" him, "(you)"
# quiet, as Browse and the sidebar name it. His DM with Apoorva says her
# name plain.
expect {
	own = steves_tile({
		path: "/chat/dm/1_1/plans",
		label: "Steve",
		author: "Steve",
		time: "2026-11-02T19:11:32Z",
		markdown: "a note",
	})
	html = Str.from_utf8_lossy(RecentFeed.tile_html(own).to_utf8())
	own.person == Person(Sample.steve.id(), Online)
		and own.who == "You"
		and html.contains("<span class=\"recent-mark\"></span>DM with Steve <span class=\"you\">(you)</span></span>")
		and html.contains("<span class=\"recent-avatar\">S</span>")
		and html.contains("data-person=\"1\" data-presence=\"online\"")
}
expect
	Str.from_utf8_lossy(
		RecentFeed.tile_html(
			steves_tile({
				path: "/chat/dm/1_2/plans",
				label: "Apoorva",
				author: "Apoorva",
				time: "2026-11-02T19:11:32Z",
				markdown: "",
			}),
		).to_utf8(),
	).contains("<span class=\"recent-mark\"></span>DM with Apoorva</span>")

# A tile: "You" for the viewer's own last message, else its author's name;
# the excerpt from its markdown.
expect {
	tile = steves_tile({
		path: "/chat/dm/1_2/plans",
		label: "Apoorva",
		author: "Steve",
		time: "2026-11-02T19:11:32Z",
		markdown: "a\n\nb",
	})
	tile.who == "You" and tile.excerpt == "a b" and tile.label == "Apoorva"
}
expect
	steves_tile({
		path: "/chat/dm/1_2/plans",
		label: "Apoorva",
		author: "Apoorva",
		time: "2026-11-02T19:11:32Z",
		markdown: "",
	}).who
		== "Apoorva"

# A DM's tile names its other human and whether they are online; a
# channel's names no one.
expect {
	at = |path, label| steves_tile({
		path,
		label,
		author: "Steve",
		time: "2026-11-02T19:11:32Z",
		markdown: "",
	}).person
	at("/chat/dm/1_2/plans", "Apoorva") == Person(Sample.user("Apoorva").id(), Online)
		and at("/chat/channel/crew/plans", "#crew") == NoPerson
}
expect
	RecentFeed.tile({
		key: key_at("/chat/dm/1_2/plans"),
		label: "Apoorva",
		latest: {
			author: Author.from_str("Steve") ?? crash "RecentFeedSpec: an author",
			time: time_of("2026-11-02T19:11:32Z"),
			markdown: "",
		},
		reader: Sample.steve.id(),
		viewer: Sample.name("Steve"),
		online_humans: [],
	}).person
		== Person(Sample.user("Apoorva").id(), Offline)

# Newest first; two in one second by their paths.
expect {
	at = |path, time| steves_tile({
		path,
		label: "Apoorva",
		author: "Steve",
		time,
		markdown: "",
	})
	RecentFeed.newest_first([
		at("/chat/dm/1_2/a", "2026-11-02T10:00:00Z"),
		at("/chat/dm/1_2/c", "2026-11-03T10:00:00Z"),
		at("/chat/dm/1_2/b", "2026-11-03T10:00:00Z"),
		at("/chat/channel/crew/d", "2026-11-01T10:00:00Z"),
	]).map(|tile| tile.key.url_path(Page))
		== ["/chat/dm/1_2/b", "/chat/dm/1_2/c", "/chat/dm/1_2/a", "/chat/channel/crew/d"]
}
