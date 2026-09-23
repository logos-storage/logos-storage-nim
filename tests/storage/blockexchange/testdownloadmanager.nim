import std/options

import pkg/chronos
import pkg/stew/byteutils
import pkg/libp2p/peerid
import pkg/libp2p/cid

import pkg/storage/blocktype as bt
import pkg/storage/stores
import pkg/storage/blockexchange
import pkg/storage/blockexchange/engine/downloadcontext {.all.}
import pkg/storage/blockexchange/engine/activedownload {.all.}
import pkg/storage/blockexchange/engine/downloadmanager {.all.}
import pkg/storage/blockexchange/engine/scheduler {.all.}
import pkg/storage/blockexchange/engine/swarm
import pkg/storage/storagetypes

import ../helpers
import ../examples
import ../../asynctest

const
  WindowSize = 16384'u64
  Threshold = 0.75

suite "DownloadManager - Want Handles":
  test "Tree-only lookup lets cancelling an unrelated download cancel another download's read":
    let
      manager = DownloadManager.new()
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      firstDownload = manager.startDownload(DownloadDesc(md: md, count: 1))
      secondDownload = manager.startDownload(DownloadDesc(md: md, count: 1))
      # Table iteration order is not an ownership rule. Observe the selected
      # entry instead of assuming the first-created download will be returned.
      unrelatedDownload = manager.getDownload(md.manifest.treeCid).get()
      readerDownload =
        if unrelatedDownload.id == firstDownload.id: secondDownload else: firstDownload
      address = BlockAddress.init(md.manifest.treeCid, 0)
      # This read belongs to readerDownload, but master's shared store receives
      # no downloadId and therefore selects unrelatedDownload instead.
      view =
        NetworkStore.new(BlockExcEngine(downloadManager: manager), CacheStore.new())
    let reading = view.getBlock(address)
    check address in unrelatedDownload
    check address notin readerDownload
    check not reading.finished
    manager.cancelDownload(unrelatedDownload)
    var cancelled = false
    try:
      discard await reading
    except CancelledError:
      cancelled = true
    check cancelled
    # The reader failed even though its own download is still active.
    check not readerDownload.cancelled
    check not readerDownload.completionFuture.finished
    manager.cancelDownload(readerDownload)

  test "A Direct reader survives cancellation of another Direct download of the same tree":
    let
      manager = DownloadManager.new()
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      firstDownload = manager.startDownload(DownloadDesc(md: md, count: 1))
      secondDownload = manager.startDownload(DownloadDesc(md: md, count: 1))
      selectedByTreeLookup = manager.getDownload(md.manifest.treeCid).get()
      # Bind to the other download so a regression to tree-only lookup fails
      # this test regardless of table iteration order.
      readerDownload =
        if selectedByTreeLookup.id == firstDownload.id:
          secondDownload
        else:
          firstDownload
      address = BlockAddress.init(md.manifest.treeCid, 0)
      blk = bt.Block.new("independent Direct reader".toBytes).tryGet()
      view = NetworkStore.new(
        BlockExcEngine(downloadManager: manager),
        CacheStore.new(),
        downloadId = some(readerDownload.id),
      )
    check selectedByTreeLookup.id != readerDownload.id
    let reading = view.getBlock(address)
    check address in readerDownload
    manager.cancelDownload(selectedByTreeLookup)
    check not reading.finished
    discard readerDownload.completeWantHandle(address, some(blk))
    check (await reading).tryGet() == blk
    manager.cancelDownload(readerDownload)

  test "Cancelling a Direct reader's own download does not attach it to another download":
    let
      manager = DownloadManager.new()
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      otherDownload = manager.startDownload(DownloadDesc(md: md, count: 1))
      readerDownload = manager.startDownload(DownloadDesc(md: md, count: 1))
      address = BlockAddress.init(md.manifest.treeCid, 0)
      view = NetworkStore.new(
        BlockExcEngine(downloadManager: manager),
        CacheStore.new(),
        downloadId = some(readerDownload.id),
      )
    let reading = view.getBlock(address)
    check address in readerDownload
    manager.cancelDownload(readerDownload)
    var cancelled = false
    try:
      discard await reading
    except CancelledError:
      cancelled = true
    check cancelled
    check not otherDownload.cancelled
    check address notin otherDownload
    manager.cancelDownload(otherDownload)

  test "A scoped streaming read waits for its own download":
    let
      manager = DownloadManager.new()
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      directDownload = manager.startDownload(DownloadDesc(md: md, count: 1))
      mixDownload = manager.startDownload(
        DownloadDesc(md: md, count: 1, transport: DownloadTransport.Mix)
      )
      address = BlockAddress.init(md.manifest.treeCid, 0)
      blk = bt.Block.new("scoped read".toBytes).tryGet()
      view = NetworkStore.new(
        BlockExcEngine(downloadManager: manager),
        CacheStore.new(),
        downloadId = some(mixDownload.id),
      )
    discard directDownload.getWantHandle(address)
    let reading = view.getBlock(address)
    discard directDownload.completeWantHandle(address, some(blk))
    check not reading.finished
    discard mixDownload.completeWantHandle(address, some(blk))
    check (await reading).tryGet() == blk
    manager.cancelDownload(directDownload)
    manager.cancelDownload(mixDownload)

  test "Background download reuse is scoped to the selected transport":
    let
      manager = DownloadManager.new()
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      directDownload = manager.startDownload(
        DownloadDesc(
          md: md, count: 1, isBackground: true, transport: DownloadTransport.Direct
        )
      )
      mixDownload = manager.startDownload(
        DownloadDesc(
          md: md, count: 1, isBackground: true, transport: DownloadTransport.Mix
        )
      )
    check manager
      .getBackgroundDownload(md.manifest.treeCid, DownloadTransport.Direct)
      .get() == directDownload
    check manager.getBackgroundDownload(md.manifest.treeCid, DownloadTransport.Mix).get() ==
      mixDownload
    manager.cancelDownload(directDownload)
    manager.cancelDownload(mixDownload)

  test "Should add want handle":
    let
      downloadManager = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = downloadManager.startDownload(desc)

    discard download.getWantHandle(address)

    check address in download

  test "Should resolve want handle":
    let
      downloadManager = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = downloadManager.startDownload(desc)
      handle = download.getWantHandle(address)

    check address in download
    discard download.completeWantHandle(address, some(blk))
    let resolved = (await handle).tryGet
    check resolved == blk

  test "Should cancel want handle":
    let
      downloadManager = DownloadManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = downloadManager.startDownload(desc)
      handle = download.getWantHandle(address)

    check address in download
    await handle.cancelAndWait()
    check address notin download

  test "Should handle retry counters":
    let
      dm = DownloadManager.new(3)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)

    check download.retries(address) == 3
    download.decRetries(address)
    check download.retries(address) == 2
    download.decRetries(address)
    check download.retries(address) == 1
    download.decRetries(address)
    check download.retries(address) == 0
    check download.retriesExhausted(address)

