## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[sequtils, sets, options, algorithm, tables, random]

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
import pkg/libp2p/protocols/protocol
import pkg/metrics
import pkg/questionable
import pkg/questionable/results
import pkg/stew/shims/sets

import ../../stores/blockstore
import ../../errors
import ../../blocktype
import ../../utils
import ../../utils/trackedfutures
import ../../merkletree
import ../../manifest
import ../../logutils
import ../protocol/message
import ../protocol/constants

import ../network
import ../peers
import ../utils as bexutils

import ./discovery
import ./advertiser
import ./downloadmanager
import ./peertracker
import ./swarm
import ./scheduler
import ./blockexccontext

export peers, downloadmanager, discovery, swarm, scheduler, blockexccontext

logScope:
  topics = "storage blockexcengine"

declareCounter(
  storage_block_exchange_blocks_received, "storage blockexchange blocks received"
)
declareCounter(
  storage_block_exchange_discovery_requests_total,
  "Total number of peer discovery requests sent",
)
declareCounter(
  storage_block_exchange_peer_timeouts_total, "Total number of peer activity timeouts"
)
declareCounter(
  storage_block_exchange_requests_failed_total,
  "Total number of block requests that failed after exhausting retries",
)

const
  # Don't do more than one discovery request per `DiscoveryRateLimit` seconds.
  DiscoveryRateLimit = 3.seconds

type
  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore # Local block store for this instance
    contexts: array[DownloadTransport, BlockExcContext]
      ## Independent protocol instances. Mix is absent until enabled at startup.
    trackedFutures: TrackedFutures # Tracks futures of blockexc tasks
    blockexcRunning: bool # Indicates if the blockexc task is running
    downloadManager*: DownloadManager
    discovery*: DiscoveryEngine
    advertiser*: Advertiser
    lastDiscRequest: Moment
    selectionPolicy*: SelectionPolicy # Block selection policy for block scheduling
    activeDownloads*: HashSet[uint64] # Track running download workers by download ID

  DownloadHandleGeneric*[T] = object
    treeCid*: Cid
    downloadId*: uint64
    iter*: SafeAsyncIter[T]
    completionFuture*: Future[?!void].Raising([CancelledError])

  DownloadHandle* = DownloadHandleGeneric[Block]
  DownloadHandleOpaque* = DownloadHandleGeneric[void]

func contextFor*(self: BlockExcEngine, transport: DownloadTransport): BlockExcContext =
  self.contexts[transport]

func contextFor(self: BlockExcEngine, download: ActiveDownload): BlockExcContext =
  self.contexts[download.ctx.transport]

proc waitForComplete*[T](
    h: DownloadHandleGeneric[T]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  return await h.completionFuture

proc requestWantBlocks(
  self: BlockExcEngine, download: ActiveDownload, peer: PeerId, blockRange: BlockRange
): Future[WantBlocksResult[seq[BlockDeliveryView]]] {.
  async: (raises: [CancelledError])
.}

proc downloadWorker(
  self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).}

proc broadcastWantHave(
  self: BlockExcEngine,
  download: ActiveDownload,
  start: uint64,
  count: uint64,
  peers: seq[PeerId],
) {.async: (raises: [CancelledError]).}

proc ensureDownloadWorker(
  self: BlockExcEngine, download: ActiveDownload
) {.gcsafe, raises: [].}

proc startDownload(
  self: BlockExcEngine, desc: DownloadDesc
): ActiveDownload {.gcsafe, raises: [].}

proc startDownload(
  self: BlockExcEngine, desc: DownloadDesc, missingBlocks: seq[uint64]
): ActiveDownload {.gcsafe, raises: [].}

proc start*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Start the blockexc task
  ##
  await self.discovery.start()
  await self.advertiser.start()

  if self.blockexcRunning:
    warn "Starting blockexc twice"
    return

  self.blockexcRunning = true
  for blockExc in self.contexts:
    if not blockExc.isNil:
      blockExc.start()

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Stop the blockexc
  ##

  await self.trackedFutures.cancelTracked()
  for blockExc in self.contexts:
    if not blockExc.isNil:
      await blockExc.stop()
  await self.discovery.stop()
  await self.advertiser.stop()

  trace "NetworkStore stop"
  if not self.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  self.blockexcRunning = false

  trace "NetworkStore stopped"

