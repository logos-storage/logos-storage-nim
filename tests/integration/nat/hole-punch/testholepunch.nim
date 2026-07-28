## Coordinated DCUtR hole-punching scenario (both peers NATed). See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesCircuitAddr(info: JsonNode): bool =
  info{"addrs"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite "NAT hole punching":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18090/api/storage/v1"
    peerApiUrl = "http://127.0.0.1:18091/api/storage/v1"
    suiteName = "NAT hole punching"
    testName = "two NATed nodes upgrade a relayed connection to a direct one"
    services = ["router1", "router2", "bootstrap", "node", "peer"]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    nodeClient: StorageClient
    peerClient: StorageClient

  setup:
    compose(composeFile, "up -d")
    nodeClient = StorageClient.new(nodeApiUrl)
    peerClient = StorageClient.new(peerApiUrl)

  teardown:
    await nodeClient.close()
    await peerClient.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # Both nodes are NotReachable behind their own NAT and take a relay reservation.
    check eventuallyInfo(
      nodeClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.announcesCircuitAddr(),
    )
    check eventuallyInfo(
      peerClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.announcesCircuitAddr(),
    )

    # D downloads from B through the relay; that opens the relayed connection.
    let cid = (await nodeClient.upload("punch me for real")).get
    check (await peerClient.download(cid)).isOk

    # B should upgrade the relayed connection to a direct one: its connection to D
    # becomes non-relayed
    let peerId = (await peerClient.info()).get{"id"}.getStr
    check eventuallyInfo(
      nodeClient,
      info{"connections"}.getElems.anyIt(
        it{"peerId"}.getStr == peerId and it{"direct"}.getBool
      ),
    )
