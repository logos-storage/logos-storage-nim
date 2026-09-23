## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p/cid
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ../network
import ../peers

import ../../utils
import ../../utils/trackedfutures
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../downloadtransport
export downloadtransport

logScope:
  topics = "storage discoveryengine"

declareGauge(storage_inflight_discovery, "inflight discovery requests")

const
  DefaultConcurrentDiscRequests = 10
  DefaultDiscoveryTimeout = 1.minutes

type DiscoveryKey = tuple[cid: Cid, transport: DownloadTransport]

type DiscoveryEngine* = ref object of RootObj
  peers*: PeerContextStore # Peer context store
  networks*: BlockExcNetworks # Protocol instances available for provider dialing
  discovery*: Discovery # Discovery interface
  discEngineRunning*: bool # Indicates if discovery is running
  concurrentDiscReqs: int # Concurrent discovery requests
  discoveryQueue*: AsyncQueue[DiscoveryKey]
  onProviders*: proc(cid: Cid, transport: DownloadTransport, peers: seq[PeerRecord]) {.
    gcsafe, raises: []
  .}
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

      if (await request.withTimeout(DefaultDiscoveryTimeout)) and peers =? await request:
        let network = b.networks.networkFor(key.transport)
        if network.isNil:
          trace "Skipping providers because selected transport is unavailable",
            transport = key.transport
          continue
        let dialed = await allFinished(peers.mapIt(network.dialPeer(it)))
        if not b.onProviders.isNil:
          b.onProviders(cid, key.transport, peers)

        for i, f in dialed:
          if f.failed:
            trace "Failed to dial discovered provider", peer = peers[i].peerId
  except CancelledError:
    trace "Discovery task cancelled"
    return

  info "Exiting discovery task runner"

proc queueFindBlocksReq*(
    b: DiscoveryEngine,
    cids: seq[Cid],
    transport: DownloadTransport = DownloadTransport.Direct,
) =
  for cid in cids:
    let key = (cid, transport)
    if key notin b.discoveryQueue:
      try:
        b.discoveryQueue.putNoWait(key)
      except CatchableError as exc:
        warn "Exception queueing discovery request", exc = exc.msg

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
    peers: PeerContextStore,
    networks: BlockExcNetworks,
    discovery: Discovery,
    concurrentDiscReqs = DefaultConcurrentDiscRequests,
): DiscoveryEngine =
  ## Create a discovery engine instance
  ##
  DiscoveryEngine(
    peers: peers,
    networks: networks,
    discovery: discovery,
    concurrentDiscReqs: concurrentDiscReqs,
    discoveryQueue: newAsyncQueue[DiscoveryKey](concurrentDiscReqs),
    trackedFutures: TrackedFutures.new(),
    inFlightDiscReqs: initTable[DiscoveryKey, Future[?!seq[PeerRecord]]](),
  )