asyncchecksuite "DownloadManager - Download Lifecycle":
  test "Should start new download":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)

    discard dm.startDownload(desc)

  test "Should allow multiple downloads for same CID":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      download1 = dm.startDownload(desc)
      download2 = dm.startDownload(desc)

    check download1.id != download2.id
    check download1.treeCid == download2.treeCid

  test "Multiple downloads for same CID have independent block state":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)

      download1 = dm.startDownload(desc)
      download2 = dm.startDownload(desc)

      address = BlockAddress(treeCid: md.manifest.treeCid, index: 0)
      handle1 = download1.getWantHandle(address)

    check address in download1
    check address notin download2

    let blk = bt.Block.new("test data".toBytes).tryGet()
    discard download1.completeWantHandle(address, some(blk))

    let res = await handle1
    check res.isOk

    check address notin download2

  test "Cancel one download for same CID while other continues":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      download1 = dm.startDownload(desc)
      download2 = dm.startDownload(desc)
      address = BlockAddress(treeCid: md.manifest.treeCid, index: 0)

    discard download1.getWantHandle(address)
    let handle2 = download2.getWantHandle(address)

    dm.cancelDownload(download1)

    check download1.cancelled == true
    check download2.cancelled == false

    let blk = bt.Block.new("test data".toBytes).tryGet()
    discard download2.completeWantHandle(address, some(blk))

    let res = await handle2
    check res.isOk

    check dm.getDownload(download2.id, md.manifest.treeCid).isSome
    check dm.getDownload(download1.id, md.manifest.treeCid).isNone

  test "Should start range download":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 150)
      desc = DownloadDesc(md: md, startIndex: 50, count: 100)
      download = dm.startDownload(desc)

    check download.ctx.totalBlocks == 150 # 50 + 100

  test "Should start download with missing blocks":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      missingBlocks = @[10'u64, 11, 12, 50, 51, 100]
      download = dm.startDownload(desc, missingBlocks)

    check download.ctx.scheduler.hasWork() == true

  test "Should release download":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      treeCid = md.manifest.treeCid

    discard dm.startDownload(desc)

    dm.cancelDownload(treeCid)
    check dm.getDownload(treeCid).isNone

  test "Should cancel download":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      treeCid = md.manifest.treeCid

    discard dm.startDownload(desc)

    dm.cancelDownload(treeCid)

    check dm.getDownload(treeCid).isNone

  test "Should return none for non-existent download":
    let
      dm = DownloadManager.new()
      treeCid = Cid.example

    check dm.getDownload(treeCid).isNone

  test "Should set cancelled flag when download is cancelled":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      treeCid = md.manifest.treeCid

    let downloadBefore = dm.startDownload(desc)

    check downloadBefore.cancelled == false

    dm.cancelDownload(treeCid)

    check dm.getDownload(treeCid).isNone

    check downloadBefore.cancelled == true

  test "Should allow new download for same CID after cancellation":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      oldDownload = dm.startDownload(desc)
      treeCid = md.manifest.treeCid

    dm.cancelDownload(treeCid)
    check oldDownload.cancelled == true

    let newDownload = dm.startDownload(desc)

    check newDownload.cancelled == false
    check newDownload != oldDownload

    check oldDownload.cancelled == true

  test "Should set cancelled flag when released":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      downloadRef = dm.startDownload(desc)
      treeCid = md.manifest.treeCid

    check downloadRef.cancelled == false

    dm.cancelDownload(treeCid)

    check dm.getDownload(treeCid).isNone

    check downloadRef.cancelled == true

suite "DownloadManager - Batch Management":
  test "Should get next batch":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome
    check batch.get.start == 0

  test "Should mark batch in flight":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)

    check download.pendingBatches.len == 1
    check batch.get.start in download.pendingBatches

  test "Should complete batch":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)
    download.completeBatch(batch.get.start, 0, 0)

    check download.pendingBatches.len == 0

  test "Should requeue batch at back":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch1 = dm.getNextBatch(download)

    download.markBatchInFlight(batch1.get.start, batch1.get.count, 0, peerId)

    let batch2 = dm.getNextBatch(download)
    download.markBatchInFlight(batch2.get.start, batch2.get.count, 0, peerId)

    download.requeueBatch(batch1.get.start, batch1.get.count, front = false)

    check download.pendingBatches.len == 1
    check download.ctx.scheduler.requeuedCount() == 1

  test "Should requeue batch at front":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch1 = dm.getNextBatch(download)

    download.markBatchInFlight(batch1.get.start, batch1.get.count, 0, peerId)

    download.requeueBatch(batch1.get.start, batch1.get.count, front = true)

    let nextBatch = dm.getNextBatch(download)
    check nextBatch.isSome
    check nextBatch.get.start == batch1.get.start

  test "Should handle partial batch completion":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)

    let missingRanges = @[(start: 50'u64, count: 50'u64)]
    download.partialCompleteBatch(batch.get.start, batch.get.count, 0, missingRanges, 0)

    check download.ctx.scheduler.requeuedCount() >= 1

  test "Should count local blocks on partial completion":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    # 3 blocks local, peer delivered 2, rest is missing
    download.markBatchInFlight(batch.get.start, batch.get.count, 3, peerId)

    let missingRanges = @[(start: batch.get.start + 5, count: batch.get.count - 5)]
    download.partialCompleteBatch(
      batch.get.start, batch.get.count, 2, missingRanges, 2'u64 * 65536
    )

    # received should include both local blocks (3) and peer-delivered (2)
    check download.ctx.received == 5
    check download.ctx.bytesReceived == 2'u64 * 65536

