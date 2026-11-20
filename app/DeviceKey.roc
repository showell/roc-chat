## A device key is what a session started by a device code is bound to
## (Steve, 2026-11-20): one for each code redeemed, numbered among the
## human's keys (`SerialNumber`), and active until that device signs out,
## which revokes it for good. The session's cookie names the key's number
## and is signed over it (`Session`), and each request of the session reads
## the key's state (`SignInFiles.check_session_key!`): only `Active` admits.
## So signing out of such a device refuses every copy of its cookie at its
## next request, and its open streams are ended then too (`SignOutRoute`);
## to sign in on it again the human makes a new code.
##
## `DeviceKeyFiles` keeps each key in the human's account folder, under
## `device-keys/<number>/`: `created`, the second it was made, then
## `state`, `active` or `revoked`, written last, so a key cut short by a
## crash has no state and admits no one.
import FactFile
import SerialNumber

DeviceKey :: [].{

	## A key's number among its human's device keys.
	Id :: U32.{

		## The number `text` spells, as a folder's name and a cookie carry it.
		from_str : Str -> Try(DeviceKey.Id, [NotADeviceKeyId])
		from_str = |text|
			SerialNumber.from_str(text)
				.map_ok(|serial_number| DeviceKey.Id.(serial_number))
				.map_err(|NotASerialNumber| NotADeviceKeyId)

		## The number after the highest of `given`, 1 for none.
		next_after : List(DeviceKey.Id) -> Try(DeviceKey.Id, [Full])
		next_after = |given|
			SerialNumber.next_after(given.map(|DeviceKey.Id.(n)| n))
				.map_ok(|serial_number| DeviceKey.Id.(serial_number))

		to_str : DeviceKey.Id -> Str
		to_str = |DeviceKey.Id.(serial_number)| serial_number.to_str()

		is_eq : _
	}

	## Whether a key still admits its device.
	State : [Active, Revoked]

	## A key's state, as its `state` file holds it.
	state_to_file : DeviceKey.State -> List(U8)
	state_to_file = |state|
		match state {
			Active => "active".to_utf8()
			Revoked => "revoked".to_utf8()
		}

	## The state a key's `state` file holds; unless it holds none
	## (`NotAState`).
	state_from_file : List(U8) -> Try(DeviceKey.State, [NotAState])
	state_from_file = |bytes| {
		word = FactFile.word_from_file(bytes)
		if word == "active".to_utf8() {
			Ok(Active)
		} else if word == "revoked".to_utf8() {
			Ok(Revoked)
		} else {
			Err(NotAState)
		}
	}
}

# ── tests
# A key's number: each spelling read back, and none that isn't one.
expect
	["1", "7", "4294967295"].all(
		|text| DeviceKey.Id.from_str(text).map_ok(DeviceKey.Id.to_str) == Ok(text),
	)
expect
	["", "0", "01", "x", "4294967296"].all(
		|text| DeviceKey.Id.from_str(text) == Err(NotADeviceKeyId),
	)
expect
	DeviceKey.Id.next_after([]).map_ok(DeviceKey.Id.to_str) == Ok("1")
expect {
	given = ["2", "9", "4"].keep_oks(DeviceKey.Id.from_str)
	DeviceKey.Id.next_after(given).map_ok(DeviceKey.Id.to_str) == Ok("10")
}
# Each state's word, read back; a hand edit's spaces and line end too; any
# other word is no state.
expect
	[Active, Revoked].all(
		|state| DeviceKey.state_from_file(DeviceKey.state_to_file(state)) == Ok(state),
	)
expect DeviceKey.state_from_file(" revoked\n".to_utf8()) == Ok(Revoked)
expect
	["", "Active", "live", "active revoked"].all(
		|word| DeviceKey.state_from_file(word.to_utf8()) == Err(NotAState),
	)
