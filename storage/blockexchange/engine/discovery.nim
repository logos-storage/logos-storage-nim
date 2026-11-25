## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronos
import pkg/libp2p/cid
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ../../utils
import ../../utils/trackedfutures
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../downloadtransport
import ./activedownload
export downloadtransport

logScope:
  topics = "storage discoveryengine"

declareGauge(storage_inflight_discovery, "inflight discovery requests")

const
  DefaultConcurrentDiscRequests = 10
  DefaultDiscoveryTimeout = 1.minutes

type
  DiscoveryKey = tuple[cid: Cid, transport: DownloadTransport]

  ProvidersCallback* =
    proc(providers: seq[PeerRecord]) {.async: (raises: [CancelledError]).}

  Subscriber = ref object
    download: ActiveDownload
    callback: ProvidersCallback
    next: int
    delivery: Future[void]
    onDone: CallbackFunc

  SharedLookup = ref object
    key: DiscoveryKey
    batches: seq[seq[PeerRecord]]
    subscribers: Table[uint64, Subscriber]
    request: Future[?!void].Raising([CancelledError])

  DiscoveryEngine* = ref object of RootObj
    discovery*: Discovery
    discEngineRunning*: bool
    concurrentDiscReqs: int
    discoveryQueue*: AsyncQueue[DiscoveryKey]
    lookups: Table[DiscoveryKey, SharedLookup]
    trackedFutures*: TrackedFutures

proc deliver(
    lookup: SharedLookup, subscriber: Subscriber
) {.async: (raises: [CancelledError]).} =
  while subscriber.next < lookup.batches.len and
      not subscriber.download.completionFuture.finished:
    let batch = lookup.batches[subscriber.next]
    inc subscriber.next
    await subscriber.callback(batch)

proc schedule(lookup: SharedLookup, subscriber: Subscriber) =
  if subscriber.delivery.isNil or subscriber.delivery.finished:
    subscriber.delivery = lookup.deliver(subscriber)

proc forget(b: DiscoveryEngine, lookup: SharedLookup) =
  if b.lookups.getOrDefault(lookup.key) == lookup:
    b.lookups.del(lookup.key)

proc runLookup(
    b: DiscoveryEngine, lookup: SharedLookup
) {.async: (raises: [CancelledError]).} =
  let key = lookup.key
  proc receive(batch: seq[PeerRecord]) =
    lookup.batches.add(batch)
    for subscriber in toSeq(lookup.subscribers.values):
      lookup.schedule(subscriber)

  try:
    if b.lookups.getOrDefault(key) != lookup:
      return
    let deadline = Moment.now() + DefaultDiscoveryTimeout
    lookup.request = b.discovery.findBatches(
      key.cid, key.transport == DownloadTransport.Mix, deadline, receive
    )
    try:
      # Waiting on the barrier lets the last subscriber cancel this request
      # without cancelling its queue worker.
      await allFutures(lookup.request).wait(deadline - Moment.now())
      if not lookup.request.cancelled:
        let res = await lookup.request
        if res.isErr:
          debug "Discovery lookup failed", cid = key.cid, error = res.error.msg
    except AsyncTimeoutError:
      debug "Discovery lookup timed out", cid = key.cid
    await lookup.request.cancelAndWait()
    while true:
      var deliveries: seq[Future[void]]
      for subscriber in lookup.subscribers.values:
        if not subscriber.delivery.isNil and not subscriber.delivery.finished:
          deliveries.add(subscriber.delivery)
      if deliveries.len == 0:
        break
      await allFutures(deliveries)
  finally:
    b.forget(lookup)
    if not lookup.request.isNil:
      await noCancel lookup.request.cancelAndWait()
    for subscriber in toSeq(lookup.subscribers.values):
      subscriber.download.completionFuture.removeCallback(subscriber.onDone)
      subscriber.onDone = nil
      if not subscriber.delivery.isNil:
        await noCancel subscriber.delivery.cancelAndWait()
    lookup.subscribers.clear()

proc discoveryTaskLoop(b: DiscoveryEngine) {.async: (raises: []).} =
  try:
    while b.discEngineRunning:
      let key = await b.discoveryQueue.get()
      let lookup = b.lookups.getOrDefault(key)
      if lookup.isNil:
        continue
      storage_inflight_discovery.inc()
      try:
        await b.runLookup(lookup)
      finally:
        storage_inflight_discovery.dec()
  except CancelledError:
    trace "Discovery task cancelled"

func lookupPending*(b: DiscoveryEngine, download: ActiveDownload): bool =
  (download.manifestCid, download.ctx.transport) in b.lookups

proc queueFindBlocksReq*(
    b: DiscoveryEngine, download: ActiveDownload, callback: ProvidersCallback
) =
  if download.cancelled or download.completionFuture.finished:
    return
  let key = (download.manifestCid, download.ctx.transport)
  var lookup = b.lookups.getOrDefault(key)
  if lookup.isNil:
    lookup = SharedLookup(key: key)
    try:
      if key notin b.discoveryQueue:
        b.discoveryQueue.putNoWait(key)
    except CatchableError as exc:
      warn "Exception queueing discovery request", exc = exc.msg
      return
    b.lookups[key] = lookup
  if download.id in lookup.subscribers:
    return
  let subscriber = Subscriber(download: download, callback: callback)
  proc done(data: pointer) =
    if not subscriber.delivery.isNil:
      subscriber.delivery.cancelSoon()
    if lookup.subscribers.values.toSeq.allIt(it.download.completionFuture.finished):
      b.forget(lookup)
      if not lookup.request.isNil:
        lookup.request.cancelSoon()

  subscriber.onDone = done
  download.completionFuture.addCallback(done)
  lookup.subscribers[download.id] = subscriber
  lookup.schedule(subscriber)

proc start*(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Start the discengine task
  ##

  trace "Discovery engine starting"

  if b.discEngineRunning:
    warn "Starting discovery engine twice"
    return

  b.discEngineRunning = true
  for i in 0 ..< b.concurrentDiscReqs:
    let fut = b.discoveryTaskLoop()
    b.trackedFutures.track(fut)

  trace "Discovery engine started"

proc stop*(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Stop the discovery engine
  ##

  trace "Discovery engine stop"
  if not b.discEngineRunning:
    warn "Stopping discovery engine without starting it"
    return

  b.discEngineRunning = false
  trace "Stopping discovery loop and tasks"
  await b.trackedFutures.cancelTracked()
  b.discoveryQueue.clear()
  for lookup in toSeq(b.lookups.values):
    for subscriber in lookup.subscribers.values:
      subscriber.download.completionFuture.removeCallback(subscriber.onDone)
      subscriber.onDone = nil
    lookup.subscribers.clear()
    b.forget(lookup)
  trace "Discovery loop and tasks stopped"

  trace "Discovery engine stopped"

proc new*(
    T: type DiscoveryEngine,
    discovery: Discovery,
    concurrentDiscReqs = DefaultConcurrentDiscRequests,
): DiscoveryEngine =
  ## Create a discovery engine instance
  ##
  DiscoveryEngine(
    discovery: discovery,
    concurrentDiscReqs: concurrentDiscReqs,
    discoveryQueue: newAsyncQueue[DiscoveryKey](concurrentDiscReqs),
    trackedFutures: TrackedFutures.new(),
  )