proc searchForNewPeers(self: BlockExcEngine, download: ActiveDownload) =
  let
    cid = download.manifestCid
    transport = download.ctx.transport
  if not self.discovery.lookupPending(download):
    if self.lastDiscRequest + DiscoveryRateLimit >= Moment.now():
      return
    trace "Searching for new peers for", cid = cid
    storage_block_exchange_discovery_requests_total.inc()
    self.lastDiscRequest = Moment.now()

  proc joinSwarm(
      providers: seq[PeerRecord]
  ): Future[void] {.async: (raises: [CancelledError]).} =
    if download.cancelled:
      return

    let blockExc = self.contextFor(download)
    if blockExc.isNil:
      trace "Skipping providers because selected transport is unavailable",
        transport = transport
      return

    let swarm = download.ctx.swarm
    var
      connected: seq[PeerRecord]
      unconnected: seq[PeerRecord]
      busy: HashSet[PeerId]
    for batch in download.pendingBatches.values:
      busy.incl(batch.peerId)
    for provider in providers:
      if swarm.getPeer(provider.peerId).isSome or
          not blockExc.dialCooldownExpired(provider.peerId):
        continue
      if provider.peerId in blockExc.peers:
        connected.add(provider)
      else:
        unconnected.add(provider)
    shuffle(connected)
    shuffle(unconnected)

    var dialing: seq[PeerRecord]
    for provider in connected & unconnected:
      let peerId = provider.peerId
      if swarm.addPeer(peerId, BlockAvailability.unknown()) or
          swarm.replaceUnknownPeer(peerId, BlockAvailability.unknown(), busy):
        busy.incl(peerId)
        dialing.add(provider)

    let dialed = await allFinished(dialing.mapIt(blockExc.network.dialPeer(it)))
    var joined: seq[PeerId]
    for i, f in dialed:
      let peerId = dialing[i].peerId
      if f.failed:
        trace "Failed to dial discovered provider", peer = peerId
        discard swarm.removePeer(peerId)
        blockExc.recordDialFailure(peerId)
      else:
        joined.add(peerId)

    if joined.len > 0 and not download.cancelled:
      let (windowStart, windowCount) = download.ctx.currentPresenceWindow()
      await self.broadcastWantHave(download, windowStart, windowCount, joined)

  self.discovery.queueFindBlocksReq(download, joinSwarm)

proc banAndDropPeer(
    self: BlockExcEngine, download: ActiveDownload, peerId: PeerId
) {.async: (raises: [CancelledError]).} =
  download.ctx.swarm.banPeer(peerId)
  download.handlePeerFailure(peerId)
  let blockExc = self.contextFor(download)
  if not blockExc.isNil:
    await blockExc.network.dropPeer(peerId)

proc validateBlockDeliveryView(self: BlockExcEngine, view: BlockDeliveryView): ?!void =
  without proof =? view.proof:
    return failure("Missing proof")

  if proof.index.uint64 != view.address.index:
    return failure(
      "Proof index " & $proof.index & " doesn't match leaf index " & $view.address.index
    )

  without expectedMhash =? view.cid.mhash.mapFailure, err:
    return failure("Unable to get mhash from cid for block, nested err: " & err.msg)

  without computedMhash =?
    MultiHash.digest(
      $expectedMhash.mcodec,
      view.sharedBuf.data.toOpenArray(
        view.dataOffset, view.dataOffset + view.dataLen - 1
      ),
    ).mapFailure, err:
    return failure("Unable to compute hash of block data, nested err: " & err.msg)

  if computedMhash != expectedMhash:
    return failure("Block data hash doesn't match claimed CID")

  without treeRoot =? view.address.treeCid.mhash.mapFailure, err:
    return failure("Unable to get mhash from treeCid for block, nested err: " & err.msg)

  if err =? proof.verify(computedMhash, treeRoot).errorOption:
    return failure("Unable to verify proof for block, nested err: " & err.msg)

  return success()

