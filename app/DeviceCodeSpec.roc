## These are the tests of `DeviceCode` and `DeviceCodeLimit`: how a code is
## drawn, typed and shown; a record's life, from its making to its one
## redemption, its expiry, its replacement or its cancelling; every refusal
## the same; and when the redeeming form locks. The host's HMAC and its
## constant-time compare are the end to end's (host/end_to_end.zig), so here
## a record's verdict is given.
import DeviceCode
import DeviceCodeLimit
import DeviceCodePage
import FirstStart
import GitHubSessionWord
import Seconds
import Session
import SignedIn
import Timestamp
import Users

DeviceCodeSpec :: [].{}

## The code `typed` spells, which a test knows is one.
code_of : Str -> DeviceCode.Code
code_of = |typed| DeviceCode.Code.from_typed(typed) ?? crash "DeviceCodeSpec: a code"

## Steve, the first start's founder, whose record a test redeems.
steve : Users.Human
steve = FirstStart.first_directory.chat_owner()

## A GitHub word, for material a test signs.
word : GitHubSessionWord
word = GitHubSessionWord.of_random_bytes(List.repeat(0xab, 32))

## When a test's record is made.
made_at : Timestamp
made_at = Timestamp.at_second(1_000_000)

## A test's record of a code whose HMAC is every byte `byte`, made at
## `made_at`.
record_of : U8 -> DeviceCode
record_of = |byte|
	DeviceCode.make({
		mac: List.repeat(byte, 32),
		material: List.repeat(9, 32),
		now: made_at,
	})

## The test's first record.
record : DeviceCode
record = record_of(7)

## The redemption at `second` of Steve's `held` record, the host's
## `verdict` on the typed code and its `material_verdict` on his material
## given.
redeemed_at : {
	held : DeviceCode,
	verdict : [DoesNotMatch, Matches],
	material_verdict : [DoesNotMatch, Matches],
	second : I64,
} -> Try(DeviceCode.Redemption, [NoMatch])
redeemed_at = |{ held, verdict, material_verdict, second }| {
	found = DeviceCode.matching_candidate([{ owner: steve, record: held, verdict }], Timestamp.at_second(second))?
	DeviceCode.redeem({ found, material_verdict, now: Timestamp.at_second(second) })
}

## The redemption at `second` of `held`, its code matched, Steve's material
## unchanged.
matched_at : DeviceCode, I64 -> Try(DeviceCode.Redemption, [NoMatch])
matched_at = |held, second|
	redeemed_at({
		held,
		verdict: Matches,
		material_verdict: Matches,
		second,
	})

## The redemption at `second` of `held`, its code not matched.
unmatched_at : DeviceCode, I64 -> Try(DeviceCode.Redemption, [NoMatch])
unmatched_at = |held, second|
	redeemed_at({
		held,
		verdict: DoesNotMatch,
		material_verdict: Matches,
		second,
	})

## The redemption at `second` of `held`, its code matched, Steve's material
## changed since it was made.
changed_at : DeviceCode, I64 -> Try(DeviceCode.Redemption, [NoMatch])
changed_at = |held, second|
	redeemed_at({
		held,
		verdict: Matches,
		material_verdict: DoesNotMatch,
		second,
	})

## Whether `held`, its code matched, is refused at `second`, with the one
## refusal.
is_refused : DeviceCode, I64 -> Bool
is_refused = |held, second| matched_at(held, second) == Err(NoMatch)

## The record a redemption at `second` leaves, which a test knows succeeds.
spent_at : I64 -> DeviceCode
spent_at = |second| {
	redemption = matched_at(record, second) ?? crash "DeviceCodeSpec: a live record redeems"
	redemption.spent_record()
}

## The code that `count` copies of `character` make, as typed.
repeated_code : U8, U64 -> Try(DeviceCode.Code, [NotACode])
repeated_code = |character, count|
	DeviceCode.Code.from_typed(Str.from_utf8_lossy(List.repeat(character, count)))

