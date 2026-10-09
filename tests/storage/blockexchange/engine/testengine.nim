import std/[sequtils, options, importutils]

import pkg/chronos
import pkg/libp2p/routing_record

import pkg/storage/rng
import pkg/storage/blockexchange
import pkg/storage/stores
import pkg/storage/chunker
import pkg/storage/discovery
import pkg/storage/blocktype
import pkg/storage/merkletree
import pkg/storage/blockexchange/utils
import pkg/storage/blockexchange/engine/activedownload {.all.}
import pkg/storage/blockexchange/engine/downloadmanager {.all.}
import pkg/storage/blockexchange/engine/engine {.all.}
import pkg/storage/blockexchange/protocol/constants

import ../../../asynctest
import ../../helpers
import ../../examples

privateAccess(BlockExcEngine)

# Exercise BlockStore's cancellable async contract with a suspending lookup.
# Current production existence lookups complete synchronously; these tests do
# not reproduce a shutdown failure with those implementations.
type PausedPresenceStore = ref object of BlockStore
  entered: AsyncEvent
  lookups: int

method hasBlock(
    self: PausedPresenceStore, tree: Cid, index: Natural
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  inc self.lookups
  if self.lookups == 1:
    self.entered.fire()
    await newAsyncEvent().wait()
  return success(false)

method isAdvertised*(
    self: PausedPresenceStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  success(true)

proc checkPresenceCancellation(
    peerStore: PeerContextStore, peer: PeerId, rangeCount: uint64
) {.async.} =
  let store = PausedPresenceStore(entered: newAsyncEvent())
  var responses = 0
  proc sendPresence(
      peerId: PeerId, presence: seq[BlockPresence]
  ) {.async: (raises: [CancelledError]).} =
    inc responses

  let
    blockExc = BlockExcContext.new(
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence)),
      store,
      DownloadManager.new(),
      peerStore,
    )
    handling = blockExc.wantListHandler(
      peer,
      WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: Cid.example, index: 0),
            wantType: WantType.WantHave,
            sendDontHave: true,
            rangeCount: rangeCount,
          )
        ]
      ),
    )
  await store.entered.wait().wait(5.seconds)
  await handling.cancelAndWait().wait(5.seconds)
  # Cancellation is consumed by the outer handler, not translated to DontHave.
  check handling.finished
  check not handling.failed
  check store.lookups == 1
  check responses == 0
  check not peerStore.get(peer).wantListBusy

