## NAT pcp scenario. See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesDirectAddr(info: JsonNode): bool =
  ## A reachable node announces at least one direct (non-circuit) address.
  info{"addrs"}.getElems.anyIt("p2p-circuit" notin it.getStr)

asyncchecksuite "NAT pcp":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18083/api/storage/v1"
    suiteName = "NAT pcp"
    testName = "node behind NAT maps its port over PCP and is Reachable"
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
    # Reachable is the settling signal: wait for it, then assert each expected
    # property separately so a failure points at the exact condition.
    check eventuallyInfo(client, info{"nat"}{"reachability"}.getStr == "Reachable")

    let info = (await client.info()).get
    let nat = info{"nat"}
    check nat{"reachability"}.getStr == "Reachable"
    check nat{"relayRunning"}.getBool == false
    check nat{"portMapping"}.getStr == "pcp"
    check info.announcesDirectAddr()
    let announced = info{"addrs"}.getElems.mapIt(it.getStr)
    # PCP may map a port different from the listen port, so check the IP only
    check announced.anyIt(("/ip4/" & routerWanIp & "/tcp/") in it)
    # the public mapped address