proc sendWantBlocksRequest(
    self: BlockExcEngine,
    download: ActiveDownload,
    start: uint64,
    count: uint64,
    missingIndices: seq[uint64],
    peer: PeerContext,
): Future[void] {.async: (raises: [CancelledError]).} =
  if download.cancelled:
    return

  let treeCid = download.treeCid

  # missingIndices must be sorted ascending with no duplicates for correct coalescing
  var ranges: seq[IndexRange] = @[]
  if missingIndices.len > 0:
    var
      rangeStart = missingIndices[0]
      rangeCount: uint64 = 1

    for i in 1 ..< missingIndices.len:
      if missingIndices[i] == rangeStart + rangeCount:
        rangeCount += 1
      else:
        ranges.add(IndexRange(start: rangeStart, count: rangeCount))
        rangeStart = missingIndices[i]
        rangeCount = 1

    ranges.add(IndexRange(start: rangeStart, count: rangeCount))

  trace "Requesting missing blocks",
    treeCid = treeCid,
    originalRange = $(start, count),
    missing = missingIndices.len,
    ranges = ranges.len,
    peer = peer.id

  let
    requestStartTime = Moment.now()
    requestResult = await self.requestWantBlocks(
      download, peer.id, BlockRange(treeCid: treeCid, ranges: ranges)
    )
    rttMicros = (Moment.now() - requestStartTime).microseconds.uint64

  if download.cancelled:
    return

  # request might have timed-out and have been requeued to another peer
  # if yes, then discard response, it's already handled.
  download.pendingBatches.withValue(start, pending):
    if pending[].peerId != peer.id:
      # discard it, was reassigned
      return
  do:
    # either completed or requeued
    return

  if requestResult.isErr:
    warn "Batch request failed", peer = peer.id, error = requestResult.error.msg
    let swarm = download.ctx.swarm
    if swarm.recordPeerFailure(peer.id):
      warn "Peer exceeded max failures, removing from swarm", peer = peer.id
      if swarm.removePeer(peer.id).isNone:
        trace "Peer was not in swarm", peer = peer.id

      download.handlePeerFailure(peer.id)
    else:
      # we can requeue immediately (cancels timeout), no benefit waiting for timeout.
      download.requeueBatch(start, count, front = true)
    return

  let allBlockViews = requestResult.get

  if allBlockViews.len == 0:
    trace "Peer responded with zero blocks", peer = peer.id, treeCid = treeCid
    download.requeueBatch(start, count, front = false)
    return

  trace "Received batch response",
    treeCid = treeCid,
    originalRange = $(start, count),
    received = allBlockViews.len,
    requested = missingIndices.len,
    peer = peer.id

  var
    totalBytes: uint64 = 0
    validCount: int = 0
    receivedIndices: HashSet[uint64]

  for view in allBlockViews:
    if not bexutils.isIndexInRanges(
      view.address.index.uint64, ranges, sortedRanges = true
    ):
      warn "Received unrequested block", index = view.address.index, ranges = ranges.len
      continue

    if view.address.index.uint64 >= download.ctx.totalBlocks:
      warn "Received block with out-of-bounds index - banning peer",
        index = view.address.index,
        totalBlocks = download.ctx.totalBlocks,
        peer = peer.id
      await self.banAndDropPeer(download, peer.id)
      return

    if err =? self.validateBlockDeliveryView(view).errorOption:
      error "Block validation failed - corrupted data from peer",
        address = view.address, msg = err.msg, peer = peer.id
      warn "Banning peer for sending corrupted block data", peer = peer.id
      await self.banAndDropPeer(download, peer.id)
      return

    let
      bd = view.toBlockDelivery()
      putResult = await self.localStore.putBlock(bd.blk)
    if putResult.isErr:
      warn "Failed to store block", address = bd.address, error = putResult.error.msg
      continue

    let proofResult = await self.localStore.putCidAndProof(
      bd.address.treeCid, bd.address.index, bd.blk.cid, bd.proof.get
    )
    if proofResult.isErr:
      warn "Failed to store proof", address = bd.address
      discard await self.localStore.delBlock(bd.blk.cid)
      continue

    totalBytes += bd.blk.data[].len.uint64
    validCount += 1
    receivedIndices.incl(bd.address.index.uint64)

    if bd.address in download.blocks:
      discard download.completeWantHandle(bd.address, some(bd.blk))

  storage_block_exchange_blocks_received.inc(validCount.int64)

  download.ctx.swarm.recordBatchSuccess(peer, rttMicros, totalBytes)

  if validCount < missingIndices.len:
    trace "Peer delivered partial batch, computing missing ranges",
      peer = peer.id, requested = missingIndices.len, received = validCount

    var stillMissing: seq[uint64]
    for idx in missingIndices:
      if idx notin receivedIndices:
        stillMissing.add(idx)

    if stillMissing.len > 0:
      var penaltyAddresses: seq[BlockAddress]
      let peerAvail = download.ctx.swarm.getPeer(peer.id)
      for idx in stillMissing:
        if peerAvail.isSome and peerAvail.get().availability.hasRange(idx, 1):
          penaltyAddresses.add(download.makeBlockAddress(idx))

      let exhausted = download.decrementBlockRetries(penaltyAddresses)
      if exhausted.len > 0:
        warn "Blocks exhausted retries after partial delivery",
          treeCid = treeCid, exhaustedCount = exhausted.len
        download.failExhaustedBlocks(exhausted)
        let exhaustedIndices = exhausted.mapIt(it.index.uint64).toHashSet
        stillMissing = stillMissing.filterIt(it notin exhaustedIndices)

    var missingRanges: seq[tuple[start: uint64, count: uint64]] = @[]
    if stillMissing.len > 0:
      stillMissing.sort()
      var
        rangeStart = stillMissing[0]
        rangeCount: uint64 = 1

      for i in 1 ..< stillMissing.len:
        if stillMissing[i] == rangeStart + rangeCount:
          rangeCount += 1
        else:
          missingRanges.add((rangeStart, rangeCount))
          rangeStart = stillMissing[i]
          rangeCount = 1

      missingRanges.add((rangeStart, rangeCount))

    trace "Partial batch completion - requeuing missing ranges",
      treeCid = treeCid,
      originalStart = start,
      originalCount = count,
      received = validCount,
      missingRanges = missingRanges.len

    download.partialCompleteBatch(
      start, count, validCount.uint64, missingRanges, totalBytes
    )
  else:
    download.completeBatch(start, validCount.uint64, totalBytes)

