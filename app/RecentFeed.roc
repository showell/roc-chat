## This module decides what Recent shows a human and writes its page, as
## Gopher Chat's `/chat/recent` did: one tile per conversation they may
## read, newest first by each conversation's last message, every
## conversation listed. A tile names its place (a channel's `#name` and the
## topic, or a DM's topic alone, its other human shown by their initial),
## when its last message was sent, and who sent it ("You" for the viewer)
## with an excerpt of it (`RecentExcerpt`). A tile links to the
## conversation's page.
##
## The places are Browse's (`Browse.places_for`), but for the viewer's own
## DM, which Gopher's Recent left out. `RecentRoute` reads each
## conversation's last message and answers; app/recent.js styles the tiles
## and says each time as how long ago it was.
import Browse
import ConversationKey
import DateTime
import Escape
import Html
import Name
import PageContract
import PageKit
import RecentExcerpt
import Script
import SignedIn
import Transcript
import TrustedHtml
import UserId

RecentFeed :: [].{

	## One conversation's tile: its key, its place's label (`#` and a
	## channel's name, or a DM's other human's name), and its last message's
	## time, author (`You` for the viewer) and excerpt.
	Tile : {
		key : ConversationKey,
		label : Str,
		time : DateTime,
		who : Str,
		excerpt : Str,
	}

	## The places Recent lists for `listed`, Browse's for the human `reader`:
	## each but the reader's own DM.
	places_without_own_dm : {
		listed : List(Browse.ListedPlace),
		reader : UserId,
	} -> List(Browse.ListedPlace)
	places_without_own_dm = |{ listed, reader }|
		listed.drop_if(
			|listed_place|
				match listed_place.place.which() {
					Dm(pair) => pair.members().all(|member| member == reader)
					Channel(_) => Bool.False
				},
		)

	## The tile of the conversation `key`, listed as `label`, whose last
	## message is `latest`, as the human named `viewer` sees it.
	tile : {
		key : ConversationKey,
		label : Str,
		latest : Transcript.LatestMessage,
		viewer : Name,
	} -> RecentFeed.Tile
	tile = |{ key, label, latest, viewer }| {
		author = latest.author.name()
		{
			key,
			label,
			time: latest.time,
			who: if author == viewer {
				"You"
			} else {
				author.to_str()
			},
			excerpt: RecentExcerpt.markdown_excerpt(latest.markdown),
		}
	}

	## `tiles`, newest first; two of one second by their pages' paths, in
	## byte order.
	newest_first : List(RecentFeed.Tile) -> List(RecentFeed.Tile)
	newest_first = |tiles|
		tiles.sort_with(
			|one, other|
				match DateTime.compare(one.time, other.time) {
					After => Before
					Before => After
					Same => compare_paths(one.key.url_path(Page), other.key.url_path(Page))
				},
		)

	## Where a Recent page's live stream is (`RecentStream`).
	stream_path : Str
	stream_path = "${PageKit.recent_path}/stream"

	## The Recent page for `viewer`: the line above the page, empty until
	## app/chrome.js says a notice there (Gopher Chat's Recent had its
	## #chat-notify), a line saying there is nothing yet when `tiles` is
	## empty, then the list of `tiles`, as given, which names its live stream.
	page : { viewer : SignedIn, tiles : List(RecentFeed.Tile) } -> TrustedHtml
	page = |{ viewer, tiles }| {
		nothing_yet =
			if tiles.is_empty() {
				[
					Html.element({
						name: P,
						attributes: [PageContract.class(Empty)],
						inner: Escape.text("Nothing yet."),
					}),
					PageKit.newline,
				]
			} else {
				[]
			}
		listed = Html.element({
			name: Div,
			attributes: [
				PageContract.class(RecentList),
				PageContract.data_attribute(Stream(PageKit.site_path(RecentFeed.stream_path))),
			],
			inner: TrustedHtml.join(tiles.map(tile_element)),
		})
		PageKit.signed_in_page({
			title: "Recent",
			viewer,
			parts: List.concat(
				List.concat(
					[
						Html.element({
							name: P,
							attributes: [PageContract.class(NoticeStrip)],
							inner: TrustedHtml.join([]),
						}),
						PageKit.newline,
					],
					nothing_yet,
				),
				[listed, PageKit.newline, PageKit.script(Script.Recent), PageKit.newline],
			),
		})
	}

	## One tile, as the page writes it and its stream sends it.
	tile_html : RecentFeed.Tile -> TrustedHtml
	tile_html = |given| tile_element(given)
}