suite "DownloadManager - Download Status":
  test "Should check if download is complete":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 10)
      desc = DownloadDesc(md: md, count: 10)
      download = dm.startDownload(desc)

    check download.isDownloadComplete() == false

    download.ctx.received = 10

    check download.isDownloadComplete() == true

  test "Should check if work remains":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      download = dm.startDownload(desc)

    check download.hasWorkRemaining() == true

  test "Should return pending batch count":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      peerId = PeerId.example
      download = dm.startDownload(desc)

    check download.pendingBatchCount() == 0

    let batch = dm.getNextBatch(download)
    download.markBatchInFlight(batch.get.start, batch.get.count, 0, peerId)

    check download.pendingBatchCount() == 1

suite "DownloadManager - Peer Management":
  test "Should handle peer failure":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 1000)
      desc = DownloadDesc(md: md, count: 1000)
      peerId = PeerId.example
      download = dm.startDownload(desc)
      batch1 = dm.getNextBatch(download)

    download.markBatchInFlight(batch1.get.start, batch1.get.count, 0, peerId)

    let batch2 = dm.getNextBatch(download)
    download.markBatchInFlight(batch2.get.start, batch2.get.count, 0, peerId)

    check download.pendingBatchCount() == 2

    download.handlePeerFailure(peerId)

    check download.pendingBatchCount() == 0
    check download.ctx.scheduler.requeuedCount() == 2

  test "Should get swarm":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      download = dm.startDownload(desc)
      swarm = download.getSwarm()
    check swarm != nil

  test "Should update peer availability - add new peer":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      peerId = PeerId.example
      availability = BlockAvailability.complete()
      download = dm.startDownload(desc)

    download.updatePeerAvailability(peerId, availability)

    let
      swarm = download.getSwarm()
      peer = swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakComplete

  test "Should update peer availability - update existing peer":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      peerId = PeerId.example
      download = dm.startDownload(desc)

    download.updatePeerAvailability(peerId, BlockAvailability.unknown())

    let peerBefore = download.getSwarm().getPeer(peerId)
    check peerBefore.get.availability.kind == bakUnknown

    download.updatePeerAvailability(peerId, BlockAvailability.complete())

    let peerAfter = download.getSwarm().getPeer(peerId)
    check peerAfter.get.availability.kind == bakComplete

