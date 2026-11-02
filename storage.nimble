version = "0.5.3"
author = "Logos Storage Team"
description = "privacy-preserving p2p file sharing"
license = "MIT"
binDir = "build"
srcDir = "."
installDirs = @["storage", "library"]
installFiles = @[
  "storage.nim", "build.nims", "config.nims", "network_presets.json",
  "LICENSE-APACHEv2", "LICENSE-MIT",
]

# Older Nimble versions cannot resolve these dependencies.
when (NimbleMajor, NimbleMinor) < (0, 26):
  {.error: "storage needs Nimble >= 0.26 (shipped with Nim >= 2.2.14)".}

requires "nim >= 2.2.14 & < 2.3.0"
requires "asynctest >= 0.5.4 & < 0.6.0"
requires "chronicles >= 0.12.3 & < 0.13.0"
# ffi needs closeThreadDispatcher, which no chronos release has yet.
requires "chronos#2d81a7625d74269581ba24c8bc40b69fccf27d47"
requires "confutils == 0.1.1"
requires "constantine >= 0.2.0 & < 0.3.0"
requires "contractabi >= 0.7.3 & < 0.8.0"
requires "https://github.com/logos-storage/nim-datastore >= 0.2.4 & < 0.3.0"
requires "leveldbstatic >= 0.2.3 & < 0.3.0"
requires "json_serialization == 0.4.4"
requires "https://github.com/status-im/lrucache.nim >= 1.2.2 & < 1.3.0"
requires "faststreams >= 0.5.0 & < 0.6.0"
# The C bindings need fixes made after v0.3.1-rc.0, which have no tag yet.
requires "ffi#16aab491d3aa6d604df0600fbdfe7190ba169577"
requires "libbacktrace >= 0.2.0 & < 0.3.0"
requires "libp2p >= 2.3.5 & < 2.4.0"
# These packages have no releases containing the required mix support.
requires "https://github.com/logos-storage/libp2p-mix-transport#653bcd6d8c2a74b72b7207723938c643416670a0"
requires "https://github.com/logos-co/nim-libp2p-mix.git#0883587f1f0d7fc6745e8db00fcd0cb0938d7dd0"
requires "https://github.com/logos-storage/nim-merkletree >= 1.0.1 & < 2.0.0"
requires "https://github.com/logos-storage/nim-serde >= 1.2.3 & < 1.3.0"
requires "https://github.com/status-im/nim-blscurve#3bf34027a2eff87e5fe8418bc97f09219452823a"
requires "secp256k1 >= 0.7.0.8.0 & < 0.8.0"
requires "testutils >= 0.8.1 & < 0.8.2"
requires "lsquic >= 0.9.0 & < 0.10.0"
requires "bearssl >= 0.2.8 & < 0.3.0"
requires "metrics >= 0.2.3 & < 0.3.0"
requires "nimcrypto >= 0.7.3 & < 0.8.0"
requires "presto >= 0.1.1 & < 0.2.0"
requires "protobuf_serialization >= 0.6.0 & < 0.6.2"
requires "questionable >= 0.10.15 & < 0.11.0"
requires "results >= 0.5.0 & < 0.6.0"
requires "serialization >= 0.5.4 & < 0.6.0"
requires "sqlite3_abi >= 3.47.0.0 & < 4.0.0.0"
requires "stew >= 0.4.2 & < 0.6.0"
requires "stint >= 0.8.2 & < 0.9.0"
requires "taskpools >= 0.2.1 & < 0.3.0"
requires "toml_serialization >= 0.2.18 & < 0.3.0"
requires "unittest2 >= 0.2.5 & < 0.3.0"
requires "https://github.com/status-im/nim-zippy >= 0.5.7 & < 0.6.0"

include "build.nims"
