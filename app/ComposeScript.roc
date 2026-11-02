## **THE CONVERSATION PAGE'S ONE SCRIPT**: app/compose.js, imported whole
## at compile time, so the file is its bytes' one home and the server
## answers them fixed, from the app. Its URL path's one home is here too:
## `Route` answers it, and `Page` names it in the page's `<script src>`,
## which the page's policy (`script-src 'self'`) lets run.
import "compose.js" as source : Str

ComposeScript :: [].{

	## **WHERE THE SCRIPT IS SERVED**: a path on this site.
	url_path : Str
	url_path = "/chat/assets/compose.js"

	## **THE SCRIPT'S BYTES**, as app/compose.js holds them.
	bytes : List(U8)
	bytes = source.to_utf8()
}

# ── tests
# The file, whole: its headline first, its last statement closing it.
expect source.starts_with("// THE CONVERSATION PAGE'S SCRIPT: ")
expect source.ends_with("\n})();\n")
expect ComposeScript.bytes == source.to_utf8()