proc ensureDownloadWorker(
    self: BlockExcEngine, download: ActiveDownload
) {.gcsafe, raises: [].} =
  let id = download.id
  if id in self.activeDownloads:
    return

  self.activeDownloads.incl(id)

  proc wrappedDownloadWorker() {.async: (raises: []).} =
    try:
      await self.downloadWorker(download)
    finally:
      self.activeDownloads.excl(id)

  self.trackedFutures.track(wrappedDownloadWorker())

proc startDownload(
    self: BlockExcEngine, desc: DownloadDesc
): ActiveDownload {.gcsafe, raises: [].} =
  result = self.downloadManager.startDownload(desc)
  self.ensureDownloadWorker(result)

proc startDownload(
    self: BlockExcEngine, desc: DownloadDesc, missingBlocks: seq[uint64]
): ActiveDownload {.gcsafe, raises: [].} =
  result = self.downloadManager.startDownload(desc, missingBlocks)
  self.ensureDownloadWorker(result)

proc broadcastWantHave(
    self: BlockExcEngine,
    download: ActiveDownload,
    start: uint64,
    count: uint64,
    peers: seq[PeerId],
) {.async: (raises: [CancelledError]).} =
  let blockExc = self.contextFor(download)
  if blockExc.isNil:
    return
  let
    rangeAddress = BlockAddress.init(download.treeCid, start)
    network = blockExc.network
  for peerId in peers:
    let swarmPeer = download.ctx.swarm.getPeer(peerId)
    if swarmPeer.isSome and swarmPeer.get().availability.kind == bakComplete:
      # Skip presence request for peer with Complete availability.
      continue

    try:
      await network.request
        .sendWantList(
          peerId,
          @[rangeAddress],
          priority = 0,
          cancel = false,
          wantType = WantType.WantHave,
          full = false,
          sendDontHave = false,
          rangeCount = count,
          downloadId = download.id,
        )
        .wait(DefaultWantHaveSendTimeout)
    except AsyncTimeoutError:
      warn "Want-have send timed out", peer = peerId
    except CatchableError as err:
      warn "Want-have send failed", peer = peerId, error = err.msg

