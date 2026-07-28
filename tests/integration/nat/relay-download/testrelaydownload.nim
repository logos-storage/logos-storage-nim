## NAT relay-download scenario. See README.md.

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

asyncchecksuite "NAT relay download":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    bootstrapApiUrl = "http://127.0.0.1:18092/api/storage/v1"
    nodeApiUrl = "http://127.0.0.1:18086/api/storage/v1"
    clientApiUrl = "http://127.0.0.1:18087/api/storage/v1"
    suiteName = "NAT relay download"
    services = ["router", "bootstrap", "client", "node"]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    bootstrapClient: StorageClient
    nodeClient: StorageClient
    clientC: StorageClient
    currentTest: string

  setup:
    compose(composeFile, "up -d")
    bootstrapClient = StorageClient.new(bootstrapApiUrl)
    nodeClient = StorageClient.new(nodeApiUrl)
    clientC = StorageClient.new(clientApiUrl)

  teardown:
    await bootstrapClient.close()
    await nodeClient.close()
    await clientC.close()
    saveContainerLogs(composeFile, suiteName, currentTest, startTime, services)
    compose(composeFile, "down -v")

  test "a NAT'd node behind a relay can be downloaded from":
    currentTest = "a NAT'd node behind a relay can be downloaded from"

    # B is NotReachable and falls back to the relay, announcing its circuit address
    check eventuallyInfo(
      nodeClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.announcesCircuitAddr(),
    )

    let info = (await nodeClient.info()).get
    # Double check B announces only its circuit address
    check info.announcesCircuitAddr()

    # C is reachable
    check eventuallyInfo(clientC, info{"nat"}{"reachability"}.getStr == "Reachable")

    # B uploads a file
    let content = "hello from behind the relay"
    let cid = (await nodeClient.upload(content)).get

    # C downloads it through the relay and gets the same content back
    let res = await clientC.download(cid)
    check res.isOk
    check res.get == content

  test "the relay server exposes no private address":
    currentTest = "the relay server exposes no private address"

    # Ensure the relay server has at least one address (it should have a public one)
    check eventuallyInfo(bootstrapClient, info{"addrs"}.getElems.len > 0)

    let info = (await bootstrapClient.info()).get

    # Ensure that the switch.peersInfo.addrs contains
    # only public addresses (no private addresses).
    check info{"addrs"}.getElems.mapIt(it.getStr) ==
      @["/ip4/" & bootstrapIp & "/tcp/8070"]
