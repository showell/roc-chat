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
		"roc_chat_append": Host.append!,
		"roc_chat_hash": Host.hash!,
		"roc_chat_list": Host.list!,
		"roc_chat_publish": Host.publish!,
		"roc_chat_random_bytes": Host.random_bytes!,
		"roc_chat_read": Host.read!,
		"roc_chat_read_at": Host.read_at!,
		"roc_chat_read_body": Host.read_body!,
		"roc_chat_read_config": Host.read_config!,
		"roc_chat_read_header": Host.read_header!,
		"roc_chat_read_query": Host.read_query!,
		"roc_chat_read_stat": Host.read_stat!,
		"roc_chat_read_time": Host.read_time!,
		"roc_chat_remove": Host.remove!,
		"roc_chat_serve_script": Host.serve_script!,
		"roc_chat_sign": Host.sign!,
		"roc_chat_verify": Host.verify!,
		"roc_chat_write": Host.write!,
		"roc_chat_write_cache": Host.write_cache!,
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
