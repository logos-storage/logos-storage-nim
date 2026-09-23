## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[sequtils, sets, options, algorithm, sugar, tables]

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
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
import ../../mix
import ../../logutils
import ../protocol/message
import ../protocol/presence
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
import ./peerselection

export peers, downloadmanager, discovery, swarm, scheduler, peerselection

logScope:
  topics = "storage blockexcengine"

declareCounter(
  storage_block_exchange_want_have_lists_received,
  "storage blockexchange wantHave lists received",
)
declareCounter(storage_block_exchange_blocks_sent, "storage blockexchange blocks sent")
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
  PeerTrackerSweepInterval = 15.seconds

type
  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore # Local block store for this instance
    networks*: BlockExcNetworks
    peers*: PeerContextStore # Peers we're currently actively exchanging with
    mixPeers*: PeerContextStore
    mixPeerTracker: PeerInFlightTracker
    peerSelectionPolicies: array[DownloadTransport, PresencePeerSelectionPolicy]
    presenceQueryPolicies: array[DownloadTransport, PresenceQueryPolicy]
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

func peersFor*(self: BlockExcEngine, transport: DownloadTransport): PeerContextStore =
  if transport == DownloadTransport.Mix: self.mixPeers else: self.peers

func trackerFor(
    self: BlockExcEngine, transport: DownloadTransport
): PeerInFlightTracker =
  if transport == DownloadTransport.Mix:
    self.mixPeerTracker
  else:
    self.downloadManager.peerTracker

proc waitForComplete*[T](
    h: DownloadHandleGeneric[T]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  return await h.completionFuture

proc requestWantBlocks*(
  self: BlockExcEngine,
  peer: PeerId,
  blockRange: BlockRange,
  transport: DownloadTransport = DownloadTransport.Direct,
): Future[WantBlocksResult[seq[BlockDeliveryView]]] {.
  async: (raises: [CancelledError])
.}

proc downloadWorker(
  self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).}

proc ensureDownloadWorker(
  self: BlockExcEngine, download: ActiveDownload
) {.gcsafe, raises: [].}

proc startDownload(
  self: BlockExcEngine, desc: DownloadDesc
): ActiveDownload {.gcsafe, raises: [].}

proc startDownload(
  self: BlockExcEngine, desc: DownloadDesc, missingBlocks: seq[uint64]
): ActiveDownload {.gcsafe, raises: [].}

proc peerTrackerSweepLoop(self: BlockExcEngine) {.async: (raises: []).} =
  try:
    while self.blockexcRunning:
      await sleepAsync(PeerTrackerSweepInterval)
      await self.downloadManager.peerTracker.sweep()
      await self.mixPeerTracker.sweep()
  except CancelledError:
    discard
  except CatchableError as exc:
    warn "Peer tracker sweep loop failed", err = exc.msg

proc start*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Start the blockexc task
  ##
  await self.discovery.start()
  await self.advertiser.start()

  if self.blockexcRunning:
    warn "Starting blockexc twice"
    return

  self.blockexcRunning = true
  self.trackedFutures.track(self.peerTrackerSweepLoop())

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Stop the blockexc
  ##

  await self.trackedFutures.cancelTracked()
  await self.networks.stop()
  await self.discovery.stop()
  await self.advertiser.stop()

  trace "NetworkStore stop"
  if not self.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  self.blockexcRunning = false

  trace "NetworkStore stopped"

proc searchForNewPeers(self: BlockExcEngine, cid: Cid, transport: DownloadTransport) =
  if self.lastDiscRequest + DiscoveryRateLimit < Moment.now():
    trace "Searching for new peers for", cid = cid
    storage_block_exchange_discovery_requests_total.inc()
    self.lastDiscRequest = Moment.now()
    self.discovery.queueFindBlocksReq(@[cid], transport)

proc banAndDropPeer(
    self: BlockExcEngine, download: ActiveDownload, peerId: PeerId
) {.async: (raises: [CancelledError]).} =
  download.ctx.swarm.banPeer(peerId)
  download.handlePeerFailure(peerId)
  let network = self.networks.networkFor(download.ctx.transport)
  if not network.isNil:
    await network.dropPeer(peerId)

