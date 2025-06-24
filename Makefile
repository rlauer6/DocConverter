#-*- mode: makefile; -*-

SHELL := /bin/bash
.SHELLFLAGS := -ec

MODULE_NAME := DocConverter
MODULE_PATH := $(subst ::,/,$(MODULE_NAME)).pm

CONSTANTS = \
    lib/DocConverter/Constants.pm.in

GCONSTANTS = $(CONSTANTS:.pm.in=.pm)

PERL_MODULES = \
    lib/$(MODULE_PATH).in \
    lib/DocConverter/Utils.pm.in \

CLIENT = \
    lib/DocConverter/Client.pm.in

GCLIENT = $(CLIENT:.pm.in=.pm)

MOD_PERL_HANDLER = \
    lib/DocConverter/Handler.pm.in

GMOD_PERL_HANDLER = $(MOD_PERL_HANDLER:.pm.in=.pm)

HANDLER = \
    lib/SQS/Queue/Worker/DocConverter.pm.in

GHANDLER = $(HANDLER:.pm.in=.pm)

ROLES = \
    lib/DocConverter/Role/S3.pm.in \
    lib/DocConverter/Role/SQS.pm.in \
    lib/DocConverter/Role/Helpers.pm.in \

GROLES = $(ROLES:.pm.in=.pm)

VERSION := $(shell cat VERSION)

TARBALL = $(subst ::,-,$(MODULE_NAME))-$(VERSION).tar.gz

all: $(TARBALL)

GPERL_MODULES = $(PERL_MODULES:.pm.in=.pm)

$(GROLES): $(GCONSTANTS)

$(GCLIENT): $(GCONSTANTS) $(GROLES)

$(GHANDLER): $(GROLES) $(GPERL_MODULES)

%.pm: %.pm.in
	sed "s/[@]PACKAGE_VERSION[@]/$(VERSION)/g" $< > $@
	perl -wc -I lib $@

$(GPERL_MODULES): $(GCONSTANTS) $(PERL_MODULES)

$(TARBALL): buildspec.yml $(GPERL_MODULES) $(GHANDLER) $(GCLIENT) $(GMOD_PERL_HANDLER) requires test-requires README.md
	make-cpan-dist.pl -b $<

README.md: lib/$(MODULE_PATH)
	pod2markdown $< > $@

clean:
	find lib -name '*.pm' -exec rm {} \;
	rm -f *.tar.gz
	rm -f provides extra-files resources

.PHONY: version
version:
	if [[ "$$bump" = "release" ]]; then \
	  bump=2; \
	elif [[ "$$bump" = "minor" ]]; then \
	  bump=1; \
	elif [[ "$$bump" = "major" ]]; then \
	  bump=0; \
	fi; \
	v=$$(echo $${bump}.$$(cat VERSION) | \
	  perl -a -F[.] -pe '$$i=shift @F;$$F[$$i]++;$$j=$$i+1;$$F[$$_]=0 for $$j..2;$$"=".";$$_="@F"'); \
	echo $$v >VERSION;

release:
	$(MAKE) version bump=release

minor:
	$(MAKE) version bump=minor

major:
	$(MAKE) version bump=major
