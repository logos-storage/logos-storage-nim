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

  DiscoveryEngine* = ref object of RootObj
    discovery*: Discovery # Discovery interface
    discEngineRunning*: bool # Indicates if discovery is running
    concurrentDiscReqs: int # Concurrent discovery requests
    discoveryQueue*: AsyncQueue[DiscoveryKey]
    providersCallbacks*: Table[DiscoveryKey, Table[uint64, ProvidersCallback]]
    trackedFutures*: TrackedFutures # Tracked Discovery tasks futures
    inFlightDiscReqs*: Table[DiscoveryKey, Future[?!seq[PeerRecord]]]

proc discoveryTaskLoop(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Run discovery tasks
  ## Peer availability is tracked per-download in DownloadContext.swarm.
  ## This loop just runs discovery for CIDs that are queued.

  try:
    while b.discEngineRunning:
      let key = await b.discoveryQueue.get()
      let cid = key.cid

      if key in b.inFlightDiscReqs:
        trace "Discovery request already in progress", cid
        continue

      trace "Running discovery task for cid", cid

      let request =
        b.discovery.find(cid, useMix = key.transport == DownloadTransport.Mix)
      b.inFlightDiscReqs[key] = request
      storage_inflight_discovery.set(b.inFlightDiscReqs.len.int64)

      defer:
        b.inFlightDiscReqs.del(key)
        storage_inflight_discovery.set(b.inFlightDiscReqs.len.int64)

      let providers =
        if await request.withTimeout(DefaultDiscoveryTimeout):
          await request
        else:
          debug "Discovery lookup timed out", cid
          seq[PeerRecord].failure("Provider lookup timed out")

      var callbacks: Table[uint64, ProvidersCallback]
      while b.providersCallbacks.pop(key, callbacks):
        if providers.isOk:
          await allFutures(callbacks.values.toSeq.mapIt(it(providers.get())))
  except CancelledError:
    trace "Discovery task cancelled"
    return

  info "Exiting discovery task runner"

func lookupPending*(b: DiscoveryEngine, download: ActiveDownload): bool =
  let key = (download.manifestCid, download.ctx.transport)
  key in b.discoveryQueue or key in b.inFlightDiscReqs

proc queueFindBlocksReq*(
    b: DiscoveryEngine, download: ActiveDownload, callback: ProvidersCallback
) =
  let key = (download.manifestCid, download.ctx.transport)
  if not b.lookupPending(download):
    try:
      b.discoveryQueue.putNoWait(key)
    except CatchableError as exc:
      warn "Exception queueing discovery request", exc = exc.msg
      return

  b.providersCallbacks.mgetOrPut(key, initTable[uint64, ProvidersCallback]())[
    download.id
  ] = callback

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
    inFlightDiscReqs: initTable[DiscoveryKey, Future[?!seq[PeerRecord]]](),
    providersCallbacks: initTable[DiscoveryKey, Table[uint64, ProvidersCallback]](),
  )
