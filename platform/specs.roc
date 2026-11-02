## **THE SPECS' PLATFORM**: what `app/Specs.roc` names, so the specs are an
## app of their own. An app is what `roc test` runs without `--main` and
## what Roc's checker (roc-types, behind shale's typed lints) reads; a type
## module it reaches only through one. It asks for a `Str` and hands it to
## no host: the specs are run by `roc test`, never built.
##
## The server's platform is platform/main.roc.
platform ""
	requires {
		main : Str
	}
	exposes []
	packages {}
	provides { "specs_main": main_for_host }

main_for_host : Str
main_for_host = main