suite "DownloadManager - Retry Management":
  test "Should decrement block retries":
    let
      dm = DownloadManager.new(retries = 5)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)

    check download.retries(address) == 5

    let exhausted = download.decrementBlockRetries(@[address])
    check exhausted.len == 0
    check download.retries(address) == 4

  test "Should return exhausted blocks":
    let
      dm = DownloadManager.new(retries = 2)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid, 0)
      md = testManifestDesc(Cid.example, DefaultBlockSize.uint32, 1)
      desc = DownloadDesc(md: md, startIndex: address.index.uint64, count: 1)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)

    discard download.decrementBlockRetries(@[address])
    check download.retries(address) == 1

    let exhausted = download.decrementBlockRetries(@[address])
    check exhausted.len == 1
    check address in exhausted

  test "Should fail exhausted blocks":
    let
      dm = DownloadManager.new(retries = 1)
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      address = BlockAddress(treeCid: md.manifest.treeCid, index: 0)
      download = dm.startDownload(desc)

    discard download.getWantHandle(address)
    discard download.decrementBlockRetries(@[address])

    download.failExhaustedBlocks(@[address])

    check download.isBlockExhausted(address) == true
    check address notin download

  test "Should get block addresses for range":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      download = dm.startDownload(desc)
      treeCid = md.manifest.treeCid

    for i in 0'u64 ..< 5:
      let address = BlockAddress(treeCid: treeCid, index: i)
      discard download.getWantHandle(address)

    let addresses = download.getBlockAddressesForRange(0, 10)
    check addresses.len == 5

