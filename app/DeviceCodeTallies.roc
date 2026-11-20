## This module keeps the device code form's tallies of failures in the
## host's memory, which `DeviceCodeLimit` decides on: it finds a request's
## client, loads its tally and everyone's, says whether either locks the
## form, and counts a failure in both, logging when everyone's reaches
## the count that tells of a flood.
import pf.Host
import pf.Http
import DeviceCodeLimit
import RequestHeader
import Timestamp

DeviceCodeTallies :: [].{

	## A tally, and whose failures it counts.
	CountedTally : { who : DeviceCodeLimit.Counted, tally : DeviceCodeLimit.Tally }

	## The tallies at `now` of the client the request's `headers` name, and
	## of everyone.
	load_tallies! : List(Http.Header), Timestamp => List(DeviceCodeTallies.CountedTally)
	load_tallies! = |headers, now| {
		client = DeviceCodeLimit.clients_of(hash_forwarded_client!(headers))
		[
			{ who: client, tally: load_tally!(client, now) },
			{ who: Everyone, tally: load_tally!(Everyone, now) },
		]
	}

	## Whether a tally among `tallies` has reached its most, the client's or
	## everyone's, so the form is locked.
	is_locked : List(DeviceCodeTallies.CountedTally) -> Bool
	is_locked = |tallies|
		tallies.any(
			|{ who, tally }|
				match who {
					Clients(_) => DeviceCodeLimit.is_locked(tally, DeviceCodeLimit.client_most)
					Everyone => DeviceCodeLimit.is_locked(tally, DeviceCodeLimit.everyone_most)
				},
		)

	## One more failure kept in each of `tallies`.
	count_failure! : List(DeviceCodeTallies.CountedTally) => {}
	count_failure! = |tallies| {
		for counted in tallies {
			after = DeviceCodeLimit.tally_after_failure(counted.tally)
			if counted.who == Everyone and after.failures == DeviceCodeLimit.everyone_most {
				Host.write_line_to_server_log!(flood_line.to_utf8())
			}
			_ = Host.replace_second_kept_under_key!(
				DeviceCodeLimit.failures_key(counted.who),
				after.failures,
			)
			_ = Host.replace_second_kept_under_key!(
				DeviceCodeLimit.since_key(counted.who),
				after.since.to_seconds_since_epoch(),
			)
		}
	}
}

## The client the request's `headers` name, as `DeviceCodeLimit` buckets it:
## the host's HMAC of its `X-Forwarded-For`'s prefix.
hash_forwarded_client! : List(Http.Header) => [NotForwarded, Repeated, Forwarded(List(U8))]
hash_forwarded_client! = |headers|
	match RequestHeader.header_value(headers, "x-forwarded-for") {
		Unsent => NotForwarded
		Repeated => Repeated
		Sent(value) => {
			signed = DeviceCodeLimit.prefix_bytes_to_sign(value)
			Forwarded(Host.hmac_sha256_with_server_secret!(signed))
		}
	}

## The tally of `who`'s failures at `now`, from the host's memory.
load_tally! : DeviceCodeLimit.Counted, Timestamp => DeviceCodeLimit.Tally
load_tally! = |who, now|
	DeviceCodeLimit.tally_of({
		failures: Host.read_second_kept_under_key!(DeviceCodeLimit.failures_key(who)),
		since: Host.read_second_kept_under_key!(DeviceCodeLimit.since_key(who)),
		now,
	})

## The log's line when everyone's failures reach their most.
flood_line : Str
flood_line = "device codes: ${DeviceCodeLimit.everyone_most.to_str()} failed in a window from everyone, a flood of guesses; the form is locked for everyone until the window ends"
