## NAT autonat-relay-discovery scenario. See README.md.

import std/[json, os, sequtils, strutils, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

const
  bootstrapIp = "7.7.7.10"
  relayServerIp = "71.71.71.12"

proc circuitAddrs(info: JsonNode): seq[string] =
  info{"addrs"}.getElems.mapIt(it.getStr).filterIt("p2p-circuit" in it)

asyncchecksuite "NAT AutoNAT and relay discovery":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18095/api/storage/v1"
    clientApiUrl = "http://127.0.0.1:18096/api/storage/v1"
    suiteName = "NAT AutoNAT and relay discovery"
    testName =
      "a NAT'd node finds its AutoNAT server and relay through service discovery"
    services =
      ["router", "bootstrap", "autonat_server", "relay_server", "client", "node"]
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
    check eventuallyInfo(
      nodeClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and
        info.circuitAddrs().len > 0,
    )

    let circuits = (await nodeClient.info()).get.circuitAddrs()
    check circuits.allIt(it.startsWith("/ip4/" & relayServerIp & "/"))
    check not circuits.anyIt(("/ip4/" & bootstrapIp & "/") in it)

    check eventuallyInfo(clientC, info{"nat"}{"reachability"}.getStr == "Reachable")

    let content = "hello through a discovered relay"
    let cid = (await nodeClient.upload(content)).get

    let res = await clientC.download(cid)
    check res.isOk
    check res.get == content
