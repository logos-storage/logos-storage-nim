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

asyncchecksuite "Test Discovery Engine":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    manifest: Manifest
    tree: StorageMerkleTree
    manifestBlock: bt.Block
    switch: Switch
    peerStore: PeerContextStore
    blockDiscovery: MockDiscovery
    downloadManager: DownloadManager
    network: BlockExcNetwork

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    (_, tree, manifest, _) = makeDataset(blocks).tryGet()
    manifestBlock = manifest.asBlock()
    blocks.add(manifestBlock)

    switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
    network = BlockExcNetwork.new(switch)
    peerStore = PeerContextStore.new()
    downloadManager = DownloadManager.new()
    blockDiscovery = MockDiscovery.new()

  test "Should queue discovery request":
    var
      discoveryEngine =
        DiscoveryEngine.new(peerStore, newBlockExcNetworks(network), blockDiscovery)
      want = newFuture[void]()

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid, useMix: bool = false
    ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
      check cid == blocks[0].cid
      if not want.finished:
        want.complete()

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await want.wait(100.millis)
    await discoveryEngine.stop()

  test "Should not request if there is already an inflight discovery request":
    var
      discoveryEngine = DiscoveryEngine.new(
        peerStore, newBlockExcNetworks(network), blockDiscovery, concurrentDiscReqs = 2
      )
      reqs = Future[void].Raising([CancelledError]).init()
      count = 0

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid, useMix: bool = false
    ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
      check cid == blocks[0].cid
      if count > 0:
        check false
      count.inc

      await reqs

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    reqs.complete()
    await discoveryEngine.stop()

  test "Should query over mix when requested":
    var
      privateCid = Cid.example
      publicCid = Cid.example
      discoveryEngine = DiscoveryEngine.new(
        peerStore, newBlockExcNetworks(network), blockDiscovery, concurrentDiscReqs = 2
      )
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

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[privateCid], transport = DownloadTransport.Mix)
    discoveryEngine.queueFindBlocksReq(
      @[publicCid], transport = DownloadTransport.Direct
    )

    check await privateMatches.wait(100.millis)
    check await publicMatches.wait(100.millis)

    await discoveryEngine.stop()
