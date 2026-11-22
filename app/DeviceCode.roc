## A device code signs a second device, such as a phone, in as a human who is
## signed in on another, so the second device needs no password and no
## GitHub. The human makes the code on the device already signed in
## (`DeviceCodeRoute`), types it on the other, and the chat signs that one in
## with a session marked as a code's (`Session.Origin`), which may not hand
## out credentials or take them back (`FullSessionRoutes`).
##
## A code is 8 digits (Steve, 2026-11-20: "The device code is not
## iphone-friendly... I would consider eight digits instead"), made from the
## host's random bytes (`Code.of_random_bytes`). It is shown as two groups
## of four, a thin space between them, and read back with spaces, thin
## spaces and dashes ignored (`Code.from_typed`), so a phone types it on its
## number pad. Ten to the eighth codes is few enough to guess at without
## limits, so `DeviceCodeLimit` locks the form for everyone, as well as for
## each client, past a count of failures.
##
## The chat keeps one record a human, never the code: the HMAC of the code's
## `bytes_to_sign` under the server's secret, which the host computes and
## compares in constant time, so the record proves nothing to whoever reads
## it. The record also keeps an HMAC of what the human's sessions were
## signed over when the code was made (`Session.Material`, through
## `material_bytes_to_sign`), and a code redeems only while that is
## unchanged: a new password, a GitHub link, or any of those files edited
## by hand, ends every code with every session. A record is `Live` for
## `lifetime_seconds` from its making, then redeems once (`Spent`), or is
## `Cancelled` by its human signing out or asking. Making a new code
## replaces the record, so a human has at most one code that may be
## redeemed.
##
## This module and `DeviceCodeLimit` are one trust boundary with
## `SignedIn`: a code is a credential for exactly one session.
import Ascii
import Hex
import Seconds
import Session
import Timestamp
import Users

