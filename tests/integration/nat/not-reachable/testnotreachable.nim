## NAT not-reachable scenario. See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesCircuitAddr(info: JsonNode): bool =
  info{"addrs"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite "NAT not reachable":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18080/api/storage/v1"
    suiteName = "NAT not reachable"
    testName = "node behind NAT is NotReachable and falls back to relay"
    services = ["router", "bootstrap", "node"]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var client: StorageClient

  setup:
    compose(composeFile, "up -d")
    client = StorageClient.new(nodeApiUrl)

  teardown:
    await client.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # Wait for the announcements, after the relay reservation is created.
    check eventuallyInfo(client, info.announcesCircuitAddr())

    let info = (await client.info()).get
    let nat = info{"nat"}
    check nat{"reachability"}.getStr == "NotReachable"
    check nat{"relayRunning"}.getBool
    check nat{"portMapping"}.getStr == "none"
    check info.announcesCircuitAddr()
    let announced = info{"addrs"}.getElems.mapIt(it.getStr)
    # the announced circuit address points at the bootstrap's relay
    check announced.anyIt(
      ("/ip4/" & bootstrapIp & "/tcp/8070" in it) and ("p2p-circuit" in it)
    )
