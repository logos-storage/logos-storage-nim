## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/sets
import std/options
import std/algorithm
import std/sugar
import std/random

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
import pkg/metrics
import pkg/stint
import pkg/questionable
import pkg/stew/shims/sets

import ../../rng
import ../../stores/blockstore
import ../../blocktype
import ../../utils
import ../../utils/exceptions
import ../../utils/trackedfutures
import ../../merkletree
import ../../logutils
import ../../manifest

import ../protobuf/blockexc
import ../protobuf/presence

import ../network
import ../peers

import ./payments
import ./discovery
import ./advertiser
import ./pendingblocks

export peers, pendingblocks, payments, discovery

logScope:
  topics = "codex blockexcengine"

declareCounter(
  codex_block_exchange_want_have_lists_sent, "codex blockexchange wantHave lists sent"
)
declareCounter(
  codex_block_exchange_want_have_lists_received,
  "codex blockexchange wantHave lists received",
)
declareCounter(
  codex_block_exchange_want_block_lists_sent, "codex blockexchange wantBlock lists sent"
)
declareCounter(
  codex_block_exchange_want_block_lists_received,
  "codex blockexchange wantBlock lists received",
)
declareCounter(codex_block_exchange_blocks_sent, "codex blockexchange blocks sent")
declareCounter(
  codex_block_exchange_blocks_received, "codex blockexchange blocks received"
)
declareCounter(
  codex_block_exchange_spurious_blocks_received,
  "codex blockexchange unrequested/duplicate blocks received",
)
declareCounter(
  codex_block_exchange_discovery_requests_total,
  "Total number of peer discovery requests sent",
)
declareCounter(
  codex_block_exchange_peer_timeouts_total, "Total number of peer activity timeouts"
)
declareCounter(
  codex_block_exchange_requests_failed_total,
  "Total number of block requests that failed after exhausting retries",
)

const
  # The default max message length of nim-libp2p is 100 megabytes, meaning we can
  # in principle fit up to 1600 64k blocks per message, so 20 is well under
  # that number.
  DefaultMaxBlocksPerMessage = 20
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  # Don't do more than one discovery request per `DiscoveryRateLimit` seconds.
  DiscoveryRateLimit = 3.seconds
  DefaultPeerActivityTimeout = 1.minutes
  # Match MaxWantListBatchSize to efficiently respond to incoming WantLists
  PresenceBatchSize = MaxWantListBatchSize
  CleanupBatchSize = 2048

type
  TaskHandler* = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BlockExcPeerCtx): bool {.gcsafe.}
  PeerSelector* =
    proc(peers: seq[BlockExcPeerCtx]): BlockExcPeerCtx {.gcsafe, raises: [].}

  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore # Local block store for this instance
    network*: BlockExcNetwork # Network interface
    peers*: PeerCtxStore # Peers we're currently actively exchanging with
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]
    selectPeer*: PeerSelector # Peers we're currently processing tasks for
    concurrentTasks: int # Number of concurrent peers we're serving at any given time
    trackedFutures: TrackedFutures # Tracks futures of blockexc tasks
    blockexcRunning: bool # Indicates if the blockexc task is running
    maxBlocksPerMessage: int
      # Maximum number of blocks we can squeeze in a single message
    pendingBlocks*: PendingBlocksManager # Blocks we're awaiting to be resolved
    wallet*: WalletRef # Nitro wallet for micropayments
    pricing*: ?Pricing # Optional bandwidth pricing
    discovery*: DiscoveryEngine
    advertiser*: Advertiser
    lastDiscRequest: Moment # time of last discovery request

  Pricing* = object
    address*: EthAddress
    price*: UInt256

# attach task scheduler to engine
proc scheduleTask(self: BlockExcEngine, task: BlockExcPeerCtx) {.gcsafe, raises: [].} =
  if self.taskQueue.pushOrUpdateNoWait(task).isOk():
    trace "Task scheduled for peer", peer = task.id
  else:
    warn "Unable to schedule task for peer", peer = task.id

proc blockexcTaskRunner(self: BlockExcEngine) {.async: (raises: []).}

proc start*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Start the blockexc task
  ##
  await self.discovery.start()
  await self.advertiser.start()

  trace "Blockexc starting with concurrent tasks", tasks = self.concurrentTasks
  if self.blockexcRunning:
    warn "Starting blockexc twice"
    return

  self.blockexcRunning = true
  for i in 0 ..< self.concurrentTasks:
    let fut = self.blockexcTaskRunner()
    self.trackedFutures.track(fut)

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Stop the blockexc blockexc
  ##

  await self.trackedFutures.cancelTracked()
  await self.network.stop()
  await self.discovery.stop()
  await self.advertiser.stop()

  trace "NetworkStore stop"
  if not self.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  self.blockexcRunning = false

  trace "NetworkStore stopped"