DeviceCode :: {
	state : DeviceCode.State,
	created : Timestamp,
	expires : Timestamp,
	mac : List(U8),
	material : List(U8),
}.{

	## What a code is, as typed or shown: 8 digits, bytes of `alphabet`.
	Code :: List(U8).{

		## The code the host's random `bytes` make: each byte below 250 is
		## one digit, its remainder by 10 the place in `alphabet`, so
		## every character is as likely; the rest are passed over. Fewer than
		## 8 such bytes is `TooFewUsableBytes`, and the caller draws again.
		of_random_bytes : List(U8) -> Try(DeviceCode.Code, [TooFewUsableBytes])
		of_random_bytes = |bytes| {
			usable = bytes.keep_if(|byte| byte < usable_below).take_first(code_length)
			if usable.len() == code_length {
				Ok(DeviceCode.Code.(usable.map(character_of)))
			} else {
				Err(TooFewUsableBytes)
			}
		}

		## The code a human typed: its digits, with any spaces, thin spaces
		## (as the page shows it, pasted) and dashes left out; unless what is
		## left is not 8 digits (`NotACode`), a letter above all.
		from_typed : Str -> Try(DeviceCode.Code, [NotACode])
		from_typed = |typed| {
			kept =
				Str.join_with(typed.split_on(thin_space), "").to_utf8()
					.drop_if(|byte| byte == ' ' or byte == '-')
			if kept.len() == code_length and kept.all(|byte| alphabet.contains(byte)) {
				Ok(DeviceCode.Code.(kept))
			} else {
				Err(NotACode)
			}
		}

		## The code as a page shows it: two groups of four, joined by a thin
		## space, which reads as a gap and is never typed.
		display_text : DeviceCode.Code -> Str
		display_text = |DeviceCode.Code.(characters)| {
			first = Str.from_utf8_lossy(characters.take_first(4))
			last = Str.from_utf8_lossy(characters.drop_first(4))
			"${first}${thin_space}${last}"
		}

		## The code the request's `Cookie` header `header` carries in the
		## cookie that shows a code just made once (`flash_cookie_text`);
		## unless it carries none, more than one, or one that is no code.
		from_cookie_header : List(U8) -> Try(DeviceCode.Code, [NoCode])
		from_cookie_header = |header| {
			pairs = header.split_on(';').map(Ascii.trim_spaces)
			match pairs.keep_if(|pair| pair.starts_with(flash_prefix)) {
				[only] =>
					match Str.from_utf8(only.drop_first(flash_prefix.len())) {
						Ok(text) => DeviceCode.Code.from_typed(text).map_err(|NotACode| NoCode)
						Err(_) => Err(NoCode)
					}
				_ => Err(NoCode)
			}
		}

		## The `Set-Cookie` value that carries the code just made to the page
		## that shows it, once: for this host alone, sent to no script and on
		## no other site's request, and gone when the browser closes, when the
		## page shows it, or when the human signs out.
		flash_cookie_text : DeviceCode.Code -> Str
		flash_cookie_text = |DeviceCode.Code.(characters)|
			"${flash_prefix_text}${Str.from_utf8_lossy(characters)}; Path=/; ${flash_attributes}"

		## The bytes the host's HMAC is over: `device-code`, a line feed and
		## the 8 characters. A session's signed bytes start with a digit, so
		## no code's are ever a session's.
		bytes_to_sign : DeviceCode.Code -> List(U8)
		bytes_to_sign = |DeviceCode.Code.(characters)| List.concat(
			"device-code\n".to_utf8(),
			characters,
		)

		is_eq : _
	}

	## The characters a code is made of: the digits.
	alphabet : List(U8)
	alphabet = "0123456789".to_utf8()

	## How many random bytes a code is drawn from: enough that fewer than 8
	## usable ones (`Code.of_random_bytes`) happens about never.
	random_byte_count : U64
	random_byte_count = 32

	## Whether a record may still be redeemed: `Live` until it is redeemed
	## (`Spent`, at a moment) or cancelled (`Cancelled`).
	State : [Live, Spent(Timestamp), Cancelled]

	## How long a code lives: five minutes.
	lifetime_seconds : Seconds
	lifetime_seconds = Seconds.of(5 * 60)

	## A new record, live from `now` for `lifetime_seconds`, of a code whose
	## HMAC is `mac`, made while the human's sessions were signed over what
	## has the HMAC `material`.
	make : {
		mac : List(U8),
		material : List(U8),
		now : Timestamp,
	} -> DeviceCode
	make = |{ mac, material, now }|
		DeviceCode.(
			{
				state: Live,
				created: now,
				expires: now.plus(DeviceCode.lifetime_seconds),
				mac,
				material,
			},
		)

	## The bytes the host's HMAC is over for what a human's sessions are
	## signed over, `material`: `device-code-material`, a line feed, then its
	## bytes. No other signed bytes start so.
	material_bytes_to_sign : Session.Material -> List(U8)
	material_bytes_to_sign = |material|
		List.concat("device-code-material\n".to_utf8(), material.bytes_to_sign())

	## The HMAC of the material the record was made under, for the host to
	## compare what the human's sessions are signed over now with.
	material_digest : DeviceCode -> List(U8)
	material_digest = |DeviceCode.(record)| record.material

	## The record cancelled, while it is live; a spent or cancelled one stays
	## as it is.
	cancel : DeviceCode -> DeviceCode
	cancel = |DeviceCode.(record)|
		match record.state {
			Live => DeviceCode.({ ..record, state: Cancelled })
			Spent(_) | Cancelled => DeviceCode.(record)
		}

	## Whether the record is live and should be cancelled.
	is_live : DeviceCode -> Bool
	is_live = |DeviceCode.(record)|
		match record.state {
			Live => Bool.True
			Spent(_) | Cancelled => Bool.False
		}

	## Whether the record may redeem at `now`: live, and `now` within its
	## life.
	is_redeemable_at : DeviceCode, Timestamp -> Bool
	is_redeemable_at = |DeviceCode.(record), now|
		match record.state {
			Live => now.is_during({ from: record.created, until: record.expires })
			Spent(_) | Cancelled => Bool.False
		}

	## Whether `mac`, a new code's HMAC, is one that any of `records` keeps,
	## so a code drawn for one human never matches another's record: the
	## caller draws again.
	is_mac_held : List(U8), List(DeviceCode) -> Bool
	is_mac_held = |mac, records| records.any(|DeviceCode.(record)| record.mac == mac)

	## When the record's code expires.
	expires : DeviceCode -> Timestamp
	expires = |DeviceCode.(record)| record.expires

	## The HMAC the record keeps, for the host to compare a typed code with.
	mac : DeviceCode -> List(U8)
	mac = |DeviceCode.(record)| record.mac

	## A record found for a redemption: whose it is, and the host's verdict
	## on whether the typed code's HMAC is the one it keeps.
	Found : {
		owner : Users.Human,
		record : DeviceCode,
		verdict : [DoesNotMatch, Matches],
	}

	## A code redeemed: the human it signs in, and their record, spent. Only
	## `redeem` makes one, and only `SignInRoute.start_session_by_device_code!`
	## takes one.
	Redemption :: { owner : Users.Human, spent : DeviceCode }.{

		## The human the code signs in.
		owner : DeviceCode.Redemption -> Users.Human
		owner = |DeviceCode.Redemption.(redemption)| redemption.owner

		## Their record, spent, to write back.
		spent_record : DeviceCode.Redemption -> DeviceCode
		spent_record = |DeviceCode.Redemption.(redemption)| redemption.spent

		is_eq : _
	}

	## The one record among `candidates` whose HMAC matched the typed
	## code's and that may redeem at `now` (`is_redeemable_at`), so a spent,
	## cancelled or expired record that happens to match never hides a live
	## one; else `NoMatch`.
	matching_candidate : List(DeviceCode.Found), Timestamp -> Try(DeviceCode.Found, [NoMatch])
	matching_candidate = |candidates, now|
		candidates.find_first(
			|candidate| candidate.verdict == Matches and candidate.record.is_redeemable_at(now),
		).map_err(|NotFound| NoMatch)

	## The redemption at `now` of `found`, the record whose HMAC matched,
	## when it is live, `now` is within its life, and the host's verdict on
	## its owner's material now, `material_verdict`, is that it is unchanged; checked
	## before the record is spent. Anything else, a spent, cancelled or
	## expired record or changed material, is the one `NoMatch`, so a refusal
	## says nothing of why.
	redeem : {
		found : DeviceCode.Found,
		material_verdict : [DoesNotMatch, Matches],
		now : Timestamp,
	} -> Try(DeviceCode.Redemption, [NoMatch])
	redeem = |{ found, material_verdict, now }| {
		DeviceCode.(record) = found.record
		lifetime = { from: record.created, until: record.expires }
		match (record.state, material_verdict) {
			(Live, Matches) if now.is_during(lifetime) => {
				spent = DeviceCode.({ ..record, state: Spent(now) })
				Ok(DeviceCode.Redemption.({ owner: found.owner, spent }))
			}
			_ => Err(NoMatch)
		}
	}

	## What the code page says of the record at `now`: none made yet, one
	## waiting until it expires, one used at a moment, one expired unused, or
	## one cancelled.
	Status : [
		NoCode,
		Waiting(Timestamp),
		Used(Timestamp),
		Expired,
		Cancelled,
	]

	## The status of `held`, a human's record or none, at `now`.
	status : [NoRecord, Record(DeviceCode)], Timestamp -> DeviceCode.Status
	status = |held, now|
		match held {
			NoRecord => NoCode
			Record(DeviceCode.(record)) =>
				match record.state {
					Spent(at) => Used(at)
					Cancelled => Cancelled
					Live if now.is_during({ from: record.created, until: record.expires }) =>
						Waiting(record.expires)
					Live => Expired
				}
		}

	## The `Set-Cookie` value that has a browser forget the cookie that shows
	## a code, once the page has shown it.
	clear_flash_cookie_text : Str
	clear_flash_cookie_text = "${flash_prefix_text}; Path=/; Max-Age=0; ${flash_attributes}"

	## The record as its file keeps it, one line: its state's word, its
	## making and expiry in seconds since the epoch, its code's HMAC and its
	## material's in lowercase hex, and for a spent one, the second it was
	## redeemed.
	to_file : DeviceCode -> List(U8)
	to_file = |DeviceCode.(record)| {
		times = "${record.created.to_str()} ${record.expires.to_str()}"
		facts = "${times} ${Hex.to_hex(record.mac)} ${Hex.to_hex(record.material)}"
		line =
			match record.state {
				Live => "live ${facts}"
				Cancelled => "cancelled ${facts}"
				Spent(at) => "spent ${facts} ${at.to_str()}"
			}
		"${line}\n".to_utf8()
	}

	## The record a file's `bytes` hold, as `to_file` writes it; unless they
	## hold anything else (`Damaged`).
	from_file : List(U8) -> Try(DeviceCode, [Damaged])
	from_file = |bytes| {
		words = bytes.drop_if(|byte| byte == '\n').split_on(' ')
		match words {
			[
				word,
				created_word,
				expires_word,
				mac_word,
				material_word,
				.. as rest,
			] => {
				created = Timestamp.from_file(created_word) ? |_| Damaged
				expiry = Timestamp.from_file(expires_word) ? |_| Damaged
				digest = digest_from_word(mac_word)?
				kept_material = digest_from_word(material_word)?
				state = state_from_words(word, rest)?
				Ok(
					DeviceCode.(
						{
							state,
							created,
							expires: expiry,
							mac: digest,
							material: kept_material,
						},
					),
				)
			}
			_ => Err(Damaged)
		}
	}

	is_eq : _
}

