## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/peerinfo
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ../../utils
import ../../utils/exceptions
import ../../utils/trackedfutures
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../manifest

logScope:
  topics = "storage discoveryengine advertiser"

declareGauge(storage_inflight_advertise, "inflight advertise requests")

const
  DefaultConcurrentAdvertRequests = 10
  DefaultAdvertiseLoopSleep = 30.minutes

type Advertiser* = ref object of RootObj
  localStore*: BlockStore # Local block store for this instance
  discovery*: Discovery # Discovery interface

  advertiserRunning*: bool # Indicates if discovery is running
  concurrentAdvReqs: int # Concurrent advertise requests

  advertiseLocalStoreLoop*: Future[void].Raising([]) # Advertise loop task handle
  advertiseQueue*: AsyncQueue[Cid] # Advertise queue
  trackedFutures*: TrackedFutures # Advertise tasks futures

  advertiseLocalStoreLoopSleep: Duration # Advertise loop sleep
  inFlightAdvReqs*: Table[Cid, Future[void]] # Inflight advertise requests
  addrChanged: AsyncEvent # Fired when the announced addresses change
  peerInfo: PeerInfo

proc addCidToQueue(b: Advertiser, cid: Cid) {.async: (raises: [CancelledError]).} =
  if cid notin b.advertiseQueue:
    await b.advertiseQueue.put(cid)

    trace "Advertising", cid

proc advertiseBlock(b: Advertiser, cid: Cid) {.async: (raises: [CancelledError]).} =
  without isM =? cid.isManifest, err:
    warn "Unable to determine if cid is manifest"
    return

  try:
    if isM:
      # announce manifest cid
      await b.addCidToQueue(cid)
  except CancelledError as exc:
    trace "Cancelled advertise block", cid
    raise exc
  except CatchableError as e:
    error "failed to advertise block", cid, error = e.msgDetail

proc reachable(b: Advertiser): bool =
  b.peerInfo.addrs.len > 0

proc onAddrChange*(b: Advertiser) =
  b.addrChanged.fire()

proc advertiseLocalStoreLoop(b: Advertiser) {.async: (raises: []).} =
  try:
    while b.advertiserRunning:
      b.addrChanged.clear()

      if b.reachable():
        if cidsIter =? await b.localStore.listBlocks(blockType = BlockType.Manifest):
          trace "Advertiser begins iterating blocks..."
          for c in cidsIter:
            if cid =? await c:
              await b.advertiseBlock(cid)
          trace "Advertiser iterating blocks finished."
      else:
        trace "No reachable address yet, skipping advertise sweep"

      discard await b.addrChanged.wait().withTimeout(b.advertiseLocalStoreLoopSleep)
  except CancelledError:
    warn "Cancelled advertise local store loop"

  info "Exiting advertise task loop"

proc processQueueLoop(b: Advertiser) {.async: (raises: []).} =
  try:
    while b.advertiserRunning:
      let cid = await b.advertiseQueue.get()

      if cid in b.inFlightAdvReqs:
        continue

      if not b.reachable():
        continue

      let request = b.discovery.provide(cid)
      b.inFlightAdvReqs[cid] = request
      storage_inflight_advertise.set(b.inFlightAdvReqs.len.int64)

      defer:
        b.inFlightAdvReqs.del(cid)
        storage_inflight_advertise.set(b.inFlightAdvReqs.len.int64)

      await request
  except CancelledError:
    warn "Cancelled advertise task runner"

  info "Exiting advertise task runner"

proc start*(b: Advertiser) {.async: (raises: []).} =
  ## Start the advertiser
  ##

  trace "Advertiser start"

  # The advertiser is expected to be started only once.
  if b.advertiserRunning:
    raiseAssert "Advertiser can only be started once — this should not happen"

  proc onBlock(cid: Cid) {.async: (raises: []).} =
    try:
      await b.advertiseBlock(cid)
    except CancelledError:
      trace "Cancelled advertise block", cid

  doAssert(b.localStore.onBlockStored.isNone())
  b.localStore.onBlockStored = onBlock.some

  b.advertiserRunning = true
  for i in 0 ..< b.concurrentAdvReqs:
    let fut = b.processQueueLoop()
    b.trackedFutures.track(fut)

  b.advertiseLocalStoreLoop = advertiseLocalStoreLoop(b)
  b.trackedFutures.track(b.advertiseLocalStoreLoop)

proc stop*(b: Advertiser) {.async: (raises: []).} =
  ## Stop the advertiser
  ##

  trace "Advertiser stop"
  if not b.advertiserRunning:
    warn "Stopping advertiser without starting it"
    return

  b.advertiserRunning = false
  # Stop incoming tasks from callback and localStore loop
  b.localStore.onBlockStored = CidCallback.none
  trace "Stopping advertise loop and tasks"
  await b.trackedFutures.cancelTracked()
  trace "Advertiser loop and tasks stopped"

proc new*(
    T: type Advertiser,
    localStore: BlockStore,
    discovery: Discovery,
    peerInfo: PeerInfo,
    concurrentAdvReqs = DefaultConcurrentAdvertRequests,
    advertiseLocalStoreLoopSleep = DefaultAdvertiseLoopSleep,
): Advertiser =
  ## Create a advertiser instance
  ##
  Advertiser(
    localStore: localStore,
    discovery: discovery,
    peerInfo: peerInfo,
    concurrentAdvReqs: concurrentAdvReqs,
    advertiseQueue: newAsyncQueue[Cid](concurrentAdvReqs),
    trackedFutures: TrackedFutures.new(),
    inFlightAdvReqs: initTable[Cid, Future[void]](),
    advertiseLocalStoreLoopSleep: advertiseLocalStoreLoopSleep,
    addrChanged: newAsyncEvent(),
  )