# The alphabet: the 10 digits.
expect DeviceCode.alphabet == "0123456789".to_utf8()
# A code from random bytes: each byte below 250 is a digit, its remainder by
# 10; bytes 250 and up are passed over. It is shown as two groups of four
# with a thin space between.
expect
	DeviceCode.Code.of_random_bytes([0, 1, 19, 250, 255, 249, 62, 9, 100, 37, 5])
		== Ok(code_of("01992907"))
		and code_of("01992907").display_text() == "0199\u(2009)2907"
expect {
	too_few = List.concat(List.repeat(250, 32), [1, 2, 3])
	DeviceCode.Code.of_random_bytes(too_few) == Err(TooFewUsableBytes)
}
# Every digit is drawn by exactly 25 of the 250 usable bytes.
expect {
	usable = List.from_iter(U8.to(0, 249))
	DeviceCode.alphabet.all(
		|character| {
			drawing = usable.keep_if(
				|byte| {
					drawn = DeviceCode.Code.of_random_bytes(List.repeat(byte, 8))
					drawn == repeated_code(character, 8)
				},
			)
			drawing.len() == 25
		},
	)
}
# Typed: the digits, with spaces, thin spaces and dashes left out, as it is
# shown, typed or pasted.
expect
	[
		"48210937",
		"4821 0937",
		"4821-0937",
		"4821\u(2009)0937",
		" 4821 0937 ",
		"48-21 09-37",
	].all(|typed| DeviceCode.Code.from_typed(typed) == Ok(code_of("48210937")))
# Not a code: too short or long, a letter (the old codes' alphabet above
# all, in either case), or anything else, refused cleanly as no code.
expect
	[
		"",
		"4821 093",
		"4821 09371",
		"4821 093O",
		"4821 093l",
		"ABCD-EFGH",
		"abcd-efgh",
		"4821_0937",
		"4821.0937",
		"4821\t0937",
		"٤٨٢١٠٩٣٧",
	].all(|typed| DeviceCode.Code.from_typed(typed) == Err(NotACode))
# The bytes the HMAC is over: kept apart from a session's.
expect code_of("4821 0937").bytes_to_sign() == "device-code\n48210937".to_utf8()
expect repeated_code('-', 8) == Err(NotACode)

# Expiry: a record lives five minutes from its making, and redeems from its
# first second to just before its last, and not after, nor before it was made.
expect DeviceCode.lifetime_seconds == Seconds.of(300)
expect record.expires() == Timestamp.at_second(1_000_300)
expect matched_at(record, 1_000_000).is_ok()
expect matched_at(record, 1_000_299).is_ok()
expect [1_000_300, 1_000_301, 2_000_000, 999_999].all(|second| is_refused(record, second))
# The redemption signs Steve in, and leaves his record spent at that second.
expect matched_at(record, 1_000_000).map_ok(|redemption| redemption.owner()) == Ok(steve)
expect
	DeviceCode.status(Record(spent_at(1_000_010)), made_at) == Used(Timestamp.at_second(1_000_010))