proc sendWantHave(
    self: BlockExcEngine, addresses: seq[BlockAddress], peers: seq[BlockExcPeerCtx]
): Future[void] {.async: (raises: [CancelledError]).} =
  for p in peers:
    let toAsk = addresses.filterIt(it notin p.peerHave)
    trace "Sending wantHave request", toAsk, peer = p.id
    await self.network.request.sendWantList(p.id, toAsk, wantType = WantType.WantHave)
    codex_block_exchange_want_have_lists_sent.inc()

proc sendWantBlock(
    self: BlockExcEngine, addresses: seq[BlockAddress], blockPeer: BlockExcPeerCtx
): Future[void] {.async: (raises: [CancelledError]).} =
  trace "Sending wantBlock request to", addresses, peer = blockPeer.id
  await self.network.request.sendWantList(
    blockPeer.id, addresses, wantType = WantType.WantBlock
  ) # we want this remote to send us a block
  codex_block_exchange_want_block_lists_sent.inc()

proc sendBatchedWantList(
    self: BlockExcEngine,
    peer: BlockExcPeerCtx,
    addresses: seq[BlockAddress],
    full: bool,
) {.async: (raises: [CancelledError]).} =
  var offset = 0
  while offset < addresses.len:
    let batchEnd = min(offset + MaxWantListBatchSize, addresses.len)
    let batch = addresses[offset ..< batchEnd]

    trace "Sending want list batch",
      peer = peer.id,
      batchSize = batch.len,
      offset = offset,
      total = addresses.len,
      full = full

    await self.network.request.sendWantList(
      peer.id, batch, full = (full and offset == 0)
    )
    for address in batch:
      peer.lastSentWants.incl(address)

    offset = batchEnd

proc refreshBlockKnowledge(
    self: BlockExcEngine, peer: BlockExcPeerCtx, skipDelta = false, resetBackoff = false
) {.async: (raises: [CancelledError]).} =
  if peer.lastSentWants.len > 0:
    var toRemove: seq[BlockAddress]

    for address in peer.lastSentWants:
      if address notin self.pendingBlocks:
        toRemove.add(address)

        if toRemove.len >= CleanupBatchSize:
          await idleAsync()
          break

    for addr in toRemove:
      peer.lastSentWants.excl(addr)

  if self.pendingBlocks.wantListLen == 0:
    if peer.lastSentWants.len > 0:
      trace "Clearing want list tracking, no pending blocks", peer = peer.id
      peer.lastSentWants.clear()
    return

  # We send only blocks that the peer hasn't already told us that they already have.
  let
    peerHave = peer.peerHave
    toAsk = toHashSet(self.pendingBlocks.wantList.toSeq.filterIt(it notin peerHave))

  if toAsk.len == 0:
    if peer.lastSentWants.len > 0:
      trace "Clearing want list tracking, peer has all blocks", peer = peer.id
      peer.lastSentWants.clear()
    return

  let newWants = toAsk - peer.lastSentWants

  if peer.lastSentWants.len > 0 and not skipDelta:
    if newWants.len > 0:
      trace "Sending delta want list update",
        peer = peer.id, newWants = newWants.len, totalWants = toAsk.len

      await self.sendBatchedWantList(peer, newWants.toSeq, full = false)

      if resetBackoff:
        peer.wantsUpdated
    else:
      trace "No changes in want list, skipping send", peer = peer.id
      peer.lastSentWants = toAsk
  else:
    trace "Sending full want list", peer = peer.id, length = toAsk.len

    await self.sendBatchedWantList(peer, toAsk.toSeq, full = true)

    if resetBackoff:
      peer.wantsUpdated

proc refreshBlockKnowledge(self: BlockExcEngine) {.async: (raises: [CancelledError]).} =
  let runtimeQuota = 10.milliseconds
  var lastIdle = Moment.now()

  for peer in self.peers.peers.values.toSeq:
    # We refresh block knowledge if:
    # 1. the peer hasn't been refreshed in a while;
    # 2. the list of blocks we care about has changed.
    #
    # Note that because of (2), it is important that we update our
    # want list in the coarsest way possible instead of over many
    # small updates.
    #

    # In dynamic swarms, staleness will dominate latency.
    let
      hasNewBlocks = peer.lastRefresh < self.pendingBlocks.lastInclusion
      isKnowledgeStale = peer.isKnowledgeStale

    if isKnowledgeStale or hasNewBlocks:
      if not peer.refreshInProgress:
        peer.refreshRequested()
        await self.refreshBlockKnowledge(
          peer, skipDelta = isKnowledgeStale, resetBackoff = hasNewBlocks
        )
    else:
      trace "Not refreshing: peer is up to date", peer = peer.id

    if (Moment.now() - lastIdle) >= runtimeQuota:
      try:
        await idleAsync()
      except CancelledError:
        discard
      lastIdle = Moment.now()

