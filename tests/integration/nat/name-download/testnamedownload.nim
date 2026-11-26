## A node finds a dataset through a name published behind a NAT, follows the
## name to a new dataset, and still gets it once the publisher has stopped. See
## README.md.

import std/[json, os, sequtils, strutils, times]
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

proc announcesCircuitAddr(info: JsonNode): bool =
  info{"addrs"}.getElems.anyIt("p2p-circuit" in it.getStr)

proc isRelayedClient(info: JsonNode): bool =
  info.isJoinedClient() and info.announcesCircuitAddr()

proc resolvesTo(
    client: StorageClient, nameKey: string, cid: Cid
): Future[bool] {.async: (raises: [CancelledError]).} =
  try:
    let response = await client.resolveNameRaw(nameKey)

    return response.status == 200 and (await response.body) == $cid
  except HttpError:
    return false

proc downloads(
    client: StorageClient, cid: Cid, content: string
): Future[bool] {.async: (raises: [CancelledError]).} =
  try:
    let res = await client.download(cid)
    return res.isOk and res.get == content
  except HttpError:
    return false

asyncchecksuite "NAT name download":
  let
    composeFile = currentSourcePath.parentDir / "compose.yml"
    publisherApiUrl = "http://127.0.0.1:18100/api/storage/v1"
    downloaderApiUrl = "http://127.0.0.1:18101/api/storage/v1"
    secondDownloaderApiUrl = "http://127.0.0.1:18102/api/storage/v1"
    suiteName = "NAT name download"
    testName = "a downloader follows a name published behind a NAT"
    services = [
      "router1", "router2", "router3", "bootstrap", "publisher", "downloader",
      "second-downloader",
    ]
    startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  var
    publisherClient: StorageClient
    downloaderClient: StorageClient
    secondDownloaderClient: StorageClient

  setup:
    compose(composeFile, "up -d")
    publisherClient = StorageClient.new(publisherApiUrl)
    downloaderClient = StorageClient.new(downloaderApiUrl)
    secondDownloaderClient = StorageClient.new(secondDownloaderApiUrl)

  teardown:
    await publisherClient.close()
    await downloaderClient.close()
    await secondDownloaderClient.close()
    saveContainerLogs(composeFile, suiteName, testName, startTime, services)
    compose(composeFile, "down -v")

  test testName:
    # A, B and D are Kad clients: the bootstrap is the only DHT server. Each
    # announces its circuit address: a node without one doesn't announce what it
    # stores.
    check eventuallyInfo(publisherClient, info.isRelayedClient())
    check eventuallyInfo(downloaderClient, info.isRelayedClient())
    check eventuallyInfo(secondDownloaderClient, info.isRelayedClient())

    let content1 = "first dataset of the catalog"

    let cid1 = (await publisherClient.upload(content1)).get
    let published1 =
      await publisherClient.publishNameRaw(@{"label": "catalog", "cid": $cid1})

    check published1.status == 200

    let nameKey = await published1.body

    # The provider record of the CID takes time to reach the DHT, so B polls the
    # download.
    check eventuallySafe(
      await downloaderClient.resolvesTo(nameKey, cid1),
      timeout = 180000,
      pollInterval = 5000,
    )
    check eventuallySafe(
      await downloaderClient.downloads(cid1, content1),
      timeout = 180000,
      pollInterval = 5000,
    )

    # Publishing again under the same label keeps the name key and moves the
    # name to the new CID.
    let content2 = "second dataset of the catalog"

    # Backs off for a second so publication does not fail if the above ends up
    # being fast (spec does not allow publishing more than once per second for
    # the same name).
    await sleepAsync(timer.seconds(2))

    let cid2 = (await publisherClient.upload(content2)).get
    let published2 =
      await publisherClient.publishNameRaw(@{"label": "catalog", "cid": $cid2})

    check published2.status == 200

    check (await published2.body) == nameKey
    check cid2 != cid1

    check eventuallySafe(
      await downloaderClient.resolvesTo(nameKey, cid2),
      timeout = 180000,
      pollInterval = 5000,
    )
    check eventuallySafe(
      await downloaderClient.downloads(cid2, content2),
      timeout = 180000,
      pollInterval = 5000,
    )

    # D announces file 2 as soon as it stores the manifest, before it has all the
    # blocks. A stops only once D has the whole file.
    check eventuallySafe(
      await secondDownloaderClient.resolvesTo(nameKey, cid2),
      timeout = 180000,
      pollInterval = 5000,
    )
    check eventuallySafe(
      await secondDownloaderClient.downloads(cid2, content2),
      timeout = 180000,
      pollInterval = 5000,
    )

    compose(composeFile, "stop publisher")

    # The name record lives 8 hours after A's last publish.
    check eventuallySafe(
      await downloaderClient.resolvesTo(nameKey, cid2),
      timeout = 180000,
      pollInterval = 5000,
    )

    # B's data dir is a tmpfs, so the restart empties it. D is then the only
    # running node that has file 2. A's provider record stays in the DHT for 48
    # hours, so B may try A first.
    compose(composeFile, "restart downloader")

    check eventuallyInfo(downloaderClient, info.isJoinedClient())

    check (await downloaderClient.download(cid2, local = true)).isErr
    check eventuallySafe(
      await downloaderClient.downloads(cid2, content2),
      timeout = 180000,
      pollInterval = 5000,
    )
