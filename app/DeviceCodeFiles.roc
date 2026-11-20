## This module keeps each human's device code record (`DeviceCode`), one file
## in their folder (`UserFolder`), `users/<id>/device-code`, written whole and
## atomically, so a new code's record replaces the one before; and their
## last sign-ins by code (`DeviceSignIns`), `users/<id>/device-sign-ins`.
import DeviceCode
import DeviceSignIns
import FileFacts
import UserFolder
import UserId

DeviceCodeFiles :: [].{

	## The human `id`'s record, or `NoRecord` when they have made no code;
	## unless the file is no record (`Damaged`) or the host's read failed.
	read_device_code! : UserId => Try([NoRecord, Record(DeviceCode)], [FileSystem(FileFacts.Fault)])
	read_device_code! = |id|
		match FileFacts.read_fact!(device_code_path(id)) {
			Ok(NoFile) => Ok(NoRecord)
			Ok(File(bytes)) =>
				match DeviceCode.from_file(bytes) {
					Ok(record) => Ok(Record(record))
					Err(Damaged) => Err(FileSystem(Damaged))
				}
			Err(NotUtf8) => Err(FileSystem(NotUtf8))
			Err(PathRefused) => Err(FileSystem(PathRefused))
			Err(Failed) => Err(FileSystem(Failed))
		}

	## The human `id`'s record, written whole over the one before, their
	## folder made as needed; unless the host refused, and then the file is
	## as it was.
	replace_device_code! : UserId, DeviceCode => Try({}, [FileSystem(FileFacts.Fault)])
	replace_device_code! = |id, record| {
		FileFacts.make_folder!(folder_path(id)) ? |fault| FileSystem(fault)
		match FileFacts.replace_fact!(device_code_path(id), record.to_file()) {
			Ok({}) => Ok({})
			Err(MissingDirectory) => Err(FileSystem(MissingDirectory))
			Err(NotUtf8) => crash "DeviceCodeFiles.replace_device_code!: a record's words are ASCII"
			Err(PathRefused) => Err(FileSystem(PathRefused))
			Err(Failed) => Err(FileSystem(Failed))
		}
	}

	## The human `id`'s last sign-ins by code, newest first, none when there
	## is no file; unless it holds anything else (`Damaged`), or the host's
	## read failed.
	read_sign_ins! : UserId => Try(List(DeviceSignIns.SignIn), [FileSystem(FileFacts.Fault)])
	read_sign_ins! = |id|
		match FileFacts.read_fact!(sign_ins_path(id)) {
			Ok(NoFile) => Ok([])
			Ok(File(bytes)) =>
				DeviceSignIns.sign_ins_from_file(bytes).map_err(|Damaged| FileSystem(Damaged))
			Err(NotUtf8) => Err(FileSystem(NotUtf8))
			Err(PathRefused) => Err(FileSystem(PathRefused))
			Err(Failed) => Err(FileSystem(Failed))
		}

	## The human `id`'s sign-ins by code, written whole, their folder made as
	## needed.
	replace_sign_ins! : UserId, List(DeviceSignIns.SignIn) => Try({}, [FileSystem(FileFacts.Fault)])
	replace_sign_ins! = |id, sign_ins| {
		FileFacts.make_folder!(folder_path(id)) ? |fault| FileSystem(fault)
		match FileFacts.replace_fact!(sign_ins_path(id), DeviceSignIns.sign_ins_to_file(sign_ins)) {
			Ok({}) => Ok({})
			Err(MissingDirectory) => Err(FileSystem(MissingDirectory))
			Err(NotUtf8) => crash "DeviceCodeFiles.replace_sign_ins!: a sign-in's words are ASCII"
			Err(PathRefused) => Err(FileSystem(PathRefused))
			Err(Failed) => Err(FileSystem(Failed))
		}
	}

	## The human `id`'s code cancelled, when it is live.
	cancel_live_device_code! : UserId => Try({}, [FileSystem(FileFacts.Fault)])
	cancel_live_device_code! = |id|
		match DeviceCodeFiles.read_device_code!(id)? {
			Record(record) if record.is_live() =>
				DeviceCodeFiles.replace_device_code!(id, record.cancel())
			Record(_) | NoRecord => Ok({})
		}
}

## The path of the human `id`'s sign-ins by code.
sign_ins_path : UserId -> Str
sign_ins_path = |id| "${folder_path(id)}/device-sign-ins"

## The human `id`'s folder.
folder_path : UserId -> Str
folder_path = |id| Str.join_with(UserFolder.of(id).parts(), "/")

## The path of the human `id`'s record.
device_code_path : UserId -> Str
device_code_path = |id| "${folder_path(id)}/device-code"