proc searchForNewPeers(self: BlockExcEngine, cid: Cid) =
  if self.lastDiscRequest + DiscoveryRateLimit < Moment.now():
    trace "Searching for new peers for", cid = cid
    codex_block_exchange_discovery_requests_total.inc()
    self.lastDiscRequest = Moment.now() # always refresh before calling await!
    self.discovery.queueFindBlocksReq(@[cid])
  else:
    trace "Not searching for new peers, rate limit not expired", cid = cid

proc evictPeer(self: BlockExcEngine, peer: PeerId) =
  ## Cleanup disconnected peer
  ##

  trace "Evicting disconnected/departed peer", peer

  let peerCtx = self.peers.get(peer)
  if not peerCtx.isNil:
    for address in peerCtx.blocksRequested:
      self.pendingBlocks.clearRequest(address, peer.some)

  # drop the peer from the peers table
  self.peers.remove(peer)

proc downloadInternal(
    self: BlockExcEngine, address: BlockAddress
) {.async: (raises: []).} =
  logScope:
    address = address

  let handle = self.pendingBlocks.getWantHandle(address)
  trace "Downloading block"
  try:
    while address in self.pendingBlocks:
      logScope:
        retries = self.pendingBlocks.retries(address)
        interval = self.pendingBlocks.retryInterval

      if self.pendingBlocks.retriesExhausted(address):
        trace "Error retries exhausted"
        codex_block_exchange_requests_failed_total.inc()
        handle.fail(newException(RetriesExhaustedError, "Error retries exhausted"))
        break

      let peers = self.peers.getPeersForBlock(address)
      logScope:
        peersWith = peers.with.len
        peersWithout = peers.without.len

      if peers.with.len == 0:
        # We know of no peers that have the block.
        if peers.without.len > 0:
          # If we have peers connected but none of them have the block, this
          # could be because our knowledge about what they have has run stale.
          # Tries to refresh it.
          await self.refreshBlockKnowledge()
          # Also tries to look for new peers for good measure.
          # TODO: in the future, peer search and knowledge maintenance should
          #   be completely decoupled from one another. It is very hard to
          #   control what happens and how many neighbors we get like this.
        self.searchForNewPeers(address.cidOrTreeCid)

        let nextDiscovery =
          if self.lastDiscRequest + DiscoveryRateLimit > Moment.now():
            (self.lastDiscRequest + DiscoveryRateLimit - Moment.now())
          else:
            0.milliseconds

        let retryDelay =
          max(secs(rand(self.pendingBlocks.retryInterval.secs)), nextDiscovery)

        # We now wait for a bit and then retry. If the handle gets completed in the
        # meantime (cause the presence handler might have requested the block and
        # received it in the meantime), we are done. Retry delays are randomized
        # so we don't get all block loops spinning at the same time.
        await handle or sleepAsync(retryDelay)
        if handle.finished:
          break

        # Without decrementing the retries count, this would infinitely loop
        # trying to find peers.
        self.pendingBlocks.decRetries(address)

        # If we still don't have the block, we'll go for another cycle.
        trace "No peers for block, will retry shortly"
        continue

      # Once again, it might happen that the block was requested to a peer
      # in the meantime. If so, we don't need to do anything. Otherwise,
      # we'll be the ones placing the request.
      let scheduledPeer =
        if not self.pendingBlocks.isRequested(address):
          let peer = self.selectPeer(peers.with)
          discard self.pendingBlocks.markRequested(address, peer.id)
          peer.blockRequestScheduled(address)
          trace "Request block from block retry loop"
          await self.sendWantBlock(@[address], peer)
          peer
        else:
          let peerId = self.pendingBlocks.getRequestPeer(address).get()
          self.peers.get(peerId)

      if scheduledPeer.isNil:
        trace "Scheduled peer no longer available, clearing stale request", address
        self.pendingBlocks.clearRequest(address)
        continue

      # Parks until either the block is received, or the peer times out.
      let activityTimer = scheduledPeer.activityTimer()
      await handle or activityTimer # TODO: or peerDropped
      activityTimer.cancel()

      # XXX: we should probably not have this. Blocks should be retried
      #   to infinity unless cancelled by the client.
      self.pendingBlocks.decRetries(address)

      if handle.finished:
        trace "Handle for block finished", failed = handle.failed
        break
      else:
        # If the peer timed out, retries immediately.
        trace "Peer timed out during block request", peer = scheduledPeer.id
        codex_block_exchange_peer_timeouts_total.inc()
        await self.network.dropPeer(scheduledPeer.id)
        # Evicts peer immediately or we may end up picking it again in the
        # next retry.
        self.evictPeer(scheduledPeer.id)
  except CancelledError as exc:
    trace "Block download cancelled"
    if not handle.finished:
      await handle.cancelAndWait()
  except RetriesExhaustedError as exc:
    warn "Retries exhausted for block", address, exc = exc.msg
    codex_block_exchange_requests_failed_total.inc()
    if not handle.finished:
      handle.fail(exc)
  finally:
    self.pendingBlocks.clearRequest(address)

