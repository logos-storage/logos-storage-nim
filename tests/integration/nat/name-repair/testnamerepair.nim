## A resolver repairs a name record that the DHT server lost. See README.md.

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

asyncchecksuite "NAT name repair":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    bootstrapApiUrl = "http://127.0.0.1:18099/api/storage/v1"
    publisherApiUrl = "http://127.0.0.1:18096/api/storage/v1"
    resolverApiUrl = "http://127.0.0.1:18097/api/storage/v1"
    lateResolverApiUrl = "http://127.0.0.1:18098/api/storage/v1"
    suiteName = "NAT name repair"
    testName = "a resolver puts back a name record that the DHT server lost"
    services = [
      "router1", "router2", "router3", "bootstrap", "publisher", "resolver",
      "late-resolver",
    ]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    bootstrapClient: StorageClient
    publisherClient: StorageClient
    resolverClient: StorageClient
    lateResolverClient: StorageClient

  setup:
    compose(composeFile, "up -d")
    bootstrapClient = StorageClient.new(bootstrapApiUrl)
    publisherClient = StorageClient.new(publisherApiUrl)
    resolverClient = StorageClient.new(resolverApiUrl)
    lateResolverClient = StorageClient.new(lateResolverApiUrl)

  teardown:
    await bootstrapClient.close()
    await publisherClient.close()
    await resolverClient.close()
    await lateResolverClient.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # A, B and C are Kad clients: the bootstrap is the only DHT server.
    check eventuallyInfo(publisherClient, info.isJoinedClient())
    check eventuallyInfo(resolverClient, info.isJoinedClient())
    check eventuallyInfo(lateResolverClient, info.isJoinedClient())

    let bootstrapId = (await bootstrapClient.info()).get{"id"}.getStr
    let cid = (await publisherClient.upload("name to repair")).get
    let published =
      await publisherClient.publishNameRaw(@{"label": "catalog", "cid": $cid})

    check published.status == 200

    let nameKey = await published.body

    # With A stopped, only the bootstrap holds the name record. B keeps a local
    # copy once it resolves the name.
    compose(composeFile, "stop publisher")

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

    # Restart the bootstrap: it loses its name records. Wait for its API, its
    # peer ID doesn't change.
    compose(composeFile, "restart bootstrap")

    check eventuallyInfo(bootstrapClient, info{"id"}.getStr == bootstrapId)

    # A Kad server never admits client peers in its table. After the restart, its
    # lookup doesn't have any peer to ask. Its lookup checks its local store
    # first, so the 500 "No peer replied" shows that the restart wiped the name
    # record.
    let resolvedOnBootstrap = await bootstrapClient.resolveNameRaw(nameKey)

    check resolvedOnBootstrap.status == 500

    let bootstrapInfo = (await bootstrapClient.info()).get

    check bootstrapInfo{"table"}{"nodes"}.getElems.len == 0

    # B answers from its local copy, and its lookup puts the name record back
    # on the bootstrap, which had no valid name record. B's 200 proves nothing:
    # C, which never resolved the name, getting the CID is the proof of the
    # repair.
    check eventuallySafe(
      block:
        var repaired = false
        try:
          discard await (await resolverClient.resolveNameRaw(nameKey)).body
          let response = await lateResolverClient.resolveNameRaw(nameKey)
          repaired = response.status == 200 and (await response.body) == $cid
        except HttpError:
          discard
        repaired,
      timeout = 180000,
      pollInterval = 5000,
    )
