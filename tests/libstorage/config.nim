import std/json
import std/monotimes
import std/options
import std/os
import std/strutils

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/node_factory

from ../../storage/storage import close, config
from ../../storage/conf import DefaultApiBindAddress

template withStorage(conf: JsonNode, body: untyped) =
  let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

  defer:
    removeDir(dataDir)

  let json = conf
  json["data-dir"] = %dataDir
  json["nat"] = %"extip:127.0.0.1"
  let res = await createStorage($json)

  check res.isOk

  if res.isOk:
    let node {.inject.} = res.get()
    body
    await node.close()

asyncchecksuite "Libstorage - config":
  test "rejects malformed JSON":
    let res = await createStorage("""{"log-level": "debug"""")

    check res.isErr

    if res.isErr:
      check "unable to load configuration" in res.error

  test "rejects an unknown option":
    let res = await createStorage("""{"unknown": "debug"}""")

    check res.isErr

    if res.isErr:
      check "unable to load configuration" in res.error

  test "rejects a config without bootstrap node and with nat auto":
    let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

    defer:
      removeDir(dataDir)

    let res = await createStorage($ %*{"data-dir": dataDir, "nat": "auto"})

    check res.isErr

    if res.isErr:
      check "--nat=auto requires --bootstrap-node" in res.error

  test "accepts a valid config":
    withStorage(%*{}):
      discard

  test "disables the REST API by default":
    withStorage(%*{}):
      check node.config.apiBindAddress.isNone

  test "enables the REST API when the config asks for it":
    withStorage(%*{"api-bindaddr": DefaultApiBindAddress}):
      check node.config.apiBindAddress == DefaultApiBindAddress.some
