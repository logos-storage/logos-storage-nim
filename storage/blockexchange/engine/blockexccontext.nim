## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[options, random, sequtils, sets, sugar, tables]

import pkg/chronos
import pkg/libp2p/[cid, peerid]
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ../../stores/blockstore
import ../../blocktype
import ../../merkletree
import ../../logutils
import ../../utils/trackedfutures
import ../protocol/message
import ../protocol/presence
import ../protocol/constants
import ../network
import ../peers
import ./peertracker
import ./downloadmanager

logScope:
  topics = "storage blockexccontext"

declareCounter(
  storage_block_exchange_want_have_lists_received,
  "storage blockexchange wantHave lists received",
)
declareCounter(storage_block_exchange_blocks_sent, "storage blockexchange blocks sent")

const
  PeerTrackerSweepInterval = 15.seconds
  DialFailureCooldown* = 60.seconds

type BlockExcContext* = ref object of RootObj
  network*: BlockExcNetwork
  peers*: PeerContextStore # Peers we're currently actively exchanging with
  peerTracker*: PeerInFlightTracker # peer-wide in-flight tracking
  localStore: BlockStore
  downloadManager: DownloadManager
  trackedFutures: TrackedFutures
  dialFailures: Table[PeerId, Moment]
  requestedPeers: HashSet[PeerId]

func transport*(self: BlockExcContext): DownloadTransport =
  self.network.transport.kind

proc peerTrackerSweepLoop(self: BlockExcContext) {.async: (raises: []).} =
  try:
    while true:
      await sleepAsync(PeerTrackerSweepInterval)
      await self.peerTracker.sweep()
  except CancelledError:
    discard
  except CatchableError as exc:
    warn "Peer tracker sweep loop failed", err = exc.msg

proc start*(self: BlockExcContext) =
  self.trackedFutures.track(self.peerTrackerSweepLoop())

proc stop*(self: BlockExcContext) {.async: (raises: []).} =
  await self.trackedFutures.cancelTracked()
  await self.network.stop()

proc evictPeer*(self: BlockExcContext, peer: PeerId) =
  ## Cleanup disconnected peer
  ##

  self.peers.remove(peer)
  self.peerTracker.clearPeer(peer)
  self.requestedPeers.excl(peer)

proc addRequestedPeer*(self: BlockExcContext, peerId: PeerId) =
  self.requestedPeers.incl(peerId)

proc admitRequestedPeers*(self: BlockExcContext, swarm: Swarm) =
  var candidates = self.requestedPeers.toSeq().filterIt(swarm.getPeer(it).isNone)
  shuffle(candidates)
  for peerId in candidates:
    if not swarm.addPeer(peerId, BlockAvailability.unknown()):
      break

proc recordDialFailure*(self: BlockExcContext, peerId: PeerId) =
  self.dialFailures[peerId] = Moment.now()

proc dialCooldownExpired*(self: BlockExcContext, peerId: PeerId): bool =
  self.dialFailures.withValue(peerId, failedAt):
    if Moment.now() - failedAt[] < DialFailureCooldown:
      return false
    self.dialFailures.del(peerId)
  true

method blockPresenceHandler*(
    self: BlockExcContext, peer: PeerId, blocks: seq[BlockPresence]
) {.base, async: (raises: []), gcsafe.} =
  trace "Received block presence from peer", peer, len = blocks.len
  let peerCtx = self.peers.get(peer)
  if peerCtx.isNil:
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      if presence.have:
        let
          treeCid = presence.address.treeCid
          downloadOpt = self.downloadManager.getDownload(blk.downloadId, treeCid)

        if blk.downloadId == 0 or
            (downloadOpt.isSome and downloadOpt.get().ctx.transport == self.transport):
          let availability =
            case presence.presenceType
            of BlockPresenceType.Complete:
              trace "peer has complete tree", peer = peer, treeCid = treeCid
              BlockAvailability.complete()
            of BlockPresenceType.HaveRange:
              trace "peer has ranges",
                peer = peer, treeCid = treeCid, len = presence.ranges.len
              BlockAvailability.fromRanges(presence.ranges)
            of BlockPresenceType.DontHave:
              trace "peer doesn't have anything", peer = peer, treeCid = treeCid
              BlockAvailability.unknown()

          if downloadOpt.isSome:
            downloadOpt.get().updatePeerAvailability(peer, availability)

          # try to propagate peer availability to other downloads for the same tree CID
          self.downloadManager.downloads.withValue(treeCid, innerTable):
            for otherId, otherDownload in innerTable[]:
              if otherId != blk.downloadId and
                  otherDownload.ctx.transport == self.transport:
                otherDownload.updatePeerAvailability(peer, availability)

