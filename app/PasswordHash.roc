## The bcrypt hash of a human's password, as their `password` file keeps it.
## It is made only from what the host's bcrypt answered
## (`Host.bcrypt_hash_of_password!`), or read from the file, with the spaces,
## tabs and line ends at either end taken off (`FactFile`), so the server's
## owner may write the file with a line end. The host checks a password
## against it, and a session is signed over it (`Session.Material`). A file
## holding no bcrypt hash is still read as one: the host's check says
## `NotABcryptHash`.
import FactFile

PasswordHash :: List(U8).{

	## The hash the host's bcrypt answered.
	of_bcrypt_answer : List(U8) -> PasswordHash
	of_bcrypt_answer = |bytes| PasswordHash.(bytes)

	## The hash a `password` file's `bytes` hold.
	from_file : List(U8) -> PasswordHash
	from_file = |bytes| PasswordHash.(FactFile.word_from_file(bytes))

	## The hash's bytes: what its file keeps, what the host checks a password
	## against, and what a session is signed over.
	bytes : PasswordHash -> List(U8)
	bytes = |PasswordHash.(hash)| hash

	is_eq : _
}

# ── tests
expect PasswordHash.from_file(" $2b$10$x\r\n".to_utf8()).bytes() == "$2b$10$x".to_utf8()
expect PasswordHash.from_file("$2b$10$x".to_utf8()) == PasswordHash.of_bcrypt_answer("$2b$10$x".to_utf8())
expect PasswordHash.from_file("\n".to_utf8()).bytes() == []