proc downloadWorker(
    self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).} =
  ## Continuously schedules batches to peers until download completes.
  ## Supports concurrent batch requests per peer based on BDP pipeline depth.
  let blockExc = self.contextFor(download)
  if blockExc.isNil:
    return
  let
    treeCid = download.treeCid
    retryInterval = self.downloadManager.retryInterval
    peers = blockExc.peers
    network = blockExc.network
    peerTracker = blockExc.peerTracker
  logScope:
    treeCid = treeCid

  try:
    if not download.fetchLocal:
      blockExc.admitRequestedPeers(download.ctx.swarm)
      self.searchForNewPeers(download)

    while not download.cancelled and not download.isDownloadComplete():
      let ctx = download.ctx
      if not download.fetchLocal and ctx.needsNextPresenceWindow():
        let (newStart, newCount) = ctx.advancePresenceWindow()

        ctx.trimPresenceBeforeWatermark()

        # Broadcast want-have for the new window to swarm peers only
        let swarmPeers = ctx.swarm.members()

        trace "Advancing presence window",
          treeCid = treeCid,
          newWindowStart = newStart,
          newWindowCount = newCount,
          watermark = ctx.scheduler.completedWatermark(),
          swarmPeers = swarmPeers.len

        await self.broadcastWantHave(download, newStart, newCount, swarmPeers)

      # Broadcast availability to peers
      if not download.fetchLocal and ctx.shouldBroadcastAvailability():
        let broadcastRanges = ctx.getAvailabilityBroadcast()
        if broadcastRanges.len > 0:
          let advertised = (await self.localStore.isAdvertised(treeCid)).valueOr:
            warn "Unable to read advertise state", treeCid = treeCid, err = error.msg
            false

          if advertised:
            trace "Broadcasting availability to swarm",
              treeCid = treeCid,
              rangeCount = broadcastRanges.len,
              swarmPeers = ctx.swarm.peerCount()

            let presence = BlockPresence(
              address: BlockAddress(treeCid: treeCid, index: broadcastRanges[0].start),
              kind: BlockPresenceType.HaveRange,
              ranges: broadcastRanges,
            )

            for peerId in ctx.swarm.members():
              let peerOpt = ctx.swarm.getPeer(peerId)
              if peerOpt.isSome and peerOpt.get().availability.kind == bakComplete:
                continue

              try:
                await network.request.sendPresence(peerId, @[presence]).wait(
                  DefaultWantHaveSendTimeout
                )
              except AsyncTimeoutError:
                trace "Availability broadcast send timed out", peer = peerId
              except CatchableError as err:
                trace "Failed to broadcast availability", peer = peerId, error = err.msg

          ctx.markAvailabilityBroadcasted()

      let batchOpt = self.downloadManager.getNextBatch(download)
      if batchOpt.isNone:
        let pendingBatchCount = download.pendingBatchCount()

        if pendingBatchCount == 0 and download.isDownloadComplete():
          break

        await sleepAsync(100.milliseconds)
        continue

      let (start, count) = batchOpt.get()
      logScope:
        batchStart = start
        batchCount = count

      var
        missingIndices: seq[uint64] = @[]
        localBlockCount: uint64 = 0
        bailFetchLocal = false

      block localScan:
        var lastIdle = Moment.now()
        let runtimeQuota = 100.milliseconds

        for i in start ..< start + count:
          if (Moment.now() - lastIdle) >= runtimeQuota:
            await idleAsync()
            lastIdle = Moment.now()

          let address = download.makeBlockAddress(i)
          if download.isBlockExhausted(address):
            continue

          let exists = await address in self.localStore

          var missing = not exists
          if exists:
            let blkResult = await self.localStore.getBlock(address)
            if blkResult.isOk:
              localBlockCount += 1
              if address in download.blocks:
                discard download.completeWantHandle(address, some(blkResult.get))
            else:
              missing = true

          if missing:
            if download.fetchLocal:
              download.failLocalMissing(address)
              bailFetchLocal = true
              break localScan
            missingIndices.add(i)

      if bailFetchLocal:
        continue

      if missingIndices.len == 0:
        download.completeBatchLocal(start, localBlockCount)
        continue

      if download.cancelled or download.fetchLocal:
        continue

      let swarm = download.ctx.swarm
      var shouldBroadcast = false

      if swarm.peersNeeded() != shHealthy:
        blockExc.admitRequestedPeers(swarm)
        self.searchForNewPeers(download)

      if swarm.peersWithRange(start, count).len == 0:
        shouldBroadcast = true

      if shouldBroadcast:
        let swarmPeers = swarm.members()

        if swarmPeers.len > 0:
          trace "Broadcasting want-have for batch range",
            treeCid = treeCid, start = start, count = count, peerCount = swarmPeers.len

          await self.broadcastWantHave(download, start, count, swarmPeers)
          # Give peers a short time to respond with presence
          await sleepAsync(50.milliseconds)
        else:
          await download.handleBatchRetry(start, count, retryInterval)
          continue

      if peers.len == 0:
        await download.handleBatchRetry(start, count, DiscoveryRateLimit)
        continue

      let staleUnknown = swarm.staleUnknownPeers()
      if staleUnknown.len > 0:
        let rangeAddress = download.makeBlockAddress(start)

        trace "Re-querying stale unknown peers",
          treeCid = treeCid,
          staleUnknownCount = staleUnknown.len,
          batchStart = start,
          batchCount = count

        for peerId in staleUnknown:
          let swarmPeer = swarm.getPeer(peerId)
          if swarmPeer.isSome:
            swarmPeer.get().touch()

          try:
            await network.request
              .sendWantList(
                peerId,
                @[rangeAddress],
                priority = 0,
                cancel = false,
                wantType = WantType.WantHave,
                full = false,
                sendDontHave = false,
                rangeCount = count,
                downloadId = download.id,
              )
              .wait(DefaultWantHaveSendTimeout)
          except AsyncTimeoutError:
            trace "Re-query stale unknown peer send timed out", peer = peerId
          except CatchableError as err:
            trace "Failed to re-query stale unknown peer",
              peer = peerId, error = err.msg

        await sleepAsync(50.milliseconds)

      let
        batchBytes = download.ctx.batchBytes
        selection =
          swarm.selectPeerForBatch(peers, start, count, batchBytes, peerTracker)

      if selection.kind == pskNoPeers:
        trace "No peer with range, searching for new peers"
        let
          hasActivePeers = swarm.activePeerCount() > 0
          waitTime = if hasActivePeers: retryInterval else: DiscoveryRateLimit
        await download.handleBatchRetry(start, count, waitTime)
        continue

      if selection.kind == pskAtCapacity:
        download.requeueBatch(start, count, front = false)
        await sleepAsync(10.milliseconds)
        continue

      let peer = selection.peer

      download.markBatchInFlight(start, count, localBlockCount, peer.id)

      let batchFuture =
        self.sendWantBlocksRequest(download, start, count, missingIndices, peer)

      peerTracker.track(peer.id, batchFuture)

      download.setBatchRequestFuture(start, batchFuture)

      let timeout = download.ctx.batchTimeout(peer, count)
      proc batchTimeoutHandler(dl: ActiveDownload) {.async: (raises: []).} =
        try:
          await sleepAsync(timeout)
        except CancelledError:
          return

        if dl.cancelled:
          return

        dl.pendingBatches.withValue(start, pending):
          if pending[].peerId == peer.id:
            trace "Batch timed out", peer = peer.id, start = start, count = count
            storage_block_exchange_peer_timeouts_total.inc()

            let swarm = dl.ctx.swarm
            if swarm.recordPeerTimeout(peer.id):
              warn "Peer exceeded max timeouts, removing from swarm", peer = peer.id
              discard swarm.removePeer(peer.id)

            let
              addresses = dl.getBlockAddressesForRange(start, count)
              exhausted = dl.decrementBlockRetries(addresses)

            if exhausted.len > 0:
              warn "Blocks exhausted retries after timeout",
                treeCid = treeCid, exhaustedCount = exhausted.len
              dl.failExhaustedBlocks(exhausted)

            let reqFuture = pending[].requestFuture
            dl.requeueBatch(start, count, front = true)

            if not reqFuture.isNil and not reqFuture.finished:
              reqFuture.cancelSoon()

      let timeoutFut = batchTimeoutHandler(download)
      self.trackedFutures.track(timeoutFut)
      download.setBatchTimeoutFuture(start, timeoutFut)

      await sleepAsync(10.milliseconds)
  except CancelledError:
    trace "Batch download loop cancelled"
  except CatchableError as exc:
    error "Error in batch download loop", err = exc.msg

