## These are the tests of `SignInRequest.password_claim`: whom a sign-in
## form's name and password claim to be. The right password and a wrong one
## make the same claim, since only the host's check tells them apart; a name
## no one has and an agent's make the same claim as each other, which
## `SignInRoute` checks against its dummy hash, so its time says nothing of
## which names exist; a form with no name or no password, or one that is no
## name or no password, claims no one before any name is looked up; and a
## request with an API key is refused before the form is read. The claim
## applies no limit of its own: the host's bucket of checks does
## (`Host.password_matches_bcrypt_hash!`), and `host/http_test.zig` counts
## its bcrypt runs.
import AgentKey
import KeyScope
import Sample
import SecretHash
import SignInRequest
import SignedIn
import Timestamp
import Users

PasswordClaimSpec :: [].{}

## CC, Steve's agent, by a key.
cc_by_key : SignedIn.Actor
cc_by_key = {
	hash = SecretHash.of_digest(List.repeat(3, 32))
	key = AgentKey.mint({
		id: AgentKey.Id.from_str("1") ?? crash "PasswordClaimSpec: a key's number",
		hash,
		now: Timestamp.at_second(0),
		scope: KeyScope.of({ read: Everywhere, post: Everywhere }),
	})
	admitted = AgentKey.admit({
		user: Sample.user("CC"),
		keys: [key],
		hash,
		now: Timestamp.at_second(0),
	}) ?? crash "PasswordClaimSpec: CC's key admits"
	SignedIn(SignedIn.by_api_key(admitted))
}

## The sample's users: Steve and Apoorva, humans, and CC, Steve's agent.
users : Users
users = Sample.directory.users()

## What the form `body` claims, from `viewer`, as a test reads it: the
## password's bytes, and the name of the human it names, or `NoHuman`.
claim_by : SignedIn.Actor, Str -> Try(
	{ password : Str, claimant : [Human(Str), NoHuman] },
	[ByApiKey, NoMatch],
)
claim_by = |viewer, body| {
	claim = SignInRequest.password_claim({ viewer, users, body: body.to_utf8() })?
	claimant =
		match claim.claimant {
			Human(human) => Human(human.user().name().to_str())
			NoHuman => NoHuman
		}
	Ok({ password: Str.from_utf8_lossy(claim.password.bytes_to_check()), claimant })
}

## What the form `body` claims from no one signed in.
claim : Str -> Try(
	{ password : Str, claimant : [Human(Str), NoHuman] },
	[ByApiKey, NoMatch],
)
claim = |body| claim_by(Anonymous, body)

# A human's name and a password: that human, and the password as typed,
# decoded from the form.
expect claim("name=Steve&password=hunter2") == Ok({ password: "hunter2", claimant: Human("Steve") })
expect
	claim("password=a%26b%3Dc&name=Apoorva")
		== Ok({ password: "a&b=c", claimant: Human("Apoorva") })
# A wrong password is the same claim on the same human: the claim never
# judges a password, so the right one and a wrong one take one path, to the
# host's check of the human's hash.
expect {
	right = claim("name=Steve&password=right")
	wrong = claim("name=Steve&password=wrong")
	right.map_ok(|c| c.claimant) == Ok(Human("Steve"))
		and wrong.map_ok(|c| c.claimant) == Ok(Human("Steve"))
}
# A name signs in exactly as it is kept (`Users.user_by_name`): another case
# of a human's name is no human, the same claim as a stranger's.
expect claim("name=sTEVE&password=x") == claim("name=Nobody&password=x")
# A name no one has, and an agent's, are both no human, the same claim
# whatever the password: `SignInRoute` spends one check on the dummy hash
# for each, so neither answers sooner than a human's wrong password.
expect claim("name=Nobody&password=guess") == Ok({ password: "guess", claimant: NoHuman })
expect claim("name=CC&password=guess") == Ok({ password: "guess", claimant: NoHuman })
expect claim("name=CC&password=guess") == claim("name=Nobody&password=guess")
# A form missing its name or its password, or holding one that is none, is
# no match: no name is looked up, so the answer is the same whether or not
# the name is a human's.
expect
	[
		"",
		"name=Steve",
		"password=hunter2",
		"name=&password=hunter2",
		"name=Steve&password=",
		"name=R2D2&password=hunter2",
		"name=%20Steve&password=hunter2",
		"name=Steve&name=Apoorva&password=hunter2",
		"name=Steve&password=a&password=b",
		"name=Ste%G0ve&password=hunter2",
		"name=Steve&password=%ff",
	].all(|body| claim(body) == Err(NoMatch))
expect claim("name=Steve&password=") == claim("name=Nobody&password=")
expect claim("name=Steve") == claim("name=Nobody")
# The limits of what is read: a password of 72 bytes is one, of 73 none;
# a name of 60 letters is one (no one's), of 61 none.
expect
	claim("name=Steve&password=${"x".repeat(72)}")
		== Ok({ password: "x".repeat(72), claimant: Human("Steve") })
expect claim("name=Steve&password=${"x".repeat(73)}") == Err(NoMatch)
expect
	claim("name=${"a".repeat(60)}&password=x") == Ok({ password: "x", claimant: NoHuman })
expect claim("name=${"a".repeat(61)}&password=x") == Err(NoMatch)
# A request with an API key never signs in, and is refused before its form
# is read: a good form, a bad one and an empty one are the same refusal, so
# a key learns nothing of the names.
expect
	[
		"name=Steve&password=hunter2",
		"name=Nobody&password=guess",
		"name=Steve",
		"",
	].all(|body| claim_by(cc_by_key, body) == Err(ByApiKey))
# Someone already signed in by a session may claim again, as anyone does:
# only a key is refused.
expect
	claim_by(SignedIn(SignedIn.dangerously_assume(Sample.steve)), "name=Apoorva&password=x")
		== Ok({ password: "x", claimant: Human("Apoorva") })
