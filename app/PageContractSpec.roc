## These are the tests of `PageContract`'s `data-` attributes, each its one
## spelling (its classes' are PageSpec's). Which script reads which name is
## tested in `PageContract` itself, beside the helpers that look.
import Html
import PageContract

PageContractSpec :: [].{}

## The token `text` spells, which a test's always is.
token : Str -> Html.Token
token = |text| Html.Token.from_str(text) ?? crash "PageContractSpec.token: \"${text}\" is a token"

# Every `data-` attribute, each its one spelling, a path or a token.
expect {
	path = Html.SitePath.from_str("/chat/dm/1_1/plans") ?? crash "PageContract's tests: a site path"
	[
		(Stream(path), "<p data-stream=\"/chat/dm/1_1/plans\"></p>"),
		(After(token("6")), "<p data-after=\"6\"></p>"),
		(Viewer(token("1")), "<p data-viewer=\"1\"></p>"),
		(Author(token("3")), "<p data-author=\"3\"></p>"),
		(Send(path), "<p data-send=\"/chat/dm/1_1/plans\"></p>"),
		(Upload(path), "<p data-upload=\"/chat/dm/1_1/plans\"></p>"),
		(ImageByteLimit(token("10485760")), "<p data-image-byte-limit=\"10485760\"></p>"),
		(Section(path), "<p data-section=\"/chat/dm/1_1/plans\"></p>"),
		(React(path), "<p data-react=\"/chat/dm/1_1/plans\"></p>"),
		(Raw(path), "<p data-raw=\"/chat/dm/1_1/plans\"></p>"),
		(Download(path), "<p data-download=\"/chat/dm/1_1/plans\"></p>"),
		(Reactors(token("1-3")), "<p data-reactors=\"1-3\"></p>"),
		(Person(token("2")), "<p data-person=\"2\"></p>"),
		(Presence(Online), "<p data-presence=\"online\"></p>"),
		(Presence(Offline), "<p data-presence=\"offline\"></p>"),
		(Opening(AlwaysOpen), "<p data-opening=\"always\"></p>"),
		(Opening(Collapsed), "<p data-opening=\"collapsed\"></p>"),
		(Group(Channels), "<p data-group=\"channels\"></p>"),
		(Group(Dms), "<p data-group=\"dms\"></p>"),
		(Joined(token("1763600000")), "<p data-joined=\"1763600000\"></p>"),
		(Kind(Human), "<p data-kind=\"human\"></p>"),
		(Kind(Agent), "<p data-kind=\"agent\"></p>"),
	].all(
		|(chosen, expected)|
			PageContract.empty_paragraph([PageContract.data_attribute(chosen)])
				== expected.to_utf8(),
	)
}
