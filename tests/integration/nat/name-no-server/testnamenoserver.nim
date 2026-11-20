## A name published while no DHT server is up. See README.md.

import std/[json, os, times]
import pkg/chronos
import pkg/libp2p/cid
import pkg/questionable/results

import ../../../asynctest
import ../../../checktest
import ../../storageclient
import ../composehelper

proc isJoinedClient(info: JsonNode): bool =
  info{"nat"}{"reachability"}.getStr == "NotReachable" and
    info{"nat"}{"clientMode"}.getBool and info{"table"}{"nodes"}.getElems.len > 0

asyncchecksuite "NAT name with no server":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    bootstrapApiUrl = "http://127.0.0.1:18095/api/storage/v1"
    publisherApiUrl = "http://127.0.0.1:18093/api/storage/v1"
    resolverApiUrl = "http://127.0.0.1:18094/api/storage/v1"
    suiteName = "NAT name with no server"
    testName = "a name published with no DHT server resolves after a restart"
    services = ["router1", "router2", "bootstrap", "publisher", "resolver"]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    bootstrapClient: StorageClient
    publisherClient: StorageClient
    resolverClient: StorageClient

  setup:
    compose(composeFile, "up -d")
    bootstrapClient = StorageClient.new(bootstrapApiUrl)
    publisherClient = StorageClient.new(publisherApiUrl)
    resolverClient = StorageClient.new(resolverApiUrl)

  teardown:
    await bootstrapClient.close()
    await publisherClient.close()
    await resolverClient.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # A and B are Kad clients: the bootstrap is the only DHT server.
    check eventuallyInfo(publisherClient, info.isJoinedClient())
    check eventuallyInfo(resolverClient, info.isJoinedClient())

    let bootstrapId = (await bootstrapClient.info()).get{"id"}.getStr
    let cid = (await publisherClient.upload("name with no server")).get

    compose(composeFile, "stop bootstrap")

    # Publish stores the name record locally and reports success.
    let published =
      await publisherClient.publishNameRaw(@{"label": "catalog", "cid": $cid})

    check published.status == 200

    let nameKey = await published.body

    # The lookup may fail fast or time out: only "no CID" is certain.
    let resolvedWithNoServer = await resolverClient.resolveNameRaw(nameKey)

    check resolvedWithNoServer.status in [404, 500]

    # Wait for the API of the bootstrap. Its peer ID doesn't change.
    compose(composeFile, "start bootstrap")

    check eventuallyInfo(bootstrapClient, info{"id"}.getStr == bootstrapId)

    # A republishes its stored name records right at start.
    compose(composeFile, "restart publisher")

    check eventuallyInfo(publisherClient, info.isJoinedClient())
    check eventuallySafe(
      block:
        var resolved = false
        try:
          let response = await resolverClient.resolveNameRaw(nameKey)
          resolved = response.status == 200 and (await response.body) == $cid
        except HttpError:
          discard
        resolved,
      timeout = 180000,
      pollInterval = 5000,
    )
