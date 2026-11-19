## This module builds the form that starts a topic in a place, which Browse
## and a conversation's sidebar (`Sidebar`) both end a place's topics with.
## It posts the field `UrlEncodedForm.topic_name` to the place's own path,
## which `BrowseRoute.start_topic!` answers. A place with no topics yet
## suggests its first, `general`.
import ConversationKey
import Escape
import Html
import PageKit
import Place
import Topic
import TrustedHtml
import UrlEncodedForm

TopicForm :: [].{

	## The form that starts a topic in `place`, whose topics are `topics`.
	form : { place : Place, topics : List(Topic) } -> TrustedHtml
	form = |{ place, topics }| {
		filled =
			if topics.is_empty() {
				[TokenValue(PageKit.token(first_topic.to_str()))]
			} else {
				[]
			}
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
							filled,
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
	}
}

## The topic a place's form suggests until it has one.
first_topic : Topic
first_topic = Topic.from_str("general") ?? crash "TopicForm.first_topic: general is a topic"
