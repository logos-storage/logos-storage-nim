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

Install Nim 2.2.12, Nimble 0.26.0 or newer, Git, Make, CMake, and a C/C++ toolchain. Native dependency sources are fetched by Nimble; no recursive checkout is needed.

For Nix builds, see [nix/README.md](nix/README.md); for container builds, see [docker/README.md](docker/README.md). CI and containers use the pinned toolchain in `tools/scripts/toolchain-versions.sh`.

From the project root:

```bash
nimble --nimbleDir:./nimbledeps build -d:release
# Or use the Makefile:
make
```

Both commands put the executable in `build/storage`. The Makefile keeps packages in `./nimbledeps`; override this with `NIMBLE_DIR=/absolute/path` if needed. Always pass `--nimbleDir` when invoking Nimble directly to keep this project's packages separate from your account packages.

`storage.nimble` declares compatible dependency ranges and pins revisions where releases are unsuitable. Builds do not require a lockfile, including when Storage is used as a dependency. `make update` resolves the manifest and generates `nimble.paths` for editor/direct compiler use.

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

The client exposes a REST API that can be used to interact with the clients. Overview of the API can be found on [api.codex.storage](https://api.codex.storage).

## Bindings

Logos Storage provides a C API that can be wrapped by other languages. The C API bindings are located in the `library` folder.

Currently, only Go bindings are provided in this repo. However, Rust bindings for Logos Storage can be found at https://github.com/nipsysdev/storage-rust-bindings.

### Build the C library

```bash
make libstorage
# Direct Nimble equivalent:
nimble --nimbleDir:./nimbledeps libstorageDynamic -d:release
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
# Or:
nimble --nimbleDir:./nimbledeps libstorageStatic -d:release
```

### Limitation

Callbacks must be fast and non-blocking; otherwise, the working thread will hang and prevent other requests from being processed.

## Contributing and development

Feel free to dive in, contributions are welcomed! Open an issue or submit PRs.

### Tests

```bash
make test                 # unit tests
make testIntegration      # integration tests
make testLibstorage       # C example and Nim library tests
```

Pass additional compiler options with `NIMFLAGS`, for example `make NIMFLAGS="--parallelBuild:4"`. Use `make USE_LIBBACKTRACE=0` for a debug build without libbacktrace.

### Linting and formatting

`logos-storage-nim` uses [nph](https://github.com/arnetheduck/nph) for formatting our code and it is required to adhere to its styling.
If you are setting up fresh setup, in order to get `nph` run `make build-nph`.
In order to format files run `make nph/<file/folder you want to format>`.
If you want you can install Git pre-commit hook using `make install-nph-hook`, which will format modified files prior committing them.
If you are using VSCode and the [NimLang](https://marketplace.visualstudio.com/items?itemName=NimLang.nimlang) extension you can enable "Format On Save" (eq. the `nim.formatOnSave` property) that will format the files using `nph`.
