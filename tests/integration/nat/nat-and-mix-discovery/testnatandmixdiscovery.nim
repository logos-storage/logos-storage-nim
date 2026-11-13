## NAT nat-and-mix-discovery scenario. See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesCircuitAddr(info: JsonNode): bool =
  info{"addrs"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite "Private downloads over discovered Mix relays and DHT proxies":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    seederApiUrl = "http://127.0.0.1:18093/api/storage/v1"
    leecherApiUrl = "http://127.0.0.1:18094/api/storage/v1"
    suiteName = "Mix queries over discovered relays and proxies"
    testName =
      "a leecher behind NAT downloads over Mix with relays and DHT proxies " &
      "found by service discovery"
    services = [
      "seeder_router", "leecher_router", "bootstrap", "relay_server", "mix_relay_1",
      "mix_relay_2", "mix_relay_3", "mix_relay_4", "dht_proxy", "seeder", "leecher",
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

    let contents = "private queries over discovered relays"
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