# Single use: the spent record redeems no more, at any second.
expect [1_000_000, 1_000_011, 1_000_299].all(|second| is_refused(spent_at(1_000_010), second))
# Replacement: a new code's record is the one held, so the old code's HMAC
# doesn't match it, and the old code is refused; the new one redeems.
expect unmatched_at(record_of(8), 1_000_001) == Err(NoMatch)
expect matched_at(record_of(8), 1_000_001).is_ok()
# Cancelled by signing out or a new password: refused, and a cancel leaves a
# spent or cancelled record as it was.
expect is_refused(record.cancel(), 1_000_001)
expect record.is_live() and !record.cancel().is_live() and !spent_at(1_000_010).is_live()
expect spent_at(1_000_010).cancel() == spent_at(1_000_010)
expect record.cancel().cancel() == record.cancel()
# The one refusal: no record matched, or none at all, is the same `NoMatch`
# as an expired, spent or cancelled one.
expect unmatched_at(record, 1_000_001) == Err(NoMatch)
expect DeviceCode.matching_candidate([], made_at) == Err(NoMatch)
# Only a record that may redeem now is a match: a spent, cancelled or
# expired record whose HMAC matches the typed code never hides a live one
# that matches too, and alone is no match.
expect {
	stale = [
		{ owner: steve, record: spent_at(1_000_010), verdict: Matches },
		{ owner: steve, record: record.cancel(), verdict: Matches },
	]
	live = { owner: steve, record: record_of(8), verdict: Matches }
	at = Timestamp.at_second(1_000_020)
	DeviceCode.matching_candidate(stale.append(live), at) == Ok(live)
		and DeviceCode.matching_candidate(stale, at) == Err(NoMatch)
		and DeviceCode.matching_candidate([live], Timestamp.at_second(1_000_300)) == Err(NoMatch)
}
expect record.is_redeemable_at(made_at) and !record.is_redeemable_at(Timestamp.at_second(1_000_300))
# A new code's HMAC that another human's record keeps, in any state, is
# held, so the code is drawn again; one no record keeps is not.
expect
	DeviceCode.is_mac_held(List.repeat(8, 32), [record, record_of(8).cancel()])
		and !DeviceCode.is_mac_held(List.repeat(9, 32), [record, record_of(8)])
		and !DeviceCode.is_mac_held(List.repeat(7, 32), [])
# A code made under other material, a password or a GitHub link since, or
# its files edited by hand: the same refusal, at any second of its life.
expect [1_000_000, 1_000_150, 1_000_299].all(|second| changed_at(record, second) == Err(NoMatch))
expect
	DeviceCode.material_bytes_to_sign(Session.Material.from_github_alone(word))
		== List.concat("device-code-material\n\n".to_utf8(), word.bytes())
# The page's word for each record.
expect DeviceCode.status(NoRecord, made_at) == NoCode
expect DeviceCode.status(Record(record), made_at) == Waiting(Timestamp.at_second(1_000_300))
expect DeviceCode.status(Record(record), Timestamp.at_second(1_000_300)) == Expired
expect DeviceCode.status(Record(record.cancel()), made_at) == Cancelled
# The file: each state written and read back; anything else is `Damaged`.
expect
	[record, record.cancel(), spent_at(1_000_010)].all(
		|held| DeviceCode.from_file(held.to_file()) == Ok(held),
	)
expect
	Str.from_utf8_lossy(spent_at(1_000_010).to_file())
		== "spent 1000000 1000300 ${"07".repeat(32)} ${"09".repeat(32)} 1000010\n"
expect
	[
		"",
		"live",
		"live 1000000 1000300",
		"live 1000000 1000300 ${"07".repeat(31)}",
		"live 1000000 1000300 ${"07".repeat(32)}",
		"live 1000000 1000300 ${"07".repeat(32)} ${"09".repeat(32)} 5",
		"spent 1000000 1000300 ${"07".repeat(32)} ${"09".repeat(32)}",
		"gone 1000000 1000300 ${"07".repeat(32)} ${"09".repeat(32)}",
		"live x 1000300 ${"07".repeat(32)} ${"09".repeat(32)}",
		"live 1000000 1000300 ${"07".repeat(32)} ${"09".repeat(31)}",
	].all(|text| DeviceCode.from_file(text.to_utf8()) == Err(Damaged))