proc evictPeer(self: BlockExcEngine, peer: PeerId, transport: DownloadTransport) =
  ## Cleanup disconnected peer
  ##

  trace "Evicting disconnected/departed peer", peer
  self.peersFor(transport).remove(peer)
  self.trackerFor(transport).clearPeer(peer)

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
      peer.id, BlockRange(treeCid: treeCid, ranges: ranges), download.ctx.transport
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
    peers: seq[PeerContext],
) {.async: (raises: [CancelledError]).} =
  let rangeAddress = BlockAddress.init(download.treeCid, start)
  let network = self.networks.networkFor(download.ctx.transport)
  if network.isNil:
    return
  for peerCtx in peers:
    if not download.addPeerIfAbsent(
      peerCtx.id,
      BlockAvailability.unknown(),
      self.presenceQueryPolicies[download.ctx.transport],
    ):
      # Skip presence request for peer with Complete availability, or when
      # QueryAdmittedPeers is selected and swarm admission failed.
      continue

    try:
      await network.request
        .sendWantList(
          peerCtx.id,
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
      warn "Want-have send timed out", peer = peerCtx.id
    except CatchableError as err:
      warn "Want-have send failed", peer = peerCtx.id, error = err.msg

proc downloadWorker(
    self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).} =
  ## Continuously schedules batches to peers until download completes.
  ## Supports concurrent batch requests per peer based on BDP pipeline depth.
  let
    treeCid = download.treeCid
    retryInterval = self.downloadManager.retryInterval
    peers = self.peersFor(download.ctx.transport)
    network = self.networks.networkFor(download.ctx.transport)
    peerTracker = self.trackerFor(download.ctx.transport)
    peerSelection = self.peerSelectionPolicies[download.ctx.transport]
  logScope:
    treeCid = treeCid

  try:
    let
      (windowStart, windowCount) = download.ctx.currentPresenceWindow()
      maxSwarmPeers = download.ctx.swarm.config.deltaMax

    let connectedPeers = peerSelection.selectInitialPresencePeers(
      peers, download.ctx.providerPeers, maxSwarmPeers
    )

    if connectedPeers.len > 0:
      trace "Initial presence window broadcast",
        treeCid = treeCid,
        windowStart = windowStart,
        windowCount = windowCount,
        totalBlocks = download.ctx.totalBlocks,
        peerCount = connectedPeers.len

      await self.broadcastWantHave(download, windowStart, windowCount, connectedPeers)
      trace "Initial broadcast sent, proceeding to batch loop"
    else:
      trace "No connected peers for initial broadcast, triggering discovery"
      self.searchForNewPeers(download.manifestCid, download.ctx.transport)

    while not download.cancelled and not download.isDownloadComplete():
      let ctx = download.ctx
      if not download.fetchLocal and ctx.needsNextPresenceWindow():
        let (newStart, newCount) = ctx.advancePresenceWindow()

        ctx.trimPresenceBeforeWatermark()

        # Broadcast want-have for the new window to swarm peers only
        var swarmPeers: seq[PeerContext] = @[]
        for peerId in ctx.swarm.connectedPeers():
          let peerCtx = peers.get(peerId)
          if not peerCtx.isNil:
            swarmPeers.add(peerCtx)

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
          trace "Broadcasting availability to swarm",
            treeCid = treeCid,
            rangeCount = broadcastRanges.len,
            swarmPeers = ctx.swarm.peerCount()

          let presence = BlockPresence(
            address: BlockAddress(treeCid: treeCid, index: broadcastRanges[0].start),
            kind: BlockPresenceType.HaveRange,
            ranges: broadcastRanges,
          )

          for peerId in ctx.swarm.connectedPeers():
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
        self.searchForNewPeers(download.manifestCid, download.ctx.transport)

      if swarm.peersWithRange(start, count).len == 0:
        shouldBroadcast = true

      if shouldBroadcast:
        let connectedPeers =
          peerSelection.selectPresencePeers(peers, download.ctx.providerPeers)

        if connectedPeers.len > 0:
          trace "Broadcasting want-have for batch range",
            treeCid = treeCid,
            start = start,
            count = count,
            peerCount = connectedPeers.len

          await self.broadcastWantHave(download, start, count, connectedPeers)
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

  if transport == DownloadTransport.Mix and not self.networks.isMixEnabled:
    return failure("Mix transport is not enabled")

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

