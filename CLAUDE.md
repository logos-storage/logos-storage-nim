# CLAUDE.md

@README.md

## Usage

- libstorage is the real interface. The [Storage Module](https://github.com/logos-co/logos-storage-module), the other bindings and the [Logos Package Manager](https://github.com/logos-co/logos-package-manager-module) use it.
- The standalone node is not used in the Logos ecosystem.
- The Logos Package Manager only downloads, with advertise off.
- The node runs on desktop only.

## Lifecycle

- A node cannot be started and stopped several times: the libp2p switch does not support it.
- After a stop, the node must be closed. To run again, create a new node.

## HTTP API

- The HTTP API is not public. It is for testing and debugging only.
- One exception: it uploads Logos packages into the Package Downloader Module for [package releases](https://github.com/logos-co/logos-modules-release#releasing-a-module).

## Network

- Bootstrap nodes are Storage nodes. They are also AutoNAT servers and relay servers.
- Bootstrap nodes run with `--nat=extip`. All other nodes run with `--nat=auto`. UPnP and PCP should be rare.
- Storage nodes and Mix proxy nodes are two node types that share the same binary.
- The testnet and the devnet each have 2 Storage nodes and 4 Mix proxy nodes.

## Trust

- Bootstrap nodes and Mix proxy nodes are trusted.
- Other peers are not: treat the manifests and blocks they send as untrusted input.

## Key Development Notes

- **Error handling**: uses `questionable/results` (`?!T`, `?T`) throughout — avoid bare exceptions. The codebase enforces `{.push raises: [].}` broadly.
- **Logging**: uses `chronicles` with runtime filtering. Topics are set per-module via `logScope`. Build with `-d:chronicles_log_level=TRACE` to enable all log levels.
- **Style**: `--styleCheck:error` is enabled — identifiers must match declaration casing exactly.
- **Formatting**: `nph` is the mandatory formatter. Run `make nph/<file>` before committing, or install the pre-commit hook.
- **Chronicles sinks**: configured in `config.nims` as `textlines[dynamic],json[dynamic],textlines[dynamic]`. Adjust runtime behavior with the `CHRONICLES_LOG_LEVEL` env var or `--log-level` CLI flag.
