## A length of time in whole seconds: how long a key lasts, or how far apart
## two `Timestamp`s are. It is `I128` so that the distance between any two
## moments fits, however far apart a token's second and the clock are, and it
## is negative when the later moment comes first.
Seconds :: I128.{

	of : I128 -> Seconds
	of = |count| Seconds.(count)

	to_i128 : Seconds -> I128
	to_i128 = |Seconds.(count)| count

	to_str : Seconds -> Str
	to_str = |Seconds.(count)| count.to_str()

	is_negative : Seconds -> Bool
	is_negative = |Seconds.(count)| count < 0

	is_at_least : Seconds, Seconds -> Bool
	is_at_least = |Seconds.(count), Seconds.(other)| count >= other

	is_more_than : Seconds, Seconds -> Bool
	is_more_than = |Seconds.(count), Seconds.(other)| count > other

	is_eq : _
}

# ── tests
expect Seconds.of(600).to_str() == "600"
expect Seconds.of(-1).to_str() == "-1"
expect Seconds.of(600).to_i128() == 600
expect Seconds.of(-1).is_negative()
expect !Seconds.of(0).is_negative()
expect !Seconds.of(1).is_negative()
expect Seconds.of(5).is_at_least(Seconds.of(4))
expect Seconds.of(5).is_at_least(Seconds.of(5))
expect !Seconds.of(5).is_at_least(Seconds.of(6))
expect Seconds.of(5).is_more_than(Seconds.of(4))
expect !Seconds.of(5).is_more_than(Seconds.of(5))
expect !Seconds.of(5).is_more_than(Seconds.of(6))
expect Seconds.of(5) == Seconds.of(5)
expect !(Seconds.of(5) == Seconds.of(6))