## Two paths in byte order.
compare_paths : Str, Str -> [Before, Same, After]
compare_paths = |one, other| compare_bytes(one.to_utf8(), other.to_utf8())

## Two lists of bytes in byte order, a list before any it begins.
compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |one, other|
	match (one, other) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([one_byte, .. as one_rest], [other_byte, .. as other_rest]) =>
			if one_byte < other_byte {
				Before
			} else if one_byte > other_byte {
				After
			} else {
				compare_bytes(one_rest, other_rest)
			}
	}

## The first word of `who`, as Gopher's tile named an author.
first_word : Str -> Str
first_word = |who| who.split_on(" ").first() ?? who

## `text`'s first letter, in capitals where it is ASCII.
initial : Str -> Str
initial = |text| {
	bytes = text.to_utf8()
	length =
		match bytes.first() {
			Ok(byte) if byte >= 0xF0 => 4
			Ok(byte) if byte >= 0xE0 => 3
			Ok(byte) if byte >= 0xC0 => 2
			Ok(_) => 1
			Err(ListWasEmpty) => 0
		}
	Str.from_utf8_lossy(bytes.take_first(length)).with_ascii_uppercased()
}

## A span of `class` holding `inner`.
span : PageContract.Class, TrustedHtml -> TrustedHtml
span = |class, inner| Html.element({
	name: Span,
	attributes: [PageContract.class(class)],
	inner,
})

## One tile: a link to its conversation's page.
tile_element : RecentFeed.Tile -> TrustedHtml
tile_element = |{ key, label, time, who, excerpt }| {
	topic = key.topic().to_str()
	(lead, context) =
		match key.place().which() {
			Channel(_) => (
				span(RecentBar, TrustedHtml.join([])),
				span(
					RecentContext,
					TrustedHtml.join([
						Escape.text(label),
						span(RecentDot, Escape.text("  ·  ")),
						span(RecentTopic, Escape.text(topic)),
					]),
				),
			)
			Dm(_) => {
				partner = if who == "You" {
					label
				} else {
					who
				}
				(
					span(RecentAvatar, Escape.text(initial(partner))),
					span(RecentTitle, Escape.text(topic)),
				)
			}
		}
	ago = Html.element({
		name: Time,
		attributes: [PageContract.class(RecentAgo), DateTime(time)],
		inner: Escape.text(time.to_str()),
	})
	preview =
		if excerpt.is_empty() {
			TrustedHtml.join([])
		} else {
			span(
				RecentPreview,
				TrustedHtml.join([
					span(RecentWho, Escape.text("${first_word(who)}: ")),
					Escape.text(excerpt),
				]),
			)
		}
	TrustedHtml.join([
		Html.element({
			name: A,
			attributes: [
				PageContract.class(RecentTile),
				Link(PageKit.site_path(key.url_path(Page))),
			],
			inner: TrustedHtml.join([
				span(RecentLead, lead),
				span(
					RecentBody,
					TrustedHtml.join([span(RecentTop, TrustedHtml.join([context, ago])), preview]),
				),
			]),
		}),
		PageKit.newline,
	])
}

# ── tests
expect compare_paths(
	"/a",
	"/b",
) == Before and compare_paths("/b", "/a") == After and compare_paths("/a", "/a") == Same
expect compare_paths("/a", "/ab") == Before and compare_paths("/ab", "/a") == After
expect first_word("Steve Howell") == "Steve" and first_word("You") == "You"
expect initial("apoorva") == "A" and initial("élan") == "é" and initial("") == ""
