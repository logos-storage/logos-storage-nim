import pkg/chronos
import pkg/storage/stores
import pkg/storage/blockexchange
import pkg/storage/blockexchange/engine/engine {.all.}
import pkg/storage/blockexchange/engine/scheduler {.all.}
import pkg/storage/blockexchange/engine/downloadmanager {.all.}
import pkg/storage/blockexchange/engine/activedownload {.all.}
import pkg/storage/chunker
import pkg/storage/discovery
import pkg/storage/blocktype as bt

import ../../../asynctest
import ../../examples
import ../../helpers

proc waitForPeerInSwarm(
    download: ActiveDownload,
    peerId: PeerId,
    timeout = 5.seconds,
    pollInterval = 50.milliseconds,
): Future[bool] {.async.} =
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    if download.getSwarm().getPeer(peerId).isSome:
      return true
    await sleepAsync(pollInterval)
  return false

asyncchecksuite "BlockExchange - Basic Block Transfer":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    # Create two nodes
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    # Create test dataset (small - 4 blocks)
    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    # Assign all blocks to seeder
    await seeder.assignBlocks(dataset)

    # Start nodes and connect them
    await cluster.components.start()
    await connectNodes(cluster)
    leecher.mockProviders(@[seeder])

  teardown:
    await cluster.components.stop()

  test "Should download dataset using networkStore":
    await leecher.downloadDataset(dataset)

    for blk in dataset.blocks:
      let hasBlock = await blk.cid in leecher.localStore
      check hasBlock

asyncchecksuite "BlockExchange - Presence Discovery":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await seeder.assignBlocks(dataset)
    await cluster.components.start()
    await connectNodes(cluster)

  teardown:
    await cluster.components.stop()

  test "Should receive presence response for blocks peer has":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      totalBlocks = dataset.blocks.len.uint64
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: totalBlocks)
      download = leecher.downloadManager.startDownload(desc)
      address = BlockAddress(treeCid: treeCid, index: 0)

    await leecher.network.request.sendWantList(
      seeder.switch.peerInfo.peerId,
      @[address],
      priority = 0,
      cancel = false,
      wantType = WantType.WantHave,
      full = false,
      sendDontHave = false,
      rangeCount = totalBlocks,
      downloadId = download.id,
    )

    let seederId = seeder.switch.peerInfo.peerId
    check await download.waitForPeerInSwarm(seederId)

    leecher.downloadManager.cancelDownload(treeCid)

  test "Peer availability should propagate across downloads for same CID":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      totalBlocks = dataset.blocks.len.uint64
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: totalBlocks)
      download1 = leecher.engine.startDownload(desc)
      download2 = leecher.engine.startDownload(desc)
      address = BlockAddress(treeCid: treeCid, index: 0)

    await leecher.network.request.sendWantList(
      seeder.switch.peerInfo.peerId,
      @[address],
      priority = 0,
      cancel = false,
      wantType = WantType.WantHave,
      full = false,
      sendDontHave = false,
      rangeCount = totalBlocks,
      downloadId = download1.id,
    )

    let seederId = seeder.switch.peerInfo.peerId
    check await download1.waitForPeerInSwarm(seederId)
    check download2.getSwarm().getPeer(seederId).isSome
    leecher.downloadManager.cancelDownload(treeCid)

  test "Should update swarm when peer reports availability":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: dataset.blocks.len.uint64)
      download = leecher.downloadManager.startDownload(desc)
      availability = BlockAvailability.complete()

    download.updatePeerAvailability(seeder.switch.peerInfo.peerId, availability)

    let swarm = download.getSwarm()
    check swarm.activePeerCount() == 1

    let peerOpt = swarm.getPeer(seeder.switch.peerInfo.peerId)
    check peerOpt.isSome
    check peerOpt.get().availability.kind == bakComplete

    leecher.downloadManager.cancelDownload(treeCid)