suite "DownloadContext - Basics":
  test "Should create download context":
    let
      md = testManifestDesc(Cid.example, 65536, 1000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 1000))

    check ctx.blockSize == 65536
    check ctx.totalBlocks == 1000
    check ctx.received == 0
    check ctx.bytesReceived == 0

  test "Should report not complete initially":
    let
      md = testManifestDesc(Cid.example, 65536, 100)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100))

    check ctx.isComplete() == false

  test "Should report complete when all received":
    let
      md = testManifestDesc(Cid.example, 65536, 100)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100))

    ctx.received = 100

    check ctx.isComplete() == true

  test "Should return progress":
    let
      md = testManifestDesc(Cid.example, 65536, 100)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100))

    ctx.received = 50
    ctx.bytesReceived = 50'u64 * 65536

    let progress = ctx.progress()
    check progress.blocksCompleted == 50
    check progress.totalBlocks == 100
    check progress.bytesTransferred == 50'u64 * 65536

  test "Should return remaining blocks":
    let
      md = testManifestDesc(Cid.example, 65536, 100)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100))

    check ctx.remainingBlocks() == 100

    ctx.received = 60
    check ctx.remainingBlocks() == 40

    ctx.received = 100
    check ctx.remainingBlocks() == 0

  test "Should init scheduler with missing blocks":
    let
      md = testManifestDesc(Cid.example, 65536, 1000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 1000))
      missingBlocks = @[10'u64, 11, 12, 50, 51, 100]

    ctx.scheduler.initFromIndices(missingBlocks, 256, WindowSize, Threshold)

    check ctx.scheduler.hasWork() == true

  test "Should mark batch received":
    let
      md = testManifestDesc(Cid.example, 65536, 100)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100))

    ctx.markBatchReceived(0, 10, 10'u64 * 65536)

    check ctx.received == 10
    check ctx.bytesReceived == 10'u64 * 65536

suite "DownloadContext - Windowed Presence":
  test "Should compute presence window size":
    check computeWindowSize(65536) == 1024'u64 * 1024 * 1024 div 65536
    check computeWindowSize(1024) == 1024'u64 * 1024 * 1024 div 1024
    check computeWindowSize(2'u32 * 1024 * 1024 * 1024) >= 1'u64

  test "Should initialize presence window":
    let
      md = testManifestDesc(Cid.example, 65536, 100000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100000))
      window = ctx.currentPresenceWindow()

    check window.start == 0
    check window.count > 0

  test "Should advance presence window":
    let
      md = testManifestDesc(Cid.example, 65536, 100000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100000))
      oldWindow = ctx.currentPresenceWindow()
      oldEnd = oldWindow.start + oldWindow.count
      advancedWindow = ctx.advancePresenceWindow()

    check advancedWindow.start == oldEnd
    check advancedWindow.start + advancedWindow.count > oldEnd

  test "Should check if needs next presence window":
    let
      md = testManifestDesc(Cid.example, 65536, 100000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100000))

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    check ctx.needsNextPresenceWindow() == false

    let
      window = ctx.currentPresenceWindow()
      windowEnd = window.start + window.count
      threshold = (windowEnd.float * 0.75).uint64

    var pos: uint64 = 0
    while pos < windowEnd:
      discard ctx.scheduler.take()
      pos += 256

    pos = 0
    while pos <= threshold:
      ctx.scheduler.markComplete(pos)
      pos += 256

    if windowEnd < ctx.totalBlocks:
      check ctx.needsNextPresenceWindow() == true

  test "Should not need next window when at last window":
    let
      md = testManifestDesc(Cid.example, 65536, 100)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100))
        # Small total, fits in one window

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)

    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    check ctx.needsNextPresenceWindow() == false

  test "Should trim ranges entirely below watermark":
    let
      md = testManifestDesc(Cid.example, 65536, 100000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100000))
      peerId = PeerId.example
      ranges = @[
        IndexRange(start: 0'u64, count: 400'u64),
        IndexRange(start: 2000'u64, count: 500'u64),
      ]

    discard ctx.swarm.addPeer(peerId, BlockAvailability.fromRanges(ranges))

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(256)

    ctx.trimPresenceBeforeWatermark()

    let peer = ctx.swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakRanges
    check peer.get.availability.ranges.len == 1
    check peer.get.availability.ranges[0].start == 2000
    check peer.get.availability.ranges[0].count == 500

  test "Should keep ranges spanning the watermark intact":
    let
      md = testManifestDesc(Cid.example, 65536, 100000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100000))
      peerId = PeerId.example
      ranges = @[IndexRange(start: 0'u64, count: 1000'u64)]
    discard ctx.swarm.addPeer(peerId, BlockAvailability.fromRanges(ranges))

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(256)

    ctx.trimPresenceBeforeWatermark()

    let peer = ctx.swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakRanges
    check peer.get.availability.ranges.len == 1
    check peer.get.availability.ranges[0].start == 0
    check peer.get.availability.ranges[0].count == 1000

  test "Should not trim bakComplete peers":
    let
      md = testManifestDesc(Cid.example, 65536, 100000)
      ctx = DownloadContext.new(DownloadDesc(md: md, count: 100000))
      peerId = PeerId.example

    discard ctx.swarm.addPeer(peerId, BlockAvailability.complete())

    ctx.scheduler.init(ctx.totalBlocks, 256, WindowSize, Threshold)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(0)
    discard ctx.scheduler.take()
    ctx.scheduler.markComplete(256)

    ctx.trimPresenceBeforeWatermark()

    let peer = ctx.swarm.getPeer(peerId)
    check peer.isSome
    check peer.get.availability.kind == bakComplete