# The limit: a client may fail 10 times in a window; the form locks for it
# at that count, and not one before. Everyone together may fail 50 times
# in a window, and the form then locks for everyone: 49 failures leave it
# open, the 50th locks it.
expect DeviceCodeLimit.client_most == 10 and DeviceCodeLimit.everyone_most == 50
expect {
	everyone = DeviceCodeLimit.tally_of({
		failures: { second: 49, status: Found },
		since: { second: 4_900, status: Found },
		now: Timestamp.at_second(5_000),
	})
	!DeviceCodeLimit.is_locked(everyone, DeviceCodeLimit.everyone_most)
		and DeviceCodeLimit.is_locked(
			DeviceCodeLimit.tally_after_failure(everyone),
			DeviceCodeLimit.everyone_most,
		)
}
expect {
	tally = DeviceCodeLimit.tally_of({
		failures: { second: 9, status: Found },
		since: { second: 4_900, status: Found },
		now: Timestamp.at_second(5_000),
	})
	after = DeviceCodeLimit.tally_after_failure(tally)
	!DeviceCodeLimit.is_locked(tally, DeviceCodeLimit.client_most)
		and DeviceCodeLimit.is_locked(after, DeviceCodeLimit.client_most)
		and after == { failures: 10, since: Timestamp.at_second(4_900) }
}
# The window: 15 minutes from its first failure, then a fresh tally; none
# kept is a fresh tally too.
expect {
	missing = { second: 0, status: Missing }
	failures = { second: 9, status: Found }
	since = { second: 1_000, status: Found }
	at = |second| Timestamp.at_second(second)
	fresh_at = |second| { failures: 0, since: at(second) }
	both_kept = { failures, since, now: at(1_100) }
	DeviceCodeLimit.tally_of({ failures, since, now: at(1_899) })
		== { failures: 9, since: at(1_000) }
		and DeviceCodeLimit.tally_of({ failures, since, now: at(1_900) }) == fresh_at(1_900)
		and DeviceCodeLimit.tally_of({ ..both_kept, failures: missing }) == fresh_at(1_100)
		and DeviceCodeLimit.tally_of({ ..both_kept, since: missing }) == fresh_at(1_100)
}
# A client's bucket: the first 12 bits of its prefix's HMAC, one of 4,096;
# `local` with none and `repeated` with two; each tally has keys of its own.
expect DeviceCodeLimit.clients_of(Forwarded([0xab, 0xcd, 0xef])) == Clients("abc")
expect DeviceCodeLimit.bucket_count == 16 * 16 * 16
expect DeviceCodeLimit.clients_of(NotForwarded) == Clients("local")
expect DeviceCodeLimit.clients_of(Repeated) == Clients("repeated")
expect DeviceCodeLimit.failures_key(Clients("ab")) == "device-code/failures/clients/ab".to_utf8()
expect DeviceCodeLimit.since_key(Everyone) == "device-code/since/everyone".to_utf8()
expect DeviceCodeLimit.failures_key(Everyone) != DeviceCodeLimit.since_key(Everyone)
# A client's prefix: an IPv4 address whole; an IPv6 address by its /64, so
# every address of one network, however it is spelt, is one client, and
# another /64 is another.
## The prefix of the `X-Forwarded-For` value `text`, as a test reads it.
prefix_of : Str -> Str
prefix_of = |text| Str.from_utf8_lossy(DeviceCodeLimit.client_prefix(text.to_utf8()))

expect prefix_of("203.0.113.7") == "203.0.113.7"
expect
	[
		"2001:db8:1:2::5",
		"2001:DB8:1:2:ffff::9",
		"2001:0db8:0001:0002:0:0:0:1",
		"2001:db8:1:2:a:b:c:d",
	].all(|text| prefix_of(text) == "v6 2001:0db8:0001:0002")
expect prefix_of("2001:db8:1:3::5") == "v6 2001:0db8:0001:0003"
expect prefix_of("::1") == "v6 0000:0000:0000:0000"
expect prefix_of("fe80::") == "v6 fe80:0000:0000:0000"
# Not an IPv6 address: kept whole, so it is still a client of its own; an
# IPv4 address written in IPv6 is whole too.
expect
	["1::2::3", "1:2:3:4:5:6:7:8:9", "12345::1", "1:2:3:4:5:6:7:8::", "g::1", "::ffff:1.2.3.4"].all(
		|text| prefix_of(text) == text,
	)
expect
	DeviceCodeLimit.prefix_bytes_to_sign("2001:db8:1:2::5".to_utf8())
		== "device-code-client\nv6 2001:0db8:0001:0002".to_utf8()

