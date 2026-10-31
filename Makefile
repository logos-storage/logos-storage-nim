# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by Make

# Run `nimble setup -l` first: it installs the dependencies in nimbledeps/.
NIM_PARAMS := $(NIMFLAGS)
BUILD_MSG := "Building:"
FORMAT_MSG := "Formatting:"

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

.PHONY: \
	all \
	clean \
	coverage \
	test \
	testAll \
	testIntegration \
	testLibstorageC \
	testLibstorage \
	buildNatImage \
	testNatIntegration

# default target, because it's the first one that doesn't start with '.'

# Builds the Logos Storage binary
all: | build
	echo -e $(BUILD_MSG) "build/$@" && \
		nim storage $(NIM_PARAMS) build.nims

mix-tools: | build
	echo -e $(BUILD_MSG) "build/mix_pool build/mix_relay_dht" && \
		nim mixTools $(NIM_PARAMS) build.nims

build:
	mkdir -p build

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

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
		nim test $(NIM_PARAMS) build.nims

# Builds and runs the integration tests
testIntegration: | build
	echo -e $(BUILD_MSG) "build/$@" && \
		nim testIntegration $(TEST_PARAMS) $(NIM_PARAMS) build.nims

DOCKER := $(or $(shell which podman 2>/dev/null), $(shell which docker 2>/dev/null))

# NAT real-topology scenarios (podman-compose), all sharing one image built here.
# Runs every scenario; limit it with STORAGE_INTEGRATION_TEST_INCLUDES (test file
# paths), as testIntegration does.
buildNatImage:
	$(DOCKER) build -t localhost/storage-nat -f tests/integration/nat/Dockerfile .

testNatIntegration: | buildNatImage
	nim testNatIntegration $(NIM_PARAMS) build.nims

BOOTSTRAP_HEALTH_CHECK_PARAMS :=
ifdef CI
	BOOTSTRAP_HEALTH_CHECK_PARAMS := $(BOOTSTRAP_HEALTH_CHECK_PARAMS) -d:ci=$(CI)
endif

checkSpr: | build
	echo -e $(BUILD_MSG) "build/check_spr" && \
		nim checkSpr $(NIM_PARAMS) build.nims

# Pings the fleet bootstrap nodes and fails if any are unreachable.
# Run from OUTSIDE the fleet VPCs (e.g. a GitHub-hosted runner) so nodes that
# advertise private/cloud-internal IPs are correctly seen as unreachable.
bootstrapHealthCheck: | build
	echo -e $(BUILD_MSG) "build/check_spr" && \
		nim bootstrapHealthCheck $(NIM_PARAMS) $(BOOTSTRAP_HEALTH_CHECK_PARAMS) build.nims

# The generated header decodes the CBOR wire with TinyCBOR, which nim-ffi vendors.
FFI_DIR = $(firstword $(wildcard $(CURDIR)/nimbledeps/pkgs2/ffi-*))
TINYCBOR_DIR = $(FFI_DIR)/ffi/codegen/templates/cpp/vendor
TINYCBOR_SRCS := $(TINYCBOR_DIR)/tinycbor/cborencoder.c \
	$(TINYCBOR_DIR)/tinycbor/cborencoder_close_container_checked.c \
	$(TINYCBOR_DIR)/tinycbor/cborparser.c \
	$(TINYCBOR_DIR)/tinycbor/cborparser_dup_string.c \
	$(TINYCBOR_DIR)/tinycbor/cborerrorstrings.c
CBINDINGS_CFLAGS := -I$(TINYCBOR_DIR) -I$(TINYCBOR_DIR)/tinycbor

# Builds a C example that uses the libstorage C library and runs it
testLibstorageC: | build
	$(MAKE) $(if $(ncpu),-j$(ncpu),) libstorage
	cd tests/cbindings && \
	if [ "$(detected_OS)" = "Windows" ]; then \
		gcc -o storage.exe storage.c $(TINYCBOR_SRCS) $(CBINDINGS_CFLAGS) -L../../build -lstorage -pthread && \
		PATH=../../build:$$PATH ./storage.exe; \
	else \
		gcc -o storage storage.c $(TINYCBOR_SRCS) $(CBINDINGS_CFLAGS) -L../../build -lstorage -Wl,-rpath,$(CURDIR)/build -pthread && \
		./storage; \
	fi

testLibstorage: | testLibstorageC
	echo -e $(BUILD_MSG) "build/$@" && \
		nim testLibstorage $(TEST_PARAMS) $(NIM_PARAMS) build.nims

# Builds and runs all tests
testAll: | build
	echo -e $(BUILD_MSG) "build/$@" && \
		nim testAll $(NIM_PARAMS) build.nims
	$(MAKE) $(if $(ncpu),-j$(ncpu),) testLibstorage

coverage: build
	echo -e $(BUILD_MSG) "build/$@" && \
		nim coverage $(NIM_PARAMS) build.nims
	echo "Run `make show-coverage` to view coverage results"

show-coverage:
	if which open >/dev/null; then (echo -e "\e[92mOpening\e[39m HTML coverage report in browser..." && open coverage/report/index.html) || true; fi

# usual cleaning
clean:
	rm -rf build

############
## Format ##
############
.PHONY: build-nph install-nph-hook clean-nph print-nph-path

NPH_VERSION := 0.7.0
NPH := build/nph/bin/nph

# Runs from build/: in the project folder, Nimble would resolve storage.nimble.
build-nph: | build
ifeq ("$(wildcard $(NPH))","")
	cd build && \
	nimble install -y --nimbleDir:nph nph@$(NPH_VERSION) && \
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
	rm -f build/libstorage*

ifeq ($(STATIC), 1)
		echo -e $(BUILD_MSG) "build/$@.a" && \
		nim libstorageStatic $(NIM_PARAMS) build.nims
else ifeq ($(detected_OS),Windows)
		echo -e $(BUILD_MSG) "build/$@.dll" && \
		nim libstorageDynamic $(NIM_PARAMS) build.nims
else ifeq ($(detected_OS),macOS)
		echo -e $(BUILD_MSG) "build/$@.dylib" && \
		nim libstorageDynamic $(NIM_PARAMS) build.nims
else
		echo -e $(BUILD_MSG) "build/$@.so" && \
		nim libstorageDynamic $(NIM_PARAMS) build.nims
endif
