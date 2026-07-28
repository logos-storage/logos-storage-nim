## NAT connection-reversal scenario. See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesCircuitAddr(info: JsonNode): bool =
  ## A node behind the relay announces its circuit (p2p-circuit) address.
  info{"addrs"}.getElems.anyIt("p2p-circuit" in it.getStr)

asyncchecksuite "NAT connection reversal":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18088/api/storage/v1"
    clientApiUrl = "http://127.0.0.1:18089/api/storage/v1"
    suiteName = "NAT connection reversal"
    testName = "a relayed node is upgraded to a direct connection"
    services = ["router", "bootstrap", "client", "node"]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    nodeClient: StorageClient
    clientC: StorageClient

  setup:
    compose(composeFile, "up -d")
    nodeClient = StorageClient.new(nodeApiUrl)
    clientC = StorageClient.new(clientApiUrl)

  teardown:
    await nodeClient.close()
    await clientC.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # B is NotReachable behind the relay, C is reachable
    check eventuallyInfo(
      nodeClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.announcesCircuitAddr(),
    )

    # C is Reachable
    check eventuallyInfo(clientC, info{"nat"}{"reachability"}.getStr == "Reachable")

    # C dials B through the relay; a download is enough to open the connection
    let cid = (await nodeClient.upload("hole punch me")).get
    check (await clientC.download(cid)).isOk

    # B sees C join over the relay and dials it back directly
    let peerId = (await clientC.info()).get{"id"}.getStr
    check eventuallyInfo(
      nodeClient,
      info{"connections"}.getElems.anyIt(
        it{"peerId"}.getStr == peerId and it{"direct"}.getBool
      ),
    )
