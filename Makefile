# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# This is the Nim version used locally and in regular CI builds.
# Can be a specific version tag, a branch name, or a commit hash.
# Can be overridden by setting the NIM_COMMIT environment variable
# before calling make.
#
# For readability in CI, if NIM_COMMIT is set to "pinned",
# this will also default to the version pinned here.
#
# If NIM_COMMIT is set to "nimbusbuild", this will use the
# version pinned by nimbus-build-system.
PINNED_NIM_VERSION := v2.2.10

ifeq ($(NIM_COMMIT),)
NIM_COMMIT := $(PINNED_NIM_VERSION)
else ifeq ($(NIM_COMMIT),pinned)
NIM_COMMIT := $(PINNED_NIM_VERSION)
endif

ifeq ($(NIM_COMMIT),nimbusbuild)
undefine NIM_COMMIT
else
export NIM_COMMIT
endif

SHELL := bash # the shell used internally by Make

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_IMAGE_NIM_PARAMS ?= -d:chronicles_colors:none -d:insecure

LINK_PCRE := 0

ifeq ($(OS),Windows_NT)
    ifeq ($(PROCESSOR_ARCHITECTURE), AMD64)
        ARCH = x86_64
    endif
    ifeq ($(PROCESSOR_ARCHITECTURE), ARM64)
        ARCH = arm64
    endif
else
    UNAME_P := $(shell uname -m)
    ifneq ($(filter $(UNAME_P), i686 i386 x86_64),)
        ARCH = x86_64
    endif
    ifneq ($(filter $(UNAME_P), aarch64 arm),)
        ARCH = arm64
    endif
endif

ifeq ($(ARCH), x86_64)
    CXXFLAGS ?= -std=c++17 -mssse3
else
    CXXFLAGS ?= -std=c++17
endif
export CXXFLAGS

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

.PHONY: \
	all \
	clean \
	coverage \
	deps \
	test \
	testAll \
	testIntegration \
	testLibstorageC \
	testLibstorage \
	buildNatImage \
	testNatIntegration \
	updatePresetFile \
	presets \
	update

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'

# Builds the Logos Storage binary
all: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim storage $(NIM_PARAMS) build.nims

mix-tools: | build deps
	echo -e $(BUILD_MSG) "build/mix_pool build/mix_relay_dht" && \
		$(ENV_SCRIPT) nim mixTools $(NIM_PARAMS) build.nims

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs

update: | update-common

# detecting the os
ifeq ($(OS),Windows_NT) # is Windows_NT on XP, 2000, 7, Vista, 10...
 detected_OS := Windows
else ifeq ($(strip $(shell uname)),Darwin)
 detected_OS := macOS
else
 # e.g. Linux
 detected_OS := $(strip $(shell uname))
endif

# Builds and run a part of the test suite
test: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim test $(NIM_PARAMS) build.nims

# Builds and runs the integration tests
testIntegration: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testIntegration $(TEST_PARAMS) $(NIM_PARAMS) build.nims

DOCKER := $(or $(shell which podman 2>/dev/null), $(shell which docker 2>/dev/null))

# NAT real-topology scenarios (podman-compose), all sharing one image built here.
# Runs every scenario; limit it with STORAGE_INTEGRATION_TEST_INCLUDES (test file
# paths), as testIntegration does.
buildNatImage:
	$(DOCKER) build -t localhost/storage-nat -f tests/integration/nat/Dockerfile .

testNatIntegration: | deps buildNatImage
	$(ENV_SCRIPT) nim testNatIntegration $(NIM_PARAMS) build.nims

BOOTSTRAP_HEALTH_CHECK_PARAMS :=
ifdef CI
	BOOTSTRAP_HEALTH_CHECK_PARAMS := $(BOOTSTRAP_HEALTH_CHECK_PARAMS) -d:ci=$(CI)
endif

checkSpr: | build deps
	echo -e $(BUILD_MSG) "build/check_spr" && \
		$(ENV_SCRIPT) nim checkSpr $(NIM_PARAMS) build.nims

# Pings the preset bootstrap nodes and fails if any are unreachable.
# Run from OUTSIDE the fleet VPCs (e.g. a GitHub-hosted runner) so nodes that
# advertise private/cloud-internal IPs are correctly seen as unreachable.
bootstrapHealthCheck: | build deps
	echo -e $(BUILD_MSG) "build/check_spr" && \
		$(ENV_SCRIPT) nim bootstrapHealthCheck $(NIM_PARAMS) $(BOOTSTRAP_HEALTH_CHECK_PARAMS) build.nims