proc blockPresenceHandler*(
    self: BlockExcEngine,
    peer: PeerId,
    blocks: seq[BlockPresence],
    transport: DownloadTransport = DownloadTransport.Direct,
) {.async: (raises: []).} =
  trace "Received block presence from peer", peer, len = blocks.len
  let peerCtx = self.peersFor(transport).get(peer)
  if peerCtx.isNil:
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      if presence.have:
        let
          treeCid = presence.address.treeCid
          downloadOpt = self.downloadManager.getDownload(blk.downloadId, treeCid)

        if downloadOpt.isSome and downloadOpt.get().ctx.transport == transport:
          let availability =
            case presence.presenceType
            of BlockPresenceType.Complete:
              trace "peer has complete tree", peer = peer, treeCid = treeCid
              BlockAvailability.complete()
            of BlockPresenceType.HaveRange:
              trace "peer has ranges",
                peer = peer, treeCid = treeCid, len = presence.ranges.len
              if presence.ranges.len > 0:
                BlockAvailability.fromRanges(presence.ranges)
              else:
                BlockAvailability.unknown()
            of BlockPresenceType.DontHave:
              trace "peer doesn't have anything", peer = peer, treeCid = treeCid
              BlockAvailability.unknown()

          downloadOpt.get().updatePeerAvailability(peer, availability)

          # try to propagate peer availability to other downloads for the same tree CID
          self.downloadManager.downloads.withValue(treeCid, innerTable):
            for otherId, otherDownload in innerTable[]:
              if otherId != blk.downloadId and otherDownload.ctx.transport == transport:
                otherDownload.updatePeerAvailability(peer, availability)

