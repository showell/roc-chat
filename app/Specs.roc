## **THE SPECS' ROOT**: every `*Spec.roc`, imported so one `roc test` runs
## them all (`roc test app/Specs.roc`, which the gate runs beside `roc test
## app/main.roc`). A Spec left out of this list never runs, so the gate
## checks that every `app/*Spec.roc` is imported here.
##
## An app, on the test-only platform/specs.roc, so that shale's typed lints
## can read the specs: Roc's checker reads an app, and a type module only
## through one.
app [main] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/specs.roc",
}

import AdminSpec
import ChannelsSpec
import ConversationKeySpec
import ConversationSpec
import DirectorySpec
import DmSpec
import PageSpec
import PlaceSpec
import SecureImageTagSpec
import TranscriptSpec
import UsersSpec

## Nothing: `roc test` runs the specs, and no host runs this app.
main : Str
main = ""
