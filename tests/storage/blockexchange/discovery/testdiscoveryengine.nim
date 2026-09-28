import pkg/chronos

import pkg/storage/rng
import pkg/storage/blockexchange
import pkg/storage/chunker
import pkg/storage/blocktype as bt
import pkg/storage/blockexchange/engine
import pkg/storage/manifest
import pkg/storage/merkletree

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

proc asBlock(m: Manifest): bt.Block =
  let mdata = m.encode().tryGet()
  bt.Block.new(data = mdata, codec = ManifestCodec).tryGet()

proc ignoreProviders(
    providers: seq[PeerRecord]
): Future[void] {.async: (raises: [CancelledError]).} =
  discard

asyncchecksuite "Test Discovery Engine":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    manifest: Manifest
    tree: StorageMerkleTree
    manifestBlock: bt.Block
    blockDiscovery: MockDiscovery
    downloadManager: DownloadManager

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    (_, tree, manifest, _) = makeDataset(blocks).tryGet()
    manifestBlock = manifest.asBlock()
    blocks.add(manifestBlock)

    downloadManager = DownloadManager.new()
    blockDiscovery = MockDiscovery.new()

  test "Should queue discovery request":
    var
      discoveryEngine = DiscoveryEngine.new(blockDiscovery)
      want = newFuture[void]()

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid, useMix: bool = false
    ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
      check cid == manifestBlock.cid
      if not want.finished:
        want.complete()

    let download = downloadManager.startDownload(
      DownloadDesc(
        md: ManifestDescriptor(manifest: manifest, manifestCid: manifestBlock.cid),
        count: 1,
      )
    )

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(download, ignoreProviders)
    await want.wait(100.millis)
    await discoveryEngine.stop()

  test "Should not request if there is already an inflight discovery request":
    var
      discoveryEngine = DiscoveryEngine.new(blockDiscovery, concurrentDiscReqs = 2)
      reqs = Future[void].Raising([CancelledError]).init()
      count = 0

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid, useMix: bool = false
    ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
      check cid == manifestBlock.cid
      if count > 0:
        check false
      count.inc

      await reqs

    let download = downloadManager.startDownload(
      DownloadDesc(
        md: ManifestDescriptor(manifest: manifest, manifestCid: manifestBlock.cid),
        count: 1,
      )
    )

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(download, ignoreProviders)
    await sleepAsync(200.millis)

    discoveryEngine.queueFindBlocksReq(download, ignoreProviders)
    await sleepAsync(200.millis)

    reqs.complete()
    await discoveryEngine.stop()

  test "Should query over mix when requested":
    var
      privateCid = Cid.example
      publicCid = Cid.example
      discoveryEngine = DiscoveryEngine.new(blockDiscovery, concurrentDiscReqs = 2)
      privateMatches = newFuture[bool]()
      publicMatches = newFuture[bool]()

    check privateCid != publicCid

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid, useMix: bool = false
    ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
      if useMix:
        privateMatches.complete(cid == privateCid)
      else:
        publicMatches.complete(cid == publicCid)

    let
      privateDownload = downloadManager.startDownload(
        DownloadDesc(
          md: ManifestDescriptor(manifest: manifest, manifestCid: privateCid),
          count: 1,
          transport: DownloadTransport.Mix,
        )
      )
      publicDownload = downloadManager.startDownload(
        DownloadDesc(
          md: ManifestDescriptor(manifest: manifest, manifestCid: publicCid),
          count: 1,
          transport: DownloadTransport.Direct,
        )
      )

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(privateDownload, ignoreProviders)
    discoveryEngine.queueFindBlocksReq(publicDownload, ignoreProviders)

    check await privateMatches.wait(100.millis)
    check await publicMatches.wait(100.millis)

    await discoveryEngine.stop()
