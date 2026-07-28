import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesCircuitAddr(info: JsonNode): bool =
  info{"addrs"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite "Mix queries with NATted endpoints":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    seederApiUrl = "http://127.0.0.1:18090/api/storage/v1"
    leecherApiUrl = "http://127.0.0.1:18091/api/storage/v1"
    suiteName = "Mix queries with NATted endpoints"
    testName =
      "a leecher behind NAT downloads a file from a seeder " &
      "also behind a NAT, and does the query over Mix"
    services = [
      "seeder_router", "leecher_router", "mix_proxy_1", "mix_proxy_2", "mix_proxy_3",
      "mix_proxy_4", "seeder", "leecher",
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
    # Both nodes are NotReachable behind their own NAT and take a relay reservation.
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

    # Both nodes route their DHT provider queries through Mix.
    check eventuallyInfo(seederClient, info{"privateQueries"}.getBool)
    check eventuallyInfo(leecherClient, info{"privateQueries"}.getBool)

    # The leecher finds the seeder's provider record over Mix and downloads.
    let contents = "private queries for the win"
    let cid = (await seederClient.upload(contents)).get
    check (await leecherClient.download(cid)).get == contents

    # Double-check that the leecher is selecting Mix nodes.
    check eventuallySafe(
      "Selected mix node for surbs:" in serviceLogs(composeFile, "leecher"),
      timeout = 60_000,
      pollInterval = 2_000,
    )
