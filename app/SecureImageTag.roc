## **SECURE IMAGE TAGS: WHICH IMAGES A MESSAGE MAY SHOW**, the one home of
## that rule. A message's markdown may hold an image (`![alt](src)` or an
## `<img>`, and a `<video>` too, which roc-markdown rules the same way);
## `Markdown.render` hands roc-markdown `is_conversation_upload`, for the
## message's own conversation, as its uploads rule, and roc-markdown shows
## as media only a source that passes it, after judging the source safe as
## a same-origin URL itself. A source that fails is left as text: an image
## becomes a plain link.
##
## **THE RULE** (`docs/design.md`, "Images"): an uploaded image belongs to
## one conversation, and exactly that conversation's readers can see it.
## So a message may show an image only from its own conversation's
## uploads: a source that is exactly the URL path `ConversationKey` gives
## one of the conversation's uploaded images, its page's path, `/uploads/`
## and a name of an uploaded image's shape (`UploadedImage.from_name`).
## Every other source is refused, another conversation's uploads among
## them.
##
## What the renderer's output becomes on a page is vouched for at
## `TrustedHtml`'s one door; see its header for the others. Text from
## outside comes in only through `UnvalidatedString`, who is acting is
## `SignedIn`, and which origins may ask is `RequestOrigin`.
import ConversationKey
import UploadedImage

SecureImageTag :: [].{

	## Whether `source` is one of the uploaded images of the conversation
	## `key`, by its URL path exactly.
	is_conversation_upload : ConversationKey, List(U8) -> Bool
	is_conversation_upload = |key, source|
		match source.split_last('/') {
			Ok({ before: _, after: name }) =>
				match Str.from_utf8(name) {
					Ok(text) =>
						match UploadedImage.from_name(text) {
							Ok(image) => key.uploaded_image_url_path(image).to_utf8() == source
							Err(NotAnUploadName) => Bool.False
						}
					Err(_) => Bool.False
				}
			Err(NotFound) => Bool.False
		}
}