proc toDownloadDesc*(
    md: ManifestDescriptor,
    selectionPolicy: SelectionPolicy = spSequential,
    isBackground: bool = false,
    fetchLocal: bool = false,
    transport: DownloadTransport = DownloadTransport.Direct,
): DownloadDesc =
  DownloadDesc(
    transport: transport,
    md: md,
    startIndex: 0,
    count: md.manifest.blocksCount.uint64,
    selectionPolicy: selectionPolicy,
    isBackground: isBackground,
    fetchLocal: fetchLocal,
  )

proc startTreeDownloadGeneric[T: Block | void](
    self: BlockExcEngine,
    md: ManifestDescriptor,
    selectionPolicy: SelectionPolicy = spSequential,
    isBackground: bool = false,
    fetchLocal: bool = false,
    transport: DownloadTransport = DownloadTransport.Direct,
): ?!DownloadHandleGeneric[T] =
  ## - T = Block: Returns actual block data (for streaming)
  ## - T = void: Returns success/failure only (for prefetching)

  if self.contexts[transport].isNil:
    return failure($transport & " transport is not enabled")

  let
    desc = toDownloadDesc(
      md,
      selectionPolicy = selectionPolicy,
      isBackground = isBackground,
      fetchLocal = fetchLocal,
      transport = transport,
    )
    activeDownload = self.startDownload(desc)
    treeCid = md.manifest.treeCid
    totalBlocks = md.manifest.blocksCount.uint64

  when T is Block:
    trace "Started tree block download", treeCid = treeCid, totalBlocks = totalBlocks

  when T is void:
    type HandleT = BlockHandleOpaque
  else:
    type HandleT = BlockHandle

  var
    pendingHandle: Option[HandleT] = none(HandleT)
    nextBlockToRequest: uint64 = 0

  proc isFinished(): bool =
    nextBlockToRequest >= totalBlocks and pendingHandle.isNone

  proc genNext(): Future[?!T] {.async: (raises: [CancelledError]).} =
    while pendingHandle.isNone and nextBlockToRequest < totalBlocks:
      let address = BlockAddress(treeCid: treeCid, index: nextBlockToRequest)
      nextBlockToRequest += 1

      let handle =
        when T is void:
          activeDownload.getWantHandleOpaque(address)
        else:
          activeDownload.getWantHandle(address)

      when T is void:
        let exists =
          try:
            await address in self.localStore
          except CatchableError:
            false
        if exists:
          discard activeDownload.completeWantHandle(address)
        elif fetchLocal:
          handle.cancelSoon()
          return failure(
            newException(BlockNotFoundError, "Block not found locally: " & $address)
          )
      else:
        let blkResult = await self.localStore.getBlock(address)
        if blkResult.isOk:
          discard activeDownload.completeWantHandle(address, some(blkResult.get))
        elif not (blkResult.error of BlockNotFoundError) or fetchLocal:
          handle.cancelSoon()
          return failure(blkResult.error)

      pendingHandle = some(handle)

    if pendingHandle.isNone:
      return failure("No more blocks")

    let handle = pendingHandle.get()
    pendingHandle = none(HandleT)
    let blkResult = await handle
    if blkResult.isOk:
      activeDownload.markBlockReturned()
    return blkResult

  success DownloadHandleGeneric[T](
    treeCid: treeCid,
    downloadId: activeDownload.id,
    iter: SafeAsyncIter[T].new(genNext, isFinished),
    completionFuture: activeDownload.completionFuture,
  )