# Builds a C example that uses the libstorage C library and runs it
testLibstorageC: | build deps
	$(MAKE) $(if $(ncpu),-j$(ncpu),) libstorage
	cd tests/cbindings && \
	if [ "$(detected_OS)" = "Windows" ]; then \
		gcc -o storage.exe storage.c -L../../build -lstorage -pthread && \
		PATH=../../build:$$PATH ./storage.exe; \
	else \
		gcc -o storage storage.c -L../../build -lstorage -Wl,-rpath,../../ -pthread && \
		LD_LIBRARY_PATH=../../build ./storage; \
	fi

testLibstorage: | testLibstorageC
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testLibstorage $(TEST_PARAMS) $(NIM_PARAMS) build.nims

# Builds and runs all tests
testAll: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testAll $(NIM_PARAMS) build.nims
	$(MAKE) $(if $(ncpu),-j$(ncpu),) testLibstorage

coverage:
	$(MAKE) NIMFLAGS="$(NIMFLAGS) --lineDir:on --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs --passL:-ftest-coverage" test
	cd nimcache/release/testStorage && rm -f *.c
	mkdir -p coverage
	lcov --capture --keep-going --directory nimcache/release/testStorage --output-file coverage/coverage.info
	shopt -s globstar && ls $$(pwd)/storage/{*,**/*}.nim
	shopt -s globstar && lcov --extract coverage/coverage.info --keep-going $$(pwd)/storage/{*,**/*}.nim --output-file coverage/coverage.f.info
	echo -e $(BUILD_MSG) "coverage/report/index.html"
	genhtml coverage/coverage.f.info --keep-going --output-directory coverage/report

show-coverage:
	if which open >/dev/null; then (echo -e "\e[92mOpening\e[39m HTML coverage report in browser..." && open coverage/report/index.html) || true; fi

coverage-script: build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim coverage $(NIM_PARAMS) build.nims
	echo "Run `make show-coverage` to view coverage results"

# usual cleaning
clean: | clean-common
	rm -rf build

############
## Format ##
############
.PHONY: build-nph install-nph-hook clean-nph print-nph-path

# Default location for nph binary shall be next to nim binary to make it available on the path.
NPH:=$(shell dirname $(NIM_BINARY))/nph

build-nph:
ifeq ("$(wildcard $(NPH))","")
	cd vendor/nph && \
	nimble setup -l && \
	nimble build -d:disable_libbacktrace && \
	mv ./nph ../../$(shell dirname $(NPH)) && \
	echo "nph utility is available at " $(NPH)
endif

GIT_PRE_COMMIT_HOOK := .git/hooks/pre-commit

install-nph-hook: build-nph
ifeq ("$(wildcard $(GIT_PRE_COMMIT_HOOK))","")
	cp ./tools/scripts/git_pre_commit_format.sh $(GIT_PRE_COMMIT_HOOK)
else
	echo "$(GIT_PRE_COMMIT_HOOK) already present, will NOT override"
	exit 1
endif

nph/%: build-nph
	echo -e $(FORMAT_MSG) "nph/$*" && \
		$(NPH) $*

format:
	$(NPH) *.nim
	$(NPH) storage/
	$(NPH) tests/
	$(NPH) library/

clean-nph:
	rm -f $(NPH)

# To avoid hardcoding nph binary location in several places
print-nph-path:
	echo "$(NPH)"

clean: | clean-nph

################
## C Bindings ##
################
.PHONY: libstorage

STATIC ?= 0

ifneq ($(strip $(STORAGE_LIB_PARAMS)),)
NIM_PARAMS := $(NIM_PARAMS) $(STORAGE_LIB_PARAMS)
endif

libstorage:
	$(MAKE) deps
	rm -f build/libstorage*

ifeq ($(STATIC), 1)
		echo -e $(BUILD_MSG) "build/$@.a" && \
		$(ENV_SCRIPT) nim libstorageStatic $(NIM_PARAMS) storage.nims
else ifeq ($(detected_OS),Windows)
		echo -e $(BUILD_MSG) "build/$@.dll" && \
		$(ENV_SCRIPT) nim libstorageDynamic $(NIM_PARAMS) storage.nims
else ifeq ($(detected_OS),macOS)
		echo -e $(BUILD_MSG) "build/$@.dylib" && \
		$(ENV_SCRIPT) nim libstorageDynamic $(NIM_PARAMS) storage.nims
else
		echo -e $(BUILD_MSG) "build/$@.so" && \
		$(ENV_SCRIPT) nim libstorageDynamic $(NIM_PARAMS) storage.nims
endif
endif # "variables.mk" was not includedMa
################
## Presets    ##
################

updatePresetFile:
	bash ./tools/scripts/storage-config.sh presets > network_presets.json

presets: updatePresetFile bootstrapHealthCheck