proc wantListHandler*(
    self: BlockExcEngine,
    peer: PeerId,
    wantList: WantList,
    transport: DownloadTransport = DownloadTransport.Direct,
) {.async: (raises: []).} =
  trace "Received want list from peer", peer, entries = wantList.entries.len

  let peerCtx = self.peersFor(transport).get(peer)
  if peerCtx.isNil:
    return

  if peerCtx.wantListBusy:
    debug "Dropping want list, handler already in flight for peer", peer
    return

  peerCtx.wantListBusy = true
  defer:
    peerCtx.wantListBusy = false

  var
    presence: seq[BlockPresence]
    iterBudget: uint64 = MaxRangeIterationsPerMessage

  try:
    for e in wantList.entries:
      storage_block_exchange_want_have_lists_received.inc()

      if e.rangeCount > 0:
        let
          startIdx = e.address.index.uint64
          count = e.rangeCount
          treeCid = e.address.treeCid

        if count > MaxPresenceWindowBlocks:
          warn "Rejecting oversized range query",
            peer = peer, treeCid = treeCid, count = count, max = MaxPresenceWindowBlocks
          continue

        let effectiveCount = min(count, iterBudget)

        trace "Processing range query",
          treeCid = treeCid, start = startIdx, count = effectiveCount

        let runtimeQuota = 100.milliseconds
        var
          ranges: seq[IndexRange] = @[]
          rangeStart: uint64 = 0
          inRange = false
          lastIdle = Moment.now()

        for i in 0'u64 ..< effectiveCount:
          if (Moment.now() - lastIdle) >= runtimeQuota:
            await idleAsync()
            lastIdle = Moment.now()

          let address = BlockAddress(treeCid: treeCid, index: startIdx + i)
          let have =
            try:
              await address in self.localStore
            except CatchableError:
              false

          if have:
            if not inRange:
              rangeStart = startIdx + i
              inRange = true
          else:
            if inRange:
              ranges.add(
                IndexRange(start: rangeStart, count: (startIdx + i) - rangeStart)
              )
              inRange = false

        if inRange:
          ranges.add(
            IndexRange(
              start: rangeStart, count: (startIdx + effectiveCount) - rangeStart
            )
          )

        iterBudget -= effectiveCount

        if ranges.len > 0:
          trace "Have blocks in range", treeCid = treeCid, ranges = ranges
          presence.add(
            BlockPresence(
              address: e.address,
              kind: BlockPresenceType.HaveRange,
              ranges: ranges,
              downloadId: e.downloadId,
            )
          )
        else:
          trace "Don't have range",
            treeCid = treeCid, start = startIdx, count = effectiveCount
          if e.sendDontHave:
            presence.add(
              BlockPresence(
                address: e.address,
                kind: BlockPresenceType.DontHave,
                downloadId: e.downloadId,
              )
            )
      else:
        let have =
          try:
            await e.address in self.localStore
          except CatchableError:
            false

        if have:
          presence.add(
            BlockPresence(
              address: e.address,
              kind: BlockPresenceType.HaveRange,
              ranges: @[IndexRange(start: e.address.index, count: 1'u64)],
              downloadId: e.downloadId,
            )
          )
        elif e.sendDontHave:
          presence.add(
            BlockPresence(
              address: e.address,
              kind: BlockPresenceType.DontHave,
              downloadId: e.downloadId,
            )
          )

    if presence.len > 0:
      let network = self.networks.networkFor(transport)
      if network.isNil:
        return
      trace "Sending presence to remote", items = presence.len
      try:
        await network.request.sendPresence(peer, presence).wait(
          DefaultWantHaveSendTimeout
        )
      except AsyncTimeoutError:
        warn "Presence response send timed out", peer = peer
  except CancelledError as exc:
    warn "Want list handling cancelled", error = exc.msg

proc peerAddedHandler*(
    self: BlockExcEngine,
    peer: PeerId,
    transport: DownloadTransport = DownloadTransport.Direct,
) {.async: (raises: [CancelledError]).} =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up peer", peer
  if peer notin self.peersFor(transport):
    let peerCtx = PeerContext.new(peer)
    self.peersFor(transport).add(peerCtx)

proc localLookup(
    self: BlockExcEngine, address: BlockAddress
): Future[?!BlockDelivery] {.async: (raises: [CancelledError]).} =
  (await self.localStore.getBlockAndProof(address.treeCid, address.index)).map(
    (blkAndProof: (Block, StorageMerkleProof)) =>
      BlockDelivery(address: address, blk: blkAndProof[0], proof: blkAndProof[1].some)
  )

proc requestWantBlocks*(
    self: BlockExcEngine,
    peer: PeerId,
    blockRange: BlockRange,
    transport: DownloadTransport = DownloadTransport.Direct,
): Future[WantBlocksResult[seq[BlockDeliveryView]]] {.
    async: (raises: [CancelledError])
.} =
  let network = self.networks.networkFor(transport)
  if network.isNil:
    return err(
      wantBlocksError(ConnectionClosed, "Selected download transport is unavailable")
    )
  let response = ?await network.sendWantBlocksRequest(peer, blockRange)
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

proc configureNetwork(
    self: BlockExcEngine, network: BlockExcNetwork, transport: DownloadTransport
) =
  proc blockWantListHandler(
      peer: PeerId, wantList: WantList
  ): Future[void] {.async: (raw: true, raises: []).} =
    self.wantListHandler(peer, wantList, transport)

  proc blockPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raw: true, raises: []).} =
    self.blockPresenceHandler(peer, presence, transport)

  proc peerAddedHandler(
      peer: PeerId
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.peerAddedHandler(peer, transport)

  proc peerDepartedHandler(
      peer: PeerId
  ): Future[void] {.async: (raises: [CancelledError]).} =
    self.evictPeer(peer, transport)

  proc wantBlocksRequestHandler(
      peer: PeerId, req: WantBlocksRequest
  ): Future[seq[BlockDelivery]] {.async: (raises: [CancelledError]).} =
    let maxIndex = high(Natural).uint64
    var totalCount: uint64 = 0

    trace "Received WantBlocks request",
      peer = peer, treeCid = req.treeCid, ranges = req.ranges.len
    for r in req.ranges:
      if r.count == 0 or r.start > maxIndex or r.count - 1 > maxIndex - r.start or
          r.start > uint64.high - r.count or r.count > uint64.high - totalCount:
        warn "Rejecting WantBlocks request: invalid range",
          peer = peer, start = r.start, count = r.count
        return @[]
      totalCount += r.count
      if totalCount > MaxBlocksPerBatch:
        warn "Rejecting WantBlocks request: total blocks exceeds cap",
          peer = peer, total = totalCount
        return @[]

    var
      blockDeliveries: seq[BlockDelivery]
      notFoundCount = 0
      totalRequested: uint64 = 0

    for r in req.ranges:
      totalRequested += r.count
      trace "Processing WantBlocks range", peer = peer, start = r.start, count = r.count
      for i in r.start ..< r.start + r.count:
        let address = BlockAddress(treeCid: req.treeCid, index: i)

        let res = await self.localLookup(address)
        if res.isOk:
          blockDeliveries.add(res.get)
        else:
          notFoundCount += 1

    if notFoundCount > 0:
      warn "Some blocks not found in WantBlocks request",
        peer = peer,
        treeCid = req.treeCid,
        requested = totalRequested,
        found = blockDeliveries.len,
        notFound = notFoundCount

    storage_block_exchange_blocks_sent.inc(blockDeliveries.len.int64)
    return blockDeliveries

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onPresence: blockPresenceHandler,
    onWantBlocksRequest: wantBlocksRequestHandler,
    onPeerJoined: peerAddedHandler,
    onPeerDeparted: peerDepartedHandler,
  )

