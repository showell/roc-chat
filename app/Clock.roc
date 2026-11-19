## This module reads the host's clock. It is the one place the app asks the
## host what time it is, so every route, sign-in and stream that needs the
## moment gets it the same way, as a `Timestamp`.
import pf.Host
import Timestamp

Clock :: [].{

	## The moment the host's clock says it is.
	read_clock! : {} => Timestamp
	read_clock! = |{}| Timestamp.at_second(Host.current_utc_seconds_since_epoch!({}))
}
