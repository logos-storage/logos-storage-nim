version = "0.5.3"
author = "Logos Storage Team"
description = "privacy-preserving p2p file sharing"
license = "MIT"
binDir = "build"
bin = @["storage"]
skipDirs = @["vendor", "nimbledeps", "nimcache", "tests", "docs"]
srcDir = "."
installDirs = @["storage", "library"]
installFiles = @[
  "storage.nim", "build.nims", "config.nims", "network_presets.json",
  "LICENSE-APACHE", "LICENSE-MIT"
]

# Keep packages in a separate Nimble directory (see README.md).
requires "nim >= 2.2.12 & < 2.3.0"
requires "asynctest >= 0.5.4 & < 0.6.0"
requires "chronicles >= 0.12.3 & < 0.13.0"
requires "chronos >= 4.2.2 & < 4.2.5"
requires "confutils == 0.1.0"
requires "constantine >= 0.2.0 & < 0.3.0"
requires "contractabi >= 0.7.3 & < 0.8.0"
requires "https://github.com/status-im/nim-datastore >= 0.2.3 & < 0.3.0"
requires "leveldbstatic >= 0.2.3 & < 0.3.0"
requires "json_serialization == 0.4.4"
requires "https://github.com/status-im/lrucache.nim >= 1.2.2 & < 1.3.0"
requires "faststreams >= 0.5.0 & < 0.6.0"
requires "libbacktrace >= 0.2.0 & < 0.3.0"
requires "libp2p >= 2.3.5 & < 2.4.0"
# These packages have no releases containing the required mix support.
requires "https://github.com/logos-storage/libp2p-mix-transport#653bcd6d8c2a74b72b7207723938c643416670a0"
requires "https://github.com/logos-co/nim-libp2p-mix.git#0883587f1f0d7fc6745e8db00fcd0cb0938d7dd0"
# The v1.0.0 tag still declares version 0.1.0 in its manifest.
requires "https://github.com/logos-storage/nim-merkletree#v1.0.0"
requires "https://github.com/logos-storage/nim-serde >= 1.2.3 & < 1.3.0"
requires "https://github.com/status-im/nim-blscurve#f4d0de2eece20380541fbf73d4b8bf57dc214b3b"
# Newer releases require stew >= 0.5, incompatible with datastore 0.2.x.
requires "secp256k1#d8f1288b7c72f00be5fc2c5ea72bf5cae1eafb15"
requires "testutils >= 0.8.1 & < 0.8.2"
requires "lsquic >= 0.9.0 & < 0.10.0"
requires "bearssl >= 0.2.8 & < 0.3.0"
requires "metrics#b4b70a88fe1755d281366cbc3f22d7515240d192"
requires "nimcrypto >= 0.7.3 & < 0.8.0"
requires "presto >= 0.1.1 & < 0.2.0"
requires "protobuf_serialization >= 0.6.0 & < 0.6.2"
requires "questionable >= 0.10.15 & < 0.11.0"
requires "results >= 0.5.0 & < 0.6.0"
requires "serialization >= 0.5.2 & < 0.5.4"
requires "sqlite3_abi >= 3.47.0.0 & < 4.0.0.0"
requires "stew >= 0.4.2 & < 0.6.0"
requires "stint >= 0.8.2 & < 0.9.0"
# libstorage uses channels_spsc_single, removed in 0.2.1; 0.2.0 has no tag.
requires "taskpools#97f76faef6ba64bc77d9808c27ec5e9917e7cfde"
requires "toml_serialization >= 0.2.18 & < 0.3.0"
requires "unittest2 >= 0.2.5 & < 0.3.0"
requires "https://github.com/status-im/nim-zippy >= 0.5.7 & < 0.6.0"

before build:
  switch("define", "chronicles_runtime_filtering")
  switch("define", "chronicles_log_level=TRACE")

include "build.nims"