asyncchecksuite "BlockExchange - Discovered Providers":
  var
    cluster: NodesCluster
    provider: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    provider = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await provider.assignBlocks(dataset)
    await cluster.components.start()

  teardown:
    await cluster.components.stop()

  test "Provider found through discovery should join the swarm":
    let
      providerId = provider.switch.peerInfo.peerId
      treeCid = dataset.manifest.treeCid
      desc = DownloadDesc(md: dataset.manifestDesc, count: dataset.blocks.len.uint64)
      download = leecher.downloadManager.startDownload(desc)

    leecher.mockProviders(@[provider])
    leecher.engine.searchForNewPeers(download)

    check eventually leecher.switch.isConnected(providerId)
    check await download.waitForPeerInSwarm(providerId)

    leecher.downloadManager.cancelDownload(treeCid)

asyncchecksuite "BlockExchange - Requested Peers":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await seeder.assignBlocks(dataset)
    await cluster.components.start()
    await connectNodes(cluster)

  teardown:
    await cluster.components.stop()

  test "Download should use a requested peer when discovery finds none":
    leecher.engine.contextFor(DownloadTransport.Direct).addRequestedPeer(
      seeder.switch.peerInfo.peerId
    )

    await leecher.downloadDataset(dataset)

    for blk in dataset.blocks:
      check (await blk.cid in leecher.localStore)

asyncchecksuite "BlockExchange - Multi-Peer Download":
  var
    cluster: NodesCluster
    seeder1: NodesComponents
    seeder2: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(3, config = NodeConfig(findFreePorts: true))
    seeder1 = cluster.components[0]
    seeder2 = cluster.components[1]
    leecher = cluster.components[2]

    let blocks = await makeRandomBlocks(8 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    let halfPoint = dataset.blocks.len div 2
    await seeder1.assignBlocks(dataset, 0 ..< halfPoint)
    await seeder2.assignBlocks(dataset, halfPoint ..< dataset.blocks.len)

    await cluster.components.start()
    await connectNodes(cluster)
    leecher.mockProviders(@[seeder1, seeder2])

  teardown:
    await cluster.components.stop()

  test "Should download blocks from multiple peers":
    await leecher.downloadDataset(dataset)

    for blk in dataset.blocks:
      let hasBlock = await blk.cid in leecher.localStore
      check hasBlock

  test "Should handle partial availability from peers":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: dataset.blocks.len.uint64)
      download = leecher.downloadManager.startDownload(desc)
      halfPoint = (dataset.blocks.len div 2).uint64
      ranges1 = @[IndexRange(start: 0'u64, count: halfPoint)]

    download.updatePeerAvailability(
      seeder1.switch.peerInfo.peerId, BlockAvailability.fromRanges(ranges1)
    )

    let ranges2 =
      @[IndexRange(start: halfPoint, count: dataset.blocks.len.uint64 - halfPoint)]
    download.updatePeerAvailability(
      seeder2.switch.peerInfo.peerId, BlockAvailability.fromRanges(ranges2)
    )

    let swarm = download.getSwarm()
    check swarm.activePeerCount() == 2

    let peersForFirst = swarm.peersWithRange(0, halfPoint)
    check seeder1.switch.peerInfo.peerId in peersForFirst

    let peersForSecond =
      swarm.peersWithRange(halfPoint, dataset.blocks.len.uint64 - halfPoint)
    check seeder2.switch.peerInfo.peerId in peersForSecond

    leecher.downloadManager.cancelDownload(treeCid)

asyncchecksuite "BlockExchange - Download Lifecycle":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await seeder.assignBlocks(dataset)
    await cluster.components.start()
    await connectNodes(cluster)
    leecher.mockProviders(@[seeder])

  teardown:
    await cluster.components.stop()

  test "Should allow multiple downloads for same CID":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      totalBlocks = dataset.blocks.len.uint64
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: totalBlocks)
      download1 = leecher.downloadManager.startDownload(desc)
      download2 = leecher.downloadManager.startDownload(desc)

    check download1.id != download2.id
    check download1.treeCid == download2.treeCid

    leecher.downloadManager.cancelDownload(treeCid)
    check leecher.downloadManager.getDownload(treeCid).isNone

  test "Two concurrent full downloads for same CID should both complete":
    let
      treeCid = dataset.manifest.treeCid
      totalBlocks = dataset.blocks.len.uint64

    let handle1 = leecher.engine.startTreeDownload(dataset.manifestDesc)
    require handle1.isOk == true

    let handle2 = leecher.engine.startTreeDownload(dataset.manifestDesc)
    require handle2.isOk == true

    let
      h1 = handle1.get()
      h2 = handle2.get()

    var
      blocksReceived1 = 0
      blocksReceived2 = 0

    for i in 0 ..< totalBlocks.int:
      if (await leecher.networkStore.getBlock(treeCid, i.Natural)).isOk:
        blocksReceived1 += 1

    for i in 0 ..< totalBlocks.int:
      if (await leecher.networkStore.getBlock(treeCid, i.Natural)).isOk:
        blocksReceived2 += 1

    check blocksReceived1 == totalBlocks.int
    check blocksReceived2 == totalBlocks.int

    leecher.engine.releaseDownload(h1)
    leecher.engine.releaseDownload(h2)

  test "Releasing one download should not cancel other downloads for same CID":
    let
      treeCid = dataset.manifest.treeCid
      totalBlocks = dataset.blocks.len.uint64

    let handle1 = leecher.engine.startTreeDownload(dataset.manifestDesc)
    require handle1.isOk
    let h1 = handle1.get()

    let handle2 = leecher.engine.startTreeDownload(dataset.manifestDesc)
    require handle2.isOk
    let h2 = handle2.get()

    leecher.engine.releaseDownload(h1)

    check leecher.downloadManager.getDownload(treeCid).isSome

    var blocksReceived = 0
    for i in 0 ..< totalBlocks.int:
      if (await leecher.networkStore.getBlock(treeCid, i.Natural)).isOk:
        blocksReceived += 1

    check blocksReceived == totalBlocks.int

    leecher.engine.releaseDownload(h2)
    check leecher.downloadManager.getDownload(treeCid).isNone

  test "Should cancel download":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      totalBlocks = dataset.blocks.len.uint64
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: totalBlocks)

    discard leecher.downloadManager.startDownload(desc)

    leecher.downloadManager.cancelDownload(treeCid)

    check leecher.downloadManager.getDownload(treeCid).isNone

