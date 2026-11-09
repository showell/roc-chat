## This module is the one way a secret is hashed, an agent's key's, an agent
## invite's code's or a human invite's code's: the host computes the SHA-256
## digest (`Host.sha256_of_bytes!`), and `SecretHash` keeps it. It stands
## apart from `SecretHash` because it asks the host, which the specs' app,
## where `SecretHash` is tested, can't.
import pf.Host
import Secret
import SecretHash

SecretHashing :: [].{

	## The hash of `secret`, as the host computes it.
	hash_secret! : Secret => SecretHash
	hash_secret! = |secret| SecretHash.of_digest(Host.sha256_of_bytes!(secret.bytes_to_hash()))
}
