## This module decides what Browse shows a human and writes its page. Browse
## is the way into the chat: every human as a DM, the reader too (their own
## DM), then each channel the reader is a member of, each with its topics and
## a form that starts a new one. Above them is the link to the invites page,
## as every human who browses may invite. `Access` decides what is listed, so a place
## the reader couldn't open is never shown. `BrowseRoute` reads the topics and
## answers.
import Access
import ConversationKey
import Directory
import Dm
import Page
import PeoplePages
import Place
import SignedIn
import Topic
import TrustedHtml
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
				.sort_with(|a, b| a.id().compare(b.id()))
				.map(|other| dm_listed({ reader, other }))
		channels = directory.channels().to_list().map(
			|channel| { label: "#${channel.name().to_str()}", place: Place.channel(channel) },
		)
		Ok(
			dms.concat(channels).keep_if(
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

	## The Browse page for `viewer`: `problem`, when there is one, the link
	## to the invites page, then each of `places`.
	page : {
		viewer : SignedIn,
		places : List(Browse.PlaceWithTopics),
		problem : [NoProblem, Problem(Str)],
	} -> TrustedHtml
	page = |{ viewer, places, problem }| {
		said =
			match problem {
				NoProblem => []
				Problem(text) => [Page.text_paragraph(text)]
			}
		Page.signed_in_page({
			title: "Browse",
			viewer,
			parts: said.append(invite_link).concat(places.map(place_section)),
		})
	}
}

## The link to the invites page.
invite_link : TrustedHtml
invite_link = Page.link_paragraph({ path: PeoplePages.invites_path, text: "Invite someone" })

## The DM between `reader` and `other`, shown by `other`'s name.
dm_listed : { reader : Users.Human, other : Users.Human } -> Browse.ListedPlace
dm_listed = |{ reader, other }| {
	label: other.user().name().to_str(),
	place: Place.dm(Dm.between({ a: reader, b: other })),
}

## One place on the page: its name, its topics as links, and the form that
## starts a topic. A place with no topics yet says so and suggests its first.
place_section : Browse.PlaceWithTopics -> TrustedHtml
place_section = |{ label, place, topics }| {
	action = ConversationKey.place_url_path(place)
	listed =
		if topics.is_empty() {
			[Page.text_paragraph("No sessions yet")]
		} else {
			topics.map(
				|topic|
					Page.link_paragraph({
						path: ConversationKey.of({ place, topic }).url_path(Page),
						text: topic.to_str(),
					}),
			)
		}
	suggestion = if topics.is_empty() {
		Suggested(first_topic)
	} else {
		NoSuggestion
	}
	TrustedHtml.join(
		[Page.heading(label)]
			.concat(listed)
			.append(Page.topic_form({ action, suggestion })),
	)
}

## The topic a place's form suggests until it has one.
first_topic : Topic
first_topic = Topic.from_str("general") ?? crash "Browse.first_topic: general is a topic"