asyncchecksuite "NetworkStore engine handlers":
  var
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerContextStore
    downloadManager: DownloadManager
    network: BlockExcNetwork
    blockExc: BlockExcContext
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    peerCtx: PeerContext
    localStore: BlockStore
    blocks: seq[Block]

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = 1024'nb, chunkSize = 256'nb)

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    peerId = PeerId.example
    blockDiscovery = MockDiscovery.new()
    peerStore = PeerContextStore.new()
    downloadManager = DownloadManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork(transport: DirectPeerTransport())

    discovery = DiscoveryEngine.new(blockDiscovery)

    advertiser =
      Advertiser.new(localStore, blockDiscovery, peerInfo = examplePeerInfo())

    engine = BlockExcEngine.new(localStore, discovery, advertiser, downloadManager)
    blockExc = BlockExcContext.new(network, localStore, downloadManager, peerStore)
    engine.attach(blockExc)

    peerCtx = PeerContext(id: peerId)
    peerStore.add(peerCtx)

  test "Cancellation during a single presence lookup sends no response":
    await checkPresenceCancellation(peerStore, peerId, 0)

  test "Cancellation during a range presence lookup stops scanning":
    await checkPresenceCancellation(peerStore, peerId, 2)

  test "Direct and Mix discovery share one cooldown in either order":
    for firstTransport in [DownloadTransport.Direct, DownloadTransport.Mix]:
      let
        secondTransport =
          if firstTransport == DownloadTransport.Direct:
            DownloadTransport.Mix
          else:
            DownloadTransport.Direct
        firstDownload = engine.downloadManager.startDownload(
          DownloadDesc(
            md: testManifestDesc(blocks[0].cid, DefaultBlockSize.uint32, 1),
            count: 1,
            transport: firstTransport,
          )
        )
        secondDownload = engine.downloadManager.startDownload(
          DownloadDesc(
            md: testManifestDesc(blocks[0].cid, DefaultBlockSize.uint32, 1),
            count: 1,
            transport: secondTransport,
          )
        )
        firstCid = firstDownload.manifestCid
        secondCid = secondDownload.manifestCid

      # Expire the cooldown explicitly; no wall-clock sleep is needed.
      engine.lastDiscRequest = Moment.now() - 4.seconds
      engine.searchForNewPeers(firstDownload)
      let requestedAt = engine.lastDiscRequest
      engine.searchForNewPeers(secondDownload)
      check discovery.discoveryQueue.len == 1
      check engine.lastDiscRequest == requestedAt
      let firstRequest = discovery.discoveryQueue.getNoWait()
      check firstRequest.cid == firstCid
      check firstRequest.transport == firstTransport

      engine.lastDiscRequest = Moment.now() - 4.seconds
      engine.searchForNewPeers(secondDownload)
      check discovery.discoveryQueue.len == 1
      let secondRequest = discovery.discoveryQueue.getNoWait()
      check secondRequest.cid == secondCid
      check secondRequest.transport == secondTransport

  test "Should handle want list":
    let
      tree = StorageMerkleTree.init(blocks.mapIt(it.cid)).tryGet
      rootCid = tree.rootCid.tryGet()

    for i, blk in blocks:
      (await localStore.putBlock(blk)).tryGet()
      (await localStore.putCidAndProof(rootCid, i, blk.cid, tree.getProof(i).tryGet())).tryGet()

    let
      done = newFuture[void]()
      wantList = makeWantList(rootCid, blocks.len)

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      check presence.mapIt(it.address) == wantList.entries.mapIt(it.address)
      for p in presence:
        check p.kind in {BlockPresenceType.HaveRange, BlockPresenceType.Complete}
      done.complete()

    network.request = BlockExcRequest(sendPresence: sendPresence)

    await blockExc.wantListHandler(peerId, wantList)
    await done

  test "Should not send presence for a tree that is not advertised":
    let
      tree = StorageMerkleTree.init(blocks.mapIt(it.cid)).tryGet
      rootCid = tree.rootCid.tryGet()

    for i, blk in blocks:
      (await localStore.putBlock(blk)).tryGet()
      (await localStore.putCidAndProof(rootCid, i, blk.cid, tree.getProof(i).tryGet())).tryGet()

    (await localStore.setAdvertise(rootCid, false)).tryGet()

    var presenceSent = false

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      presenceSent = true

    network.request = BlockExcRequest(sendPresence: sendPresence)

    await blockExc.wantListHandler(peerId, makeWantList(rootCid, blocks.len))

    check not presenceSent

  test "Should handle want list - `dont-have`":
    let
      done = newFuture[void]()
      treeCid = Cid.example
      wantList = makeWantList(treeCid, blocks.len, sendDontHave = true)

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      check presence.mapIt(it.address) == wantList.entries.mapIt(it.address)
      for p in presence:
        check:
          p.kind == BlockPresenceType.DontHave

      done.complete()

    network.request = BlockExcRequest(sendPresence: sendPresence)

    await blockExc.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have` some blocks":
    let
      tree = StorageMerkleTree.init(blocks.mapIt(it.cid)).tryGet
      rootCid = tree.rootCid.tryGet()

    for i in 0 ..< 2:
      (await engine.localStore.putBlock(blocks[i])).tryGet()

      (
        await engine.localStore.putCidAndProof(
          rootCid, i, blocks[i].cid, tree.getProof(i).tryGet()
        )
      ).tryGet()

    let
      done = newFuture[void]()
      wantList = makeWantList(rootCid, blocks.len, sendDontHave = true)

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      for p in presence:
        if p.address.index >= 2:
          check p.kind == BlockPresenceType.DontHave
        else:
          check p.kind in {BlockPresenceType.HaveRange, BlockPresenceType.Complete}

      done.complete()

    network.request = BlockExcRequest(sendPresence: sendPresence)

    await blockExc.wantListHandler(peerId, wantList)

    await done

  test "Should handle block presence":
    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
        rangeCount: uint64 = 0,
        downloadId: uint64 = 0,
    ) {.async: (raises: [CancelledError]).} =
      discard

    network.request = BlockExcRequest(sendWantList: sendWantList)

    let
      md = testManifestDesc(blocks[0].cid, DefaultBlockSize.uint32, 1)
      address = BlockAddress(treeCid: md.manifest.treeCid, index: 0)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = engine.downloadManager.startDownload(desc)

    discard download.getWantHandle(address)

    await blockExc.blockPresenceHandler(
      peerId,
      @[
        BlockPresence(
          address: address, kind: BlockPresenceType.Complete, downloadId: download.id
        )
      ],
    )

    let
      swarm = download.getSwarm()
      peerOpt = swarm.getPeer(peerId)
    check peerOpt.isSome

  test "Swarm should only hold peers that can serve what is still needed":
    let
      md = testManifestDesc(blocks[0].cid, DefaultBlockSize.uint32, 32)
      treeCid = md.manifest.treeCid
      download = engine.downloadManager.startDownload(DownloadDesc(md: md, count: 32))
      swarm = download.getSwarm()
      batch = engine.downloadManager.getNextBatch(download).get()
      nextStart = batch.start + batch.count

    proc replyHaveRange(
        peer: PeerId, start: uint64, count: uint64
    ) {.async: (raises: [CancelledError]).} =
      await blockExc.blockPresenceHandler(
        peer,
        @[
          BlockPresence(
            address: BlockAddress(treeCid: treeCid, index: start),
            kind: BlockPresenceType.HaveRange,
            ranges: @[IndexRange(start: start, count: count)],
            downloadId: download.id,
          )
        ],
      )

    for _ in 0 ..< swarm.config.deltaMax:
      discard swarm.addPeer(PeerId.example, BlockAvailability.unknown())

    var partialPeers: seq[PeerId]
    for _ in 0 ..< swarm.config.deltaMax:
      let partialPeer = PeerContext.new(PeerId.example)
      peerStore.add(partialPeer)
      partialPeers.add(partialPeer.id)
      await replyHaveRange(partialPeer.id, batch.start, batch.count)

    check swarm.peersWithRange(batch.start, batch.count).len == partialPeers.len

    download.completeBatchLocal(batch.start, batch.count)
    download.ctx.trimPresenceBeforeWatermark()

    check swarm.peersNeeded() != shHealthy

    await replyHaveRange(peerId, nextStart, batch.count)

    check peerId in swarm.peersWithRange(nextStart, batch.count)

  test "Availability pushed to the swarm should reach every download of the tree":
    let
      md = testManifestDesc(blocks[0].cid, DefaultBlockSize.uint32, 32)
      treeCid = md.manifest.treeCid
      download = engine.downloadManager.startDownload(DownloadDesc(md: md, count: 32))
      otherDownload =
        engine.downloadManager.startDownload(DownloadDesc(md: md, count: 32))

    await blockExc.blockPresenceHandler(
      peerId,
      @[
        BlockPresence(
          address: BlockAddress(treeCid: treeCid, index: 0),
          kind: BlockPresenceType.HaveRange,
          ranges: @[IndexRange(start: 0, count: 4)],
        )
      ],
    )

    check peerId in download.getSwarm().peersWithRange(0, 4)
    check peerId in otherDownload.getSwarm().peersWithRange(0, 4)

  test "Availability should only be pushed for advertised downloads":
    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
        rangeCount: uint64 = 0,
        downloadId: uint64 = 0,
    ) {.async: (raises: [CancelledError]).} =
      discard

    var pushes = 0
    proc sendPresence(
        peer: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      pushes.inc

    network.request =
      BlockExcRequest(sendWantList: sendWantList, sendPresence: sendPresence)

    for advertised in [true, false]:
      let
        md = testManifestDesc(blocks[0].cid, DefaultBlockSize.uint32, 48)
        download = engine.downloadManager.startDownload(DownloadDesc(md: md, count: 48))
        batchCount = download.ctx.scheduler.batchSizeCount

      (await localStore.setAdvertise(md.manifest.treeCid, advertised)).tryGet()
      discard download.getSwarm().addPeer(peerId, BlockAvailability.unknown())
      download.completeBatchLocal(batchCount, batchCount)
      pushes = 0

      let worker = engine.downloadWorker(download)
      check eventually(not download.ctx.shouldBroadcastAvailability())
      await worker.cancelAndWait()
      engine.downloadManager.cancelDownload(download)

      check pushes == (if advertised: 1 else: 0)

  test "Should handle range want list":
    let
      done = newFuture[void]()
      treeCid = Cid.example
      tree = StorageMerkleTree.init(blocks.mapIt(it.cid)).tryGet
      rootCid = tree.rootCid.tryGet()

    for i, blk in blocks:
      (await localStore.putBlock(blk)).tryGet()
      let proof = tree.getProof(i).tryGet()
      (await localStore.putCidAndProof(rootCid, i, blk.cid, proof)).tryGet()

    let wantList = WantList(
      entries: @[
        WantListEntry(
          address: BlockAddress(treeCid: rootCid, index: 0),
          priority: 0,
          cancel: false,
          wantType: WantType.WantHave,
          sendDontHave: false,
          rangeCount: blocks.len.uint64,
        )
      ],
      full: false,
    )

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      check presence.len == 1
      check presence[0].kind == BlockPresenceType.HaveRange
      check presence[0].ranges.len > 0
      done.complete()

    network.request = BlockExcRequest(sendPresence: sendPresence)

    await blockExc.wantListHandler(peerId, wantList)
    await done

  test "Should not send presence for blocks not in range":
    let
      done = newFuture[void]()
      treeCid = Cid.example
      tree = StorageMerkleTree.init(blocks.mapIt(it.cid)).tryGet
      rootCid = tree.rootCid.tryGet()

    for i in 0 ..< 2:
      (await localStore.putBlock(blocks[i])).tryGet()
      let proof = tree.getProof(i).tryGet()
      (await localStore.putCidAndProof(rootCid, i, blocks[i].cid, proof)).tryGet()

    let wantList = WantList(
      entries: @[
        WantListEntry(
          address: BlockAddress(treeCid: rootCid, index: 0),
          priority: 0,
          cancel: false,
          wantType: WantType.WantHave,
          sendDontHave: false,
          rangeCount: blocks.len.uint64,
        )
      ],
      full: false,
    )

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      check presence.len == 1
      check presence[0].kind == BlockPresenceType.HaveRange
      for r in presence[0].ranges:
        check r.start < 2
      done.complete()

    network.request = BlockExcRequest(sendPresence: sendPresence)

    await blockExc.wantListHandler(peerId, wantList)
    await done

  test "WantBlocks: rejects range with count = 0":
    let req = WantBlocksRequest(
      requestId: 1,
      treeCid: Cid.example,
      ranges: @[IndexRange(start: 0'u64, count: 0'u64)],
    )

    let blocks = await network.handlers.onWantBlocksRequest(peerId, req)
    check blocks.len == 0

  test "WantBlocks: rejects range with count > MaxBlocksPerBatch":
    let req = WantBlocksRequest(
      requestId: 1,
      treeCid: Cid.example,
      ranges: @[IndexRange(start: 0'u64, count: MaxBlocksPerBatch.uint64 + 1)],
    )

    let blocks = await network.handlers.onWantBlocksRequest(peerId, req)
    check blocks.len == 0

  test "WantBlocks: rejects range whose start+count overflows":
    let req = WantBlocksRequest(
      requestId: 1,
      treeCid: Cid.example,
      ranges: @[IndexRange(start: uint64.high, count: 1'u64)],
    )

    let blocks = await network.handlers.onWantBlocksRequest(peerId, req)
    check blocks.len == 0

  test "WantBlocks: rejects range whose max index exceeds Natural":
    let req = WantBlocksRequest(
      requestId: 1,
      treeCid: Cid.example,
      ranges: @[IndexRange(start: high(Natural).uint64 + 1, count: 1'u64)],
    )

    let blocks = await network.handlers.onWantBlocksRequest(peerId, req)
    check blocks.len == 0

  test "WantBlocks: rejects when total count across ranges exceeds cap":
    var ranges: seq[IndexRange] = @[]
    let halfMaxBlocksPerBatchPlusOne = (MaxBlocksPerBatch div 2).uint64 + 1
    ranges.add(IndexRange(start: 0'u64, count: halfMaxBlocksPerBatchPlusOne))
    ranges.add(IndexRange(start: 10_000'u64, count: halfMaxBlocksPerBatchPlusOne))

    let req = WantBlocksRequest(requestId: 1, treeCid: Cid.example, ranges: ranges)

    let blocks = await network.handlers.onWantBlocksRequest(peerId, req)
    check blocks.len == 0

  test "WantBlocks: accepts a valid small request":
    let
      tree = StorageMerkleTree.init(blocks.mapIt(it.cid)).tryGet
      rootCid = tree.rootCid.tryGet()

    for i, blk in blocks:
      (await localStore.putBlock(blk)).tryGet()
      (await localStore.putCidAndProof(rootCid, i, blk.cid, tree.getProof(i).tryGet())).tryGet()

    let
      reqLen = min(MaxBlocksPerBatch.int, blocks.len)
      req = WantBlocksRequest(
        requestId: 1,
        treeCid: rootCid,
        ranges: @[IndexRange(start: 0'u64, count: reqLen.uint64)],
      )

    let delivered = await network.handlers.onWantBlocksRequest(peerId, req)
    check delivered.len == reqLen

  test "WantBlocks: serves no block of a tree that is not advertised":
    let
      tree = StorageMerkleTree.init(blocks.mapIt(it.cid)).tryGet
      rootCid = tree.rootCid.tryGet()

    for i, blk in blocks:
      (await localStore.putBlock(blk)).tryGet()
      (await localStore.putCidAndProof(rootCid, i, blk.cid, tree.getProof(i).tryGet())).tryGet()

    (await localStore.setAdvertise(rootCid, false)).tryGet()

    let req = WantBlocksRequest(
      requestId: 1,
      treeCid: rootCid,
      ranges: @[IndexRange(start: 0'u64, count: blocks.len.uint64)],
    )

    let delivered = await network.handlers.onWantBlocksRequest(peerId, req)
    check delivered.len == 0

suite "IsIndexInRanges":
  test "Empty ranges returns false":
    let ranges: seq[IndexRange] = @[]
    check not isIndexInRanges(0, ranges)
    check not isIndexInRanges(100, ranges)

  test "Single range - index inside":
    let ranges = @[IndexRange(start: 10'u64, count: 5'u64)]
    check isIndexInRanges(10, ranges, sortedRanges = true)
    check isIndexInRanges(12, ranges, sortedRanges = true)
    check isIndexInRanges(14, ranges, sortedRanges = true)

  test "Single range - index outside":
    let ranges = @[IndexRange(start: 10'u64, count: 5'u64)]
    check not isIndexInRanges(9, ranges, sortedRanges = true)
    check not isIndexInRanges(15, ranges, sortedRanges = true)
    check not isIndexInRanges(100, ranges, sortedRanges = true)

  test "Multiple sorted ranges - index in each":
    let ranges = @[
      IndexRange(start: 0'u64, count: 3'u64),
      IndexRange(start: 10'u64, count: 5'u64),
      IndexRange(start: 100'u64, count: 10'u64),
    ]
    check isIndexInRanges(0, ranges, sortedRanges = true)
    check isIndexInRanges(2, ranges, sortedRanges = true)
    check isIndexInRanges(10, ranges, sortedRanges = true)
    check isIndexInRanges(14, ranges, sortedRanges = true)
    check isIndexInRanges(100, ranges, sortedRanges = true)
    check isIndexInRanges(109, ranges, sortedRanges = true)

  test "Multiple ranges - index in gaps":
    let ranges = @[
      IndexRange(start: 0'u64, count: 3'u64),
      IndexRange(start: 10'u64, count: 5'u64),
      IndexRange(start: 100'u64, count: 10'u64),
    ]
    check not isIndexInRanges(3, ranges, sortedRanges = true)
    check not isIndexInRanges(9, ranges, sortedRanges = true)
    check not isIndexInRanges(15, ranges, sortedRanges = true)
    check not isIndexInRanges(99, ranges, sortedRanges = true)
    check not isIndexInRanges(110, ranges, sortedRanges = true)

  test "Unsorted ranges with sortedRanges=false":
    let ranges = @[
      IndexRange(start: 100'u64, count: 10'u64),
      IndexRange(start: 0'u64, count: 3'u64),
      IndexRange(start: 10'u64, count: 5'u64),
    ]
    check isIndexInRanges(0, ranges, sortedRanges = false)
    check isIndexInRanges(2, ranges, sortedRanges = false)
    check isIndexInRanges(10, ranges, sortedRanges = false)
    check isIndexInRanges(105, ranges, sortedRanges = false)
    check not isIndexInRanges(50, ranges, sortedRanges = false)

  test "Adjacent ranges":
    let ranges = @[
      IndexRange(start: 0'u64, count: 5'u64),
      IndexRange(start: 5'u64, count: 5'u64),
      IndexRange(start: 10'u64, count: 5'u64),
    ]
    for i in 0'u64 ..< 15:
      check isIndexInRanges(i, ranges, sortedRanges = true)
    check not isIndexInRanges(15, ranges, sortedRanges = true)

  test "Large range values":
    let ranges = @[IndexRange(start: 1_000_000_000'u64, count: 1_000_000'u64)]
    check isIndexInRanges(1_000_000_000, ranges, sortedRanges = true)
    check isIndexInRanges(1_000_500_000, ranges, sortedRanges = true)
    check not isIndexInRanges(999_999_999, ranges, sortedRanges = true)
    check not isIndexInRanges(1_001_000_000, ranges, sortedRanges = true)
