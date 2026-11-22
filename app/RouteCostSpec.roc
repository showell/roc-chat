## These are the tests of `RouteCost`: each probe of
## app/route_cost_probes.txt, which `zig build cost-check` measures at two
## sizes of chat, routes to a route whose class is the one its line names,
## so the measured class and the declared one are held to one file.
import "route_cost_probes.txt" as probes_text : Str
import FirstStart
import Route
import RouteCost

RouteCostSpec :: [].{}

## The probes' lines, each a class, who asks, a method, a path, and for a
## POST its form; comments and blank lines left out.
probe_lines : List(Str)
probe_lines = probes_text.split_on("\n").keep_if(|line| !line.is_empty() and !line.starts_with("#"))

## A probe's line, and the class its route declares in the first start's
## directory, its path read up to any `?` as the host splits it.
declared_class : Str -> { named : Str, declared : Str }
declared_class = |line|
	match line.split_on(" ") {
		[named, _, method, path_and_query, ..] => {
			path =
				match path_and_query.split_on("?") {
					[before, ..] => before
					[] => path_and_query
				}
			choice = Route.choose({
				method: method.to_utf8(),
				path: path.to_utf8(),
				directory: FirstStart.first_directory,
			})
			{ named, declared: RouteCost.class_name(RouteCost.class_of(choice)) }
		}
		_ => crash "RouteCostSpec.declared_class: a probe is a class, who asks, a method and a path"
	}

# Every probe's route declares the class its line names, and there are
# probes of every class.
expect probe_lines.all(|line| declared_class(line).named == declared_class(line).declared)
expect
	["Constant", "PerReaderPlaces", "PerHuman"].all(
		|class| probe_lines.any(|line| declared_class(line).named == class),
	)
