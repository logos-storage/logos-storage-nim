# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash
.DEFAULT_GOAL := all

# Keep installed packages and tools separate from account-wide packages.
NIMBLE ?= nimble
NIMBLE_DIR ?= $(CURDIR)/nimbledeps
export NIMBLE_DIR
NIMBLE_FLAGS ?=
NIMBLE_CMD = $(NIMBLE) --nimbleDir:"$(NIMBLE_DIR)" --accept $(NIMBLE_FLAGS)
NIM_PARAMS = $(NIMFLAGS)
BUILD_MSG := "Building"
FORMAT_MSG := "Formatting"

# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_IMAGE_NIM_PARAMS ?= -d:chronicles_colors:none -d:insecure

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

.PHONY: all deps update clean test testAll testIntegration testLibstorage \
 testLibstorageC testNatIntegration mix-tools checkSpr bootstrapHealthCheck \
 coverage coverage-script show-coverage format buildNatImage updatePresetFile presets

all: | build
	$(NIMBLE_CMD) build $(NIM_PARAMS)

mix-tools: | build
	$(NIMBLE_CMD) mixTools $(NIM_PARAMS)

build:
	mkdir -p build

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS += -d:debug -d:disable_libbacktrace
else
NIM_PARAMS += -d:release
endif

deps:
	$(NIMBLE_CMD) setup

# Resolve the manifest and generate dependency paths for editor/compiler use.
update: deps

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
test: | build
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE_CMD) test $(NIM_PARAMS)

# Builds and runs the integration tests
testIntegration: | build
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE_CMD) testIntegration $(TEST_PARAMS) $(NIM_PARAMS)

DOCKER := $(or $(shell which podman 2>/dev/null), $(shell which docker 2>/dev/null))

# NAT real-topology scenarios (podman-compose), all sharing one image built here.
# Runs every scenario; limit it with STORAGE_INTEGRATION_TEST_INCLUDES (test file
# paths), as testIntegration does.
buildNatImage:
	$(DOCKER) build -t localhost/storage-nat -f tests/integration/nat/Dockerfile .

testNatIntegration: | deps buildNatImage
	$(NIMBLE_CMD) testNatIntegration $(NIM_PARAMS)

BOOTSTRAP_HEALTH_CHECK_PARAMS :=
ifdef CI
	BOOTSTRAP_HEALTH_CHECK_PARAMS := $(BOOTSTRAP_HEALTH_CHECK_PARAMS) -d:ci=$(CI)
endif

checkSpr: | build
	echo -e $(BUILD_MSG) "build/check_spr" && \
		$(NIMBLE_CMD) checkSpr $(NIM_PARAMS)

# Pings the preset bootstrap nodes and fails if any are unreachable.
# Run from OUTSIDE the fleet VPCs (e.g. a GitHub-hosted runner) so nodes that
# advertise private/cloud-internal IPs are correctly seen as unreachable.
bootstrapHealthCheck: | build
	echo -e $(BUILD_MSG) "build/check_spr" && \
		$(NIMBLE_CMD) bootstrapHealthCheck $(NIM_PARAMS) $(BOOTSTRAP_HEALTH_CHECK_PARAMS)

# Builds a C example that uses the libstorage C library and runs it
testLibstorageC: | build
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
		$(NIMBLE_CMD) testLibstorage $(TEST_PARAMS) $(NIM_PARAMS)

# Builds and runs all tests
testAll: | build
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE_CMD) testAll $(NIM_PARAMS)
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
		$(NIMBLE_CMD) coverage $(NIM_PARAMS)
	echo "Run `make show-coverage` to view coverage results"

# usual cleaning
clean:
	rm -rf build nimcache

############
## Format ##
############
.PHONY: build-nph install-nph-hook clean-nph print-nph-path

# Resolve formatter dependencies separately from Storage's dependency graph.
NPH_DIR := $(abspath $(NIMBLE_DIR))/tools
NPH := $(NPH_DIR)/bin/nph

build-nph:
	mkdir -p "$(NPH_DIR)"
	cd "$(NPH_DIR)" && $(NIMBLE) --nimbleDir:"$(NPH_DIR)" --accept $(NIMBLE_FLAGS) install "nph@>=0.7.0 & <0.8.0"

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
		"$(NPH)" $*

format: build-nph
	"$(NPH)" *.nim
	"$(NPH)" storage/
	"$(NPH)" tests/
	"$(NPH)" library/

clean-nph:
	rm -f "$(NPH)"

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
NIM_PARAMS += $(STORAGE_LIB_PARAMS)
endif

libstorage: | build
	rm -f build/libstorage*

ifeq ($(STATIC), 1)
		echo -e $(BUILD_MSG) "build/$@.a" && \
		$(NIMBLE_CMD) libstorageStatic $(NIM_PARAMS)
else ifeq ($(detected_OS),Windows)
		echo -e $(BUILD_MSG) "build/$@.dll" && \
		$(NIMBLE_CMD) libstorageDynamic $(NIM_PARAMS)
else ifeq ($(detected_OS),macOS)
		echo -e $(BUILD_MSG) "build/$@.dylib" && \
		$(NIMBLE_CMD) libstorageDynamic $(NIM_PARAMS)
else
		echo -e $(BUILD_MSG) "build/$@.so" && \
		$(NIMBLE_CMD) libstorageDynamic $(NIM_PARAMS)
endif
################
## Presets    ##
################

updatePresetFile:
	bash ./tools/scripts/storage-config.sh presets > network_presets.json

presets: updatePresetFile bootstrapHealthCheck
