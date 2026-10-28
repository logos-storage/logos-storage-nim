# Logos Storage Filesharing Client

> The Logos Storage project aims to create a filesharing client that allows sharing data privately in p2p networks.

> WARNING: This project is under active development and is considered pre-alpha.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)
[![CI](https://github.com/logos-storage/logos-storage-nim/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/logos-storage/logos-storage-nim/actions/workflows/ci.yml?query=branch%3Amaster)
[![Docker](https://github.com/logos-storage/logos-storage-nim/actions/workflows/docker.yml/badge.svg?branch=master)](https://github.com/logos-storage/logos-storage-nim/actions/workflows/docker.yml?query=branch%3Amaster)
[![Codecov](https://codecov.io/gh/logos-storage/logos-storage-nim/branch/master/graph/badge.svg?token=XFmCyPSNzW)](https://codecov.io/gh/logos-storage/logos-storage-nim)
[![Discord](https://img.shields.io/discord/895609329053474826)](https://discord.gg/CaJTh24ddQ)
![Docker Pulls](https://img.shields.io/docker/pulls/logosstorage/logos-storage-nim)


## Build and Run

To build the project, clone it and run:

```bash
make update && make
# Tip: use -j{ncpu} to for parallel execution, eg:
# make -j12 update && make -j12
```

The executable will be placed under the `build` directory under the project root.

Run the client with:

```bash
build/storage
```

## Configuration

It is possible to configure a Logos Storage node in several ways:
 1. CLI options
 2. Environment variables
 3. Configuration file

The order of priority is the same as above: CLI options --> Environment variables --> Configuration file.

Please check `build/storage --help` for more information.

## API

The node exposes an HTTP API for testing and debugging only. It is not a public API: applications use the C library, see [Bindings](#bindings).

One exception: the HTTP API uploads Logos packages into the Package Downloader Module for [package releases](https://github.com/logos-co/logos-modules-release#releasing-a-module).

The OpenAPI spec is in [openapi.yaml](openapi.yaml).

## Bindings

Logos Storage provides a C API that can be wrapped by other languages. The C API bindings are located in the `library` folder.

Currently, only Go bindings are provided in this repo. However, Rust bindings for Logos Storage can be found at https://github.com/nipsysdev/storage-rust-bindings.

### Build the C library

```bash
make libstorage
```

This produces the shared library under `build/`.

### Run the Go example

See https://github.com/logos-storage/logos-storage-go-bindings-example.

### Static vs Dynamic build

By default, Logos Storage builds a dynamic library (`libstorage.so`/`libstorage.dylib`/`libstorage.dll`), which you can load at runtime.

If you prefer a static library (`libstorage.a`), set the `STATIC` flag:

```bash
# Build dynamic (default)
make libstorage

# Build static
make STATIC=1 libstorage
```

### Limitation

Callbacks must be fast and non-blocking; otherwise, the working thread will hang and prevent other requests from being processed.

## Test Commands

```bash
# Run unit tests (tests/storage/)
make test

# Run integration tests (spawns real node processes)
make testIntegration

# Run one integration test file (path from tests/)
STORAGE_INTEGRATION_TEST_INCLUDES="integration/5_minutes/testrestapivalidation.nim" \
  ./env.sh nim testIntegration build.nims

# Keep the node logs, in tests/integration/logs/
STORAGE_INTEGRATION_TEST_INCLUDES="integration/5_minutes/testrestapivalidation.nim" \
  ./env.sh nim testIntegration -d:StorageLogToFile=true build.nims

# Run all tests
make testAll

# Run a single test file directly
./env.sh nim c -r tests/storage/testblockexchange.nim

# Run C bindings test
make testLibstorage

# Coverage report (requires lcov)
make coverage && make show-coverage
```

## Contributing and development

Feel free to dive in, contributions are welcomed! Open an issue or submit PRs.

### Linting and formatting

`logos-storage-nim` uses [nph](https://github.com/arnetheduck/nph) for formatting our code and it is required to adhere to its styling.
If you are setting up fresh setup, in order to get `nph` run `make build-nph`.
In order to format files run `make nph/<file/folder you want to format>`.
If you want you can install Git pre-commit hook using `make install-nph-hook`, which will format modified files prior committing them.
If you are using VSCode and the [NimLang](https://marketplace.visualstudio.com/items?itemName=NimLang.nimlang) extension you can enable "Format On Save" (eq. the `nim.formatOnSave` property) that will format the files using `nph`.