proc startTreeDownload*(
    self: BlockExcEngine,
    md: ManifestDescriptor,
    fetchLocal: bool = false,
    transport: DownloadTransport = DownloadTransport.Direct,
): ?!DownloadHandle =
  startTreeDownloadGeneric[Block](
    self, md, fetchLocal = fetchLocal, transport = transport
  )

proc startTreeDownloadOpaque*(
    self: BlockExcEngine,
    md: ManifestDescriptor,
    selectionPolicy: SelectionPolicy = spSequential,
    isBackground: bool = false,
    fetchLocal: bool = false,
    transport: DownloadTransport = DownloadTransport.Direct,
): ?!DownloadHandleOpaque =
  startTreeDownloadGeneric[void](
    self,
    md,
    selectionPolicy = selectionPolicy,
    isBackground = isBackground,
    fetchLocal = fetchLocal,
    transport = transport,
  )

proc releaseDownload*[T](self: BlockExcEngine, handle: DownloadHandleGeneric[T]) =
  self.downloadManager.releaseDownload(handle.downloadId, handle.treeCid)

proc cancelDownload*(self: BlockExcEngine, treeCid: Cid) =
  self.downloadManager.cancelDownload(treeCid)

proc cancelBackgroundDownload*(
    self: BlockExcEngine, downloadId: uint64, treeCid: Cid
): bool =
  self.downloadManager.cancelBackgroundDownload(downloadId, treeCid)

