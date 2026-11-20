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
## place even before its first message gives it a folder. The DMs group
## lists every human, the viewer's own DM, named "<name> (you)"
## (`PageKit.own_name`), next after the page's own place
## (Steve, 2026-11-20: "Show all the users. Scrolling is fine."), each
## collapsed to its name's row but the page's own.
##
## Before the page's layout comes the sidebar's toggle, the button a narrow
## window's drawer opens the sidebar by. app/sidebar.js styles the sidebar,
## lets each place's topics collapse, opens the new-topic popup, and in a
## narrow window, a phone's, moves the toggle into the top bar and makes the
## sidebar a drawer over the page. It finds each part by `PageContract`'s classes, and a place by
## its path (`data-section`).
##
## A DM names its person (`data-person`), the other human or, for the
## viewer's own DM, the viewer, and says whether they are online
## (`data-presence`, by `Presence`), so app/sidebar.js draws its dot, and
## fills it when the page's stream says they have come online. The viewer
## is always drawn online, since they are making this very request: their
## own dot is green, which is how a reader learns what green means (Steve,
## 2026-11-20: "Show the presence bubble for Steve to Steve. This is how we
## teach people how presence works!").
## Clicking a place's name opens app/sidebar-popups.js's card about it, a
## channel's and a DM's alike: its name (the place's label), for a DM whether
## its person is online, its topics as links, and a new topic. A channel's
## card lists its members too, in `ChannelRoster`'s order, by participation:
## the server writes them after the channel's topics (`sidebar-members`),
## each naming who they are (`data-person`), whether a human or an agent
## (`data-kind`), and for a human, the viewer too, whether they are online
## and the path of the viewer's DM with them (`data-section`), whose card
## theirs is; and when
## they last posted, when lately. app/sidebar.js takes the list out of the
## sidebar, and the card shows it. When each
## human joined is not drawn yet: once accounts keep it,
## `person_attributes` adds `data-joined` (its seconds since 1970,
## `PageContract`'s `Joined`), and the card says it.
import Browse
import ChannelRoster
import ConversationKey
import Escape
import Html
import PageContract
import PageKit
import Place
import SidebarOrder
import SignedIn
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
	## humans in `online_humans` said to be online, each channel's members as
	## `rosters` orders them.
	nav : {
		places : List(SidebarOrder.TimedPlace),
		current : ConversationKey,
		viewer : SignedIn,
		online_humans : List(UserId),
		rosters : List(ChannelRoster.Roster),
	} -> TrustedHtml
	nav = |{ places, current, viewer, online_humans, rosters }| {
		people = { viewer, online_humans }
		in_order = SidebarOrder.ordered_places({
			places,
			shown: Conversation(current),
			viewer: viewer.user().id(),
		})
		drawn = |ordered| place_section({ ordered, current, people, rosters })
		channels = group_section({
			group: Channels,
			places: in_order.keep_if(is_channel).map(drawn),
		})
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
## collapse the whole group, and its `places`, in `SidebarOrder`'s order. A
## group with no places is left out, as nothing.
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

## Who the page is for, and who else is online.
People : { viewer : SignedIn, online_humans : List(UserId) }

## Whether the human `id` is drawn online: the viewer always is, since they
## are making this very request, and anyone else while `online_humans`
## holds them.
presence_of : UserId, People -> [Online, Offline]
presence_of = |id, people|
	if id == people.viewer.user().id() or people.online_humans.contains(id) {
		Online
	} else {
		Offline
	}

## The attributes that say whom the DM `place` is with, the other human or,
## for the viewer's own DM, the viewer, and whether they are online; none for
## a channel.
person_attributes : { place : Place, people : People } -> List(Html.Attribute)
person_attributes = |{ place, people }|
	match place.which() {
		Channel(_) => []
		Dm(pair) => {
			viewer = people.viewer.user().id()
			person =
				match pair.members().drop_if(|id| id == viewer) {
					[other] => other
					_ => viewer
				}
			[
				PageContract.data_attribute(Person(PageKit.token(person.to_str()))),
				PageContract.data_attribute(Presence(presence_of(person, people))),
			]
		}
	}

## One place: its name, how it starts, its topics, `current`'s marked, a
## channel's members as its roster among `rosters` orders them, and the form
## that starts a topic there. A place with no topics lists none.
place_section : {
	ordered : SidebarOrder.OrderedPlace,
	current : ConversationKey,
	people : People,
	rosters : List(ChannelRoster.Roster),
} -> TrustedHtml
place_section = |{ ordered, current, people, rosters }| {
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
					inner: if Browse.is_own_dm(place, people.viewer) {
						PageKit.own_name(ordered.label)
					} else {
						Escape.text(ordered.label)
					},
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
				members_list({ place, rosters, people }),
				TopicForm.form({ place, topics }),
			]),
		}),
		PageKit.newline,
	])
}

## The members of the channel `place`, as its roster among `rosters` orders
## them, each a row naming them and, when they posted lately, its words;
## nothing for a DM.
members_list : {
	place : Place,
	rosters : List(ChannelRoster.Roster),
	people : People,
} -> TrustedHtml
members_list = |{ place, rosters, people }|
	match rosters.find_first(|roster| roster.place == place) {
		Err(NotFound) => TrustedHtml.join([])
		Ok(roster) =>
			TrustedHtml.join([
				Html.element({
					name: Ul,
					attributes: [PageContract.class(SidebarMembers)],
					inner: TrustedHtml.join(
						List.concat(
							[PageKit.newline],
							roster.rows.map(
								|row| TrustedHtml.join([member_row(row, people), PageKit.newline]),
							),
						),
					),
				}),
				PageKit.newline,
			])
	}

## One member's row: their name, and when they posted lately. A human, the
## viewer too, says whether they are online.
member_row : ChannelRoster.Row, People -> TrustedHtml
member_row = |row, people| {
	who = PageContract.data_attribute(Person(PageKit.token(row.id.to_str())))
	attributes =
		match row.kind {
			Human(dm) => {
				dm_path = PageKit.site_path(ConversationKey.place_url_path(dm))
				[
					who,
					PageContract.data_attribute(Kind(Human)),
					PageContract.data_attribute(Presence(presence_of(row.id, people))),
					PageContract.data_attribute(Section(dm_path)),
				]
			}
			Agent => [who, PageContract.data_attribute(Kind(Agent))]
		}
	words =
		match row.posted {
			Posted(text) => [
				Html.element({
					name: Span,
					attributes: [PageContract.class(SidebarMemberWords)],
					inner: Escape.text(text),
				}),
			]
			NotLately => []
		}
	Html.element({
		name: Li,
		attributes,
		inner: TrustedHtml.join(
			List.concat(
				[
					Html.element({
						name: Span,
						attributes: [PageContract.class(SidebarMemberName)],
						inner: Escape.text(row.name),
					}),
				],
				words,
			),
		),
	})
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
