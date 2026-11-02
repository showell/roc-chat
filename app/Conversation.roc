## **A CONVERSATION**: a topic and its messages, in id order. It stands
## alone: no channel, no DM, no reader. Given its transcript, it renders as
## one page of HTML, each message's markdown by roc-markdown; the page
## carries structure and class names, and only enough style to read.
import md.Md
import Message
import Transcript

Conversation :: {
	topic : Str,
	messages : List(Message),
}.{

	## The conversation a transcript holds, its topic named by its file.
	read : Str, Str -> Try(Conversation, [Malformed(Str)])
	read = |
		topic,
		transcript,
	| Transcript.read(topic, transcript).map_ok(|messages| Conversation.({ topic, messages }))

	## Its topic's name.
	topic : Conversation -> Str
	topic = |Conversation.(c)| c.topic

	## Its messages, oldest first.
	messages : Conversation -> List(Message)
	messages = |Conversation.(c)| c.messages

	## **THE PAGE**: the topic, then each message under its author and time,
	## with its reference (`MSG_<topic>_<n>`) as a link to itself.
	html : Conversation -> Str
	html = |Conversation.(c)|
		Str.join_with(
			[
				"<!doctype html>\n<meta charset=utf-8>\n<title>${escape(c.topic)}</title>\n",
				style,
				"<h1>${escape(c.topic)}</h1>\n",
				if (c.messages.is_empty()) "<p class=empty>No messages yet.</p>\n" else Str.join_with(
					c.messages.map(|m| message_html(c.topic, m)),
					"",
				),
			],
			"",
		)
}

## One message: its header, then its markdown rendered.
message_html : Str, Message -> Str
message_html = |topic, m| {
	n = m.id().to_str()
	body = Str.from_utf8(
		Md.render(
			m.markdown().to_utf8(),
			{ uploads: |_| Bool.False },
		),
	) ?? crash "Conversation: roc-markdown renders UTF-8"
	"<article class=message id=msg-${n}><header><span class=author>${escape(m.author())}</span> <time datetime=\"${escape(m.at())}\">${escape(m.at())}</time> <a class=ref href=\"#msg-${n}\">MSG_${escape(topic)}_${n}</a></header>\n<div class=body>${body}</div></article>\n"
}

## Text made safe inside HTML, as text or in a quoted attribute.
escape : Str -> Str
escape = |text| {
	bytes = text.to_utf8().fold(
		[],
		|out, b|
			match b {
				'<' => out.concat("&lt;".to_utf8())
				'>' => out.concat("&gt;".to_utf8())
				'&' => out.concat("&amp;".to_utf8())
				'"' => out.concat("&quot;".to_utf8())
				_ => out.append(b)
			},
	)
	Str.from_utf8(bytes) ?? crash "Conversation.escape: escaping keeps UTF-8 whole"
}

style : Str
style = "<style>body{font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}.message{border-top:1px solid #ccc;padding:.5rem 0}.author{font-weight:600}time,.ref{color:#777;font-size:.85em}.ref{float:right}</style>\n"

# ── tests
said : {
	id : Message.Id,
	author : Str,
	markdown : Str,
} -> Message
said = |
	{
		id,
		author,
		markdown,
	},
|
	match Message.new({
		id,
		author,
		at: "2026-11-02T19:11:32Z",
		markdown,
	}) {
		Ok(m) => m
		Err(_) => crash "said: a test's message has an author"
	}

expect escape("<b>\"Tom & Jerry\"</b>") == "&lt;b&gt;&quot;Tom &amp; Jerry&quot;&lt;/b&gt;"
expect escape("café 🎉") == "café 🎉"
expect message_html(
	"plans",
	said({
		id: Message.Id.first,
		author: "Steve",
		markdown: "**hi**",
	}),
) == "<article class=message id=msg-1><header><span class=author>Steve</span> <time datetime=\"2026-11-02T19:11:32Z\">2026-11-02T19:11:32Z</time> <a class=ref href=\"#msg-1\">MSG_plans_1</a></header>\n<div class=body><p><strong>hi</strong></p>\n</div></article>\n"
expect Conversation.read(
	"plans",
	Transcript.write(
		"plans",
		[
			said({
				id: Message.Id.first,
				author: "<Eve>",
				markdown: "x",
			}),
		],
	),
).map_ok(|c| c.html().contains("&lt;Eve&gt;")) == Ok(Bool.True)
expect Conversation.read("plans", "").map_ok(Conversation.topic).is_err()