proc requestBlocks*(
    self: BlockExcEngine, addresses: seq[BlockAddress]
): SafeAsyncIter[Block] =
  var handles: seq[BlockHandle]

  # Adds all blocks to pendingBlocks before calling the first downloadInternal. This will
  # ensure that we don't send incomplete want lists.
  for address in addresses:
    if address notin self.pendingBlocks:
      handles.add(self.pendingBlocks.getWantHandle(address))

  for address in addresses:
    self.trackedFutures.track(self.downloadInternal(address))

  let totalHandles = handles.len
  var completed = 0

  proc isFinished(): bool =
    completed == totalHandles

  proc genNext(): Future[?!Block] {.async: (raises: [CancelledError]).} =
    # Be it success or failure, we're completing this future.
    let value =
      try:
        # FIXME: this is super expensive. We're doing several linear scans,
        #   not to mention all the copying and callback fumbling in `one`.
        let
          handle = await one(handles)
          i = handles.find(handle)
        handles.del(i)
        success await handle
      except CancelledError as err:
        warn "Block request cancelled", addresses, err = err.msg
        raise err
      except CatchableError as err:
        error "Error getting blocks from exchange engine", addresses, err = err.msg
        failure err

    inc(completed)
    return value

  return SafeAsyncIter[Block].new(genNext, isFinished)

