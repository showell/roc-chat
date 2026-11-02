## **THE SPECS' ROOT**: every `*Spec.roc`, imported so one `roc test` runs
## them all (`roc test app/Specs.roc --main=app/main.roc`, which the gate
## runs beside `roc test app/main.roc`). A Spec left out of this list never
## runs, and the gate's floor then fails.
import ConversationSpec
import PageSpec
import TranscriptSpec

Specs :: [].{}
