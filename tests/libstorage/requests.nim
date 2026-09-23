import std/json
import std/monotimes
import std/os
import std/strutils

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/storage_thread_requests/requests/node_lifecycle_request
import ../../library/storage_thread_requests/requests/node_info_request
import ../../library/storage_thread_requests/requests/node_storage_request
import ../../library/storage_thread_requests/requests/node_debug_request

from ../../storage/storage import StorageServer

asyncchecksuite "Libstorage - request on a node that is not created":
  var uncreated: StorageServer

  test "rejects a start":
    let res =
      await NodeLifecycleRequest.createShared(START_NODE).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects a stop":
    let res = await NodeLifecycleRequest.createShared(STOP_NODE).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects a close":
    let res =
      await NodeLifecycleRequest.createShared(CLOSE_NODE).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects an info request":
    let res =
      await NodeInfoRequest.createShared(NodeInfoMsgType.SPR).process(addr uncreated)

    check res.isErr and "not created" in res.error

  test "rejects a storage list request":
    let res = await NodeStorageRequest.createShared(NodeStorageMsgType.LIST).process(
      addr uncreated
    )

    check res.isErr and "not created" in res.error

  test "accepts a metrics request, it reads the process registry":
    let res = await NodeInfoRequest.createShared(NodeInfoMsgType.METRICS).process(
      addr uncreated
    )

    check res.isOk

  test "accepts a node creation":
    let dataDir = getTempDir() / "libstorage-requests" / $getMonoTime()

    defer:
      removeDir(dataDir)

    var created: StorageServer
    let config = $ %*{"data-dir": dataDir}
    let res = await NodeLifecycleRequest
      .createShared(CREATE_NODE, config.cstring)
      .process(addr created)

    check res.isOk

    let closed =
      await NodeLifecycleRequest.createShared(CLOSE_NODE).process(addr created)
    check closed.isOk

  test "reports the network the node was configured with":
    let dataDir = getTempDir() / "libstorage-requests" / $getMonoTime()

    defer:
      removeDir(dataDir)

    var created: StorageServer
    let config = $ %*{"data-dir": dataDir, "network": "logos.dev"}
    check (
      await NodeLifecycleRequest.createShared(CREATE_NODE, config.cstring).process(
        addr created
      )
    ).isOk

    let res =
      await NodeInfoRequest.createShared(NodeInfoMsgType.NETWORK).process(addr created)

    check res.isOk and res.get == "logos.dev"

    check (await NodeLifecycleRequest.createShared(CLOSE_NODE).process(addr created)).isOk

  test "rejects a second close, the node is dropped by the first one":
    let dataDir = getTempDir() / "libstorage-requests" / $getMonoTime()

    defer:
      removeDir(dataDir)

    var created: StorageServer
    let config = $ %*{"data-dir": dataDir}
    check (
      await NodeLifecycleRequest.createShared(CREATE_NODE, config.cstring).process(
        addr created
      )
    ).isOk
    check (await NodeLifecycleRequest.createShared(CLOSE_NODE).process(addr created)).isOk

    let res = await NodeLifecycleRequest.createShared(CLOSE_NODE).process(addr created)

    check res.isErr and "not created" in res.error

  test "accepts a log level change":
    let res = await NodeDebugRequest
      .createShared(NodeDebugMsgType.LOG_LEVEL, logLevel = "WARN")
      .process(addr uncreated)

    check res.isOk
