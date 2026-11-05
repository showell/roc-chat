## This module answers Browse's routes (`Route` lists them). `Browse` decides
## what is shown; this module reads each place's topics and answers.
##
## A POST to a place's own path starts a topic there: the browser goes to the
## topic's page, empty and ready to write in. Nothing is written, since only a
## message's POST starts a conversation (`ConversationRoute`), so a topic left
## with no message leaves no trace. A name that is no topic is Browse again,
## saying why.
##
## Both routes are a human's, by their own session: a key is refused. main has
## asked `Access` that the human may post at the place.
import pf.Http
import Browse
import ConversationKey
import Directory
import FileSystem
import HttpAnswer
import Page
import Place
import SignedIn
import Topic
import UrlEncodedForm

BrowseRoute :: [].{

	## A GET of Browse, for `acting`.
	show! : { acting : SignedIn, directory : Directory } => Http.Response
	show! = |{ acting, directory }|
		answer_page!({
			acting,
			directory,
			status: 200,
			problem: NoProblem,
		})

	## A POST of a new topic's form, `body`, to `place`: a 303 to its page; or
	## Browse again, a 400, saying what is wrong with the name.
	start_topic! : {
		acting : SignedIn,
		directory : Directory,
		place : Place,
		body : List(U8),
	} => Http.Response
	start_topic! = |
		{
			acting,
			directory,
			place,
			body,
		},
	|
		match acting.human_in_session() {
			Err(ByApiKey) => key_refusal
			Err(Agent(_)) => key_refusal
			Ok(_) =>
				match topic_from_form(body) {
					Ok(topic) => HttpAnswer.see_other(ConversationKey.of({ place, topic }).url_path(Page))
					Err(NotATopic(words)) =>
						answer_page!({
							acting,
							directory,
							status: 400,
							problem: Problem(words),
						})
				}
		}
}

## Browse for `acting`, answered with `status`, saying `problem`.
answer_page! : {
	acting : SignedIn,
	directory : Directory,
	status : U16,
	problem : [NoProblem, Problem(Str)],
} => Http.Response
answer_page! = |
	{
		acting,
		directory,
		status,
		problem,
	},
|
	match Browse.places_for({ acting, directory }) {
		Err(ByApiKey) => key_refusal
		Err(Agent(_)) => key_refusal
		Ok(listed) =>
			match load_topics!(listed) {
				Ok(places) =>
					HttpAnswer.page(
						status,
						Browse.page({
							viewer: acting,
							places,
							problem,
						}),
					)
				Err(fault) => HttpAnswer.page(
					500,
					Page.notice({ title: "Failed", text: FileSystem.fault_words(fault) }),
				)
			}
	}

## Each listed place with its topics; unless the host's listing failed.
load_topics! : List(Browse.ListedPlace) => Try(
	List(Browse.PlaceWithTopics),
	[NotUtf8, PathRefused, Failed],
)
load_topics! = |listed| {
	var $places = []
	for { label, place } in listed {
		topics = FileSystem.list_place_topics!(place)?
		$places = $places.append({
			label,
			place,
			topics,
		})
	}
	Ok($places)
}

## The topic a form's `body` names; or why not, in words for its reader.
topic_from_form : List(U8) -> Try(Topic, [NotATopic(Str)])
topic_from_form = |body| {
	name = UrlEncodedForm.topic_name
	unchecked = UrlEncodedForm.field({ body, name }) ? |fault| NotATopic(UrlEncodedForm.fault_words({ fault, name }))
	unchecked.topic().map_err(|_| NotATopic(topic_rule_words))
}

topic_rule_words : Str
topic_rule_words =
	"A topic's name starts with a letter and holds letters, digits and hyphens, at most 60 of them."

## The 403 for a request with an API key.
key_refusal : Http.Response
key_refusal = HttpAnswer.page(
	403,
	Page.notice({ title: "Forbidden", text: "Browse is a human's, by their own session." }),
)

# ── tests
expect topic_from_form("topic=plans".to_utf8()).map_ok(Topic.to_str) == Ok("plans")
expect topic_from_form("x=1&topic=gopher-roc-2".to_utf8()).map_ok(Topic.to_str) == Ok("gopher-roc-2")
# A name at the longest a topic may be, and just past it.
expect topic_from_form("topic=${"a".repeat(60)}".to_utf8()).is_ok()
expect topic_from_form("topic=${"a".repeat(61)}".to_utf8()) == Err(NotATopic(topic_rule_words))
# Each name that is no topic, and each form that holds none.
expect
	[
		"topic=",
		"topic=2plans",
		"topic=two+words",
		"topic=plans_2",
		"topic=a%2Fb",
	].all(|body| topic_from_form(body.to_utf8()) == Err(NotATopic(topic_rule_words)))
expect topic_from_form("".to_utf8()) == Err(NotATopic("The form has no field `topic`."))
expect topic_from_form("topic=a&topic=b".to_utf8()) == Err(NotATopic("The form has the field `topic` more than once."))
expect topic_from_form("topic=%G0".to_utf8()) == Err(NotATopic("The form's `topic` holds a % that starts no two hex digits."))
expect topic_from_form("topic=%FF".to_utf8()) == Err(NotATopic("The form's `topic` is not UTF-8."))
expect key_refusal.status == 403