asyncchecksuite "BlockExchange - Error Handling":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await seeder.assignBlocks(dataset, 0 ..< 2)

    await cluster.components.start()
    await connectNodes(cluster)

  teardown:
    await cluster.components.stop()

  test "Should handle peer with partial blocks in swarm":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: dataset.blocks.len.uint64)
      download = leecher.downloadManager.startDownload(desc)
      ranges = @[IndexRange(start: 0'u64, count: 2'u64)]

    download.updatePeerAvailability(
      seeder.switch.peerInfo.peerId, BlockAvailability.fromRanges(ranges)
    )

    let
      swarm = download.getSwarm()
      candidates = swarm.peersWithRange(0, 2)
    check seeder.switch.peerInfo.peerId in candidates

    let candidatesForMissing = swarm.peersWithRange(2, 2)
    check seeder.switch.peerInfo.peerId notin candidatesForMissing

    leecher.downloadManager.cancelDownload(treeCid)

  test "Should requeue batch on peer failure":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: dataset.blocks.len.uint64)
      download = leecher.downloadManager.startDownload(desc)
      batch = leecher.downloadManager.getNextBatch(download)
    check batch.isSome

    download.markBatchInFlight(
      batch.get.start, batch.get.count, 0, seeder.switch.peerInfo.peerId
    )

    check download.pendingBatchCount() == 1

    download.handlePeerFailure(seeder.switch.peerInfo.peerId)

    check download.pendingBatchCount() == 0
    check download.ctx.scheduler.requeuedCount() == 1

    leecher.downloadManager.cancelDownload(treeCid)

