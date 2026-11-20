## This module decides what Browse shows a human and writes its page. Browse
## lists every place a human may open: every human as a DM, the reader too
## (their own DM), then each channel the reader is a member of, each with its
## topics and a form that starts a new one, in two panes, the channels and
## the DMs. A conversation's sidebar (`Sidebar`) lists the same places, and
## Browse is where someone who can't find a place there looks, so it opens
## with a few quiet lines for someone new. `Access` decides what is listed,
## so a place the reader couldn't open is never shown. A problem with a
## form, such as a name that is no topic, is said beside that form, which
## keeps what was typed. `BrowseRoute` reads the topics and answers.
import Access
import ConversationKey
import Directory
import Dm
import Escape
import Html
import PageContract
import PageKit
import Place
import SignedIn
import Topic
import TopicForm
import TrustedHtml
import UnvalidatedString
import UserId
import Users

Browse :: [].{

	## A place Browse lists, by the name it shows.
	ListedPlace : { label : Str, place : Place }

	## A listed place and the topics of its conversations.
	PlaceWithTopics : {
		label : Str,
		place : Place,
		topics : List(Topic),
	}

	## The places `acting` may read in `directory`: the DMs, by their other
	## human's id, then the channels, in the directory's order. Only a human
	## browses, by their own session (`SignedIn.human_in_session`).
	places_for : { acting : SignedIn, directory : Directory } -> Try(
		List(Browse.ListedPlace),
		[ByApiKey, Agent(UserId)],
	)
	places_for = |{ acting, directory }| {
		reader = acting.human_in_session()?
		dms =
			directory.users().to_list()
				.keep_oks(|user| user.as_human())
				.sort_with(|a, b| UserId.compare(a.id(), b.id()))
				.map(|other| dm_listed({ reader, other }))
		channels = directory.channels().to_list().map(
			|channel| { label: "#${channel.name().to_str()}", place: Place.channel(channel) },
		)
		Ok(
			List.concat(dms, channels).keep_if(
				|listed|
					Access.check({
						acting,
						place: listed.place,
						directory,
						act: Read,
					}).is_ok(),
			),
		)
	}

	## A form's problem on Browse: the place whose form was refused, what was
	## typed there, if anything, and why, said beside that place's form.
	TopicProblem : [
		NoProblem,
		Problem(
			{
				place : Place,
				typed : [Typed(UnvalidatedString), NothingTyped],
				words : Str,
			},
		),
	]

	## The Browse page for `viewer`: a few quiet lines for someone new, then
	## two panes, the channels and the DMs, each place with its topics and
	## its form; `problem`, when there is one, beside its place's form, or
	## first when no place listed is its own.
	page : {
		viewer : SignedIn,
		places : List(Browse.PlaceWithTopics),
		problem : Browse.TopicProblem,
	} -> TrustedHtml
	page = |{ viewer, places, problem }| {
		is_listed = |place| places.any(|listed| listed.place == place)
		unplaced =
			match problem {
				Problem({ place, typed: _, words }) if !is_listed(place) =>
					[PageKit.problem(words)]
				_ => []
			}
		section = |listed| place_section(listed, { viewer, problem })
		channels = places.keep_if(|listed| is_channel(listed.place))
		dms = places.drop_if(|listed| is_channel(listed.place))
		PageKit.signed_in_page({
			title: "Browse",
			viewer,
			parts: List.concat(
				unplaced,
				[
					newcomer_lines,
					Html.element({
						name: Div,
						attributes: [PageContract.class(BrowsePanes)],
						inner: TrustedHtml.join([
							pane("Channels", channels.map(section)),
							pane("Direct messages", dms.map(section)),
						]),
					}),
					PageKit.newline,
				],
			),
			panel: PlainPanel,
		})
	}

	## Whether `place` is the DM of `viewer` alone, their own DM, which Browse
	## and the sidebar label with `PageKit.own_name`.
	is_own_dm : Place, SignedIn -> Bool
	is_own_dm = |place, viewer|
		match place.which() {
			Dm(pair) => pair.members().all(|id| id == viewer.user().id())
			Channel(_) => Bool.False
		}
}

## The path of `topic`'s page in `place`.
topic_path : Place, Topic -> Str
topic_path = |place, topic| ConversationKey.of({ place, topic }).url_path(Page)

## Whether `place` is a channel.
is_channel : Place -> Bool
is_channel = |place|
	match place.which() {
		Channel(_) => Bool.True
		Dm(_) => Bool.False
	}

## One of the page's two panes: its heading, then `sections`, or a line
## saying it has none.
pane : Str, List(TrustedHtml) -> TrustedHtml
pane = |title, sections|
	Html.element({
		name: Div,
		attributes: [],
		inner: TrustedHtml.join(
			List.concat(
				[PageKit.heading(title)],
				if sections.is_empty() {
					[PageKit.paragraph("None yet.")]
				} else {
					sections
				},
			),
		),
	})

## The quiet lines for someone new: what the chat has and how to reach it.
newcomer_lines : TrustedHtml
newcomer_lines =
	Html.element({
		name: Div,
		attributes: [PageContract.class(Help)],
		inner: TrustedHtml.join([
			PageKit.paragraph("New here? Every place you can read is below: open a topic, or start one with its place's form."),
			PageKit.paragraph("In a conversation, the sidebar lists your places, and its + starts a topic or a DM."),
			PageKit.paragraph("Recent shows the newest messages everywhere, as they arrive."),
			PageKit.paragraph("In a topic, c writes, q quote-replies, and / searches; the keys are listed beside the messages."),
			PageKit.paragraph("To bring someone in, use Invites in the top bar."),
		]),
	})

## The DM between `reader` and `other`, shown by `other`'s name.
dm_listed : { reader : Users.Human, other : Users.Human } -> Browse.ListedPlace
dm_listed = |{ reader, other }| {
	label: other.user().name().to_str(),
	place: Place.dm(Dm.between({ one: reader, other })),
}

## One place on the page: its name, the reader's own DM marked "(you)", its
## topics as links, and the form that starts a topic, holding what was typed
## and saying `problem` when that form was refused. A place with no topics
## yet says so and suggests its first.
place_section :
	Browse.PlaceWithTopics, { viewer : SignedIn, problem : Browse.TopicProblem } -> TrustedHtml
place_section = |{ label, place, topics }, { viewer, problem }| {
	name =
		if Browse.is_own_dm(place, viewer) {
			PageKit.own_name(label)
		} else {
			Escape.text(label)
		}
	listed =
		if topics.is_empty() {
			[PageKit.paragraph("No topics yet")]
		} else {
			topics.map(
				|topic|
					TrustedHtml.join([
						Html.element({
							name: P,
							attributes: [],
							inner: Html.element({
								name: A,
								attributes: [
									PageContract.class(TopicLink),
									Link(PageKit.site_path(topic_path(place, topic))),
								],
								inner: Escape.text(topic.to_str()),
							}),
						}),
						PageKit.newline,
					]),
			)
		}
	form =
		match problem {
			Problem({ place: refused, typed, words }) if refused == place =>
				TopicForm.refused_form({ place, typed, problem: words })
			_ => TopicForm.form({ place, topics })
		}
	TrustedHtml.join(List.concat([PageKit.heading_of(name)], listed).append(form))
}
