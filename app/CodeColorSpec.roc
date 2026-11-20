## Tests of a message's code blocks, through `Markdown`: a block in Roc,
## JavaScript, Shale or Zig comes out colored by roc-syntax-color, inside
## roc-markdown's own frame, every byte of it escaped once; a block in any
## other language, or none, is roc-markdown's plain escape; a quote-reply is
## never colored. The spans' classes are `PageContract.SyntaxClass`'s.
import ConversationKey
import Directory
import Markdown
import Name
import PageContract
import Topic
import UserId
import UserPair

CodeColorSpec :: [].{}

## `plans` in Steve's own DM.
plans : ConversationKey
plans = {
	directory = Directory.with_founder(Name.from_str("Steve") ?? crash "CodeColorSpec: a name")
	place = directory.place(
		Dm(UserPair.of({ one: UserId.chat_owner, other: UserId.chat_owner })),
	) ?? crash "CodeColorSpec: Steve's own DM"
	ConversationKey.of({ place, topic: Topic.from_str("plans") ?? crash "CodeColorSpec: a topic" })
}

## `markdown` rendered as a message of `plans`, as a test reads it.
message_html : Str -> Str
message_html = |markdown| Str.from_utf8(
	Markdown.message_html(markdown, plans).to_utf8(),
) ?? crash "CodeColorSpec: a render is UTF-8"

## The HTML with every span roc-syntax-color writes taken out: what is left
## is roc-markdown's frame and the block's text, escaped.
without_spans : Str -> Str
without_spans = |html| {
	closed = Str.join_with(html.split_on("</span>"), "")
	pieces = closed.split_on("<span class=\"")
	after_opening = |piece| piece.split_first("\">").map_ok(|parts| parts.after) ?? crash "CodeColorSpec: an opened span has its `\">`"
	Str.join_with(List.concat(pieces.take_first(1), pieces.drop_first(1).map(after_opening)), "")
}

## The classes of the spans in `html`, each as often as it opens one.
span_classes : Str -> List(Str)
span_classes = |html|
	html.split_on("<span class=\"").drop_first(1).map(
		|piece| piece.split_first("\"").map_ok(|parts| parts.before) ?? crash "CodeColorSpec: a class is quoted",
	)

# A Roc block: its keyword, number, string and comment each in its span,
# inside roc-markdown's `<pre><code class="language-roc">`.
expect
	message_html("```roc\nx = if y then 1 else \"a\" # note\n```")
		== "<pre><code class=\"language-roc\"><span class=\"syn-name\">x</span> = <span class=\"syn-keyword\">if</span> y then <span class=\"syn-number\">1</span> <span class=\"syn-keyword\">else</span> <span class=\"syn-string\">&quot;a&quot;</span> <span class=\"syn-comment\"># note</span>\n</code></pre>\n"
# A `<` and an `&` inside the code, in a string, a comment and the plain
# text between, are escaped exactly once: taking the spans out leaves
# roc-markdown's plain rendering of the same block, and no `<` but a tag's.
expect {
	code = "a = \"<b> & c\" # x < y && z\nb = a < 1 & 2\n"
	colored = message_html("```roc\n${code}```")
	plain = message_html("```text\n${code}```")
	without_spans(colored) == Str.join_with(plain.split_on("language-text"), "language-roc")
		and colored.contains("<span class=\"syn-string\">&quot;&lt;b&gt; &amp; c&quot;</span>")
		and colored.contains("<span class=\"syn-comment\"># x &lt; y &amp;&amp; z</span>")
		and !colored.contains("&amp;lt;")
		and !colored.contains("&amp;amp;")
}
# JavaScript, Shale and Zig are colored too, each by its own lexer.
expect message_html("```js\nconst a = 1;\n```").contains("<span class=\"syn-keyword\">const</span>")
expect message_html("```shale\nlocal a = 1\n```").contains("<span class=\"syn-keyword\">local</span>")
expect message_html("```zig\nconst a = 1;\n```").contains("<span class=\"syn-keyword\">const</span>")
# A language roc-syntax-color doesn't read, and a block with none, are
# roc-markdown's escape, with no span.
expect
	message_html("```python\nif a < b & c: pass\n```")
		== "<pre><code class=\"language-python\">if a &lt; b &amp; c: pass\n</code></pre>\n"
expect message_html("```\nif a < b\n```") == "<pre><code>if a &lt; b\n</code></pre>\n"
expect message_html("```Roc\nif a\n```") == "<pre><code class=\"language-Roc\">if a\n</code></pre>\n"
# A block as long as a message can hold is still colored: the chat sets
# no size of its own.
expect {
	long = "#${"a".repeat(60 * 1024)}"
	message_html("```roc\n${long}\n```") == "<pre><code class=\"language-roc\"><span class=\"syn-comment\">${long}</span>\n</code></pre>\n"
}
# A quote-reply is never colored, whatever it quotes.
expect message_html("```quote\nif a < b\n```") == "<pre class=\"chat-quote\">if a &lt; b\n</pre>\n"
# Every class a colored block's spans name is one `PageContract` names, and
# a block of every kind names each of them.
expect {
	names = PageContract.syntax_classes.map(PageContract.syntax_class_name)
	found = span_classes(message_html("```roc\n# c\nmain : Str -> U64\nmain = |s| if s == \"a\" 1 else 2\n```"))
	found.all(|class| names.contains(class))
		and names.all(|class| found.contains(class))
}
