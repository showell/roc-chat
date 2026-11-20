## This module decides when the form that redeems a device code
## (`DeviceCode`) is locked for a client, so a code can't be guessed. Every
## failed redemption is counted twice, for its client and for everyone
## together, in a window of `window_seconds` that starts at the first
## failure; a client with `client_most` failures in its window finds the
## form locked until that window ends. Everyone's count locks nothing, since
## a guesser with many addresses could lock the form for all; at
## `everyone_noted_at` failures in a window the route logs a line, once.
##
## A client is the `X-Forwarded-For` value the proxy sets (docs/deploy.md,
## "The per-client cap"), an IPv4 address whole and an IPv6 address by its
## /64 (`client_prefix`), since one household or host holds a whole /64;
## or the one client `local` for a request from this machine, which comes
## with none. Its tally is kept under one of `bucket_count` buckets, the
## first 12 bits of the prefix's HMAC under the server's secret, so the
## host's memory holds a bounded number of keys whatever the clients, and
## no one outside can choose addresses that share a bucket; two clients in
## one bucket share a tally, which only locks sooner.
##
## The tallies are seconds the host keeps in memory under a key
## (`Host.replace_second_kept_under_key!`): a count and the window's start,
## each under its own key. A restart forgets them.
import Hex
import Seconds
import Timestamp

DeviceCodeLimit :: [].{

	## How long a window of failures lasts: fifteen minutes.
	window_seconds : Seconds
	window_seconds = Seconds.of(15 * 60)

	## How many failures a client may have in a window.
	client_most : I64
	client_most = 10

	## How many failures everyone together have in a window when the route
	## logs it, so the server's owner hears of a flood of guesses.
	everyone_noted_at : I64
	everyone_noted_at = 1_000

	## How many buckets clients are kept in: 4,096, two keys each in the
	## host's memory.
	bucket_count : U64
	bucket_count = 4_096

	## Whose failures a tally counts: one bucket of clients, or everyone.
	Counted : [Clients(Str), Everyone]

	## The bucket of the client a request's `X-Forwarded-For` names, from
	## the host's HMAC `digest` of its prefix (`prefix_bytes_to_sign`): its
	## first 12 bits as 3 hex digits; `local` when it has none, and
	## `repeated` when it has more than one, which the proxy never sends.
	clients_of : [NotForwarded, Repeated, Forwarded(List(U8))] -> DeviceCodeLimit.Counted
	clients_of = |forwarded|
		match forwarded {
			NotForwarded => Clients("local")
			Repeated => Clients("repeated")
			Forwarded(digest) => {
				digits = Hex.to_hex(digest.take_first(2)).to_utf8().take_first(3)
				Clients(Str.from_utf8_lossy(digits))
			}
		}

	## The bytes the host's HMAC is over for a client whose
	## `X-Forwarded-For` is `value`: `device-code-client`, a line feed, then
	## its `client_prefix`. No other signed bytes start so.
	prefix_bytes_to_sign : List(U8) -> List(U8)
	prefix_bytes_to_sign = |value|
		List.concat("device-code-client\n".to_utf8(), DeviceCodeLimit.client_prefix(value))

	## The part of an `X-Forwarded-For` value a client is kept by: an IPv6
	## address's first four groups, its /64, each written as four lowercase
	## hex digits after `v6 `, so every spelling of one network is one
	## prefix; anything else, an IPv4 address above all, whole.
	client_prefix : List(U8) -> List(U8)
	client_prefix = |value|
		match Str.from_utf8(value) {
			Ok(text) if text.contains(":") and !text.contains(".") =>
				match ipv6_groups(text) {
					Ok(groups) => "v6 ${Str.join_with(groups.take_first(4), ":")}".to_utf8()
					Err(NotIpv6) => value
				}
			_ => value
		}

	## The key a tally's count is kept under.
	failures_key : DeviceCodeLimit.Counted -> List(U8)
	failures_key = |counted| "device-code/failures/${counted_word(counted)}".to_utf8()

	## The key a tally's window's start is kept under.
	since_key : DeviceCodeLimit.Counted -> List(U8)
	since_key = |counted| "device-code/since/${counted_word(counted)}".to_utf8()

	## A tally: how many failures there were since its window started.
	Tally : { failures : I64, since : Timestamp }

	## The tally at `now` from what the host keeps under its two keys: a
	## fresh one, of no failures from `now`, when either is missing or the
	## window has ended.
	tally_of : {
		failures : { second : I64, status : [Found, Missing] },
		since : { second : I64, status : [Found, Missing] },
		now : Timestamp,
	} -> DeviceCodeLimit.Tally
	tally_of = |{ failures, since, now }| {
		fresh = { failures: 0, since: now }
		match (failures.status, since.status) {
			(Found, Found) => {
				started = Timestamp.at_second(since.second)
				window = { from: started, until: started.plus(DeviceCodeLimit.window_seconds) }
				if now.is_during(window) {
					{ failures: failures.second, since: started }
				} else {
					fresh
				}
			}
			_ => fresh
		}
	}

	## Whether `tally` has reached `most` failures, so its form is locked.
	is_locked : DeviceCodeLimit.Tally, I64 -> Bool
	is_locked = |tally, most| tally.failures >= most

	## The tally after one more failure.
	tally_after_failure : DeviceCodeLimit.Tally -> DeviceCodeLimit.Tally
	tally_after_failure = |tally| { ..tally, failures: tally.failures + 1 }
}

## A tally's name, as its keys spell it.
counted_word : DeviceCodeLimit.Counted -> Str
counted_word = |counted|
	match counted {
		Clients(bucket) => "clients/${bucket}"
		Everyone => "everyone"
	}

## The eight groups of the IPv6 address `text`, each four lowercase hex
## digits, a `::` filled with zero groups; unless it is no IPv6 address.
ipv6_groups : Str -> Try(List(Str), [NotIpv6])
ipv6_groups = |text| {
	found =
		match text.split_on("::") {
			[whole] => groups_of(whole)
			[head, tail] => filled_groups(groups_of(head)?, groups_of(tail)?)
			_ => Err(NotIpv6)
		}
	written = found?
	if written.len() == 8 {
		Ok(written)
	} else {
		Err(NotIpv6)
	}
}

## The groups `head_groups` and `tail_groups` with zero groups between them, where a
## `::` stood, to make eight; unless they leave no room for one.
filled_groups : List(Str), List(Str) -> Try(List(Str), [NotIpv6])
filled_groups = |head_groups, tail_groups| {
	written = head_groups.len() + tail_groups.len()
	if written >= 8 {
		Err(NotIpv6)
	} else {
		Ok(List.concat(List.concat(head_groups, List.repeat("0000", 8 - written)), tail_groups))
	}
}

## The groups `part` of an IPv6 address holds between its colons, none for
## an empty part; unless one is not one to four hex digits.
groups_of : Str -> Try(List(Str), [NotIpv6])
groups_of = |part|
	if part.is_empty() {
		Ok([])
	} else {
		part.split_on(":").map_try(group_of)
	}

## The group `written`, as four lowercase hex digits; unless it is not one
## to four hex digits.
group_of : Str -> Try(Str, [NotIpv6])
group_of = |written| {
	digits = written.with_ascii_lowercased().to_utf8()
	if digits.is_empty() or digits.len() > 4 or !digits.all(Hex.is_lower_digit) {
		Err(NotIpv6)
	} else {
		padding = List.repeat('0', 4 - digits.len())
		Ok(Str.from_utf8_lossy(List.concat(padding, digits)))
	}
}