proc enableMixNetwork*(self: BlockExcEngine, mixTransport: MixTransport) =
  doAssert not mixTransport.isNil
  doAssert self.networks.mix.isNil, "Mix BlockExchange is already enabled"
  let network = BlockExcNetwork.new(
    self.networks.direct.switch,
    maxInflight = self.networks.direct.sendConcurrencyLimit,
    mixTransport = mixTransport,
  )
  self.configureNetwork(network, DownloadTransport.Mix)
  self.networks.mix = network

proc disableMixNetwork*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Remove BlockExchange's Mix instance after MixTransport has stopped, or
  ## when startup fails. This does not stop the shared transport service.
  let network = self.networks.mix
  self.networks.mix = nil
  if not network.isNil:
    await network.stop()
  self.mixPeers = PeerContextStore.new()
  self.mixPeerTracker = PeerInFlightTracker.new()

proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    networks: BlockExcNetworks,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    peerStore: PeerContextStore,
    downloadManager: DownloadManager,
    selectionPolicy = spSequential,
    directPeerSelectionPolicy: PresencePeerSelectionPolicy =
      newPresencePeerSelectionPolicy(),
    mixPeerSelectionPolicy: PresencePeerSelectionPolicy =
      newPresencePeerSelectionPolicy(),
    directPresenceQueryPolicy: PresenceQueryPolicy =
      PresenceQueryPolicy.QuerySelectedPeers,
    mixPresenceQueryPolicy: PresenceQueryPolicy = PresenceQueryPolicy.QuerySelectedPeers,
): BlockExcEngine =
  doAssert not directPeerSelectionPolicy.isNil
  doAssert not mixPeerSelectionPolicy.isNil
  let self = BlockExcEngine(
    localStore: localStore,
    peers: peerStore,
    mixPeers: PeerContextStore.new(),
    mixPeerTracker: PeerInFlightTracker.new(),
    peerSelectionPolicies: [directPeerSelectionPolicy, mixPeerSelectionPolicy],
    presenceQueryPolicies: [directPresenceQueryPolicy, mixPresenceQueryPolicy],
    downloadManager: downloadManager,
    networks: networks,
    trackedFutures: TrackedFutures(),
    discovery: discovery,
    advertiser: advertiser,
    selectionPolicy: selectionPolicy,
    activeDownloads: initHashSet[uint64](),
  )
  self.configureNetwork(networks.direct, DownloadTransport.Direct)
  if not networks.mix.isNil:
    self.configureNetwork(networks.mix, DownloadTransport.Mix)

  if directPeerSelectionPolicy.needsProviderTracking or
      mixPeerSelectionPolicy.needsProviderTracking:
    discovery.onProviders = proc(
        cid: Cid, transport: DownloadTransport, providers: seq[PeerRecord]
    ) {.gcsafe, raises: [].} =
      if not self.peerSelectionPolicies[transport].needsProviderTracking:
        return
      for downloads in self.downloadManager.downloads.values:
        for download in downloads.values:
          if download.manifestCid == cid and download.ctx.transport == transport:
            download.ctx.providerPeers.clear()
            for provider in providers:
              if provider.peerId in self.peersFor(transport):
                download.ctx.providerPeers.incl(provider.peerId)

  return self
