## **A CONVERSATION**: a topic and its messages, in id order. It stands
## alone: no channel, no DM, no reader. Given its transcript, it renders as
## one page of HTML, each message's markdown by roc-markdown; the page
## carries structure and class names, and only enough style to read.
import md.Md
import Html
import Message
import Sample
import Topic
import Transcript

Conversation :: {
	topic : Topic,
	messages : List(Message),
}.{

	## The conversation a transcript holds, its topic named by its file.
	read : Topic, Str -> Try(Conversation, [Malformed(Str)])
	read = |
		topic,
		transcript,
	| Transcript.read(topic, transcript).map_ok(|messages| Conversation.({ topic, messages }))

	## Its topic.
	topic : Conversation -> Topic
	topic = |Conversation.(c)| c.topic

	## Its messages, oldest first.
	messages : Conversation -> List(Message)
	messages = |Conversation.(c)| c.messages

	is_eq : _

	## **THE PAGE**: the topic, then each message under its author and time,
	## with its reference (`MSG_<topic>_<n>`) as a link to itself.
	html : Conversation -> Html
	html = |Conversation.(c)|
		Html.page({
			title: c.topic.to_str(),
			body: Html.join([
				Html.element({
					name: "h1",
					attrs: [],
					inner: Html.text(c.topic.to_str()),
				}),
				Html.markup("\n"),
				if (c.messages.is_empty())
					Html.join([
						Html.element({
							name: "p",
							attrs: [Attr("class", "empty")],
							inner: Html.text("No messages yet."),
						}),
						Html.markup("\n"),
					])
				else
					Html.join(c.messages.map(|m| message_html(c.topic, m))),
			]),
		})
}

## One message: its header, then its markdown rendered.
message_html : Topic, Message -> Html
message_html = |topic, m| {
	n = m.id().to_str()
	time = m.time().to_str()
	rendered = Md.render(m.markdown().to_utf8(), { uploads: |_| Bool.False })
	body = Str.from_utf8(rendered) ?? crash "Conversation: roc-markdown renders UTF-8"
	header = Html.join([
		Html.element({
			name: "span",
			attrs: [Attr("class", "author")],
			inner: Html.text(m.author().to_str()),
		}),
		Html.markup(" "),
		Html.element({
			name: "time",
			attrs: [Attr("datetime", time)],
			inner: Html.text(time),
		}),
		Html.markup(" "),
		Html.element({
			name: "a",
			attrs: [Attr("class", "ref"), Attr("href", "#msg-${n}")],
			inner: Html.text("MSG_${topic.to_str()}_${n}"),
		}),
	])
	article = Html.element({
		name: "article",
		attrs: [Attr("class", "message"), Attr("id", "msg-${n}")],
		inner: Html.join([
			Html.element({
				name: "header",
				attrs: [],
				inner: header,
			}),
			Html.markup("\n"),
			Html.element({
				name: "div",
				attrs: [Attr("class", "body")],
				inner: Html.rendered(body),
			}),
		]),
	})
	Html.join([article, Html.markup("\n")])
}

# ── tests
expect
	message_html(
		Sample.plans,
		Sample.said({
			id: Sample.first,
			author: "Steve",
			markdown: "**hi**",
		}),
	).to_str()
		== "<article class=\"message\" id=\"msg-1\"><header><span class=\"author\">Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=\"ref\" href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=\"body\"><p><strong>hi</strong></p>\n</div></article>\n"
# A name holding markup is text on the page.
expect
	Conversation.read(
		Sample.plans,
		Transcript.write(
			Sample.plans,
			[
				Sample.said({
					id: Sample.first,
					author: "<Eve>",
					markdown: "x",
				}),
			],
		),
	)
		.map_ok(|c| c.html().to_str().contains("<span class=\"author\">&lt;Eve&gt;</span>"))
		== Ok(Bool.True)
# No messages: the page says so, and only then.
expect
	Conversation.read(Sample.plans, "").map_ok(|c| c.html().to_str())
		== Ok(
			Html.page({
				title: "plans",
				body: Html.markup("<h1>plans</h1>\n<p class=\"empty\">No messages yet.</p>\n"),
			}).to_str(),
		)
expect Conversation.read(
	Sample.plans,
	Transcript.write(Sample.plans, Sample.two),
).map_ok(|c| c.html().to_str().contains("No messages yet.")) == Ok(Bool.False)
expect Conversation.read(
	Sample.plans,
	Transcript.write(Sample.plans, Sample.two),
).map_ok(|c| c.messages()) == Ok(Sample.two)
expect Conversation.read(
	Sample.plans,
	"\n",
).map_ok(Conversation.topic) == Err(Malformed("a transcript starts with the separator and ends with an empty line"))
