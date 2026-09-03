## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, sets, options, random]

import pkg/chronos
import pkg/libp2p/peerid

import ../peers/peerctxstore
import ../peers/peerstats
import ../types
import ../../logutils
import ./peertracker

export peerctxstore, types, options

randomize()

logScope:
  topics = "logos-storage swarm"

const
  DefaultDeltaMin* = 2
  DefaultDeltaMax* = 16
  DefaultDeltaTarget* = 8
  PeerStaleTimeout* = 30.seconds
  PeerDefaultMaxFailures*: uint32 = 2
  PeerDefaultMaxTimeouts*: uint32 = 5
  ExplorationProbability* = 0.2
  TimeoutPenaltyWeight* = 3.0

type
  SwarmPeer* = ref object
    availability*: BlockAvailability
    lastSeen*: Moment
    availabilityUpdated*: Moment
    failureCount*: uint32
    timeoutCount*: uint32

  SwarmConfig* = object
    deltaMin*: int
    deltaMax*: int
    deltaTarget*: int
    maxPeerFailures*: uint32
    maxPeerTimeouts*: uint32

  SwarmHealth* = enum
    shHealthy
    shBelowTarget
    shBelowMin

  PeerSelectionKind* = enum
    pskFound
    pskAtCapacity
    pskNoPeers

  PeerSelection* = object
    case kind*: PeerSelectionKind
    of pskFound:
      peer*: PeerContext
    of pskAtCapacity, pskNoPeers:
      discard

  Swarm* = ref object
    config*: SwarmConfig
    peers: Table[PeerId, SwarmPeer]
    removedPeers: HashSet[PeerId]

proc new*(T: type SwarmPeer, availability: BlockAvailability): SwarmPeer =
  let now = Moment.now()
  SwarmPeer(
    availability: availability,
    lastSeen: now,
    availabilityUpdated: now,
    failureCount: 0,
    timeoutCount: 0,
  )

proc isStale*(peer: SwarmPeer): bool =
  Moment.now() - peer.lastSeen > PeerStaleTimeout

proc touch*(peer: SwarmPeer) =
  peer.lastSeen = Moment.now()

proc updateAvailability*(peer: SwarmPeer, availability: BlockAvailability) =
  peer.availability = peer.availability.merge(availability)
  peer.availabilityUpdated = Moment.now()
  peer.touch()

proc recordFailure*(peer: SwarmPeer) =
  peer.failureCount += 1

proc recordTimeout*(peer: SwarmPeer) =
  peer.timeoutCount += 1

proc resetFailures*(peer: SwarmPeer) =
  peer.failureCount = 0
  peer.timeoutCount = 0

proc defaultConfig*(_: type SwarmConfig): SwarmConfig =
  SwarmConfig(
    deltaMin: DefaultDeltaMin,
    deltaMax: DefaultDeltaMax,
    deltaTarget: DefaultDeltaTarget,
    maxPeerFailures: PeerDefaultMaxFailures,
    maxPeerTimeouts: PeerDefaultMaxTimeouts,
  )

proc new*(T: type Swarm, config: SwarmConfig = SwarmConfig.defaultConfig()): Swarm =
  Swarm(
    config: config,
    peers: initTable[PeerId, SwarmPeer](),
    removedPeers: initHashSet[PeerId](),
  )

proc addPeer*(swarm: Swarm, peerId: PeerId, availability: BlockAvailability): bool =
  if peerId in swarm.removedPeers:
    return false
  if swarm.peers.len >= swarm.config.deltaMax:
    return false
  swarm.peers[peerId] = SwarmPeer.new(availability)
  true

proc removePeer*(swarm: Swarm, peerId: PeerId): Option[SwarmPeer] =
  swarm.peers.withValue(peerId, peer):
    let res = some(peer[])
    swarm.peers.del(peerId)
    return res
  return none(SwarmPeer)

proc banPeer*(swarm: Swarm, peerId: PeerId) =
  swarm.peers.del(peerId)
  swarm.removedPeers.incl(peerId)

proc getPeer*(swarm: Swarm, peerId: PeerId): Option[SwarmPeer] =
  swarm.peers.withValue(peerId, peer):
    return some(peer[])
  return none(SwarmPeer)

proc updatePeerAvailability*(
    swarm: Swarm, peerId: PeerId, availability: BlockAvailability
) =
  swarm.peers.withValue(peerId, peer):
    peer[].updateAvailability(availability)

proc recordPeerFailure*(swarm: Swarm, peerId: PeerId): bool =
  ## return true if peer should be removed
  swarm.peers.withValue(peerId, peer):
    peer[].recordFailure()
    return peer[].failureCount >= swarm.config.maxPeerFailures
  return false

proc recordPeerTimeout*(swarm: Swarm, peerId: PeerId): bool =
  ## return true if peer should be removed
  swarm.peers.withValue(peerId, peer):
    peer[].recordTimeout()
    return peer[].timeoutCount >= swarm.config.maxPeerTimeouts
  return false

proc recordBatchSuccess*(
    swarm: Swarm, peer: PeerContext, rttMicros: uint64, totalBytes: uint64
) =
  swarm.peers.withValue(peer.id, swarmPeer):
    swarmPeer[].resetFailures()
    swarmPeer[].touch()
  peer.stats.recordRequest(rttMicros, totalBytes)

proc activePeerCount*(swarm: Swarm): int =
  for peer in swarm.peers.values:
    if not peer.isStale:
      result += 1

proc peerCount*(swarm: Swarm): int =
  swarm.peers.len