method wantListHandler*(
    self: BlockExcContext, peer: PeerId, wantList: WantList
) {.base, async: (raises: []), gcsafe.} =
  trace "Received want list from peer", peer, entries = wantList.entries.len

  let peerCtx = self.peers.get(peer)
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

      without advertised =? (await self.localStore.isAdvertised(e.address.treeCid)), err:
        warn "Unable to read advertise state",
          treeCid = e.address.treeCid, err = err.msg
        continue

      if not advertised:
        trace "Not serving presence", peer = peer, treeCid = e.address.treeCid
        continue

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
            except CancelledError:
              raise
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
          except CancelledError:
            raise
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
      trace "Sending presence to remote", items = presence.len
      try:
        await self.network.request.sendPresence(peer, presence).wait(
          DefaultWantHaveSendTimeout
        )
      except AsyncTimeoutError:
        warn "Presence response send timed out", peer = peer
  except CancelledError as exc:
    warn "Want list handling cancelled", error = exc.msg

proc localLookup(
    self: BlockExcContext, address: BlockAddress
): Future[?!BlockDelivery] {.async: (raises: [CancelledError]).} =
  (await self.localStore.getBlockAndProof(address.treeCid, address.index)).map(
    (blkAndProof: (Block, StorageMerkleProof)) =>
      BlockDelivery(address: address, blk: blkAndProof[0], proof: blkAndProof[1].some)
  )

method wantBlocksRequestHandler*(
    self: BlockExcContext, peer: PeerId, req: WantBlocksRequest
): Future[seq[BlockDelivery]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  without advertised =? (await self.localStore.isAdvertised(req.treeCid)), advertiseErr:
    warn "Unable to read advertise state", treeCid = req.treeCid, err = advertiseErr.msg
    return @[]

  if not advertised:
    trace "Not serving blocks", peer = peer, treeCid = req.treeCid
    return @[]

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

method peerJoinedHandler*(
    self: BlockExcContext, peer: PeerId
) {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up peer", peer
  if peer notin self.peers:
    let peerCtx = PeerContext.new(peer)
    self.peers.add(peerCtx)

method peerDepartedHandler*(
    self: BlockExcContext, peer: PeerId
) {.base, async: (raises: [CancelledError]), gcsafe.} =
  trace "Evicting disconnected/departed peer", peer
  self.evictPeer(peer)

proc new*(
    T: type BlockExcContext,
    network: BlockExcNetwork,
    localStore: BlockStore,
    downloadManager: DownloadManager,
    peers: PeerContextStore = PeerContextStore.new(),
): BlockExcContext =
  doAssert not network.isNil
  let self = BlockExcContext(
    network: network,
    peers: peers,
    peerTracker: PeerInFlightTracker.new(),
    localStore: localStore,
    downloadManager: downloadManager,
    trackedFutures: TrackedFutures(),
    dialFailures: initTable[PeerId, Moment](),
    requestedPeers: initHashSet[PeerId](),
  )

  proc onWantList(
      peer: PeerId, wantList: WantList
  ): Future[void] {.async: (raw: true, raises: []).} =
    self.wantListHandler(peer, wantList)

  proc onPresence(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raw: true, raises: []).} =
    self.blockPresenceHandler(peer, presence)

  proc onWantBlocksRequest(
      peer: PeerId, req: WantBlocksRequest
  ): Future[seq[BlockDelivery]] {.async: (raw: true, raises: [CancelledError]).} =
    self.wantBlocksRequestHandler(peer, req)

  proc onPeerJoined(
      peer: PeerId
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.peerJoinedHandler(peer)

  proc onPeerDeparted(
      peer: PeerId
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.peerDepartedHandler(peer)

  network.handlers = BlockExcHandlers(
    onWantList: onWantList,
    onPresence: onPresence,
    onWantBlocksRequest: onWantBlocksRequest,
    onPeerJoined: onPeerJoined,
    onPeerDeparted: onPeerDeparted,
  )
  self
