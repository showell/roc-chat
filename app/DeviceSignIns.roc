## A human's last sign-ins by device code, newest first, at most
## `most_kept`, which the device code page lists. Each is when it was, and
## the device it was from, as coarse as a browser's family and an operating
## system's (`device_of_user_agent`): never the `User-Agent` itself, which
## no file holds and no page shows.
##
## `DeviceCodeFiles` keeps them in the human's folder, one line a sign-in:
## its second, its browser's word and its system's word.
import Timestamp

DeviceSignIns :: [].{

	## A browser's family.
	Browser : [Edge, Opera, Firefox, Chrome, Safari, OtherBrowser]

	## An operating system's family: `IPhone` for an iPhone's or an iPad's.
	System : [IPhone, Android, Chromebook, Windows, Mac, Linux, OtherSystem]

	## A device, as coarsely as its sign-in is told.
	Device : { browser : DeviceSignIns.Browser, system : DeviceSignIns.System }

	## A sign-in by a device code: when, and from what.
	SignIn : { at : Timestamp, device : DeviceSignIns.Device }

	## How many sign-ins are kept: ten.
	most_kept : U64
	most_kept = 10

	## The device a request's `User-Agent`, `header`, names: the first family
	## of each list whose mark the header holds, so Edge and Opera, which say
	## they are Chrome too, are named for themselves, and an iPad, which says
	## it is a Mac, is an iPhone's system; else the other of each.
	device_of_user_agent : List(U8) -> DeviceSignIns.Device
	device_of_user_agent = |header| {
		text = Str.from_utf8_lossy(header)
		browser =
			browser_marks.find_first(|(mark, _)| text.contains(mark))
				.map_ok(|(_, family)| family)
				?? OtherBrowser
		system =
			system_marks.find_first(|(mark, _)| text.contains(mark))
				.map_ok(|(_, family)| family)
				?? OtherSystem
		{ browser, system }
	}

	## `sign_ins` with `sign_in` first, and at most `most_kept` in all.
	with_sign_in : List(DeviceSignIns.SignIn), DeviceSignIns.SignIn -> List(DeviceSignIns.SignIn)
	with_sign_in = |sign_ins, sign_in|
		List.concat([sign_in], sign_ins).take_first(DeviceSignIns.most_kept)

	## A device as the page says it: `Safari on iOS`.
	device_words : DeviceSignIns.Device -> Str
	device_words = |{ browser, system }| "${browser_name(browser)} on ${system_name(system)}"

	## The sign-ins as their file keeps them, a line each.
	sign_ins_to_file : List(DeviceSignIns.SignIn) -> List(U8)
	sign_ins_to_file = |sign_ins|
		sign_ins
			.map(
				|
					{ at, device },
				| "${at.to_str()} ${browser_word(device.browser)} ${system_word(device.system)}\n",
			)
			.join_map(Str.to_utf8)

	## The sign-ins a file's `bytes` hold, as `sign_ins_to_file` writes them; unless
	## a line is anything else (`Damaged`).
	sign_ins_from_file : List(U8) -> Try(List(DeviceSignIns.SignIn), [Damaged])
	sign_ins_from_file = |bytes|
		bytes.split_on('\n').drop_if(List.is_empty).map_try(sign_in_from_line)
}

## The marks of each browser's family, in the order they are looked for.
browser_marks : List((Str, DeviceSignIns.Browser))
browser_marks = [
	("Edg/", Edge),
	("OPR/", Opera),
	("Firefox/", Firefox),
	("FxiOS/", Firefox),
	("CriOS/", Chrome),
	("Chrome/", Chrome),
	("Safari/", Safari),
]

## The marks of each system's family, in the order they are looked for.
system_marks : List((Str, DeviceSignIns.System))
system_marks = [
	("iPhone", IPhone),
	("iPad", IPhone),
	("Android", Android),
	("CrOS", Chromebook),
	("Windows", Windows),
	("Macintosh", Mac),
	("Linux", Linux),
]

browser_name : DeviceSignIns.Browser -> Str
browser_name = |browser|
	match browser {
		Edge => "Edge"
		Opera => "Opera"
		Firefox => "Firefox"
		Chrome => "Chrome"
		Safari => "Safari"
		OtherBrowser => "a browser"
	}

system_name : DeviceSignIns.System -> Str
system_name = |system|
	match system {
		IPhone => "iOS"
		Android => "Android"
		Chromebook => "ChromeOS"
		Windows => "Windows"
		Mac => "macOS"
		Linux => "Linux"
		OtherSystem => "another system"
	}

## Each browser's family and its word in the file.
browser_words : List((DeviceSignIns.Browser, Str))
browser_words = [
	(Edge, "edge"),
	(Opera, "opera"),
	(Firefox, "firefox"),
	(Chrome, "chrome"),
	(Safari, "safari"),
	(OtherBrowser, "other"),
]

## Each system's family and its word in the file.
system_words : List((DeviceSignIns.System, Str))
system_words = [
	(IPhone, "ios"),
	(Android, "android"),
	(Chromebook, "chromeos"),
	(Windows, "windows"),
	(Mac, "macos"),
	(Linux, "linux"),
	(OtherSystem, "other"),
]

browser_word : DeviceSignIns.Browser -> Str
browser_word = |browser|
	match browser_words.find_first(|(family, _)| family == browser) {
		Ok((_, word)) => word
		Err(NotFound) => crash "DeviceSignIns.browser_word: every family has a word"
	}

system_word : DeviceSignIns.System -> Str
system_word = |system|
	match system_words.find_first(|(family, _)| family == system) {
		Ok((_, word)) => word
		Err(NotFound) => crash "DeviceSignIns.system_word: every family has a word"
	}

## The sign-in a file's `line` holds; unless it is anything else.
sign_in_from_line : List(U8) -> Try(DeviceSignIns.SignIn, [Damaged])
sign_in_from_line = |line|
	match line.split_on(' ') {
		[at_word, browser_text, system_text] => {
			at = Timestamp.from_file(at_word) ? |_| Damaged
			browser = word_family(browser_words, browser_text)?
			system = word_family(system_words, system_text)?
			Ok({ at, device: { browser, system } })
		}
		_ => Err(Damaged)
	}

## The family among `words` whose word is `text`; else `Damaged`.
word_family : List((family, Str)), List(U8) -> Try(family, [Damaged])
word_family = |words, text|
	words.find_first(|(_, word)| word.to_utf8() == text)
		.map_ok(|(family, _)| family)
		.map_err(|NotFound| Damaged)
