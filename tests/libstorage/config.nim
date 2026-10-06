import std/json
import std/monotimes
import std/options
import std/os
import std/strutils

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/storage_thread_requests/requests/node_lifecycle_request

from ../../storage/storage import StorageServer, config
from ../../storage/conf import DefaultApiBindAddress

asyncchecksuite "Libstorage - config":
  var server: StorageServer

  test "rejects malformed JSON":
    let request =
      NodeLifecycleRequest.createShared(CREATE_NODE, """{"log-level": "debug"""")
    let res = await request.process(addr server)

    check res.isErr

    if res.isErr:
      check "unable to load configuration" in res.error

  test "rejects an unknown option":
    let request =
      NodeLifecycleRequest.createShared(CREATE_NODE, """{"unknown": "debug"}""")
    let res = await request.process(addr server)

    check res.isErr

    if res.isErr:
      check "unable to load configuration" in res.error

  test "rejects a config without bootstrap node and with nat auto":
    let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

    defer:
      removeDir(dataDir)

    let config = $ %*{"data-dir": dataDir, "nat": "auto"}
    let request = NodeLifecycleRequest.createShared(CREATE_NODE, config.cstring)
    let res = await request.process(addr server)

    check res.isErr

    if res.isErr:
      check "--nat=auto requires --bootstrap-node" in res.error

  test "accepts a valid config":
    let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

    defer:
      removeDir(dataDir)

    # %* escapes the path so that it can be used in JSON.
    let config = $ %*{"data-dir": dataDir, "nat": "extip:127.0.0.1"}
    let request = NodeLifecycleRequest.createShared(CREATE_NODE, config.cstring)
    let res = await request.process(addr server)

    check res.isOk

    let closeRequest = NodeLifecycleRequest.createShared(CLOSE_NODE)
    check (await closeRequest.process(addr server)).isOk

  test "disables the REST API by default":
    let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

    defer:
      removeDir(dataDir)

    let config = $ %*{"data-dir": dataDir, "nat": "extip:127.0.0.1"}
    let request = NodeLifecycleRequest.createShared(CREATE_NODE, config.cstring)
    check (await request.process(addr server)).isOk

    check server.config.apiBindAddress.isNone

    let closeRequest = NodeLifecycleRequest.createShared(CLOSE_NODE)
    check (await closeRequest.process(addr server)).isOk

  test "enables the REST API when the config asks for it":
    let dataDir = getTempDir() / "libstorage-config" / $getMonoTime()

    defer:
      removeDir(dataDir)

    let config = $ %*{
      "data-dir": dataDir,
      "api-bindaddr": DefaultApiBindAddress,
      "nat": "extip:127.0.0.1",
    }
    let request = NodeLifecycleRequest.createShared(CREATE_NODE, config.cstring)
    check (await request.process(addr server)).isOk

    check server.config.apiBindAddress == DefaultApiBindAddress.some

    let closeRequest = NodeLifecycleRequest.createShared(CLOSE_NODE)
    check (await closeRequest.process(addr server)).isOk
