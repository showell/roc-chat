## This app is the root of the specs. It imports every `*Spec.roc`, so one
## `roc test app/Specs.roc` runs them all, and the gate runs it beside
## `roc test app/main.roc`. A Spec left out of this list never runs, so the
## gate checks that every `app/*Spec.roc` is imported here.
##
## It is an app, on the test-only platform/specs.roc, so that shale's typed
## lints can read the specs: Roc's checker reads an app, and a type module
## only through one.
app [main] {
	md: "../../roc-markdown/package/main.roc",
	pf: platform "../platform/specs.roc",
}

import AdminSpec
import AgentKeySpec
import AgentsSpec
import ChannelsSpec
import ConversationKeySpec
import ConversationSpec
import DirectorySpec
import DmSpec
import PageSpec
import PlaceSpec
import RouteSpec
import SecureImageTagSpec
import StoredDirectorySpec
import TranscriptSpec
import UsersSpec

## Nothing: `roc test` runs the specs, and no host runs this app.
main : Str
main = ""
