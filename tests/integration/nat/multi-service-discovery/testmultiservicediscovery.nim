## NAT multi-service-discovery scenario. See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesCircuitAddr(info: JsonNode): bool =
  info{"addrs"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite "Private downloads over nodes that provide all services":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    seederApiUrl = "http://127.0.0.1:18097/api/storage/v1"
    leecherApiUrl = "http://127.0.0.1:18098/api/storage/v1"
    suiteName = "Multi-service discovery"
    testName =
      "a leecher behind NAT downloads over Mix from public nodes that " &
      "advertise all services"
    services = [
      "seeder_router", "leecher_router", "bootstrap", "public_node_1", "public_node_2",
      "public_node_3", "public_node_4", "seeder", "leecher",
    ]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    seederClient: StorageClient
    leecherClient: StorageClient

  setup:
    compose(composeFile, "up -d")
    seederClient = StorageClient.new(seederApiUrl)
    leecherClient = StorageClient.new(leecherApiUrl)

  teardown:
    await seederClient.close()
    await leecherClient.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    check eventuallyInfo(
      seederClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.announcesCircuitAddr(),
    )
    check eventuallyInfo(
      leecherClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.announcesCircuitAddr(),
    )

    let contents = "private queries over multi-service nodes"
    let cid = (await seederClient.upload(contents)).get

    var downloaded = ""
    for _ in 0 ..< 60:
      let res = await leecherClient.download(cid, private = true)
      if res.isOk:
        downloaded = res.get
        break
      await sleepAsync(5_000)
    check downloaded == contents

    check eventuallySafe(
      "Selected mix node for surbs:" in serviceLogs(composeFile, "leecher"),
      timeout = 60_000,
      pollInterval = 2_000,
    )

    check eventuallySafe(
      "connect requested" in serviceLogs(composeFile, "leecher"),
      timeout = 60_000,
      pollInterval = 2_000,
    )
