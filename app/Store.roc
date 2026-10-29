## **THE STORE: EVERY FILE THE APP KEEPS, AND THE ONLY MODULE THAT NAMES
## ONE.** Its functions take and give the core's types (the accounts, the
## settings, a session, an audit entry); the paths, the line formats
## (the core's codecs) and the host's file functions are kept here. A
## handler never names a path, so the store's layout is read in one module,
## and a fork that keeps its records elsewhere (a database) rewrites this
## module and the host's file functions, never a handler.
##
## The layout, under the data root:
##
##     auth/accounts             every account, a line each (AccountCodec)
##     auth/settings             the generation counter (SignInWeb.settings_line)
##     auth/barred               the barred GitHub ids, a line each
##     auth/audit                every refusal and admin act, appended (AuditCodec)
##     auth/sessions/<hash>      a session, named for its secret's hash (SessionCodec)
##     auth/spent/state/<hex>    a state's nonce, spent
##     auth/spent/pending/<hex>  a pending sign-up's nonce, spent
##
## **`Failed` HAS FAILED THE REQUEST** (Host.roc): a caller answers
## anything, and the host answers the 500.
import pf.Host
import AccountCodec
import AuditCodec
import GitHubSignIn
import Principal
import SessionCodec
import SignInWeb
import Stored

Store := [].{

	## Which set a spent nonce is kept in: a state's or a pending sign-up's,
	## each its own (GitHubSignIn: the same nonce is spent once in each).
	Spent : [State, Pending]

	## Every account; none before the first.
	accounts! : {} => Try(List(Principal), [Failed])
	accounts! = |{}| {
		read = Host.read!(accounts_path)
		match read.status {
			Missing => Ok([])
			Failed => Err(Failed)
			Found => AccountCodec.load(read.bytes).map_err(|_| Failed)
		}
	}

	## The settings: `first_admin` (the config's, which the caller reads),
	## the barred ids, and the generation counter (1 before the first
	## account).
	settings! : [Unnamed, Named(Principal.GitHubId)] => Try(GitHubSignIn.Settings, [Failed])
	settings! = |first_admin| {
		settings_read = Host.read!(settings_path)
		next_generation =
			match settings_read.status {
				Missing => Principal.Generation.from_u64(1).map_err(|_| Failed)
				Failed => Err(Failed)
				Found => SignInWeb.settings_next(settings_read.bytes).map_err(|_| Failed)
			}
		barred_read = Host.read!(barred_path)
		barred =
			match barred_read.status {
				Missing => Ok([])
				Failed => Err(Failed)
				Found => SignInWeb.barred(barred_read.bytes).map_err(|_| Failed)
			}
		Ok({ first_admin, barred: barred?, next_generation: next_generation? })
	}

	## Whether `nonce` was spent before, in its set.
	nonce_use! : Store.Spent, List(U8) => Try([FirstUse, UsedBefore], [Failed])
	nonce_use! = |set, nonce| {
		read = Host.read!(spent_path(set, nonce))
		match read.status {
			Missing => Ok(FirstUse)
			Found => Ok(UsedBefore)
			Failed => Err(Failed)
		}
	}

	## `nonce` spent, in its set: a second use is refused from now on.
	spend! : Store.Spent, List(U8) => [Failed, Written]
	spend! = |set, nonce| Host.write!(spent_path(set, nonce), [])

	## The session whose secret hashes to `hash`: its stored line, nothing
	## there, or a line that does not read (`Malformed`, which a caller
	## takes for no session).
	session! : Stored.SecretHash => Try(SessionCodec.Line, [Missing, Malformed, Failed])
	session! = |hash| {
		read = Host.read!(session_path(hash))
		match read.status {
			Failed => Err(Failed)
			Missing => Err(Missing)
			Found => SessionCodec.decode(read.bytes).map_err(|_| Malformed)
		}
	}

	## A session written: started, or its `last seen` touched.
	save_session! : SessionCodec.Fields => [Failed, Written]
	save_session! = |fields| Host.write!(session_path(fields.token_hash), SessionCodec.encode(fields))

	## **A SIGN-IN'S RECORDS, IN ORDER**: the settings (the generation
	## counter first, so no generation is ever given twice), the accounts,
	## then the new session. `Failed` when an account will not encode, or a
	## write fails.
	save_signed_in! : { accounts : List(Principal), settings : GitHubSignIn.Settings, session : SessionCodec.Fields } => [Failed, Written]
	save_signed_in! = |{ accounts, settings, session }|
		match List.map_try(accounts, AccountCodec.encode) {
			Err(_) => Failed
			Ok(lines) =>
				match Host.write!(settings_path, SignInWeb.settings_line(settings.next_generation)) {
					Failed => Failed
					Written =>
						match Host.write!(accounts_path, List.join(lines)) {
							Failed => Failed
							Written => save_session!(session)
						}
				}
		}

	## An audit entry appended. The audit is a record of what happened, not
	## the request's work, so its failure is the host's to log alone.
	audit! : AuditCodec.Entry => {}
	audit! = |entry| {
		_ = Host.append!(audit_path, AuditCodec.encode(entry))
		{}
	}
}

accounts_path : List(U8)
accounts_path = Str.to_utf8("auth/accounts")

settings_path : List(U8)
settings_path = Str.to_utf8("auth/settings")

barred_path : List(U8)
barred_path = Str.to_utf8("auth/barred")

audit_path : List(U8)
audit_path = Str.to_utf8("auth/audit")

## A session's file, named for its secret's hash: found only by one who
## holds the secret, with no compare to time.
session_path : Stored.SecretHash -> List(U8)
session_path = |h| Str.to_utf8("auth/sessions/${Stored.hash_text(h)}")

spent_path : Store.Spent, List(U8) -> List(U8)
spent_path = |set, nonce| {
	kind =
		match set {
			State => "state"
			Pending => "pending"
		}
	List.concat(Str.to_utf8("auth/spent/${kind}/"), SignInWeb.hex(nonce))
}

expect spent_path(State, [0xAB]) == Str.to_utf8("auth/spent/state/ab")
expect spent_path(Pending, [0x01]) == Str.to_utf8("auth/spent/pending/01")