proc requestBlock*(
    self: BlockExcEngine, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  if address notin self.pendingBlocks:
    self.trackedFutures.track(self.downloadInternal(address))

  try:
    let handle = self.pendingBlocks.getWantHandle(address)
    success await handle
  except CancelledError as err:
    warn "Block request cancelled", address
    raise err
  except CatchableError as err:
    error "Block request failed", address, err = err.msg
    failure err

proc requestBlock*(
    self: BlockExcEngine, cid: Cid
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  self.requestBlock(BlockAddress.init(cid))

proc completeBlock*(self: BlockExcEngine, address: BlockAddress, blk: Block) =
  if address in self.pendingBlocks.blocks:
    self.pendingBlocks.completeWantHandle(address, blk)
  else:
    warn "Attempted to complete non-pending block", address

proc blockPresenceHandler*(
    self: BlockExcEngine, peer: PeerId, blocks: seq[BlockPresence]
) {.async: (raises: []).} =
  trace "Received block presence from peer", peer, len = blocks.len
  let
    peerCtx = self.peers.get(peer)
    ourWantList = toHashSet(self.pendingBlocks.wantList.toSeq)

  if peerCtx.isNil:
    return

  peerCtx.refreshReplied()

  for blk in blocks:
    if presence =? Presence.init(blk):
      peerCtx.setPresence(presence)

  let
    peerHave = peerCtx.peerHave
    dontWantCids = peerHave - ourWantList

  if dontWantCids.len > 0:
    peerCtx.cleanPresence(dontWantCids.toSeq)

  let ourWantCids = ourWantList.filterIt(
    it in peerHave and not self.pendingBlocks.retriesExhausted(it) and
      self.pendingBlocks.markRequested(it, peer)
  ).toSeq

  for address in ourWantCids:
    self.pendingBlocks.decRetries(address)
    peerCtx.blockRequestScheduled(address)

  if ourWantCids.len > 0:
    trace "Peer has blocks in our wantList", peer, wants = ourWantCids
    # FIXME: this will result in duplicate requests for blocks
    if err =? catch(await self.sendWantBlock(ourWantCids, peerCtx)).errorOption:
      warn "Failed to send wantBlock to peer", peer, err = err.msg
      for address in ourWantCids:
        self.pendingBlocks.clearRequest(address, peer.some)

proc scheduleTasks(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  # schedule any new peers to provide blocks to
  for p in self.peers:
    for blockDelivery in blocksDelivery: # for each cid
      # schedule a peer if it wants at least one cid
      # and we have it in our local store
      if blockDelivery.address in p.wantedBlocks:
        let cid = blockDelivery.blk.cid
        try:
          if await (cid in self.localStore):
            # TODO: the try/except should go away once blockstore tracks exceptions
            self.scheduleTask(p)
            break
        except CancelledError as exc:
          warn "Checking local store canceled", cid = cid, err = exc.msg
          return
        except CatchableError as exc:
          error "Error checking local store for cid", cid = cid, err = exc.msg
          raiseAssert "Unexpected error checking local store for cid"

proc cancelBlocks(
    self: BlockExcEngine, addrs: seq[BlockAddress]
) {.async: (raises: [CancelledError]).} =
  ## Tells neighboring peers that we're no longer interested in a block.
  ##

  let blocksDelivered = toHashSet(addrs)
  var scheduledCancellations: Table[PeerId, HashSet[BlockAddress]]

  if self.peers.len == 0:
    return

  proc dispatchCancellations(
      entry: tuple[peerId: PeerId, addresses: HashSet[BlockAddress]]
  ): Future[PeerId] {.async: (raises: [CancelledError]).} =
    trace "Sending block request cancellations to peer",
      peer = entry.peerId, addresses = entry.addresses.len
    await self.network.request.sendWantCancellations(
      peer = entry.peerId, addresses = entry.addresses.toSeq
    )

    return entry.peerId

  try:
    for peerCtx in self.peers.peers.values:
      # Do we have pending requests, towards this peer, for any of the blocks
      # that were just delivered?
      let intersection = peerCtx.blocksRequested.intersection(blocksDelivered)
      if intersection.len > 0:
        # If so, schedules a cancellation.
        scheduledCancellations[peerCtx.id] = intersection

    if scheduledCancellations.len == 0:
      return

    let (succeededFuts, failedFuts) = await allFinishedFailed[PeerId](
      toSeq(scheduledCancellations.pairs).map(dispatchCancellations)
    )

    (await allFinished(succeededFuts)).mapIt(it.read).apply do(peerId: PeerId):
      let ctx = self.peers.get(peerId)
      if not ctx.isNil:
        ctx.cleanPresence(addrs)
        for address in scheduledCancellations[peerId]:
          ctx.blockRequestCancelled(address)

    if failedFuts.len > 0:
      warn "Failed to send block request cancellations to peers", peers = failedFuts.len
    else:
      trace "Block request cancellations sent to peers", peers = self.peers.len
  except CancelledError as exc:
    warn "Error sending block request cancellations", error = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error sending block request cancellations", error = exc.msg

proc resolveBlocks*(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  self.pendingBlocks.resolve(blocksDelivery)
  await self.scheduleTasks(blocksDelivery)
  await self.cancelBlocks(blocksDelivery.mapIt(it.address))

proc resolveBlocks*(
    self: BlockExcEngine, blocks: seq[Block]
) {.async: (raises: [CancelledError]).} =
  await self.resolveBlocks(
    blocks.mapIt(
      BlockDelivery(blk: it, address: BlockAddress(leaf: false, cid: it.cid))
    )
  )

proc payForBlocks(
    self: BlockExcEngine, peer: BlockExcPeerCtx, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  let
    sendPayment = self.network.request.sendPayment
    price = peer.price(blocksDelivery.mapIt(it.address))

  if payment =? self.wallet.pay(peer, price):
    trace "Sending payment for blocks", price, len = blocksDelivery.len
    await sendPayment(peer.id, payment)

proc validateBlockDelivery(self: BlockExcEngine, bd: BlockDelivery): ?!void =
  if bd.address notin self.pendingBlocks:
    return failure("Received block is not currently a pending block")

  if bd.address.leaf:
    without proof =? bd.proof:
      return failure("Missing proof")

    if proof.index != bd.address.index:
      return failure(
        "Proof index " & $proof.index & " doesn't match leaf index " & $bd.address.index
      )

    without leaf =? bd.blk.cid.mhash.mapFailure, err:
      return failure("Unable to get mhash from cid for block, nested err: " & err.msg)

    without treeRoot =? bd.address.treeCid.mhash.mapFailure, err:
      return
        failure("Unable to get mhash from treeCid for block, nested err: " & err.msg)

    if err =? proof.verify(leaf, treeRoot).errorOption:
      return failure("Unable to verify proof for block, nested err: " & err.msg)
  else: # not leaf
    if bd.address.cid != bd.blk.cid:
      return failure(
        "Delivery cid " & $bd.address.cid & " doesn't match block cid " & $bd.blk.cid
      )

  return success()

proc blocksDeliveryHandler*(
    self: BlockExcEngine,
    peer: PeerId,
    blocksDelivery: seq[BlockDelivery],
    allowSpurious: bool = false,
) {.async: (raises: []).} =
  trace "Received blocks from peer", peer, blocks = (blocksDelivery.mapIt(it.address))

  var validatedBlocksDelivery: seq[BlockDelivery]
  let peerCtx = self.peers.get(peer)

  let runtimeQuota = 10.milliseconds
  var lastIdle = Moment.now()

  for bd in blocksDelivery:
    logScope:
      peer = peer
      address = bd.address

    try:
      # Unknown peers and unrequested blocks are dropped with a warning.
      if not allowSpurious and (peerCtx == nil or not peerCtx.blockReceived(bd.address)):
        warn "Dropping unrequested or duplicate block received from peer"
        codex_block_exchange_spurious_blocks_received.inc()
        continue

      if err =? self.validateBlockDelivery(bd).errorOption:
        warn "Block validation failed", msg = err.msg
        continue

      if err =? (await self.localStore.putBlock(bd.blk)).errorOption:
        error "Unable to store block", err = err.msg
        continue

      if bd.address.leaf:
        without proof =? bd.proof:
          warn "Proof expected for a leaf block delivery"
          continue
        if err =? (
          await self.localStore.putCidAndProof(
            bd.address.treeCid, bd.address.index, bd.blk.cid, proof
          )
        ).errorOption:
          warn "Unable to store proof and cid for a block"
          continue
    except CancelledError:
      trace "Block delivery handling cancelled"
    except CatchableError as exc:
      warn "Error handling block delivery", error = exc.msg
      continue

    validatedBlocksDelivery.add(bd)

    if (Moment.now() - lastIdle) >= runtimeQuota:
      try:
        await idleAsync()
      except CancelledError:
        discard
      except CatchableError:
        discard
      lastIdle = Moment.now()

  codex_block_exchange_blocks_received.inc(validatedBlocksDelivery.len.int64)

  if peerCtx != nil:
    if err =? catch(await self.payForBlocks(peerCtx, blocksDelivery)).errorOption:
      warn "Error paying for blocks", err = err.msg
      return

  if err =? catch(await self.resolveBlocks(validatedBlocksDelivery)).errorOption:
    warn "Error resolving blocks", err = err.msg
    return

proc wantListHandler*(
    self: BlockExcEngine, peer: PeerId, wantList: WantList
) {.async: (raises: []).} =
  trace "Received want list from peer", peer, wantList = wantList.entries.len

  let peerCtx = self.peers.get(peer)

  if peerCtx.isNil:
    return

  var
    presence: seq[BlockPresence]
    schedulePeer = false

  let runtimeQuota = 10.milliseconds
  var lastIdle = Moment.now()

  try:
    for e in wantList.entries:
      logScope:
        peer = peerCtx.id
        address = e.address
        wantType = $e.wantType

      if e.address notin peerCtx.wantedBlocks: # Adding new entry to peer wants
        let
          have =
            try:
              await e.address in self.localStore
            except CatchableError as exc:
              # TODO: should not be necessary once we have proper exception tracking on the BlockStore interface
              false
          price = @(self.pricing.get(Pricing(price: 0.u256)).price.toBytesBE)

        if e.cancel:
          # This is sort of expected if we sent the block to the peer, as we have removed
          # it from the peer's wantlist ourselves.
          trace "Received cancelation for untracked block, skipping",
            address = e.address
          continue

        trace "Processing want list entry", wantList = $e
        case e.wantType
        of WantType.WantHave:
          if have:
            trace "We HAVE the block", address = e.address
            presence.add(
              BlockPresence(
                address: e.address, `type`: BlockPresenceType.Have, price: price
              )
            )
          else:
            trace "We DON'T HAVE the block", address = e.address
            if e.sendDontHave:
              presence.add(
                BlockPresence(
                  address: e.address, `type`: BlockPresenceType.DontHave, price: price
                )
              )

          codex_block_exchange_want_have_lists_received.inc()
        of WantType.WantBlock:
          peerCtx.wantedBlocks.incl(e.address)
          schedulePeer = true
          codex_block_exchange_want_block_lists_received.inc()
      else: # Updating existing entry in peer wants
        # peer doesn't want this block anymore
        if e.cancel:
          trace "Canceling want for block", address = e.address
          peerCtx.wantedBlocks.excl(e.address)
          trace "Canceled block request",
            address = e.address, len = peerCtx.wantedBlocks.len
        else:
          trace "Peer has requested a block more than once", address = e.address
          if e.wantType == WantType.WantBlock:
            schedulePeer = true

      if presence.len >= PresenceBatchSize or (Moment.now() - lastIdle) >= runtimeQuota:
        if presence.len > 0:
          trace "Sending presence batch to remote", items = presence.len
          await self.network.request.sendPresence(peer, presence)
          presence = @[]
        try:
          await idleAsync()
        except CancelledError:
          discard
        lastIdle = Moment.now()

    # Send any remaining presence messages
    if presence.len > 0:
      trace "Sending final presence to remote", items = presence.len
      await self.network.request.sendPresence(peer, presence)

    if schedulePeer:
      self.scheduleTask(peerCtx)
  except CancelledError as exc: #TODO: replace with CancelledError
    warn "Error processing want list", error = exc.msg

proc accountHandler*(
    self: BlockExcEngine, peer: PeerId, account: Account
) {.async: (raises: []).} =
  let context = self.peers.get(peer)
  if context.isNil:
    return

  context.account = account.some

proc paymentHandler*(
    self: BlockExcEngine, peer: PeerId, payment: SignedState
) {.async: (raises: []).} =
  trace "Handling payments", peer

  without context =? self.peers.get(peer).option and account =? context.account:
    trace "No context or account for peer", peer
    return

  if channel =? context.paymentChannel:
    let sender = account.address
    discard self.wallet.acceptPayment(channel, Asset, sender, payment)
  else:
    context.paymentChannel = self.wallet.acceptChannel(payment).option

proc peerAddedHandler*(
    self: BlockExcEngine, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up peer", peer

  if peer notin self.peers:
    let peerCtx = BlockExcPeerCtx(id: peer, activityTimeout: DefaultPeerActivityTimeout)
    trace "Setting up new peer", peer
    self.peers.add(peerCtx)
    trace "Added peer", peers = self.peers.len
    await self.refreshBlockKnowledge(peerCtx)

  if address =? self.pricing .? address:
    trace "Sending account to peer", peer
    await self.network.request.sendAccount(peer, Account(address: address))

proc localLookup(
    self: BlockExcEngine, address: BlockAddress
): Future[?!BlockDelivery] {.async: (raises: [CancelledError]).} =
  if address.leaf:
    (await self.localStore.getBlockAndProof(address.treeCid, address.index)).map(
      (blkAndProof: (Block, CodexProof)) =>
        BlockDelivery(address: address, blk: blkAndProof[0], proof: blkAndProof[1].some)
    )
  else:
    (await self.localStore.getBlock(address)).map(
      (blk: Block) => BlockDelivery(address: address, blk: blk, proof: CodexProof.none)
    )

iterator splitBatches[T](sequence: seq[T], batchSize: int): seq[T] =
  var batch: seq[T]
  for element in sequence:
    if batch.len == batchSize:
      yield batch
      batch = @[]
    batch.add(element)

  if batch.len > 0:
    yield batch

proc taskHandler*(
    self: BlockExcEngine, peerCtx: BlockExcPeerCtx
) {.async: (raises: [CancelledError, RetriesExhaustedError]).} =
  # Send to the peer blocks he wants to get,
  # if they present in our local store

  # Blocks that have been sent have already been picked up by other tasks and
  # should not be re-sent.
  var
    wantedBlocks = peerCtx.wantedBlocks.filterIt(not peerCtx.isBlockSent(it))
    sent: HashSet[BlockAddress]

  trace "Running task for peer", peer = peerCtx.id

  for wantedBlock in wantedBlocks:
    peerCtx.markBlockAsSent(wantedBlock)

  try:
    for batch in wantedBlocks.toSeq.splitBatches(self.maxBlocksPerMessage):
      var blockDeliveries: seq[BlockDelivery]
      for wantedBlock in batch:
        # I/O is blocking so looking up blocks sequentially is fine.
        without blockDelivery =? await self.localLookup(wantedBlock), err:
          error "Error getting block from local store",
            err = err.msg, address = wantedBlock
          peerCtx.markBlockAsNotSent(wantedBlock)
          continue
        blockDeliveries.add(blockDelivery)
        sent.incl(wantedBlock)

      if blockDeliveries.len == 0:
        continue

      await self.network.request.sendBlocksDelivery(peerCtx.id, blockDeliveries)
      codex_block_exchange_blocks_sent.inc(blockDeliveries.len.int64)
      # Drops the batch from the peer's set of wanted blocks; i.e. assumes that after
      # we send the blocks, then the peer no longer wants them, so we don't need to
      # re-send them. Note that the send might still fail down the line and we will
      # have removed those anyway. At that point, we rely on the requester performing
      # a retry for the request to succeed.
      peerCtx.wantedBlocks.keepItIf(it notin sent)
  finally:
    # Better safe than sorry: if an exception does happen, we don't want to keep
    # those as sent, as it'll effectively prevent the blocks from ever being sent again.
    peerCtx.blocksSent.keepItIf(it notin wantedBlocks)

proc blockexcTaskRunner(self: BlockExcEngine) {.async: (raises: []).} =
  ## process tasks
  ##

  trace "Starting blockexc task runner"
  try:
    while self.blockexcRunning:
      let peerCtx = await self.taskQueue.pop()
      await self.taskHandler(peerCtx)
  except CancelledError:
    trace "block exchange task runner cancelled"
  except CatchableError as exc:
    error "error running block exchange task", error = exc.msg

  info "Exiting blockexc task runner"

proc selectRandom*(
    peers: seq[BlockExcPeerCtx]
): BlockExcPeerCtx {.gcsafe, raises: [].} =
  if peers.len == 1:
    return peers[0]

  proc evalPeerScore(peer: BlockExcPeerCtx): float =
    let
      loadPenalty = peer.blocksRequested.len.float * 2.0
      successRate =
        if peer.exchanged > 0:
          peer.exchanged.float / (peer.exchanged + peer.blocksRequested.len).float
        else:
          0.5
      failurePenalty = (1.0 - successRate) * 5.0
    return loadPenalty + failurePenalty

  let
    scores = peers.mapIt(evalPeerScore(it))
    maxScore = scores.max() + 1.0
    weights = scores.mapIt(maxScore - it)

  var totalWeight = 0.0
  for w in weights:
    totalWeight += w

  var r = rand(totalWeight)
  for i, weight in weights:
    r -= weight
    if r <= 0.0:
      return peers[i]

  return peers[^1]

proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    wallet: WalletRef,
    network: BlockExcNetwork,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    peerStore: PeerCtxStore,
    pendingBlocks: PendingBlocksManager,
    maxBlocksPerMessage = DefaultMaxBlocksPerMessage,
    concurrentTasks = DefaultConcurrentTasks,
    selectPeer: PeerSelector = selectRandom,
): BlockExcEngine =
  ## Create new block exchange engine instance
  ##

  let self = BlockExcEngine(
    localStore: localStore,
    peers: peerStore,
    pendingBlocks: pendingBlocks,
    network: network,
    wallet: wallet,
    concurrentTasks: concurrentTasks,
    trackedFutures: TrackedFutures(),
    maxBlocksPerMessage: maxBlocksPerMessage,
    taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize),
    discovery: discovery,
    advertiser: advertiser,
    selectPeer: selectPeer,
  )

  proc blockWantListHandler(
      peer: PeerId, wantList: WantList
  ): Future[void] {.async: (raises: []).} =
    self.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raises: []).} =
    self.blockPresenceHandler(peer, presence)

  proc blocksDeliveryHandler(
      peer: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[void] {.async: (raises: []).} =
    self.blocksDeliveryHandler(peer, blocksDelivery)

  proc accountHandler(
      peer: PeerId, account: Account
  ): Future[void] {.async: (raises: []).} =
    self.accountHandler(peer, account)

  proc paymentHandler(
      peer: PeerId, payment: SignedState
  ): Future[void] {.async: (raises: []).} =
    self.paymentHandler(peer, payment)

  proc peerAddedHandler(
      peer: PeerId
  ): Future[void] {.async: (raises: [CancelledError]).} =
    await self.peerAddedHandler(peer)

  proc peerDepartedHandler(
      peer: PeerId
  ): Future[void] {.async: (raises: [CancelledError]).} =
    self.evictPeer(peer)

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocksDelivery: blocksDeliveryHandler,
    onPresence: blockPresenceHandler,
    onAccount: accountHandler,
    onPayment: paymentHandler,
    onPeerJoined: peerAddedHandler,
    onPeerDeparted: peerDepartedHandler,
  )

  return self
