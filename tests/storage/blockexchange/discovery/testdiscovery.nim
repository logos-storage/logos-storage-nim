import std/[options, sequtils, sugar, tables]

import pkg/chronos
import pkg/libp2p_mix

import pkg/storage/discovery
import pkg/storage/rng
import pkg/storage/stores
import pkg/storage/blockexchange
import pkg/storage/chunker
import pkg/storage/manifest
import pkg/storage/merkletree
import pkg/storage/blocktype as bt
import pkg/storage/storagetypes

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

asyncchecksuite "Block Advertising and Discovery":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    manifest: Manifest
    tree: StorageMerkleTree
    manifestBlock: bt.Block
    switch: Switch
    peerStore: PeerContextStore
    blockDiscovery: MockDiscovery
    discovery: DiscoveryEngine
    advertiser: Advertiser
    network: BlockExcNetwork
    localStore: CacheStore
    engine: BlockExcEngine
    downloadManager: DownloadManager

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
    blockDiscovery = MockDiscovery.new()
    network = BlockExcNetwork.new(switch)
    localStore = CacheStore.new(blocks.mapIt(it))
    peerStore = PeerContextStore.new()
    downloadManager = DownloadManager.new()

    (_, tree, manifest, _) = makeDataset(blocks).tryGet()
    manifestBlock =
      bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    discovery = DiscoveryEngine.new(
      peerStore, newBlockExcNetworks(network), blockDiscovery, concurrentDiscReqs = 20
    )

    advertiser =
      Advertiser.new(localStore, blockDiscovery, peerInfo = examplePeerInfo())

    engine = BlockExcEngine.new(
      localStore, discovery.networks, discovery, advertiser, peerStore, downloadManager
    )

    switch.mount(discovery.networks.dispatchProtocol)

  test "Should discover want list":
    var handles: seq[Future[?!bt.Block]]
    for blk in blocks:
      let
        address = BlockAddress.init(blk.cid, 0)
        md = testManifestDesc(blk.cid, DefaultBlockSize.uint32, 1)
        desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
        download = engine.downloadManager.startDownload(desc)
      handles.add(download.getWantHandle(address))

    blockDiscovery.publishBlockProvideHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[void] {.async: (raises: [CancelledError]).} =
      return

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid, useMix: bool = false
    ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
      let matching = blocks.filterIt(it.cid == cid)
      for blk in matching:
        let address = BlockAddress(treeCid: blk.cid, index: 0)
        let dlOpt = engine.downloadManager.getDownload(blk.cid)
        if dlOpt.isSome:
          discard dlOpt.get().completeWantHandle(address, some(blk))

    await engine.start()

    discovery.queueFindBlocksReq(blocks.mapIt(it.cid))

    await allFuturesThrowing(allFinished(handles)).wait(10.seconds)

    await engine.stop()

  test "Should advertise manifests":
    let cids = @[manifestBlock.cid]
    var advertised = initTable.collect:
      for cid in cids:
        {cid: newFuture[void]()}

    blockDiscovery.publishBlockProvideHandler = proc(
        d: MockDiscovery, cid: Cid
    ) {.async: (raises: [CancelledError]).} =
      advertised.withValue(cid, fut):
        if not fut[].finished:
          fut[].complete()

    await engine.start()
    await allFuturesThrowing(allFinished(toSeq(advertised.values)))
    await engine.stop()

  test "Should not advertise local blocks":
    let blockCids = blocks.mapIt(it.cid)

    blockDiscovery.publishBlockProvideHandler = proc(
        d: MockDiscovery, cid: Cid
    ) {.async: (raises: [CancelledError]).} =
      check:
        cid notin blockCids

    await engine.start()
    await sleepAsync(3.seconds)
    await engine.stop()

  test "Should query via mix when requested":
    let
      public = PeerRecord.example
      private = PeerRecord.example
      discovery = MixMockDiscovery.new()

    discovery.directRecord = public
    discovery.privateRecord = private
    discovery.refCid = manifestBlock.cid
    # The lookup is mocked, but find still requires Mix to be configured.
    discovery.mixProto = MixProtocol()
    discovery.dhtMixProxies = @[SignedPeerRecord.example]

    # Better safe than sorry.
    check public.peerId != private.peerId

    check (await discovery.find(manifestBlock.cid, useMix = true)).get == @[private]
    check (await discovery.find(manifestBlock.cid)).get == @[public]

  test "should error out if mix is requested but not configured":
    let discovery = MixMockDiscovery.new()
    discovery.directRecord = PeerRecord.example
    discovery.privateRecord = PeerRecord.example
    discovery.refCid = manifestBlock.cid

    check (await discovery.find(manifestBlock.cid, useMix = true)).isErr
