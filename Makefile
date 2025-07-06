#-*- mode: makefile; -*-

SHELL := /bin/bash
.SHELLFLAGS := -ec

MODULE_NAME := DocConverter
MODULE_PATH := $(subst ::,/,$(MODULE_NAME)).pm

DAEMON_NAME := DocConverter::Daemon
DAEMON_PATH := $(subst ::,/,$(DAEMON_NAME)).pm

CONSTANTS = \
    lib/DocConverter/Constants.pm.in

GCONSTANTS = $(CONSTANTS:.pm.in=.pm)

PERL_MODULES = \
    lib/$(MODULE_PATH).in \
    lib/DocConverter/Utils.pm.in \
    lib/DocConverter/Authorize.pm.in \
    lib/DocConverter/Daemon.pm.in

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

DAEMON = $(subst ::,-,$(DAEMON_NAME))-$(VERSION).tar.gz

all: $(TARBALL)

GPERL_MODULES = $(PERL_MODULES:.pm.in=.pm)

$(GROLES): $(GCONSTANTS)

$(GCLIENT): $(GCONSTANTS) $(GROLES)

$(GHANDLER): $(GROLES) $(GPERL_MODULES)

%.pm: %.pm.in
	rm -f $@
	sed "s/[@]PACKAGE_VERSION[@]/$(VERSION)/g" $< > $@
	perl -wc -I lib $@
	chmod -w $@

$(GPERL_MODULES): $(GCONSTANTS) $(PERL_MODULES)

DAEMON_DEPS = \
    $(GPERL_MODULES) \
    $(GHANDLER) \
    $(GCLIENT) \
    start-server \
    daemon.req \
    test-requires \
    postamble-daemon \
    README.md

TARBALL_DEPS = \
    $(GPERL_MODULES) \
    $(GHANDLER) \
    $(GCLIENT) \
    $(GMOD_PERL_HANDLER) \
    start-server \
    requires \
    test-requires \
    postamble-server \
    README.md

.PHONY: daemon
daemon: $(DAEMON)

$(DAEMON): buildspec-daemon.yml $(DAEMON_DEPS)
	cp postamble-daemon postamble
	make-cpan-dist.pl -b $<

$(TARBALL): buildspec.yml $(TARBALL_DEPS)
	cp postamble-server postamble
	make-cpan-dist.pl -b $<

README.md: lib/$(MODULE_PATH)
	pod2markdown $< > $@

clean:
	find lib -name '*.pm' -exec rm -f {} \;
	rm -f *.tar.gz
	rm -f provides extra-files resources

DAEMON_IMAGE_NAME := doc-converter-daemon
DAEMON_IMAGE_ID_FILE := $(DAEMON_IMAGE_NAME).dockerid

IMAGE_NAME     := doc-converter
IMAGE_ID_FILE  := $(IMAGE_NAME).dockerid

.PHONY: image docker-clean daemon-image

daemon-image: $(DAEMON_IMAGE_ID_FILE)

$(DAEMON_IMAGE_ID_FILE): Dockerfile.daemon $(DAEMON)
	@if [ -e "$(DAEMON_IMAGE_ID_FILE)" ]; then \
	  oldid=$$(cut -d: -f2 "$(DAEMON_IMAGE_ID_FILE)"); \
	else \
	  oldid=""; \
	fi; \
	docker build -f $< -t $(DAEMON_IMAGE_NAME) .; \
	docker image inspect $(DAEMON_IMAGE_NAME) | jq -r '.[0].Id' > "$@"; \
	newid=$$(cut -d: -f2 "$@"); \
	if [ -n "$$oldid" ] && [ "$$oldid" != "$$newid" ]; then \
	  docker rmi "$$oldid" || true; \
	fi

image: $(IMAGE_ID_FILE)

$(IMAGE_ID_FILE): Dockerfile $(TARBALL)
	@if [ -e "$(IMAGE_ID_FILE)" ]; then \
	  oldid=$$(cut -d: -f2 "$(IMAGE_ID_FILE)"); \
	else \
	  oldid=""; \
	fi; \
	docker build -f $< -t $(IMAGE_NAME) .; \
	docker image inspect $(IMAGE_NAME) | jq -r '.[0].Id' > "$@"; \
	newid=$$(cut -d: -f2 "$@"); \
	if [ -n "$$oldid" ] && [ "$$oldid" != "$$newid" ]; then \
	  docker rmi "$$oldid" || true; \
	fi

docker-clean:
	rm -f $(IMAGE_ID_FILE)

include version.mk
