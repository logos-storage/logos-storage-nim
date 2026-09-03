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
      localStore, peerStore, network, blockDiscovery, concurrentDiscReqs = 20
    )

    advertiser =
      Advertiser.new(localStore, blockDiscovery, peerInfo = examplePeerInfo())

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, downloadManager
    )

    switch.mount(network)

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
        d: MockDiscovery, cid: Cid
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

  test "should route queries over mix when privacy toggle is enabled":
    let
      privateRecord = PeerRecord.example
      directRecord = PeerRecord.example
      refCid = Cid.example

    let
      # this is an invalid object, but we just need it to be non-null
      mix = MixProtocol()
      discovery = MixMockDiscovery.new()

    discovery.mixProto = mix
    discovery.dhtMixProxies = @[SignedPeerRecord.example]

    discovery.privateRecord = privateRecord
    discovery.directRecord = directRecord
    discovery.refCid = refCid

    check (await discovery.find(refCid)) == @[directRecord]
    let toggleRes = discovery.togglePrivateQueries(true)
    check toggleRes.isOk
    check toggleRes.get == false
    check (await discovery.find(refCid)) == @[privateRecord]

  test "should fail to enable private queries when MixProtocol is nil":
    let discovery = MixMockDiscovery.new()
    discovery.dhtMixProxies = @[SignedPeerRecord.example]
    let res = discovery.togglePrivateQueries(true)
    check res.isErr
