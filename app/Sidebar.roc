## This module builds the sidebar of a conversation's page: the places
## `Browse` lists for the viewer, their DMs and then their channels, each
## place's topics under it as links, and at the end of each place's topics
## the form that starts one (`TopicForm`). The topic the page shows is
## marked current, and it is listed in its place even before its first
## message gives it a folder. A group with no places is left out.
##
## Before the page's layout comes the sidebar's toggle, the button a narrow
## window's drawer opens the sidebar by. app/sidebar.js styles the sidebar,
## lets each place's topics collapse, and in a narrow window, a phone's,
## moves the toggle into the top bar and makes the sidebar a drawer over
## the page. It finds each part by `PageContract`'s classes, and a place by
## its path (`data-section`).
import Browse
import ConversationKey
import Escape
import Html
import PageContract
import PageKit
import Place
import TopicForm
import TrustedHtml

Sidebar :: [].{

	## The button that opens the sidebar as a drawer, and a line end.
	toggle : TrustedHtml
	toggle = TrustedHtml.join([
		Html.element({
			name: Button,
			attributes: [PageContract.class(SidebarToggle)],
			inner: Escape.text("Conversations"),
		}),
		PageKit.newline,
	])

	## The sidebar of `places`, on the page of the conversation `current`.
	nav : { places : List(Browse.PlaceWithTopics), current : ConversationKey } -> TrustedHtml
	nav = |{ places, current }| {
		dms = places.keep_if(|listed| is_dm(listed.place))
		channels = places.keep_if(|listed| !is_dm(listed.place))
		groups = List.concat(
			group_elements({ heading: "DMs", places: dms, current }),
			group_elements({ heading: "Channels", places: channels, current }),
		)
		TrustedHtml.join([
			Html.element({
				name: Nav,
				attributes: [PageContract.class(Sidebar)],
				inner: TrustedHtml.join(List.concat([PageKit.newline], groups)),
			}),
			PageKit.newline,
		])
	}
}

## Whether `place` is a DM, which the sidebar lists before the channels.
is_dm : Place -> Bool
is_dm = |place|
	match place.which() {
		Dm(_) => Bool.True
		Channel(_) => Bool.False
	}

## A group of the sidebar: its heading, then each of `places`; nothing when
## there are none.
group_elements : {
	heading : Str,
	places : List(Browse.PlaceWithTopics),
	current : ConversationKey,
} -> List(TrustedHtml)
group_elements = |{ heading, places, current }|
	if places.is_empty() {
		[]
	} else {
		List.concat(
			[
				Html.element({
					name: P,
					attributes: [PageContract.class(SidebarHeading)],
					inner: Escape.text(heading),
				}),
				PageKit.newline,
			],
			places.map(|listed| place_section({ listed, current })),
		)
	}

## One place: its name, its topics, `current`'s marked, and the form that
## starts a topic there.
place_section : { listed : Browse.PlaceWithTopics, current : ConversationKey } -> TrustedHtml
place_section = |{ listed, current }| {
	topics =
		if listed.place == current.place() and !listed.topics.contains(current.topic()) {
			listed.topics.append(current.topic())
		} else {
			listed.topics
		}
	rows =
		if topics.is_empty() {
			[
				Html.element({
					name: Li,
					attributes: [PageContract.class(SidebarEmpty)],
					inner: Escape.text("No sessions yet"),
				}),
			]
		} else {
			topics.map(
				|topic| topic_row({
					key: ConversationKey.of({ place: listed.place, topic }),
					current,
				}),
			)
		}
	section = PageKit.site_path(ConversationKey.place_url_path(listed.place))
	TrustedHtml.join([
		Html.element({
			name: Div,
			attributes: [
				PageContract.class(SidebarPlace),
				PageContract.data_attribute(Section(section)),
			],
			inner: TrustedHtml.join([
				Html.element({
					name: P,
					attributes: [PageContract.class(SidebarPlaceName)],
					inner: Escape.text(listed.label),
				}),
				PageKit.newline,
				Html.element({
					name: Ul,
					attributes: [PageContract.class(SidebarTopics)],
					inner: TrustedHtml.join(
						List.concat(
							[PageKit.newline],
							rows.map(|row| TrustedHtml.join([row, PageKit.newline])),
						),
					),
				}),
				PageKit.newline,
				TopicForm.form({ place: listed.place, topics }),
			]),
		}),
		PageKit.newline,
	])
}

## One topic's row: a link to the conversation `key`, marked when it is
## `current`.
topic_row : { key : ConversationKey, current : ConversationKey } -> TrustedHtml
topic_row = |{ key, current }| {
	marked = if key == current {
		[PageContract.class(Current)]
	} else {
		[]
	}
	Html.element({
		name: Li,
		attributes: [],
		inner: Html.element({
			name: A,
			attributes: marked.append(Link(PageKit.site_path(key.url_path(Page)))),
			inner: Escape.text(key.topic().to_str()),
		}),
	})
}
