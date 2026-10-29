## THE CHAT'S PLATFORM: the Roc chat answers every request roc-chat's host
## (host/) hands it. The app provides `handle!`, called as
## `roc_chat_handle`; its effects are hosted functions (Host.roc), prefixed
## `roc_chat_`.
platform ""
	requires {
		handle! : Chat.Request => Chat.Answer
	}
	exposes [Chat, Host, Sse]
	packages {}
	provides { "roc_chat_handle": handle_for_host! }
	hosted {
		"roc_chat_publish": Host.publish!,
		"roc_chat_read_body": Host.read_body!,
		"roc_chat_read_header": Host.read_header!,
		"roc_chat_serve_script": Host.serve_script!,
		"roc_chat_stub_append": Host.stub_append!,
		"roc_chat_stub_read": Host.stub_read!,
	}
	targets: {
		x64musl: {
			inputs: [app],
			output: Archive,
		},
	}

import Chat
import Host
import Sse

handle_for_host! : Chat.Request => Chat.Answer
handle_for_host! = |request| handle!(request)