proc peersNeeded*(swarm: Swarm): SwarmHealth =
  let active = swarm.activePeerCount()
  if active < swarm.config.deltaMin:
    shBelowMin
  elif active < swarm.config.deltaTarget:
    shBelowTarget
  else:
    shHealthy

proc connectedPeers*(swarm: Swarm): seq[PeerId] =
  for peerId in swarm.peers.keys:
    result.add(peerId)

proc peersWithRange*(swarm: Swarm, start: uint64, count: uint64): seq[PeerId] =
  for peerId, peer in swarm.peers:
    if not peer.isStale and peer.availability.hasRange(start, count):
      result.add(peerId)

proc peersWithAnyInRange*(swarm: Swarm, start: uint64, count: uint64): seq[PeerId] =
  for peerId, peer in swarm.peers:
    if not peer.isStale and peer.availability.hasAnyInRange(start, count):
      result.add(peerId)

proc staleUnknownPeers*(swarm: Swarm): seq[PeerId] =
  for peerId, peer in swarm.peers:
    if peer.isStale and peer.availability.kind == bakUnknown:
      result.add(peerId)

proc selectByBDP*(
    peers: seq[PeerContext],
    batchBytes: uint64,
    tracker: PeerInFlightTracker,
    penalties: var Table[PeerId, float],
    explorationProb: float = ExplorationProbability,
): Option[PeerContext] {.gcsafe, raises: [].} =
  if peers.len == 0:
    return none(PeerContext)
  if peers.len == 1:
    return some(peers[0])

  var untriedPeers: seq[PeerContext]
  for peer in peers:
    if peer.stats.throughputBps().isNone:
      let
        pipelineDepth = peer.optimalPipelineDepth(batchBytes)
        currentLoad = tracker.count(peer.id)
      if currentLoad < pipelineDepth:
        untriedPeers.add(peer)

  if untriedPeers.len > 0:
    var
      bestPeer = untriedPeers[0]
      bestLoad = tracker.count(bestPeer.id)
    for i in 1 ..< untriedPeers.len:
      let load = tracker.count(untriedPeers[i].id)
      if load < bestLoad:
        bestLoad = load
        bestPeer = untriedPeers[i]
    return some(bestPeer)

  let exploreRoll = rand(1.0)
  if exploreRoll < explorationProb:
    var peersWithCapacity: seq[PeerContext]
    for peer in peers:
      let
        pipelineDepth = peer.optimalPipelineDepth(batchBytes)
        currentLoad = tracker.count(peer.id)
      if currentLoad < pipelineDepth:
        peersWithCapacity.add(peer)

    if peersWithCapacity.len > 0:
      let idx = rand(peersWithCapacity.len - 1)
      return some(peersWithCapacity[idx])

  var
    bestPeers: seq[PeerContext] = @[peers[0]]
    bestScore = peers[0].evalBDPScore(
      batchBytes, tracker.count(peers[0].id), penalties.getOrDefault(peers[0].id, 0.0)
    )

  for i in 1 ..< peers.len:
    let score = peers[i].evalBDPScore(
      batchBytes, tracker.count(peers[i].id), penalties.getOrDefault(peers[i].id, 0.0)
    )
    if score < bestScore:
      bestScore = score
      bestPeers = @[peers[i]]
    elif score == bestScore:
      bestPeers.add(peers[i])

  if bestPeers.len > 1:
    let idx = rand(bestPeers.len - 1)
    return some(bestPeers[idx])
  else:
    return some(bestPeers[0])

proc selectPeerForBatch*(
    swarm: Swarm,
    peers: PeerContextStore,
    start: uint64,
    count: uint64,
    batchBytes: uint64,
    tracker: PeerInFlightTracker,
): PeerSelection =
  var penalties: Table[PeerId, float]
  for peerId, swarmPeer in swarm.peers:
    if swarmPeer.timeoutCount > 0:
      penalties[peerId] = swarmPeer.timeoutCount.float * TimeoutPenaltyWeight

  let candidates = swarm.peersWithRange(start, count)

  if candidates.len == 0:
    let partialCandidates = swarm.peersWithAnyInRange(start, count)
    trace "No full range peers, checking partial",
      start = start, count = count, partialPeers = partialCandidates.len
    if partialCandidates.len == 0:
      return PeerSelection(kind: pskNoPeers)

    var peerCtxs: seq[PeerContext]
    for peerId in partialCandidates:
      let peer = peers.get(peerId)
      if peer.isNil:
        # peer disconnected, remove from swarm immediately
        discard swarm.removePeer(peerId)
        continue
      if tracker.count(peerId) < peer.optimalPipelineDepth(batchBytes):
        peerCtxs.add(peer)

    if peerCtxs.len == 0:
      return PeerSelection(kind: pskAtCapacity)

    let selected = selectByBDP(peerCtxs, batchBytes, tracker, penalties)
    if selected.isSome:
      return PeerSelection(kind: pskFound, peer: selected.get())
    return PeerSelection(kind: pskNoPeers)

  var peerCtxs: seq[PeerContext]
  for peerId in candidates:
    let peer = peers.get(peerId)
    if peer.isNil:
      # peer disconnected - remove from swarm immediately
      discard swarm.removePeer(peerId)
      continue
    if tracker.count(peerId) < peer.optimalPipelineDepth(batchBytes):
      peerCtxs.add(peer)

  if peerCtxs.len == 0:
    return PeerSelection(kind: pskAtCapacity)

  let selected = selectByBDP(peerCtxs, batchBytes, tracker, penalties)
  if selected.isSome:
    return PeerSelection(kind: pskFound, peer: selected.get())
  return PeerSelection(kind: pskNoPeers)
