## This module builds the form that starts a topic in a place, which Browse
## and a conversation's sidebar (`Sidebar`) both end a place's topics with.
## It posts the field `UrlEncodedForm.topic_name` to the place's own path,
## which `BrowseRoute.start_topic!` answers. A place with no topics yet
## suggests its first, `general`. A refused post draws the place's form
## again, holding what was typed, with the problem beside it.
import ConversationKey
import Escape
import Html
import PageKit
import Place
import Topic
import TrustedHtml
import UnvalidatedString
import UrlEncodedForm

TopicForm :: [].{

	## The form that starts a topic in `place`, whose topics are `topics`.
	form : { place : Place, topics : List(Topic) } -> TrustedHtml
	form = |{ place, topics }|
		if topics.is_empty() {
			form_holding(place, [TokenValue(PageKit.token(first_topic.to_str()))])
		} else {
			form_holding(place, [])
		}

	## The form of `place` after a post of `typed` was refused for `problem`:
	## the field holds what was typed, when a name or a token spells it
	## (a value is never free text, `Html`), and the problem is said under it.
	refused_form : {
		place : Place,
		typed : [Typed(UnvalidatedString), NothingTyped],
		problem : Str,
	} -> TrustedHtml
	refused_form = |{ place, typed, problem }| {
		value =
			match typed {
				Typed(text) =>
					match (text.name(), text.html_token()) {
						(Ok(name), _) => [NameValue(name)]
						(_, Ok(token)) => [TokenValue(token)]
						_ => []
					}
				NothingTyped => []
			}
		TrustedHtml.join([form_holding(place, value), PageKit.problem(problem)])
	}
}

## The form of `place`, its field holding `value_attributes`.
form_holding : Place, List(Html.Attribute) -> TrustedHtml
form_holding = |place, value_attributes|
	TrustedHtml.join([
		Html.element({
			name: Form,
			attributes: [
				MethodPost,
				Action(PageKit.site_path(ConversationKey.place_url_path(place))),
			],
			inner: TrustedHtml.join([
				PageKit.labelled_input({
					label: "New topic",
					attributes: List.concat(
						[
							InputType(Text),
							FieldName(PageKit.token(UrlEncodedForm.topic_name)),
							Required,
						],
						value_attributes,
					),
				}),
				Html.element({
					name: Button,
					attributes: [],
					inner: Escape.text("Add topic"),
				}),
			]),
		}),
		PageKit.newline,
	])

## The topic a place's form suggests until it has one.
first_topic : Topic
first_topic = Topic.from_str("general") ?? crash "TopicForm.first_topic: general is a topic"