proc getDownloadProgress*(
    self: BlockExcEngine, downloadId: uint64, treeCid: Cid
): Option[DownloadProgress] =
  self.downloadManager.getDownloadProgress(downloadId, treeCid)

proc requestWantBlocks(
    self: BlockExcEngine, download: ActiveDownload, peer: PeerId, blockRange: BlockRange
): Future[WantBlocksResult[seq[BlockDeliveryView]]] {.
    async: (raises: [CancelledError])
.} =
  let blockExc = self.contextFor(download)
  if blockExc.isNil:
    return err(
      wantBlocksError(
        NoConnection, $download.ctx.transport & " transport is not enabled"
      )
    )
  let response = ?await blockExc.network.sendWantBlocksRequest(peer, blockRange)
  var blockViews: seq[BlockDeliveryView]

  for btBlock in response.blocks:
    let viewResult =
      toBlockDeliveryView(btBlock, response.treeCid, response.sharedBuffer)
    if viewResult.isOk:
      blockViews.add(viewResult.get)
    else:
      warn "Failed to convert block entry to view", error = viewResult.error.msg

  if blockViews.len == 0:
    trace "Request succeeded but received zero blocks",
      peer = peer,
      treeCid = blockRange.treeCid,
      rangeCount = blockRange.ranges.len,
      responseBlockCount = response.blocks.len

  return ok(blockViews)

proc attach*(self: BlockExcEngine, blockExc: BlockExcContext) =
  doAssert self.contexts[blockExc.transport].isNil,
    $blockExc.transport & " BlockExchange is already enabled"
  self.contexts[blockExc.transport] = blockExc
  if self.blockexcRunning:
    blockExc.start()

proc newBlockExcProtocol*(self: BlockExcEngine): LPProtocol =
  let direct = self.contextFor(DownloadTransport.Direct)
  doAssert not direct.isNil,
    "Direct BlockExchange context must be attached before mounting"

  proc handler(
      conn: Connection, codec: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    for blockExc in self.contexts:
      if not blockExc.isNil and blockExc.network.transport.accepts(conn):
        await blockExc.network.handleConnection(conn)
        return
    await conn.close()

  # Both transports use this one mounted codec and its incoming-stream quota.
  LPProtocol.new(
    @[Codec], handler, maxIncomingStreamsTotal = direct.network.sendConcurrencyLimit
  )

proc detach*(
    self: BlockExcEngine, transport: DownloadTransport
) {.async: (raises: []).} =
  ## Remove BlockExchange's Mix instance after MixTransport has stopped, or
  ## when startup fails. This does not stop the shared transport service.
  let blockExc = self.contexts[transport]
  self.contexts[transport] = nil
  if not blockExc.isNil:
    await blockExc.stop()

proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    downloadManager: DownloadManager,
    selectionPolicy = spSequential,
): BlockExcEngine =
  let self = BlockExcEngine(
    localStore: localStore,
    downloadManager: downloadManager,
    trackedFutures: TrackedFutures(),
    discovery: discovery,
    advertiser: advertiser,
    selectionPolicy: selectionPolicy,
    activeDownloads: initHashSet[uint64](),
  )

  return self
