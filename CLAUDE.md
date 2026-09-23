# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# First-time setup (initializes nimbus-build-system submodule)
make update && make

# Parallel build (faster)
make -j$(nproc) update && make -j$(nproc)

# Build the storage binary only
make

# Build the C shared/static library
make libstorage           # dynamic (.so/.dylib/.dll)
make STATIC=1 libstorage  # static (.a)

# Format code with nph
make build-nph            # build nph formatter first
make nph/<path>           # format a specific file or folder
make format               # format all nim sources
make install-nph-hook     # install git pre-commit hook for auto-formatting
```

## Test Commands

```bash
# Run unit tests (tests/storage/)
make test

# Run integration tests (spawns real node processes)
make testIntegration

# Run all tests
make testAll

# Run a single test file directly
$(ENV_SCRIPT) nim c -r tests/storage/testblockexchange.nim

# Run C bindings test
make testLibstorage

# Coverage report (requires lcov)
make coverage && make show-coverage
```

## Architecture

**Core node** (`storage/node.nim`): `StorageNode` composes all subsystems — a libp2p `Switch`, `NetworkStore`, `BlockExcEngine`, `Discovery`, `ManifestProtocol`, and `Taskpool`.

**Storage layer** (`storage/stores/`):
- `BlockStore` — abstract base type with virtual methods
- `RepoStore` — persistent LevelDB-backed store
- `CacheStore` — in-memory cache
- `NetworkStore` — wraps a local store with block exchange to fetch from the network

**Block exchange** (`storage/blockexchange/`): BitSwap-inspired protocol with an engine, network layer, and peer tracking. Blocks are identified by CID (Content Identifier).

**Manifest & Merkle tree** (`storage/manifest/`, `storage/merkletree/`): Files are split into chunks, organized in a Merkle tree, and described by a `Manifest`. The manifest CID is the user-facing handle for a stored file.

**REST API** (`storage/rest/`): HTTP API surface. See `openapi.yaml` for the full spec.

**C library bindings** (`library/`): built on [nim-ffi](https://github.com/logos-messaging/nim-ffi). Each entry point is a `{.ffi.}` proc in `library/storage_api/`; `libstorage.nim` imports them and calls `genBindings()`, which writes `library/generated/storage.h` at build time. nim-ffi owns the worker thread, the request queue, the CBOR wire and the event thread. Lifecycle is `storage_ctx_create / storage_ctx_start / storage_ctx_stop / storage_ctx_destroy`. Result callbacks and event listeners must be fast and non-blocking. See `library/README.md`.

**Integration tests** (`tests/integration/`): Tests that spawn actual node processes. `twonodessuite` / `multinodesuite` macros set up N nodes and `StorageClient` (HTTP client) for interacting with them.

**Unit tests** (`tests/storage/`): Auto-discovered by the `importTests` macro — any file named `test*.nim` in that directory is included automatically in `testStorage`.

**Distributed tests** (`https://github.com/logos-storage/logos-storage-nim-cs-dist-tests): Uses Kubernetes to deploy a cluster either locally on Docker Desktop or on Google Cloud Platoform (using .github/workflows/release.yml in the logos-storage-nim repo). 

## Key Development Notes

- **Nim version**: pinned to `v2.2.10` (see `Makefile`). Override with `NIM_COMMIT=<version>`.
- **Memory model**: ORC (`--mm:orc`) for Nim ≥ 2.0, refc for the C library build.
- **Error handling**: uses `questionable/results` (`?!T`, `?T`) throughout — avoid bare exceptions. The codebase enforces `{.push raises: [].}` broadly.
- **Logging**: uses `chronicles` with runtime filtering. Topics are set per-module via `logScope`. Build with `-d:chronicles_log_level=TRACE` to enable all log levels.
- **Style**: `--styleCheck:error` is enabled — identifiers must match declaration casing exactly.
- **Formatting**: `nph` is the mandatory formatter. Run `make nph/<file>` before committing, or install the pre-commit hook.
- **Chronicles sinks**: configured in `config.nims` as `textlines[dynamic],json[dynamic],textlines[dynamic]`. Adjust runtime behavior with the `CHRONICLES_LOG_LEVEL` env var or `--log-level` CLI flag.
