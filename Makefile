#-*- mode: makefile; -*-

SHELL := /bin/bash
.SHELLFLAGS := -ec

MODULE_NAME := DocConverter
MODULE_PATH := $(subst ::,/,$(MODULE_NAME)).pm

PERL_MODULES = \
    lib/$(MODULE_PATH).in \
    lib/DocConverter/Utils.pm.in \
    lib/DocConverter/Constants.pm.in

VERSION := $(shell cat VERSION)

TARBALL = $(subst ::,-,$(MODULE_NAME))-$(VERSION).tar.gz

all: $(TARBALL)


GPERL_MODULES = $(PERL_MODULES:.pm.in=.pm)

%.pm: %.pm.in
	sed "s/[@]PACKAGE_VERSION[@]/$(VERSION)/g" $< > $@

$(GPERL_MODULES): $(PERL_MODULES)

$(TARBALL): buildspec.yml $(GPERL_MODULES) requires test-requires README.md
	make-cpan-dist.pl -b $<

README.md: lib/$(MODULE_PATH)
	pod2markdown $< > $@

clean:
	rm -f *.tar.gz
	rm -f provides extra-files resources
