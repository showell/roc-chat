## This module builds the sidebar of a conversation's page: the places
## `Browse` lists for the viewer, in two groups, Channels and DMs, each
## under its heading (`data-group`) and in the order `SidebarOrder` gives
## them, a group with no places left out. The group holding the page's own
## topic comes first: DMs before Channels on a DM's page, Channels first
## on a channel's. The order is the server's, so nothing moves once the
## page loads, and each group keeps its own collapsed or open state, kept
## by its name and not its place; each place's topics under it as
## links, and at the end of each place's
## topics the form that starts one (`TopicForm`). Under each place's name is
## its button that offers that form, "New topic in" and the place's name:
## app/sidebar.js shows the button as a small "+" beside the name, and the
## form only in a popup the button opens. Each place says how it
## starts (`data-opening`), open or collapsed, as `SidebarOrder` decides.
## The topic the page shows is marked current, and it is listed in its
## place even before its first message gives it a folder.
##
## Before the page's layout comes the sidebar's toggle, the button a narrow
## window's drawer opens the sidebar by. app/sidebar.js styles the sidebar,
## lets each place's topics collapse, opens the new-topic popup, and in a
## narrow window, a phone's, moves the toggle into the top bar and makes the
## sidebar a drawer over the page. It finds each part by `PageContract`'s classes, and a place by
## its path (`data-section`).
##
## A DM with another human names them (`data-person`) and says whether they
## are online (`data-presence`, by `Presence`), so app/sidebar.js draws its
## dot, and fills it when the page's stream says they have come online.
## Clicking a DM's name opens app/sidebar-popups.js's card about the person:
## their name (the place's label), whether they are online, the topics of
## the DM as links, and a new topic. When each human joined is not drawn yet:
## once accounts keep it, `person_attributes` adds `data-joined` (its seconds
## since 1970, `PageContract`'s `Joined`), and the card says it.
import ConversationKey
import Escape
import Html
import PageContract
import PageKit
import Place
import SidebarOrder
import TopicForm
import TrustedHtml
import UserId

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

	## The sidebar of `places` on `viewer`'s page of the conversation
	## `current`, in `SidebarOrder`'s order, `current`'s group first, the
	## humans in `online_humans` said to be online.
	nav : {
		places : List(SidebarOrder.TimedPlace),
		current : ConversationKey,
		viewer : UserId,
		online_humans : List(UserId),
	} -> TrustedHtml
	nav = |{ places, current, viewer, online_humans }| {
		people = { viewer, online_humans }
		in_order = SidebarOrder.ordered_places({ places, shown: Conversation(current), viewer })
		drawn = |ordered| place_section({ ordered, current, people })
		channels = group_section({ group: Channels, places: in_order.keep_if(is_channel).map(drawn) })
		dms = group_section({ group: Dms, places: in_order.drop_if(is_channel).map(drawn) })
		groups =
			match current.place().which() {
				Channel(_) => [channels, dms]
				Dm(_) => [dms, channels]
			}
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

## Whether `ordered` is a channel, which the Channels group lists; a DM
## is listed under DMs.
is_channel : SidebarOrder.OrderedPlace -> Bool
is_channel = |ordered|
	match ordered.place.which() {
		Channel(_) => Bool.True
		Dm(_) => Bool.False
	}

## One of the sidebar's two groups: its heading, which app/sidebar.js lets
## collapse the whole group, and its `places`, in `SidebarOrder`'s order.
## A group with no places is left out, as nothing.
group_section : { group : [Channels, Dms], places : List(TrustedHtml) } -> TrustedHtml
group_section = |{ group, places }|
	if places.is_empty() {
		TrustedHtml.join([])
	} else {
		heading =
			match group {
				Channels => "Channels"
				Dms => "DMs"
			}
		TrustedHtml.join([
			Html.element({
				name: Div,
				attributes: [
					PageContract.class(SidebarSection),
					PageContract.data_attribute(Group(group)),
				],
				inner: TrustedHtml.join(
					List.concat(
						[
							Html.element({
								name: P,
								attributes: [PageContract.class(SidebarSectionName)],
								inner: Escape.text(heading),
							}),
							PageKit.newline,
						],
						places,
					),
				),
			}),
			PageKit.newline,
		])
	}

## Who the page is for, and who is online.
People : { viewer : UserId, online_humans : List(UserId) }

## The attributes that say who the DM `place` is with, when it is another
## human than the viewer, and whether they are online; none for a channel or
## the viewer's own DM.
person_attributes : { place : Place, people : People } -> List(Html.Attribute)
person_attributes = |{ place, people }|
	match place.which() {
		Channel(_) => []
		Dm(pair) =>
			match pair.members().drop_if(|id| id == people.viewer) {
				[other] => [
					PageContract.data_attribute(Person(PageKit.token(other.to_str()))),
					PageContract.data_attribute(
						Presence(
							if people.online_humans.contains(other) {
								Online
							} else {
								Offline
							},
						),
					),
				]
				_ => []
			}
	}

## One place: its name, how it starts, its topics, `current`'s marked, and
## the form that starts a topic there. A place with no topics lists none.
place_section : {
	ordered : SidebarOrder.OrderedPlace,
	current : ConversationKey,
	people : People,
} -> TrustedHtml
place_section = |{ ordered, current, people }| {
	topics = ordered.topics
	place = ordered.place
	rows = topics.map(|topic| topic_row({ key: ConversationKey.of({ place, topic }), current }))
	section = PageKit.site_path(ConversationKey.place_url_path(place))
	TrustedHtml.join([
		Html.element({
			name: Div,
			attributes: List.concat(
				[
					PageContract.class(SidebarPlace),
					PageContract.data_attribute(Section(section)),
					PageContract.data_attribute(Opening(ordered.opening)),
				],
				person_attributes({ place, people }),
			),
			inner: TrustedHtml.join([
				Html.element({
					name: P,
					attributes: [PageContract.class(SidebarPlaceName)],
					inner: Escape.text(ordered.label),
				}),
				PageKit.newline,
				Html.element({
					name: Button,
					attributes: [PageContract.class(SidebarNewTopic)],
					inner: Escape.text("New topic in ${ordered.label}"),
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
				TopicForm.form({ place, topics }),
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