# The cookie that carries a code just made to the page, once: for this host
# alone, for the browser's session, sent to no script and on no other
# site's request; read back among other cookies, and nothing else is a code.
expect
	code_of("4821 0937").flash_cookie_text()
		== "__Host-device_code=48210937; Path=/; HttpOnly; Secure; SameSite=Strict"
expect
	DeviceCode.clear_flash_cookie_text
		== "__Host-device_code=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
expect
	DeviceCode.Code.from_cookie_header("theme=dark; __Host-device_code=48210937; x=y".to_utf8())
		== Ok(code_of("48210937"))
expect
	[
		"",
		"theme=dark",
		"__Host-device_code=",
		"__Host-device_code=4821O937",
		"__Host-device_code=ABCDEFGH",
		"__Host-device_code=48210937; __Host-device_code=48210937",
		"device_code=48210937",
	].all(|header| DeviceCode.Code.from_cookie_header(header.to_utf8()) == Err(NoCode))

# The page, a code just made: the code, its expiry as a time the script
# shows in the viewer's zone, the warning, the line that hears the stream,
# a button that cancels it, and the script; waiting, with no code shown:
# its expiry and the button; used or none: neither.
## The device code page for Steve showing `shown`, as a test reads it.
page_text : DeviceCodePage.Shown -> Str
page_text = |shown|
	Str.from_utf8_lossy(
		DeviceCodePage.page({
			viewer: SignedIn.dangerously_assume(steve.user()),
			shown,
			sign_ins: [],
			sign_in_url: "https://chat.example.com/login",
		}).to_utf8(),
	)

expect {
	text = page_text(Made({ code: code_of("48210937"), expires: Timestamp.at_second(1_000_300) }))
	[
		"<p class=\"sign-in-code\">4821\u(2009)0937</p>",
		"<time class=\"code-expiry\" datetime=\"1970-01-12T13:51:40Z\">1970-01-12T13:51:40Z</time>",
		"Type this only into your own device. Nobody will ever ask you for it.",
		"<p class=\"code-status\" data-stream=\"/devices/stream\">",
		"<form method=\"post\" action=\"/devices/cancel\"><button>Cancel this code</button></form>",
		"<script src=\"/chat/assets/devices.js\"></script>",
	].all(|part| text.contains(part))
}
expect {
	text = page_text(Status(Waiting(Timestamp.at_second(1_000_300))))
	!text.contains("sign-in-code")
		and text.contains("A code is waiting to be used, until <time class=\"code-expiry\"")
		and text.contains("action=\"/devices/cancel\"")
}
expect
	[
		Status(Used(made_at)),
		Status(NoCode),
		Status(Expired),
		Status(Cancelled),
	].all(
		|shown| !page_text(shown).contains("/devices/cancel") and !page_text(shown).contains("sign-in-code"),
	)
# The page is three numbered steps, in the order the human acts: open the
# sign-in page on the phone, its address copyable; make a code here; type
# it on the phone. What became of the last code is a quiet line below
# them, in plain words, never a raw time.
expect {
	text = page_text(Status(NoCode))
	text.contains(
		"<ol><li>On your phone, open this page:<p class=\"invite-code\">https://chat.example.com/login</p></li>\n<li>Make a code here:<form method=\"post\" action=\"/devices\"><button>Make a code</button></form>",
	)
		and text.contains("<li>On your phone, type the code under &quot;Have a code from your other device?&quot;. It works once, for 5 minutes.</li>\n</ol>")
}
expect {
	used = page_text(Status(Used(made_at)))
	!used.contains("signed a device in at")
		and !used.contains("1970-01-12T13:46:40Z")
		and page_text(Status(Expired)).contains("<p>Your last code expired unused.</p>")
}
# The page hears that its code was used, and when.
expect
	Str.from_utf8_lossy(DeviceCodePage.used_frame(made_at))
		== "event: device-used\ndata: 1970-01-12T13:46:40Z\n\n"