asyncchecksuite "BlockExchange - Local Block Resolution":
  var
    cluster: NodesCluster
    node1: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(1, config = NodeConfig(findFreePorts: true))
    node1 = cluster.components[0]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await node1.assignBlocks(dataset)
    await cluster.components.start()

  teardown:
    await cluster.components.stop()

  test "Download worker should complete wantHandles when all blocks are local":
    let
      manifestCid = dataset.manifestCid
      treeCid = dataset.manifest.treeCid
      totalBlocks = dataset.blocks.len.uint64
      blockSize = dataset.manifest.blockSize.uint32
      desc = DownloadDesc(md: dataset.manifestDesc, count: totalBlocks)
      download = node1.downloadManager.startDownload(desc)

    var handles: seq[BlockHandle] = @[]
    for i in 0'u64 ..< totalBlocks:
      let address = download.makeBlockAddress(i)
      handles.add(download.getWantHandle(address))

    await node1.engine.downloadWorker(download)

    for handle in handles:
      check handle.finished
      let blk = await handle
      check blk.isOk

    node1.downloadManager.cancelDownload(treeCid)

asyncchecksuite "BlockExchange - Mixed Local and Network":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(8 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await seeder.assignBlocks(dataset)

    let halfPoint = dataset.blocks.len div 2
    await leecher.assignBlocks(dataset, 0 ..< halfPoint)

    await cluster.components.start()
    await connectNodes(cluster)
    leecher.mockProviders(@[seeder])

  teardown:
    await cluster.components.stop()

  test "Should download dataset with some blocks local and some from network":
    await leecher.downloadDataset(dataset)

    for blk in dataset.blocks:
      let hasBlock = await blk.cid in leecher.localStore
      check hasBlock

  test "Should handle interleaved local and network blocks":
    for i, blk in dataset.blocks:
      if i mod 2 == 0:
        (await leecher.localStore.putBlock(blk)).tryGet()

    await leecher.downloadDataset(dataset)

    for blk in dataset.blocks:
      let hasBlock = await blk.cid in leecher.localStore
      check hasBlock

asyncchecksuite "BlockExchange - Re-download from Local":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await seeder.assignBlocks(dataset)

    await cluster.components.start()
    await connectNodes(cluster)
    leecher.mockProviders(@[seeder])

  teardown:
    await cluster.components.stop()

  test "Should re-download from local after network download":
    await leecher.downloadDataset(dataset)

    for blk in dataset.blocks:
      let hasBlock = await blk.cid in leecher.localStore
      check hasBlock

    await leecher.downloadDataset(dataset)

    for blk in dataset.blocks:
      let hasBlock = await blk.cid in leecher.localStore
      check hasBlock

asyncchecksuite "BlockExchange - NetworkStore getBlocks":
  var
    cluster: NodesCluster
    seeder: NodesComponents
    leecher: NodesComponents
    dataset: TestDataset

  setup:
    cluster = generateNodes(2, config = NodeConfig(findFreePorts: true))
    seeder = cluster.components[0]
    leecher = cluster.components[1]

    let blocks = await makeRandomBlocks(4 * 1024, 1024.NBytes)
    dataset = makeDataset(blocks).tryGet()

    await seeder.assignBlocks(dataset)
    await cluster.components.start()
    await connectNodes(cluster)
    leecher.mockProviders(@[seeder])

  teardown:
    await cluster.components.stop()

  test "getBlocks all local":
    await leecher.assignBlocks(dataset)
    await leecher.downloadDataset(dataset)

  test "getBlocks all from network":
    await leecher.downloadDataset(dataset)

  test "getBlocks mixed local and network":
    await leecher.assignBlocks(dataset, 0 ..< 2)
    await leecher.downloadDataset(dataset)