flash_prefix_text : Str
flash_prefix_text = "__Host-device_code="

flash_prefix : List(U8)
flash_prefix = flash_prefix_text.to_utf8()

flash_attributes : Str
flash_attributes = "HttpOnly; Secure; SameSite=Strict"

## How many characters a code is.
code_length : U64
code_length = 8

## The bytes below which a random byte is one character: 10 times 25, so
## each of the 10 digits has 25 bytes.
usable_below : U8
usable_below = 250

## The character a usable random byte stands for.
character_of : U8 -> U8
character_of = |byte|
	DeviceCode.alphabet.get((byte % 10).to_u64())
		?? crash "DeviceCode.character_of: a remainder by 10 is a place in the 10-digit alphabet"

## The thin space, U+2009, between a shown code's two groups.
thin_space : Str
thin_space = "\u(2009)"

## The 32 bytes a file's `word` spells in lowercase hex; unless it spells
## anything else.
digest_from_word : List(U8) -> Try(List(U8), [Damaged])
digest_from_word = |word|
	match Str.from_utf8(word) {
		Ok(text) =>
			match Hex.from_hex(text) {
				Ok(digest) if digest.len() == 32 => Ok(digest)
				_ => Err(Damaged)
			}
		Err(_) => Err(Damaged)
	}

## The state a file's first word, and the words after its HMACs, spell.
state_from_words : List(U8), List(List(U8)) -> Try(DeviceCode.State, [Damaged])
state_from_words = |word, trailing_words|
	match trailing_words {
		[] if word == "live".to_utf8() => Ok(Live)
		[] if word == "cancelled".to_utf8() => Ok(Cancelled)
		[at_word] if word == "spent".to_utf8() =>
			Timestamp.from_file(at_word).map_ok(|at| Spent(at)).map_err(|_| Damaged)
		_ => Err(Damaged)
	}
