## **SECURE IMAGE TAGS' TESTS, THROUGH THE RENDERER**: every image a
## message's markdown can hold, by every kind of source, comes out as the
## frozen rendering that is no image, since no conversation has an upload
## yet (`SecureImageTag`).
import Markdown

SecureImageTagSpec :: [].{}

## `markdown` rendered, as a test reads it.
shown : Str -> Str
shown = |markdown| Str.from_utf8(Markdown.render(markdown).to_utf8()) ?? crash "SecureImageTagSpec: a render is UTF-8"

# `![alt](src)`: a relative, an absolute, another origin's, a `data:` and
# a `javascript:` source. Each is a plain link, or text, never an image.
expect shown("![x](a.png)") == "<p><a href=\"a.png\">x</a></p>\n"
expect shown("![x](/user_uploads/a.png)") == "<p><a href=\"/user_uploads/a.png\">x</a></p>\n"
expect shown("![x](https://evil.example/a.png)") == "<p><a href=\"https://evil.example/a.png\" target=\"_blank\" rel=\"noopener\">x</a></p>\n"
expect shown("![x](data:image/png;base64,AAAA)") == "<p><a href=\"data:image/png;base64,AAAA\">x</a></p>\n"
expect shown("![x](javascript:alert(1))") == "<p>![x](javascript:alert(1))</p>\n"
# An `<img>` tag, the same four sources: each is text, escaped.
expect shown("<img src=\"a.png\">") == "&lt;img src=&quot;a.png&quot;&gt;"
expect shown("<img src=\"/user_uploads/a.png\">") == "&lt;img src=&quot;/user_uploads/a.png&quot;&gt;"
expect shown("<img src=\"data:image/png;base64,AAAA\">") == "&lt;img src=&quot;data:image/png;base64,AAAA&quot;&gt;"
expect shown("<img src=\"javascript:alert(1)\">") == "&lt;img src=&quot;javascript:alert(1)&quot;&gt;"
