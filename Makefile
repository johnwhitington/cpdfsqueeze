# Build the cpdf command line tools and top level
SOURCES = cpdfsqueeze.ml

RESULT = cpdfsqueeze
ANNOTATE = true
PACKS = camlpdf

OCAMLFLAGS = -bin-annot
OCAMLNCFLAGS = -g -safe-string -w -3
OCAMLBCFLAGS = -g -safe-string -w -3
OCAMLLDFLAGS = -g

all : native-code top

clean ::
	rm -rf doc foo foo2 out.pdf out2.pdf *.cmt *.cmti

-include OCamlMakefile

