## The account's own proof, which the one writer of a password's hash
## (`AccountFiles.replace_password_hash!`) takes in place of a bare id, so
## no code sets a human's password without it. Today one thing makes one: an
## invite redeemed for a human who had claimed nothing (`HumanClaim`), their
## first join, as `HumanInvite.redeem` alone makes an `Admission` and takes
## an `Unclaimed` human to. A later way for a human to change their own
## password adds its maker here, from their own sign-in.
## tools/check_credential_writers.shale holds every path to a credential.
import HumanInvite
import UserId

AccountProof :: UserId.{

	## The proof of a first join: the human an invite's redemption admitted.
	of_first_join : HumanInvite.Admission -> AccountProof
	of_first_join = |admission| AccountProof.(admission.human().id())

	## The human whose account it proves.
	human : AccountProof -> UserId
	human = |AccountProof.(id)| id
}
