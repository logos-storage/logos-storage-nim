import std/[sequtils, options]

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
import pkg/storage/blockexchange/protocol/constants

import ../../../asynctest
import ../../helpers
import ../../examples

asyncchecksuite "NetworkStore engine handlers":
  var
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerContextStore
    downloadManager: DownloadManager
    network: BlockExcNetwork
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
    network = BlockExcNetwork()

    discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery)

    advertiser =
      Advertiser.new(localStore, blockDiscovery, peerInfo = examplePeerInfo())

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, downloadManager
    )

    peerCtx = PeerContext(id: peerId)
    engine.peers.add(peerCtx)

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

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await engine.wantListHandler(peerId, wantList)
    await done

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

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await engine.wantListHandler(peerId, wantList)
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

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await engine.wantListHandler(peerId, wantList)

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

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendWantList: sendWantList))

    let
      md = testManifestDesc(blocks[0].cid, DefaultBlockSize.uint32, 1)
      address = BlockAddress(treeCid: md.manifest.treeCid, index: 0)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = engine.downloadManager.startDownload(desc)

    discard download.getWantHandle(address)

    await engine.blockPresenceHandler(
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

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await engine.wantListHandler(peerId, wantList)
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

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await engine.wantListHandler(peerId, wantList)
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

    let req = WantBlocksRequest(
      requestId: 1,
      treeCid: rootCid,
      ranges: @[IndexRange(start: 0'u64, count: blocks.len.uint64)],
    )

    let delivered = await network.handlers.onWantBlocksRequest(peerId, req)
    check delivered.len == blocks.len

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
