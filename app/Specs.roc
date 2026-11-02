## **THE SPECS' ROOT**: every `*Spec.roc`, imported so one `roc test` runs
## them all (`roc test app/Specs.roc --main=app/main.roc`, which the gate
## runs beside `roc test app/main.roc`). A Spec left out of this list never
## runs, so the gate checks that every `app/*Spec.roc` is imported here.
import AdminSpec
import ChannelsSpec
import ConversationSpec
import DirectorySpec
import DmSpec
import PageSpec
import PlaceSpec
import SecureImageTagSpec
import TranscriptSpec
import UsersSpec

Specs :: [].{}