suite "DownloadManager - Completion Future":
  test "Should complete batch locally":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 10)
      desc = DownloadDesc(md: md, count: 10)
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.completeBatchLocal(batch.get.start, batch.get.count)

    check download.ctx.scheduler.isEmpty()
    check download.ctx.received == 10
    check download.ctx.bytesReceived == 0
    check download.pendingBatches.len == 0
    check download.ctx.isComplete()

  test "Should resolve completion future on success":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 10)
      desc = DownloadDesc(md: md, count: 10)
      download = dm.startDownload(desc)

    check not download.completionFuture.finished

    let batch = dm.getNextBatch(download)
    check batch.isSome

    download.completeBatchLocal(batch.get.start, batch.get.count)

    check download.completionFuture.finished
    check not download.completionFuture.failed
    let res = await download.waitForComplete()
    check res.isOk

  test "Should resolve completion future with error on exhausted blocks":
    let
      dm = DownloadManager.new(retries = 1)
      md = testManifestDesc(Cid.example, 65536, 10)
      desc = DownloadDesc(md: md, count: 10)
      download = dm.startDownload(desc)
      treeCid = md.manifest.treeCid

    var addresses: seq[BlockAddress] = @[]
    for i in 0'u64 ..< 10:
      let address = BlockAddress(treeCid: treeCid, index: i)
      discard download.getWantHandle(address)
      addresses.add(address)

    discard download.decrementBlockRetries(addresses)

    download.failExhaustedBlocks(addresses)

    check download.completionFuture.finished
    check not download.completionFuture.failed
    let res = await download.waitForComplete()
    check res.isErr
    check res.error of RetriesExhaustedError

  test "Should fail completion future on cancel":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 100)
      desc = DownloadDesc(md: md, count: 100)
      download = dm.startDownload(desc)
      treeCid = md.manifest.treeCid

    check not download.completionFuture.finished

    dm.cancelDownload(treeCid)

    check download.completionFuture.finished
    check download.completionFuture.failed

  test "Should not double-complete completion future":
    let
      dm = DownloadManager.new()
      md = testManifestDesc(Cid.example, 65536, 10)
      desc = DownloadDesc(md: md, count: 10)
      download = dm.startDownload(desc)
      batch = dm.getNextBatch(download)

    check batch.isSome

    download.completeBatchLocal(batch.get.start, batch.get.count)

    check download.completionFuture.finished
    check not download.completionFuture.failed
    let result1 = await download.waitForComplete()
    check result1.isOk

    let error = (ref RetriesExhaustedError)(msg: "test error")
    download.signalCompletionIfDone(error)

    check not download.completionFuture.failed
    let result2 = await download.waitForComplete()
    check result2.isOk

  test "Should propagate error through waitForComplete async":
    let
      dm = DownloadManager.new(retries = 1)
      md = testManifestDesc(Cid.example, 65536, 10)
      desc = DownloadDesc(md: md, count: 10)
      download = dm.startDownload(desc)
      waiter = download.waitForComplete()
      treeCid = md.manifest.treeCid

    check not waiter.finished

    var addresses: seq[BlockAddress] = @[]
    for i in 0'u64 ..< 10:
      let address = BlockAddress(treeCid: treeCid, index: i)
      discard download.getWantHandle(address)
      addresses.add(address)

    discard download.decrementBlockRetries(addresses)
    download.failExhaustedBlocks(addresses)

    let res = await waiter
    check res.isErr
    check res.error of RetriesExhaustedError
