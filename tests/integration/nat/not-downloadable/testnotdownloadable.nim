## NAT not-downloadable scenario. See README.md.

import std/[json, os, times]
import pkg/chronos
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc announcesNothing(info: JsonNode): bool =
  ## An unreachable node with no relay has no dialable address to announce.
  info{"addrs"}.getElems.len == 0

asyncchecksuite "NAT not downloadable":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    nodeApiUrl = "http://127.0.0.1:18084/api/storage/v1"
    clientApiUrl = "http://127.0.0.1:18085/api/storage/v1"
    suiteName = "NAT not downloadable"
    testName = "a NAT'd node without relay cannot be downloaded from"
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
    # Make sure nodeClient is not reachable
    check eventuallyInfo(
      nodeClient,
      info{"nat"}{"reachability"}.getStr == "NotReachable" and info.announcesNothing(),
    )

    let info = (await nodeClient.info()).get
    # Double check to make sure nodeClient is not reachable and has
    # nothing to announce
    check info.announcesNothing()

    # C is reachable
    check eventuallyInfo(clientC, info{"nat"}{"reachability"}.getStr == "Reachable")

    # B uploads a file
    let cid = (await nodeClient.upload("hello from behind the NAT")).get

    # C cannot download the manifest, as B is not reachable
    let res = await clientC.downloadManifestOnly(cid)
    check res.isErr
